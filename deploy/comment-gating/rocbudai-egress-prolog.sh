#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# /shared/share/slurmscripts/prolog.d/rocbudai-egress-prolog.sh
#
# rocBudAI Phase A.2 — per-job user-UID egress block (prolog drop-in).
#
# When a job lands with `ollama` in its `--comment`, install a per-job nft
# chain `job_<SLURM_JOB_ID>` in the boot-loaded `inet rocbudai_user_egress`
# table (see deploy/airgap/rocbudai-user-egress.{service,nft}). The chain
# allows loopback, DNS to the host's configured nameservers, and RFC1918,
# then REJECTs everything else; a UID-matched jump rule scopes it to the
# job user. The matching epilog drop-in (rocbudai-egress-epilog.sh) removes
# the chain at job end.
#
# Failure semantics: fail-CLOSED. Any setup error exits non-zero (aborts
# the job) so a user is never silently left without the egress block.
#
# Portability: the allowed DNS servers are read from /etc/resolv.conf, so
# there is no site-specific IP baked into this script. Override the DNS
# allow-list with ROCBUDAI_EGRESS_DNS (space/comma-separated IPs) if your
# resolver does not live in /etc/resolv.conf (e.g. systemd-resolved stub).

set -u

log() { logger -t "rocbudai-egress-prolog" "$*"; echo "[rocbudai-egress-prolog] $*" >&2; }

job_comment="${SLURM_JOB_COMMENT:-}"
if [[ "$job_comment" != *ollama* ]]; then
    exit 0
fi

job_id="${SLURM_JOB_ID:-}"
job_user="${SLURM_JOB_USER:-}"
if [[ -z "$job_id" || -z "$job_user" ]]; then
    log "missing SLURM_JOB_ID/USER, skipping"
    exit 0
fi

# Resolve the job user's UID; fail closed on anything unexpected.
user_uid="${SLURM_JOB_UID:-}"
if [[ -z "$user_uid" ]]; then
    user_uid="$(getent passwd "$job_user" | cut -d: -f3 || true)"
fi
if [[ -z "$user_uid" || ! "$user_uid" =~ ^[0-9]+$ ]]; then
    log "cannot resolve UID for $job_user (job $job_id), failing closed"
    exit 1
fi
if [[ "$user_uid" -lt 1000 ]]; then
    log "refusing to install on system UID $user_uid (job $job_id, user $job_user), failing closed"
    exit 1
fi

if ! /usr/sbin/nft list table inet rocbudai_user_egress >/dev/null 2>&1; then
    log "table not loaded — is rocbudai-user-egress.service active? failing closed for job $job_id"
    exit 1
fi

# Allowed DNS servers: explicit override, else /etc/resolv.conf nameservers.
dns_servers=()
if [[ -n "${ROCBUDAI_EGRESS_DNS:-}" ]]; then
    IFS=', ' read -ra dns_servers <<< "${ROCBUDAI_EGRESS_DNS}"
elif [[ -r /etc/resolv.conf ]]; then
    while read -r _kw ip _rest; do
        [[ "$_kw" == "nameserver" && -n "$ip" ]] && dns_servers+=("$ip")
    done < /etc/resolv.conf
fi

chain_name="job_${job_id}"
# Flush a stale chain from a killed/crashed prior prolog for this job id.
if /usr/sbin/nft list chain inet rocbudai_user_egress "$chain_name" >/dev/null 2>&1; then
    log "chain $chain_name already exists, flushing"
    while read -r h; do
        /usr/sbin/nft delete rule inet rocbudai_user_egress output handle "$h" 2>/dev/null || true
    done < <(/usr/sbin/nft -a list chain inet rocbudai_user_egress output 2>/dev/null \
                | awk -v t="jump $chain_name" '$0 ~ t {print $NF}')
    /usr/sbin/nft delete chain inet rocbudai_user_egress "$chain_name" 2>/dev/null || true
fi

log "installing block job=$job_id user=$job_user uid=$user_uid dns=${dns_servers[*]:-<none>}"
{
    echo "add chain inet rocbudai_user_egress $chain_name"
    echo "add rule inet rocbudai_user_egress $chain_name oif \"lo\" accept"
    for ip in "${dns_servers[@]:-}"; do
        [[ -z "$ip" ]] && continue
        echo "add rule inet rocbudai_user_egress $chain_name ip daddr $ip udp dport 53 accept"
        echo "add rule inet rocbudai_user_egress $chain_name ip daddr $ip tcp dport 53 accept"
    done
    echo "add rule inet rocbudai_user_egress $chain_name ip daddr 10.0.0.0/8 accept"
    echo "add rule inet rocbudai_user_egress $chain_name ip daddr 172.16.0.0/12 accept"
    echo "add rule inet rocbudai_user_egress $chain_name ip daddr 192.168.0.0/16 accept"
    echo "add rule inet rocbudai_user_egress $chain_name reject with icmpx type admin-prohibited"
    echo "insert rule inet rocbudai_user_egress output meta skuid $user_uid jump $chain_name"
} | /usr/sbin/nft -f - 2>&1 | while read -r line; do log "nft: $line"; done

if ! /usr/sbin/nft list chain inet rocbudai_user_egress "$chain_name" >/dev/null 2>&1; then
    log "post-apply check failed for job $job_id, failing closed"
    exit 1
fi
log "ok for job $job_id (user $job_user uid $user_uid)"
exit 0
