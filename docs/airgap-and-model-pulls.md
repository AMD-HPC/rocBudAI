# rocBudAI — airgap design and model-pull procedure

This document is the design rationale and the operational procedure
for the rocBudAI airgap baseline: what it does, why it has the shape
it has, and how an admin pulls a new model after the cluster is
locked down.

It is the long-form companion to `deploy/airgap/README.md` (which is
the per-file deployment map) and to the `Airgap baseline` section of
`INSTALL.md` (which is the step-by-step install recipe). Read this
file when you want to understand *why* each piece is shaped the way
it is, or when you need the model-pull recipe.

The rules match the ollama user by name (`skuid "ollama"`), which nft
resolves to the UID at load time, and rely on the RFC1918 allow to cover
the site DNS resolver — so they are portable as-is. Substitute your
cluster's values only if your resolver lives on a public IP.

---

## What the baseline is

Four cooperating pieces, all always-on for any `--comment=ollama`
allocation:

1. A managed `/etc/opencode/opencode.json` that pins `share:"disabled"`
   and 14 disabled cloud providers — overrides any per-user /
   per-project config. The modulefile additionally sets five
   `OPENCODE_DISABLE_*` env vars (autoupdate, LSP download, models
   fetch, external skills, share) so every known opencode phone-home
   call site is suppressed.
2. `OLLAMA_NOPRUNE=1` + `OLLAMA_NO_CLOUD=1` in the systemd unit, plus
   `OLLAMA_HOST=127.0.0.1:11435` (loopback only). No cloud handshake,
   no background update probe, no external listener.
3. `ollama-egress.service` — boot-time systemd unit that loads an
   `nft inet ollama_egress` table with an owner-match rule on the
   `ollama` UID. External traffic from that UID is REJECTed; loopback,
   cluster DNS, and RFC1918 are permitted.
4. `rocbudai-user-egress.service` + Slurm prolog/epilog — boot-time
   systemd unit loads an `nft inet rocbudai_user_egress` skeleton
   table; the prolog adds a per-job chain that REJECTs external traffic
   from the **user UID** for the duration of every `--comment=ollama`
   allocation; the epilog removes it. Loopback, cluster DNS, and
   RFC1918 remain reachable.

Together they ensure that source code, prompts, model output, AND
user-side commands stay on the cluster while the allocation runs.

---

## Design rationale

### Why managed `/etc/opencode/opencode.json` (and not just per-project)

Project-local templates at
`/shared/apps/ubuntu/opt/rocbudai/share/rocbudai/opencode-default.json`
already set `autoupdate:false` and `share:"disabled"` *for sessions
started via `rocbudai-tui`*. Nothing else protects a bare `opencode`
invocation in the same allocation.

opencode reads, in this order (highest precedence wins
on conflict): `/etc/opencode/opencode.json` → `~/.config/opencode/opencode.json`
→ `<project>/opencode.json`. The site-managed file is the only one a
user cannot rewrite, which is why the lockdown lives there. Verified
once on the reference cluster by staging a project with
`"autoupdate": true` AND a managed file with `"autoupdate": false` —
opencode behaved as if autoupdate was false.

The managed file is deliberately minimal: it does **not** set `model`,
`instructions`, or `permission` here — those are session/project-level
concerns and rocBudAI sets them per-session via `rocbudai-tui`. The
managed config only hard-locks the things users should never override.

