# Ollama authorization hardening

Source artefacts for the 5-layer ollama lockdown. Goal: keep
inference open to all allocated users (`list`, `show`, `ps`, `run`)
while restricting mutation (`pull`, `rm`, `push`, `create`, `cp`) to
admins.

The base `ollama.service` (loopback bind on `:11435` — layer 1 of
the 5-layer story) lives in `deploy/ollama-daemon/`. The matching
daemon-gating story lives in `deploy/comment-gating/`; the airgap
baseline lives in `deploy/airgap/`.

## The 5 layers

| # | Mechanism | What it stops | File(s) |
|---|---|---|---|
| 1 | **Bind**  | Daemon on `127.0.0.1:11435` — no cross-node API access. | `deploy/ollama-daemon/ollama.service` (`OLLAMA_HOST=127.0.0.1:11435`) |
| 2 | **ACL**   | nft `inet ollama_acl` table — owner-match: only `root` (UID 0) and `ollama` (UID 997) can reach the raw daemon on `:11435`. | `ollama-acl.nft`, `ollama-acl.service` |
| 3 | **Proxy** | Python reverse-proxy on `127.0.0.1:11434` — forwards reads, returns `403` on mutate endpoints (`/api/{pull,delete,push,create,copy}`). All users go through this. | `ollama-proxy.py`, `ollama-proxy.service` |
| 4 | **CLI**   | `/usr/local/bin/ollama` wrapper — rejects mutate verbs from non-root users at the shell layer (defence in depth; the wrapper points at `:11434` so it's also subject to layer 3). | `ollama-wrapper.sh` |
| 5 | **Mode**  | `/shareddata/Ollama_Models/` is `2755` `ollama:ollama` — group-writable bypass blocked at the filesystem layer. | (no file in this dir; `chmod 2755` on the model store at install) |

## Files in this directory

| File | Where it goes when promoted | Purpose |
|---|---|---|
| `ollama-acl.nft` | `/etc/nftables.d/ollama-acl.nft` (each compute node + chroot) | Layer 2: nft `inet ollama_acl` table. UID 0 and 997 → `accept`; everyone else → `reject` on tcp dport 11435. |
| `ollama-acl.service` | `/etc/systemd/system/ollama-acl.service` (each node + chroot) | Loads the `.nft` file at boot, after `nftables.service`. |
| `ollama-proxy.py` | `/usr/local/bin/ollama-proxy` (each node + chroot; mode 755 root:root) | Layer 3: Python reverse-proxy. Listens on `127.0.0.1:11434`, forwards reads to `127.0.0.1:11435`, returns `403 {"error": "..."}` on mutate endpoints. |
| `ollama-proxy.service` | `/etc/systemd/system/ollama-proxy.service` (each node + chroot) | systemd unit for the proxy. Started by the prolog when `--comment=ollama` is set (see `deploy/comment-gating/`); stopped by the epilog. |
| `ollama-wrapper.sh` | `/usr/local/bin/ollama` (each node + chroot; mode 755 root:root) | Layer 4: CLI wrapper. Inspects `$1`; for mutate verbs and non-root caller, prints "permission denied: ask an admin" and exits 1. The real binary lives at `/usr/local/bin/ollama-real` (rename during install). |

## Promotion checklist

Short version:

1. **Stage `ollama-real`**: `sudo mv /usr/local/bin/ollama /usr/local/bin/ollama-real` on one compute node.
2. **Drop `ollama-wrapper.sh`** at `/usr/local/bin/ollama`; `chmod 755 root:root`.
3. **Drop `ollama-proxy.py`** at `/usr/local/bin/ollama-proxy`; `chmod 755 root:root`.
4. **Drop both `.service` files** at `/etc/systemd/system/`;
   `sudo systemctl daemon-reload && sudo systemctl enable ollama-acl.service`.
   (`ollama-proxy.service` is started by the prolog, not enabled.)
5. **Drop `ollama-acl.nft`** at `/etc/nftables.d/` and reload via the service.
6. **Mode the model store**: `sudo install -d -m 2755 -o ollama -g ollama /shareddata/Ollama_Models` (idempotent).
7. **End-to-end test** as a non-admin user:
   - `ollama list` → works (layer 3 forwards reads).
   - `ollama pull foo` → "permission denied" from layer 4.
   - `curl -X POST http://127.0.0.1:11434/api/pull -d '{"name":"foo"}'` → `403` from layer 3.
   - `curl http://127.0.0.1:11435/api/version` → REJECTed by layer 2.
8. **Replicate** to all SPX nodes + the Warewulf chroot.

## Defence-in-depth rationale

Each layer is meant to stop a different class of bypass:

- Layer 1 alone is not enough — anyone on the same node can `curl 127.0.0.1:11435`.
- Layer 2 alone is not enough — a process running as the `ollama` UID could still mutate (and the proxy itself runs as root and forwards to `:11435`, so we couldn't drop the ACL even if we wanted to).
- Layer 3 alone is not enough — a determined user could `curl 127.0.0.1:11435` directly.
- Layer 4 alone is not enough — it's a shell wrapper; bypassed by anyone using `curl` directly or invoking `/usr/local/bin/ollama-real`.
- Layer 5 catches the FS-level bypass (group `ollama` no longer writeable from outside the daemon).

Stacked, they require an attacker to (a) spoof a UID-in-allow-list, (b)
bypass the proxy on `:11434`, AND (c) write directly to the model
store as `ollama` — three independent bypasses for a single mutation.
