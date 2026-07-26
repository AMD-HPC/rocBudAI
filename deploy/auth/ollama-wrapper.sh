#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# /usr/local/bin/ollama — rocBudAI cluster ollama wrapper
#
# This wrapper restricts mutation verbs (pull|rm|push|create|cp) to root
# and the ollama service user (UID 997). The shared /shareddata/Ollama_Models/
# store is a curated cluster artefact — users consume models, admins curate.
#
# All other ollama commands (run, list, show, ps, embed, serve) pass through
# unchanged to /usr/local/bin/ollama-real.
#
# Real binary: /usr/local/bin/ollama-real (same package version, just renamed).
# Bypass: admins can call /usr/local/bin/ollama-real directly via sudo.
# Defence-in-depth: see ollama-proxy.service for HTTP-level enforcement.

set -u

REAL=/usr/local/bin/ollama-real
DENY_VERBS="pull rm push create cp"

# Block list — UIDs other than root (0) and ollama (997) cannot use the
# DENY_VERBS. If the cluster ever adds a "rocbudai-admin" group, replace
# this UID check with a group membership check.
ALLOW_UIDS="0 997"

uid="$(id -u)"

# First positional arg is the verb. If no args, just run the binary
# (it'll print its own help / version).
verb="${1:-}"

is_denied=0
for v in $DENY_VERBS; do
    if [[ "$verb" == "$v" ]]; then
        is_denied=1
        break
    fi
done

if [[ $is_denied -eq 1 ]]; then
    is_allowed=0
    for u in $ALLOW_UIDS; do
        if [[ "$uid" == "$u" ]]; then
            is_allowed=1
            break
        fi
    done

    if [[ $is_allowed -eq 0 ]]; then
        cat >&2 <<EOF
[ollama-wrapper] '$verb' is restricted on this cluster.

The ollama model store at /shareddata/Ollama_Models/ is a curated
artefact — users consume models, admins curate.

Available to you:
  ollama run <model>            inference
  ollama list / show / ps       introspection
  ollama serve                  (admin / systemd)

To request a new model, contact the cluster admin team.
EOF
        exit 1
    fi
fi

exec "$REAL" "$@"
