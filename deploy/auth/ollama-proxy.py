#!/usr/bin/env python3
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
"""ollama-proxy — restrict mutation endpoints on the local ollama API.

Listens on 127.0.0.1:11434 (the historical ollama port — what users and
opencode connect to). Forwards to 127.0.0.1:11435 (the real ollama
daemon — protected by an nftables rule that allows only UIDs 0/997).

Mutation endpoints (/api/pull, /api/delete, /api/create, /api/copy,
/api/push) get a 403 regardless of caller. Inference endpoints
(/api/generate, /api/chat, /api/embed, /api/show, /api/tags, /api/ps,
/api/version, /api/embeddings, /api/blobs/*) are forwarded with full
streaming support.

Admin escape hatch: hit :11435 directly via sudo, e.g.
    sudo OLLAMA_HOST=127.0.0.1:11435 ollama-real pull <model>
"""

import http.client
import http.server
import re
import socketserver
import sys
from urllib.parse import urlsplit

UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 11435
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 11434

DENY_PATHS = (
    "/api/pull",
    "/api/delete",
    "/api/create",
    "/api/copy",
    "/api/push",
)

DENY_BODY = (
    "This endpoint is restricted on this cluster's curated ollama model "
    "store.\nUsers consume models, admins curate. To request a new "
    "model, contact\nthe cluster admin team.\n"
).encode()

# Headers we strip when forwarding (hop-by-hop or rewritten by us).
DROP_HEADERS = {
    "host", "connection", "keep-alive", "transfer-encoding",
    "te", "upgrade", "proxy-authorization", "proxy-authenticate",
}

MAX_REQUEST_BODY = 16 * 1024 * 1024  # 16 MiB; chat requests are <<1 MiB

# Control chars (incl. CR/LF/NUL) never appear in a legitimate forwarded
# request header; presence of one means header injection, so we drop it.
CTL_CHARS = re.compile(r"[\x00-\x1f\x7f]")

# The only request targets we forward: ollama's own namespaces — "/" (health),
# "/api/..." (native) and "/v1/..." (OpenAI-compat, used by the opencode
# provider) — restricted to printable, non-space ASCII ([!-~]) so no control
# char can ride along. A re.fullmatch against this is the request-forgery
# barrier (and a request-smuggling guard).
SAFE_TARGET = re.compile(r"/(?:(?:api|v1)/[!-~]*)?")


def is_denied(path):
    p = urlsplit(path).path
    for d in DENY_PATHS:
        if p == d or p.startswith(d + "/"):
            return True
    return False


def sanitized_target(raw):
    """Validate the client's request target and return the path (+query) to
    forward upstream, or None if it is malformed or addresses a path outside
    ollama's own namespaces.

    The re.fullmatch against SAFE_TARGET is the barrier against request
    forgery: only a value that fully matches (an ollama route, printable
    non-space ASCII) is ever returned, so no control char or foreign path can
    reach the upstream request.
    """
    parts = urlsplit(raw)
    target = parts.path + ("?" + parts.query if parts.query else "")
    if SAFE_TARGET.fullmatch(target):
        return target
    return None


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.0 — no keepalive; client reads to EOF. Avoids needing to
    # re-chunk the upstream's chunked-transfer streaming response.
    protocol_version = "HTTP/1.0"

    def _proxy(self):
        if is_denied(self.path):
            self._reject(403, DENY_BODY)
            return

        target = sanitized_target(self.path)
        if target is None:
            self._reject(400, b"bad request target\n")
            return

        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            n = 0
        if n > MAX_REQUEST_BODY:
            self._reject(413, b"request body too large\n")
            return
        body = self.rfile.read(n) if n > 0 else None

        fwd_headers = {
            k: v for k, v in self.headers.items()
            if k.lower() not in DROP_HEADERS
            and not (CTL_CHARS.search(k) or CTL_CHARS.search(v))
        }
        fwd_headers["Connection"] = "close"

        try:
            conn = http.client.HTTPConnection(
                UPSTREAM_HOST, UPSTREAM_PORT, timeout=None
            )
            conn.request(self.command, target, body=body,
                         headers=fwd_headers)
            resp = conn.getresponse()
        except Exception as e:
            self._reject(502, f"upstream error: {e}\n".encode())
            return

        try:
            self.send_response_only(resp.status, resp.reason or "")
            for k, v in resp.getheaders():
                if k.lower() in DROP_HEADERS:
                    continue
                # Strip CR/LF from the name and value before reflecting the
                # upstream header back: a newline here would let the upstream
                # split our response to the client (response splitting).
                self.send_header(
                    k.replace("\r", "").replace("\n", ""),
                    v.replace("\r", "").replace("\n", ""),
                )
            self.send_header("Connection", "close")
            self.end_headers()

            # Stream the body. read1() returns whatever's available, so
            # streaming endpoints (chat/generate) flush one JSON line at
            # a time instead of buffering up to 64 KiB.
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _reject(self, status, body):
        try:
            self.send_response_only(
                status,
                "Bad Request" if status == 400
                else "Forbidden" if status == 403
                else "Payload Too Large" if status == 413
                else "Bad Gateway"
            )
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        pass

    do_GET = _proxy
    do_POST = _proxy
    do_PUT = _proxy
    do_DELETE = _proxy
    do_HEAD = _proxy
    do_OPTIONS = _proxy
    do_PATCH = _proxy


class ThreadingProxy(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    server = ThreadingProxy((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    print(f"ollama-proxy: listening {LISTEN_HOST}:{LISTEN_PORT} "
          f"-> upstream {UPSTREAM_HOST}:{UPSTREAM_PORT}",
          file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