The full file ships as `deploy/airgap/opencode-managed.json`; an
abbreviated form for reference:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "disabled_providers": [
    "anthropic", "openai", "openrouter", "google", "gemini",
    "amazon-bedrock", "azure", "groq", "mistral", "xai",
    "deepseek", "meta", "github-copilot", "vertex"
  ]
}
```

### Why an nft owner-match egress rule (not iptables, not netns)

The goal: even if root mistakenly runs `sudo -u ollama ollama pull X`,
the daemon cannot reach `registry.ollama.ai`. Legitimate admin pulls
are unblocked through a documented procedure (below).

The rules match the ollama user by name (`skuid "ollama"`);
nft resolves it to the numeric UID at load time, so the ruleset is
portable across sites regardless of the UID (it happens to be `997` on
the reference cluster).

On a typical HPC compute node `/etc/resolv.conf` points
at an internal (RFC1918) nameserver, **not** loopback (`systemd-resolved`
on `127.0.0.53` may be running but resolv.conf often bypasses it). A
naked egress block on the ollama UID would block DNS too — and ollama
would fail to resolve any internal host. The RFC1918 allow below covers
the resolver in that common case. If your resolver is on a public IP,
add an explicit DNS accept for it.

NFS reads of `/shareddata/Ollama_Models/` happen in kernel context
(mount-level), not over the ollama process's TCP socket, so the
owner-match rule never sees them. Verified once on the reference
cluster: `nft list ruleset` plus a test
`cat /shareddata/Ollama_Models/blobs/sha256-... > /dev/null` from
`sudo -u ollama` after the rule was applied — the read succeeded.

The Python proxy (`deploy/auth/`) runs as `uid=ollama` and connects
from the user-facing socket (`:11434`) to the upstream daemon
(`127.0.0.1:11435`). That outbound connection is owned by `ollama`,
so a blanket REJECT on `uid=ollama` would break the proxy — the
loopback exemption is mandatory.

A network namespace for ollama would be over-engineered for this
threat model: the nft owner-match achieves the same goal in six rules
and survives daemon restarts cleanly.

The ruleset that satisfies all three constraints (cluster DNS works,
loopback works, RFC1918 works, everything else REJECTed):

```nft
table inet ollama_egress {}
flush table inet ollama_egress

table inet ollama_egress {
    chain output {
        type filter hook output priority filter; policy accept;

        # Allow loopback unconditionally — proxy ↔ daemon, systemd-resolved.
        meta skuid "ollama" oif "lo" accept

        # Allow cluster-internal RFC1918 traffic (NFS, Slurm, etc.) — this
        # also covers the site DNS resolver when it lives in RFC1918 (the
        # common HPC case). If your resolver is on a public IP, add an
        # explicit DNS accept above this block.
        meta skuid "ollama" ip daddr 10.0.0.0/8     accept
        meta skuid "ollama" ip daddr 172.16.0.0/12  accept
        meta skuid "ollama" ip daddr 192.168.0.0/16 accept

        # Reject everything else from the ollama UID.
        meta skuid "ollama" reject with icmpx type admin-prohibited \
            comment "rocBudAI airgap: ollama UID egress blocked"
    }
}
```

The deployed file (`deploy/airgap/ollama-egress.nft`) is loaded at
boot by `ollama-egress.service`.

### Why `OLLAMA_NOPRUNE=1` in the systemd unit

Without it the daemon attempts (and logs a connection failure on) the
upstream "is this model still fresh?" probe at each start. Harmless
but noisy, and misleading in a verifiably-airgapped deployment where
any "tried to call out" line in the journal looks alarming.

`OLLAMA_NO_CLOUD=1` similarly disables the cloud-feature handshake.
Both are set in `deploy/ollama-daemon/ollama.service`.

---

## Verifying the baseline

A user-visible verifier ships at `bin/rocbudai-airgap-check`. From
inside a `--comment=ollama` allocation:

```bash
rocbudai-airgap-check              # user-visible probes (no sudo)
rocbudai-airgap-check --deep       # also dumps nft contents (sudo)
```

Exit code 0 ⇔ baseline intact. The tool reports pass / fail / warn
for the four pieces (managed opencode config, daemon hardening,
egress block, daemon reachability) and prints an informational note
that the user's own UID is *not* blocked by design.

---

## Pulling new models after the airgap is in force

When admin (you) needs to add a new model post-deployment, the
egress block has to be lifted briefly on one node. The flow also
has to deal with the local-NVMe model cache (`deploy/model-cache/`):
the pull lands in `/var/local/cache/ollama/` on the pull node, NOT
in the NFS-shared model store, so we have to push it back and trigger
a re-sync on the other SPX nodes.

```bash
# 1. Hold an SPX node briefly with --comment=ollama (so the daemon is up)
JOBID=$(salloc --no-shell -p PPAC_MI300A_SPX \
        --exclusive --comment=ollama --time=00:30:00 -J ollama-pull 2>&1 \
        | awk '/granted/{print $4}')
NODE=$(scontrol show job "$JOBID" \
        | awk -F= '/NodeList=/{print $2; exit}')

