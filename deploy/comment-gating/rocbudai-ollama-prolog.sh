#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# /shared/share/slurmscripts/prolog.d/rocbudai-ollama-prolog.sh
#
# rocBudAI Phase-4 — ollama daemon-gating prolog drop-in.
#
# Runs as part of the cluster's prolog.d chain whenever a job lands on a
# compute node. We act ONLY when the user passed `ollama` as one of the
# comma-separated tokens in their `--comment` string (which
# `job_submit.lua` Rule 2 has already validated comes with `--exclusive`
# on an SPX-only partition).
#
# What this script does:
#   1. Start ollama.service and ollama-proxy.service via systemctl.
#   2. Wait up to 10 s for the proxy on :11434 to respond to /api/version.
#   3. Pre-warm the canonical model (qwen3.5:122b) in the background via
#      `systemd-run --no-block` so the user's first prompt doesn't pay
#      the ~10-min cold-load (NFS → host RAM → VRAM, dominated by the
#      first forward pass).
#
# The matching epilog drop-in
# (`/shared/share/slurmscripts/epilog.d/rocbudai-ollama-epilog.sh`)
# unloads the model from VRAM and stops both services at job end.
#
# Slurm sets these env vars in prolog.d scripts:
#   SLURM_JOB_ID, SLURM_JOB_USER, SLURM_JOB_UID, SLURM_JOB_COMMENT,
#   SLURM_JOB_ACCOUNT, SLURM_JOB_PARTITION
#
# Failure semantics: fail-OPEN. A start failure is logged but does NOT
# kill the job — the user can still run their workload, they just won't
# have the LLM.
#
# systemd-run is REQUIRED for the pre-warm: PrologFlags=Contain places
# this script in a cgroup and waits for all children. Backgrounding with
# `&` does NOT escape the cgroup (the prolog blocks until the curl
# finishes). `systemd-run --no-block` runs the curl in a fresh transient
# scope outside the prolog cgroup — the prolog returns immediately and
# the pre-warm continues asynchronously.

set -u

LOG_TAG="[rocbudai-ollama-prolog]"
log() { logger -t "rocbudai-ollama-prolog" "$*"; echo "$LOG_TAG $*" >&2; }

# Canonical model name. Must match `setenv("ROCBUDAI_MODEL", …)` in
# modulefiles/rocbudai/dev.lua. The prolog runs as root before the
# user's environment is set up, so we can't read ROCBUDAI_MODEL here;
# keep this string in sync if the canonical model changes.
ROCBUDAI_PREWARM_MODEL="${ROCBUDAI_PREWARM_MODEL:-qwen3.5:122b}"

# Proxy URL (loopback). Phase 3.5 binds the daemon to 127.0.0.1:11435
# and the Python proxy to 127.0.0.1:11434; that's what users hit.
ROCBUDAI_PROXY_URL="${ROCBUDAI_PROXY_URL:-http://127.0.0.1:11434}"

# 1. Gate on the comment ----------------------------------------------------

job_id="${SLURM_JOB_ID:-}"
job_user="${SLURM_JOB_USER:-}"

# Resolve the comment via scontrol (authoritative); Slurm does not reliably
# export SLURM_JOB_COMMENT into the prolog/epilog env across versions, so
# trusting the env var alone silently skips gating. Mirrors how
# rocbudai-tui / -doctor / -airgap-check resolve it.
job_comment=""
if command -v scontrol >/dev/null 2>&1; then
    job_comment="$(scontrol show job "$job_id" -o 2>/dev/null \
        | grep -oE 'Comment=[^[:space:]]+' | head -1 | sed 's/^Comment=//')"
    [[ "$job_comment" == "(null)" ]] && job_comment=""
fi
job_comment="${job_comment:-${SLURM_JOB_COMMENT:-}}"

if [[ "$job_comment" != *ollama* ]]; then
    exit 0
fi

# 2. Start ollama + proxy ---------------------------------------------------
#
# systemctl start is idempotent. We log warnings rather than exit non-zero
# so a partial start (e.g. proxy up but daemon failed) still lets the job
# proceed; the pre-warm step below self-checks daemon health.

log "starting ollama daemon + proxy for job ${job_id} on $(hostname)"
systemctl start ollama        2>/dev/null || log "WARN: failed to start ollama.service"
systemctl start ollama-proxy  2>/dev/null || log "WARN: failed to start ollama-proxy.service"

# 3. Wait for proxy readiness (up to 10 s) ----------------------------------

ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -m 1 "${ROCBUDAI_PROXY_URL}/api/version" >/dev/null 2>&1; then
        log "ollama+proxy ready after ${i}s on $(hostname)"
        ready=1
        break
    fi
    sleep 1
done
if [[ $ready -eq 0 ]]; then
    log "WARN: ollama+proxy not ready after 10s on $(hostname)"
fi

# 4. Pre-warm in the background --------------------------------------------

if systemctl is-active --quiet ollama 2>/dev/null; then
    log "pre-warming ${ROCBUDAI_PREWARM_MODEL} for ${job_user} on $(hostname)"
    systemd-run --no-block --quiet --unit="ollama-prewarm-${job_id}" \
        curl -s -m 600 "${ROCBUDAI_PROXY_URL}/api/generate" \
        -d "{\"model\":\"${ROCBUDAI_PREWARM_MODEL}\",\"prompt\":\"\",\"keep_alive\":\"4h\"}" \
        || true
else
    log "ollama.service not active after start attempt; skipping pre-warm"
fi

exit 0
