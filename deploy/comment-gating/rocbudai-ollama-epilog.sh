#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# /shared/share/slurmscripts/epilog.d/rocbudai-ollama-epilog.sh
#
# rocBudAI Phase-4 — ollama daemon-gating epilog drop-in.
#
# Companion to /shared/share/slurmscripts/prolog.d/rocbudai-ollama-prolog.sh.
# Acts ONLY when the job's `--comment` string contained the `ollama`
# token. Tears down what the prolog drop-in set up.
#
# What this script does:
#   1. POST `keep_alive:0` to the proxy to release the model from VRAM.
#      We do this BEFORE stopping the daemon — reversing the order
#      strands the model in VRAM until OOM-kill on the next pre-warm.
#   2. Stop ollama-proxy.service (so no new requests can arrive).
#   3. Stop ollama.service.
#
# Slurm sets the same env vars as in prolog.d scripts:
#   SLURM_JOB_ID, SLURM_JOB_USER, SLURM_JOB_UID, SLURM_JOB_COMMENT,
#   SLURM_JOB_ACCOUNT, SLURM_JOB_PARTITION
#
# Failure semantics: fail-OPEN, best-effort. If the daemon already
# crashed (e.g., the user's job OOM'd it) the unload step is a no-op
# and the stops are idempotent. The epilog never blocks the next job.

set -u

LOG_TAG="[rocbudai-ollama-epilog]"
log() { logger -t "rocbudai-ollama-epilog" "$*"; echo "$LOG_TAG $*" >&2; }

ROCBUDAI_PREWARM_MODEL="${ROCBUDAI_PREWARM_MODEL:-qwen3.5:122b}"
ROCBUDAI_PROXY_URL="${ROCBUDAI_PROXY_URL:-http://127.0.0.1:11434}"

# 1. Gate on the comment ----------------------------------------------------

job_id="${SLURM_JOB_ID:-}"
job_comment="${SLURM_JOB_COMMENT:-}"

if [[ "$job_comment" != *ollama* ]]; then
    exit 0
fi

# 2. Unload the model from VRAM (only if daemon still running) -------------

if systemctl is-active --quiet ollama 2>/dev/null; then
    log "unloading ${ROCBUDAI_PREWARM_MODEL} on $(hostname) for job ${job_id}"
    curl -s -m 30 "${ROCBUDAI_PROXY_URL}/api/generate" \
        -d "{\"model\":\"${ROCBUDAI_PREWARM_MODEL}\",\"keep_alive\":0}" \
        >/dev/null 2>&1 || true
fi

# 3. Stop proxy first, then daemon -----------------------------------------

log "stopping ollama-proxy + ollama after job ${job_id} on $(hostname)"
systemctl stop ollama-proxy 2>/dev/null || true
systemctl stop ollama       2>/dev/null || true

exit 0