# 2. Temporarily lift the egress block on that node only
ssh "$NODE" 'sudo systemctl stop ollama-egress.service'

# 3. Pull (admin runs as ollama user inside the node).
#    NOTE: with the local NVMe model cache in place, the pull
#    lands in /var/local/cache/ollama on $NODE — NOT in
#    /shareddata/Ollama_Models. We push it back in step 4.5.
ssh "$NODE" 'sudo -u ollama OLLAMA_HOST=127.0.0.1:11435 \
            ollama-real pull MODEL_NAME_HERE'
ssh "$NODE" 'sudo -u ollama OLLAMA_HOST=127.0.0.1:11435 \
            ollama-real list'

# 4. RE-CLOSE the egress — this is the dangerous step to forget
ssh "$NODE" 'sudo systemctl start ollama-egress.service'
ssh "$NODE" 'sudo nft list table inet ollama_egress'  # sanity check

# 4.5. Push the new blobs/manifests from the pull node's local cache
#      back to the NFS-shared model store, so other nodes can re-sync.
#      Use --update so existing files (older models) are not clobbered
#      by the local copy.
ssh "$NODE" 'sudo rsync -a --update \
             /var/local/cache/ollama/ /shareddata/Ollama_Models/'

# 4.6. Trigger a re-sync on the other SPX nodes (or wait for next boot).
#      `systemctl restart` re-runs the oneshot rsync against the now-
#      updated NFS source.
for n in $(sinfo -h -p PPAC_MI300A_SPX -N -o '%N' | \
           sort -u | grep -v "^$NODE$"); do
    ssh "$n" 'sudo systemctl restart rocbudai-model-cache.service'
done

# 5. Verify lockdown is back
ssh "$NODE" 'sudo -u ollama timeout 5 curl -sI https://ollama.com 2>&1 \
             | head -3 || echo "egress blocked (good)"'

# 6. Release
scancel "$JOBID"

# 7. Confirm the model is visible from a fresh node, both in NFS and
#    on each node's local cache:
ls /shareddata/Ollama_Models/manifests/registry.ollama.ai/library/
for n in $(sinfo -h -p PPAC_MI300A_SPX -N -o '%N' | sort -u); do
    ssh "$n" 'ls /var/local/cache/ollama/manifests/registry.ollama.ai/library/'
done

# 8. MANDATORY: re-apply the rocbudai SYSTEM-prompt overlay to the
#    pulled model. Stock models from ollama.com ship with NO SYSTEM
#    layer, so the freshly-pulled manifest has no rocbudai operating
#    rules at the inference root. Without this step, the model on
#    every node will run with stock behaviour and silently regress.
#    Applies to gpt-oss:120b, qwen3.5:122b, and nemotron-3-super:120b;
#    other model names are skipped (no overlay shipped).
#
#    The overlay Modelfile lives in the rocbudai repo at
#    deploy/ollama-models/Modelfile.<sanitized-model-name>.rocbudai.
#    Sanitization: replace ':' with '-' (e.g. gpt-oss:120b →
#    gpt-oss-120b).
MODEL_NAME=MODEL_NAME_HERE                 # same as step 3
ROCBUDAI_REPO=<path to your rocBudAI checkout>
SANITIZED="${MODEL_NAME//:/-}"
OVERLAY="${ROCBUDAI_REPO}/deploy/ollama-models/Modelfile.${SANITIZED}.rocbudai"
if [[ -f "$OVERLAY" ]]; then
    # 8a. Apply on the pull node first (where the new manifest lives)
    ssh "$NODE" "sudo -u ollama OLLAMA_HOST=127.0.0.1:11435 \
                 ollama-real create $MODEL_NAME -f $OVERLAY"
    # 8b. The augmented manifest is now in /var/local/cache/ollama on $NODE.
    #     Re-rsync to NFS so other nodes pick up the SYSTEM-augmented version.
    ssh "$NODE" 'sudo rsync -a --update \
                 /var/local/cache/ollama/ /shareddata/Ollama_Models/'
    # 8c. Trigger re-sync on the other SPX nodes (same as step 4.6).
    for n in $(sinfo -h -p PPAC_MI300A_SPX -N -o '%N' | \
               sort -u | grep -v "^$NODE$"); do
        ssh "$n" 'sudo systemctl restart rocbudai-model-cache.service'
    done
    # 8d. Verify the SYSTEM layer is present on every node.
    for n in $(sinfo -h -p PPAC_MI300A_SPX -N -o '%N' | sort -u); do
        ssh "$n" "sudo -u ollama OLLAMA_HOST=127.0.0.1:11435 \
                  ollama-real show $MODEL_NAME --modelfile | grep -A 1 '^SYSTEM'"
    done
