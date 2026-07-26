# Daemon gating via `--comment=ollama`

Source artefacts that tie the ollama daemon's lifetime to a Slurm
allocation. With these in place, ollama runs only on nodes whose
current job specified `--comment=ollama`; idle nodes have no daemon
running.

The base `ollama.service` itself (the unit these scripts start/stop)
lives in `deploy/ollama-daemon/`. The matching cluster-wide airgap
hardening lives in `deploy/airgap/`. The 5-layer auth story lives in
`deploy/auth/`.

## Files in this directory

The `/shared/share/slurmscripts` prolog/epilog root below is the reference-cluster
default; override it with `SLURMSCRIPTS_DIR` in `site.conf` and `install.sh`
installs the drop-ins under `${SLURMSCRIPTS_DIR}/{prolog.d,epilog.d}` instead.

| File | Where it goes when promoted | Purpose |
|---|---|---|
| `job_submit.lua` | `/etc/slurm/job_submit.lua` (login node only; one file replaces the existing one) | Adds Rule 2: `--comment=ollama` requires `--exclusive` and an SPX-only partition. Mismatched allocations are rejected at submit time. |
| `rocbudai-ollama-prolog.sh` | `/shared/share/slurmscripts/prolog.d/rocbudai-ollama-prolog.sh` (cluster-wide; one copy via NFS; mode 755 root:root) | Runs at job start. If `ollama` ∈ comment tokens: starts `ollama.service` + `ollama-proxy.service`, waits up to 10 s for proxy readiness, pre-warms the default `qwen3.5:122b` via `systemd-run --no-block`. Fail-open. |
| `rocbudai-ollama-epilog.sh` | `/shared/share/slurmscripts/epilog.d/rocbudai-ollama-epilog.sh` (cluster-wide; one copy via NFS; mode 755 root:root) | Runs at job end. If `ollama` ∈ comment tokens: posts `keep_alive:0` to release VRAM, stops proxy, stops daemon. Best-effort. |
| `rocbudai-egress-prolog.sh` | `/shared/share/slurmscripts/prolog.d/rocbudai-egress-prolog.sh` (cluster-wide; one copy via NFS; mode 755 root:root) | Runs at job start. If `ollama` ∈ comment tokens: installs a per-job nft chain in the `inet rocbudai_user_egress` table (see `deploy/airgap/`) allowing loopback + DNS (read from `/etc/resolv.conf`) + RFC1918 and REJECTing all other egress from the job user's UID. Fail-closed. |
| `rocbudai-egress-epilog.sh` | `/shared/share/slurmscripts/epilog.d/rocbudai-egress-epilog.sh` (cluster-wide; one copy via NFS; mode 755 root:root) | Runs at job end. Removes the per-job nft chain installed by the egress prolog drop-in; also cleans up orphans from a crashed prolog. Best-effort. |

rocBudAI does **not** ship a prolog/epilog "monolith" — every site has its
own. The four drop-ins above plus `job_submit.lua` are the entire supported
integration surface; you wire them into your site's prolog/epilog via the
dispatch blocks below.

## Wiring the drop-ins into your cluster's prolog / epilog

Slurm's `Prolog=` / `Epilog=` point at your site's prolog/epilog scripts.
Drop-ins under `prolog.d/` and `epilog.d/` are NOT auto-discovered — your
prolog/epilog must dispatch to them explicitly.

Add these dispatch blocks. In your **prolog**, near the top (before other
`--comment`-dependent logic):

```bash
# Daemon gating — fail-OPEN (a daemon-start failure must not block the job):
if [[ -x /shared/share/slurmscripts/prolog.d/rocbudai-ollama-prolog.sh ]]; then
    /shared/share/slurmscripts/prolog.d/rocbudai-ollama-prolog.sh || \
        logger "prolog: rocbudai-ollama-prolog.sh exited rc=$? (non-fatal)"
fi
# User-UID egress block — fail-CLOSED (abort the job if it can't install):
if [[ -x /shared/share/slurmscripts/prolog.d/rocbudai-egress-prolog.sh ]]; then
    /shared/share/slurmscripts/prolog.d/rocbudai-egress-prolog.sh || exit $?
fi
```

