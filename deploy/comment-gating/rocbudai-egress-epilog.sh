#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# /shared/share/slurmscripts/epilog.d/rocbudai-egress-epilog.sh
#
# rocBudAI Phase A.2 — tear down the per-job user-UID egress block.
#
# Companion to rocbudai-egress-prolog.sh. Removes the UID-matched jump
# rule in the `inet rocbudai_user_egress` table's output chain, then
# deletes the per-job chain `job_<SLURM_JOB_ID>`.
#
# Failure semantics: best-effort. Failures are logged but never propagate
# (a stale chain is non-blocking; an admin can flush it later). Always
# runs regardless of --comment so that orphans left by a killed/crashed
# prolog also get cleaned up.

set -u

log() { logger -t "rocbudai-egress-epilog" "$*"; echo "[rocbudai-egress-epilog] $*" >&2; }

job_id="${SLURM_JOB_ID:-}"
[[ -z "$job_id" ]] && exit 0

chain_name="job_${job_id}"
if ! /usr/sbin/nft list chain inet rocbudai_user_egress "$chain_name" >/dev/null 2>&1; then
    exit 0
fi

log "removing block job=$job_id chain=$chain_name"
while read -r h; do
    [[ -z "$h" ]] && continue
    /usr/sbin/nft delete rule inet rocbudai_user_egress output handle "$h" 2>/dev/null \
        | while read -r line; do log "nft(jump): $line"; done
done < <(/usr/sbin/nft -a list chain inet rocbudai_user_egress output 2>/dev/null \
            | awk -v t="jump $chain_name" '$0 ~ t {print $NF}')

/usr/sbin/nft delete chain inet rocbudai_user_egress "$chain_name" 2>&1 \
    | while read -r line; do log "nft(chain): $line"; done

if /usr/sbin/nft list chain inet rocbudai_user_egress "$chain_name" >/dev/null 2>&1; then
    log "WARN chain $chain_name still present after teardown"
else
    log "ok teardown for job $job_id"
fi
exit 0