else
    echo "WARN: no rocbudai SYSTEM overlay at $OVERLAY"
    echo "      $MODEL_NAME will run with stock (no-SYSTEM) behaviour."
    echo "      Drop a Modelfile at the path above to add operating rules."
fi
```

Every model pull must be entered in the admin's audit log with the
JOBID, node, model name, the `chmod 2755` verification on
`/shareddata/Ollama_Models/`, confirmation that the per-node
`/var/local/cache/ollama/` mirrors match (steps 4.5, 4.6, and 7
above), and confirmation that the SYSTEM-prompt overlay was re-applied
on every node (step 8 above). Skipping the re-sync leaves other nodes
with a stale cache that doesn't see the new model; skipping the SYSTEM
re-augmentation leaves the model running without the rocbudai
operating rules — both are silent and hard to debug.

For the SYSTEM-overlay design rationale, the full rule list, and
alternative rollback paths (e.g. dropping the SYSTEM layer
deliberately to test stock behaviour), see
`deploy/ollama-models/README.md`.

---

## What the baseline does NOT cover

- **Out-of-job state.** The user-UID block is per-job — installed by
  the Slurm prolog on every `--comment=ollama` allocation, torn down
  by the epilog. Outside an allocation, the user UID has full network
  egress — by design, so admin tooling and pre-staging dependencies
  (`pip install`, `git clone https://…`, model downloads) work. Stage
  external dependencies BEFORE allocating with `--comment=ollama`.
- **The login node.** No allocation runs on it, so no per-job chain;
  user UID has full egress. The egress block lives on compute nodes
  only.
- **In-flight TCP connections at rule-load time.** The nft rules apply
  to new connections; conntrack may keep older ones alive. Restart
  the daemon after rule load if this matters.
- **Recursive DNS via the cluster resolver.** A motivated user UID
  can still tunnel data over DNS queries; defenders against that
  threat model need a stricter setup (e.g. firejail, apptainer,
  `unshare -n`).
- **Cluster admins.** They can read NFS contents directly. Trust in
  cluster admins is implicit.
- **IPv6 RFC4193 (ULA).** The reference cluster is IPv4-only today.
  If IPv6 is ever enabled, add `ip6 daddr fc00::/7 accept` to the
  nft chain.

This document is the canonical threat-model statement for rocBudAI's
airgap baseline.

---

## Rollback

Per node, in priority order (run any subset; each is independent):

```bash
# Lift the egress block (keeps the .nft on disk, just unloads it):
sudo systemctl disable --now ollama-egress.service

# Force the table out of the running ruleset (the unit's ExecStop
# normally handles this; this is the safety hatch):
sudo nft delete table inet ollama_egress

# Drop the managed opencode config:
sudo rm -rf /etc/opencode/

# Revert OLLAMA_NOPRUNE/OLLAMA_NO_CLOUD if you ever staged a backup
# of the pre-airgap unit:
sudo cp /etc/systemd/system/ollama.service.bak-<DATE>-pre-egress \
        /etc/systemd/system/ollama.service
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

For the Warewulf chroot:

```bash
sudo rm -f /var/local/warewulf/chroots/ubuntu-24.04/rootfs/etc/systemd/system/ollama-egress.service
sudo rm -f /var/local/warewulf/chroots/ubuntu-24.04/rootfs/etc/nftables.d/ollama-egress.nft
sudo rm -f /var/local/warewulf/chroots/ubuntu-24.04/rootfs/etc/systemd/system/multi-user.target.wants/ollama-egress.service
sudo rm -rf /var/local/warewulf/chroots/ubuntu-24.04/rootfs/etc/opencode/
sudo wwctl container build --force ubuntu-24.04
```