In your **epilog**, the symmetric teardown (both best-effort):

```bash
if [[ -x /shared/share/slurmscripts/epilog.d/rocbudai-ollama-epilog.sh ]]; then
    /shared/share/slurmscripts/epilog.d/rocbudai-ollama-epilog.sh || \
        logger "epilog: rocbudai-ollama-epilog.sh exited rc=$? (non-fatal)"
fi
if [[ -x /shared/share/slurmscripts/epilog.d/rocbudai-egress-epilog.sh ]]; then
    /shared/share/slurmscripts/epilog.d/rocbudai-egress-epilog.sh || \
        logger "epilog: rocbudai-egress-epilog.sh exited rc=$? (non-fatal)"
fi
```

Note the asymmetry: the **daemon-gating** drop-ins are fail-OPEN
(`|| logger …`) — a daemon-start failure must not block the user's job —
while the **egress** prolog drop-in is fail-CLOSED (`|| exit $?`) so a
job never runs without its egress block.

## Promotion checklist

Short version:

1. **Stage and review the drop-ins**: copy
   `rocbudai-{ollama,egress}-{prolog,epilog}.sh` to the cluster's NFS
   `prolog.d/` / `epilog.d/` paths; `chmod 755`; `chown root:root`.
2. **Add dispatch blocks** to your site's prolog / epilog (back up
   first). Test on one node with a real `salloc --comment=ollama`
   allocation; verify with `journalctl -t rocbudai-ollama-prolog` and
   `-t rocbudai-egress-prolog`.
3. **Deploy `job_submit.lua`** on the login node (review the SITE CONFIG
   partition allow-list at the top first); `scontrol reconfigure`.
4. **Disable ollama at boot** on each GPU node and the chroot:
   `sudo systemctl disable ollama` (do NOT `--now`; the prolog will
   start it on the next allocation).
5. **End-to-end test** as a regular user: `salloc -p <spx-partition>
   --exclusive --comment=ollama`; verify ollama+proxy come up
   (`systemctl is-active ollama ollama-proxy`); load module; run a
   prompt; `/exit`; verify both stop on epilog. Also verify the
   user-UID egress chain: from inside the job,
   `curl https://huggingface.co/` should be rejected at the firewall;
   after `scancel`, `sudo nft list table inet rocbudai_user_egress`
   should show the per-job chain torn down.

## Slurm comment grammar

Recognised tokens today:

- `ollama`         — required for any rocBudAI job; node-wide ollama daemon + 4-GPU model.
                     Always inherits the cluster-wide airgap baseline (see `deploy/airgap/`).
- `cpx` / `tpx`    — orthogonal; rocm-smi GPU-mode change. Pre-existing rule.

The parser (`comment_has_token` in `job_submit.lua`) accepts a
comma- and/or whitespace-separated list of lowercased tokens. A
previously-supported `confidential` token has been removed; its
function is now subsumed by the always-on airgap baseline at
`deploy/airgap/` (which blocks both the `ollama` UID always and
the user UID per-job).

## Knobs

- `ROCBUDAI_PREWARM_MODEL` (default `qwen3.5:122b`) — model name posted
  to `/api/generate` in the prolog pre-warm and the epilog unload.
  Exportable via `/etc/default/rocbudai-ollama` if you ever need to
  override per-node — Slurm prolog scripts don't source that today,
  but adding `[ -f /etc/default/rocbudai-ollama ] && . /etc/default/rocbudai-ollama`
  near the top of each drop-in is a one-line change.
- `ROCBUDAI_PROXY_URL` (default `http://127.0.0.1:11434`) — same story.
  Useful if the loopback port changes or you skip the
  `deploy/auth/` Python proxy.
