# Airgap baseline

Source artefacts that stop the ollama daemon, opencode, AND the user's
own commands from reaching the internet while a `--comment=ollama`
allocation is running. Four pieces:

1. A managed `/etc/opencode/opencode.json` that pins `share:"disabled"`
   and 14 disabled cloud providers (overrides any project-local config).
2. `OPENCODE_DISABLE_{AUTOUPDATE,LSP_DOWNLOAD,MODELS_FETCH,
   EXTERNAL_SKILLS,SHARE}=1` set by the modulefile — suppresses every
   known opencode phone-home call site.
3. `OLLAMA_NOPRUNE=1` + `OLLAMA_NO_CLOUD=1` in the systemd unit
   (lives in `deploy/ollama-daemon/ollama.service`, NOT here — the
   env vars are part of the base unit, not a separate file).
4. Two kernel-firewall egress blocks (nft owner-match):
   - **always-on** — `ollama-egress.service` rejects external traffic
     from the `ollama` UID at boot.
   - **per-job** — `rocbudai-user-egress.service` loads a skeleton
     table at boot; the Slurm prolog/epilog (see
     `/shared/share/slurmscripts/{prolog,epilog}/`) extends it with a
     per-job chain that rejects external traffic from the **user UID**
     for the duration of every `--comment=ollama` allocation and
     removes it on epilog.

## Files in this directory

| File | Where it goes when promoted | Purpose |
|---|---|---|
| `opencode-managed.json` | `/etc/opencode/opencode.json` (each compute node + the Warewulf chroot) | Site-managed opencode config. Pins `share:"disabled"`, 14 disabled cloud providers. Overrides any project-local `opencode.json` (verified live with `opencode debug config` by `rocbudai-airgap-check` section 3c). |
| `ollama-egress.nft` | `/etc/nftables.d/ollama-egress.nft` (each compute node + chroot) | nft owner-match table `inet ollama_egress`: rejects external traffic from the `ollama` UID, allows loopback / DNS / RFC1918. Loaded at boot by `ollama-egress.service`. |
| `ollama-egress.service` | `/etc/systemd/system/ollama-egress.service` (each compute node + chroot) | systemd unit that loads the .nft file at boot, after `nftables.service`. |
| `rocbudai-user-egress.nft` | `/etc/nftables.d/rocbudai-user-egress.nft` (each compute node + chroot) | nft skeleton table `inet rocbudai_user_egress` with an empty `output` chain. The Slurm prolog adds a `job_$JOBID` jump rule scoped to the user's UID; the epilog removes it. Loaded at boot by `rocbudai-user-egress.service`. |
| `rocbudai-user-egress.service` | `/etc/systemd/system/rocbudai-user-egress.service` (each compute node + chroot) | systemd unit that loads `rocbudai-user-egress.nft` at boot, after `nftables.service`. |

## Companion documentation

Design rationale, the model-pull-and-relock procedure (how an admin
pulls a new model after the cluster is airgapped), and the
end-to-end `gemma4:12b` proof-of-life live in
`docs/airgap-and-model-pulls.md`.

## Promotion checklist

Short version:

1. **Drop `opencode-managed.json`** at `/etc/opencode/opencode.json`
   on one compute node; verify `opencode debug config` shows it as
   the active config (overrides any project-local one).
2. **Replicate to all SPX nodes** + the Warewulf chroot.
3. **Drop `ollama-egress.nft`** at `/etc/nftables.d/` on one node;
   `sudo nft -f /etc/nftables.d/ollama-egress.nft`; verify the table
   is loaded (`sudo nft list table inet ollama_egress`).
4. **Drop `ollama-egress.service`** at `/etc/systemd/system/`;
   `sudo systemctl daemon-reload && sudo systemctl enable --now ollama-egress.service`.
5. **End-to-end test**: as `ollama` UID, `curl https://huggingface.co`
   should return REJECTed (`admin-prohibited`); `curl http://127.0.0.1:11434/api/version`
   should still work; `curl http://10.x.x.x` (an RFC1918 destination) should still work.
6. **Replicate to all SPX nodes** + chroot.
7. **Bake** into Warewulf chroot for re-provision survival.

## User-facing verification

After a user runs `module load rocbudai` on a `--comment=ollama`
allocation, they can verify the baseline themselves with
`rocbudai-airgap-check` (no sudo) or `rocbudai-airgap-check --deep`
(also dumps the nft table contents — sudo). The tool ships in
`bin/rocbudai-airgap-check` and reports pass / fail / warn for:

- managed `/etc/opencode/opencode.json` flags
   (`share=disabled`, `autoupdate=false`, ≥10 disabled providers),
- `ollama` daemon reachable on `127.0.0.1:11434`,
- `ollama.service` / `ollama-proxy.service` / `ollama-egress.service`
   all `active`,
- `OLLAMA_NOPRUNE=1` and `OLLAMA_NO_CLOUD=1` in the daemon
   `Environment=`,
- `ollama` bound to `127.0.0.1` (loopback only),
- `OPENCODE_DISABLE_*` env vars set by the modulefile,
- the per-job `rocbudai_user_egress` chain is installed for this
   allocation (user UID's external egress is REJECTed; loopback /
   cluster DNS / RFC1918 still reachable),
- `opencode debug config` live-resolver check (section 3c) — confirms
   opencode actually accepts the managed config (not silently
   falling back to defaults on a schema-rejected key).

Exit code 0 ⇔ baseline intact. Use this in onboarding when you
need an industry partner to *see* the airgap, not just be told
about it.

## What this does NOT cover

The residual risks — out-of-job state, the login node, recursive DNS,
in-flight TCP connections, cluster admins, IPv6 — are enumerated in
the canonical threat-model statement:
[`../../docs/airgap-and-model-pulls.md`](../../docs/airgap-and-model-pulls.md)
(section "What the baseline does NOT cover").
