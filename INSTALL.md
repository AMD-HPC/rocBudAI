# rocBudAI: installation guide

This is the recipe for sysadmins deploying rocBudAI on a fresh AMD GPU
cluster. It has been tested on Ubuntu 22.04 and 24.04 with Lmod and Slurm
(the conventions used on the reference cluster); adapting it to other distros
and schedulers is straightforward (see
[Adapting to other clusters](#adapting-to-other-clusters)).

---

## Installation (for sysadmins on a new cluster)

### Automated install (`install.sh`)

The repo ships an `install.sh` at the top level that walks the same recipe end
to end. From inside the checkout, run `sudo ./install.sh --yes` for a vanilla
install, or `sudo ./install.sh --yes --with-hardening` to also enable all six
step 8 features; `./install.sh --dry-run --with-hardening` previews every
command without touching the system. The script's defaults match the paths in
this document verbatim. Site-specific overrides go in a single `site.conf`
(copy `site.conf.example` next to `install.sh` and edit it): the script sources
it and it overrides the `CONFIGURATION` defaults at the top of the script, so
it is the one file to edit per site.

The script is one-to-one with the manual steps below, except for three
intentional divergences:

1. `MODELS_DIR` is read from the `OLLAMA_MODELS=` line in
   `deploy/ollama-daemon/ollama.service` instead of being a separate knob. The
   daemon reads whatever value lives in the unit file, so that file is the
   single source of truth.
2. The Warewulf chroot bake at the end of step 2 is auto-detected (it runs
   only if `wwctl` is on `PATH` and the chroot dir exists) instead of being an
   explicit step.
3. On a host without systemd (test containers, CI, dev workstations: anywhere
   `/run/systemd/system` does not exist), step 2 installs the unit file for
   reference but skips `systemctl daemon-reload` / `restart`. It instead
   launches `ollama serve` as a plain background `runuser`-ed process, sourcing
   the same env block from the unit file. This is purely a test-mode fallback;
   production compute nodes always have systemd.

The rest of this document is the equivalent recipe for sysadmins who prefer to
run each command by hand or who need to deviate mid-flow.

### GPU architecture

`install.sh` autodetects the GPU arch via `rocminfo`; the supported archs are
`gfx90a`, `gfx942`, and `gfx950`. `--gfx-arch <arch>` overrides the detection,
and anything outside the supported set aborts. This is a preflight sanity check
only: the AGENTS persona is resolved at launch on the compute node, not at
install time (see step 6). The installer reserves the last GPU on the node (a
whole OAM, i.e. 2 GCDs, on gfx90a) for `rocbudai-bench` and serves the model on
the remaining GPUs, through a systemd drop-in
(`ollama.service.d/10-gpu-split.conf`, step 2) set from the detected topology.
CPU pinning is best-effort and omitted when the NUMA mapping is not cleanly
derivable.

### Slurm partition

`--partition <name[,name2,...]>` tells the installer which partitions rocBudAI
may launch on. The value is baked into the deployed modulefile's
`ROCBUDAI_SPX_PARTITIONS`, which is what `rocbudai-tui` and `rocbudai-doctor`
gate on; `--partition ''` disables the partition gate. The model needs enough
full-GPU (SPX-style) devices: sliced modes (e.g. MI300A CPX/TPX) make the
runner abort, so pick a partition that exposes whole GPUs.

### Container quick test and no-systemd hosts

To sample rocBudAI without a full host install, run `./install.sh --container`
from inside a Slurm allocation. It pulls a ROCm dev image
(`docker.io/rocm/dev-${distro}-${distro_version}:${rocm_version}-complete`,
defaults `ubuntu` / `24.04` / `7.2.4`; override with `--distro`,
`--distro-version`, `--rocm-version`), installs rocBudAI inside the container
with a tools-enabled test model (`gemma4:12b`) and no GPU fencing, clones the
AMD HPC training examples, and drops you into a shell where `rocbudai-tui` runs
directly (no `module load`). This is for quick testing only and is *not* the
supported way to run rocBudAI: for real use, install on the host and use
`module load rocbudai`.

Testing the installer inside a container or another no-systemd host is
covered separately in [`docs/CONTAINER-TEST.md`](./docs/CONTAINER-TEST.md):
three verification tiers, from a raw daemon probe up through the full TUI
launcher with a fake Slurm context. The production compute-node smoke test
(real systemd, real Slurm, real GPUs) remains
[`docs/SMOKE-TEST.md`](./docs/SMOKE-TEST.md).

### Prerequisites

- GPU hardware: AMD GPU(s) with the ROCm driver installed. The
  most testing has been done on MI300A in SPX mode (with 4 logical devices per
  node, 32 GiB HBM3 each); the project also works on discrete CDNA
  GPUs with the same `OLLAMA_SCHED_SPREAD` story. CPX mode is currently not
  supported (Ollama's GGML runner aborts above 16 visible devices).

  If ROCm is not already installed on your compute nodes, there are
  two supported install paths:

  1. HPCTrainingDock `rocm_setup.sh` (recommended: this is the
     same script the rocBudAI reference cluster's base image uses,
     so it gives you a binary-identical ROCm stack to what we test
     against):

     ```bash
     curl -fsSL https://raw.githubusercontent.com/amd/HPCTrainingDock/main/rocm/scripts/rocm_setup.sh | sudo bash
     ```

     Source: [`amd/HPCTrainingDock/rocm/scripts/rocm_setup.sh`](https://github.com/amd/HPCTrainingDock/blob/main/rocm/scripts/rocm_setup.sh).

  2. Spack, for sites that already manage their software stack
     with Spack:

     ```bash
     spack install rocm
     spack load rocm
     ```

  After ROCm is installed, verify with `rocminfo` (must list at
  least one AMD GPU agent) before running `install.sh`. `install.sh`
  itself probes for `rocminfo` after the Ollama vendor install and
  emits the same two-path hint above if it does not find a working
  ROCm.
- Lmod ≥ 6.6 with a site MODULEPATH that points at a directory you
  control (e.g. `/shared/apps/modules/ubuntu/lmodfiles/base/`).
- Slurm with interactive `salloc` working. `LaunchParameters=use_interactive_step`
  is convenient (drops the user on the compute node automatically) but
  not required. `--comment=ollama` daemon-gating (step 8 below) is
  optional polish; for the bootstrap you can simply run the daemon as
  a permanent system service.
- Shared storage: at least one NFS mount visible from all compute
  nodes. The reference cluster uses `/shareddata/`. We need ~70 GB for
  the model store and a few hundred MB for opencode + the install tree.
- Network: outbound HTTPS during the install (to pull the model
  and the opencode binary). Step 8 below documents how to airgap
  afterwards.
- A user that can `sudo` (the sysadmin) on the compute nodes for the one-time setup.

### 1. Install Ollama (compute nodes)

Bake into your base image / provisioning system. Ollama is not in
the stock Ubuntu 22.04 / 24.04 apt repositories, so the canonical
install path is the upstream vendor installer.

Recent Ollama versions ship the binary as `ollama-linux-amd64.tar.zst`
and the installer aborts with `ERROR: This version requires zstd for
extraction` if `zstd` is missing, which is the case on minimal Ubuntu
rootfs images (e.g. the `bare_system` Docker base). Install the host
prereqs first, then run the vendor installer:

```bash
sudo apt-get update
sudo apt-get install -y zstd curl ca-certificates
# Pinned to a known-good release (see OLLAMA_VERSION in install.sh). This
# version already includes the MI300A unified-memory fix, so no rebuild.
curl -fsSL https://ollama.com/install.sh | sudo OLLAMA_VERSION=0.34.4 sh
```

If compute nodes reach the internet only via an
HTTP(S) proxy, set `SITE_HTTP_PROXY` (and `SITE_NO_PROXY`) in `site.conf`.
`install.sh` then prefixes the vendor installer and opencode download with it,
and also writes an `ollama.service.d/10-proxy.conf` drop-in so the daemon uses
it. The step-3 `ollama pull` is performed by the daemon, not the shell, so
without that drop-in a proxied site's model pull hangs reaching
`registry.ollama.ai`.

The installer places the binary at `/usr/local/bin/ollama`, creates
the `ollama` system user, and drops a systemd unit (which step 2
below overwrites with the rocBudAI canonical unit, so the vendor
unit is harmless). This is exactly what the systemd unit in step 2
(`ExecStart=/usr/local/bin/ollama serve`) and the step 8 auth-
hardening wrapper expect.

`install.sh` runs the same commands for you (`apt-get update`, install
`zstd curl ca-certificates`, then the vendor `curl … | sh`). If you have
your own provisioning path for the `ollama` binary (custom apt mirror,
Warewulf base image, manual rsync: anything that ends with
`/usr/local/bin/ollama` on the compute node), pre-stage it before
running `install.sh`; the script's `command -v ollama` early exit will
skip both the apt-update and the vendor download in that case.

After the install, step 1 runs a fail-fast GPU backend probe: a one-shot
`ollama serve` on a throwaway port that asserts ollama's own discovery
enumerates at least one ROCm device. This catches the silent *CPU-fallback*
failure mode, where ollama is installed and the daemon comes up "active" yet loads a broken/mismatched ROCm backend
(e.g. a pre-staged bundle whose `rocm*` libs dangle, or MI300A APUs
dropped without `OLLAMA_IGPU_ENABLE=1`), so the model runs 100% on CPU
and the TUI hangs for minutes on "model warming up". The probe fails the
install loudly (with the discovery log at
`/tmp/rocbudai-ollama-gpu-probe.log`) instead of letting a user hit it at
runtime. It is enforced only when `rocminfo` sees GPU hardware: a
GPU-less CI/container/dev host skips it automatically. To bypass it
explicitly, set `ROCBUDAI_SKIP_GPU_PROBE=1` before running `install.sh`.

Verify the `ollama` system user exists and owns `/usr/share/ollama`:

```bash
id ollama
sudo ls -ld /usr/share/ollama
# should show owner=ollama group=ollama. If a UID mismatch
# (e.g. nginx UID owns the dir on a fresh image), fix with:
sudo chown -R ollama:ollama /usr/share/ollama
```

MI300A needs no ollama source rebuild or patch step. A window of `ollama`
versions (≈ v0.13.0, late 2025) read `mem_info_vram_total` to size the GPU
memory pool; on AMD APUs (MI300A) the GPU/CPU memory is unified and that sysfs
node returns 0, so those versions refused to load any model.
[PR #13463](https://github.com/ollama/ollama/pull/13463) fixed it upstream
(`discover/amd.go`) by falling back to `mem_info_gtt_total` (the unified pool)
when VRAM is zero. rocBudAI pins `ollama` to a release that already contains
the fix (`OLLAMA_VERSION` in `install.sh`, currently `0.34.4`), so the stock
pinned binary loads models on MI300A out of the box.

### 2. Configure Ollama for shared models + multi-GPU spread

Override the package-default `ollama.service` with a full unit that
sets the NFS model path, spreads large models across all GPUs, binds
to loopback only, and keeps models resident in VRAM. The canonical
copy lives at `deploy/ollama-daemon/ollama.service` in this repo (with
a per-line rationale in the companion `README.md`); the inline heredoc
below has the same directives without the rationale comments, for
cut-and-paste (modify as needed):

```bash
sudo tee /etc/systemd/system/ollama.service >/dev/null <<'EOF'
[Unit]
Description=Ollama Service (rocBudAI)
Documentation=file:///shared/apps/ubuntu/opt/rocbudai/README.md
After=network-online.target remote-fs.target
Wants=network-online.target
RequiresMountsFor=/shareddata

[Service]
Type=simple
User=ollama
Group=ollama
SupplementaryGroups=render video
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

Environment="OLLAMA_MODELS=/shareddata/Ollama_Models"
Environment="OLLAMA_HOST=127.0.0.1:11435"
Environment="OLLAMA_IGPU_ENABLE=1"
# The GPU/CPU fence (ROCR_VISIBLE_DEVICES + AllowedCPUs) is NOT set here: it
# lives in the drop-in ollama.service.d/10-gpu-split.conf (see below).
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_SCHED_SPREAD=1"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NOPRUNE=1"
Environment="OLLAMA_NO_CLOUD=1"
Environment="OLLAMA_LOAD_TIMEOUT=15m"
Environment="OLLAMA_GPU_OVERHEAD=4294967296"

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl restart ollama
systemctl is-active ollama          # → active
```

Key settings:
- `OLLAMA_MODELS`: point to your NFS model store.
- `OLLAMA_HOST=127.0.0.1:11435`: loopback only. The Python reverse
  proxy on `:11434` (added by step 8 below) is what users actually
  talk to; the raw daemon stays behind it on `:11435`. If you skip
  step 8, change this to `0.0.0.0:11434` so users can reach the
  daemon directly.
- `OLLAMA_IGPU_ENABLE=1`: MI300A dies enumerate as integrated GPUs, which
  ollama >= 0.30 drops by default (falling back to CPU); older ollama ignores it.
- `ROCR_VISIBLE_DEVICES=0,1,2,..` + `AllowedCPUs=....`: dedicated-bench-GPU
  isolation, written to the drop-in
  `/etc/systemd/system/ollama.service.d/10-gpu-split.conf` by
  `libexec/rocbudai-detect-topology.sh --write-fence`. `install.sh` runs it at
  install time and the `--comment=ollama` prolog re-runs it per job; by hand,
  run it as root, then `sudo systemctl restart ollama`. For example, on MI300A
  SPX with 4 sockets each APU is one ROCr device (0..3): the fence puts the
  daemon (and the agent) on APUs 0,1,2 and keeps its host threads off die-3
  cores, leaving APU 3 reserved exclusively for `rocbudai-bench` (GPU 3 +
  cores 72-95,168-191), so the in-session FOM is free of inference contention.
  Multi-GPU / MPI FOMs use `rocbudai-submit` instead of the in-node bench GPU:
  it runs the multi-rank command on a separate Slurm GPU allocation (partition
  from `SUBMIT_PARTITION` / `ROCBUDAI_SUBMIT_PARTITION` / `-p`, else the
  cluster default) and returns the same median/[FACT] summary.
- `OLLAMA_SCHED_SPREAD=1`: spread the model across the visible GPUs
  (now the three fenced dies 0,1,2; essential when the model exceeds a
  single die's VRAM).
- `OLLAMA_KEEP_ALIVE=-1`: keep the model resident in VRAM for the life
  of the allocation (the Slurm epilog unloads it and stops the daemon at
  job end). This amortises the cold-load; see also the local NVMe model
  cache feature in step 8.
- `OLLAMA_MAX_LOADED_MODELS=1` (+ `OLLAMA_NUM_PARALLEL=1`): with the
  daemon confined to three dies, keep exactly ONE model resident. The
  prolog pre-warms only the default (`qwen3.5:122b`); opt-in models
  cold-load on demand.
- `OLLAMA_NOPRUNE=1` + `OLLAMA_NO_CLOUD=1`: disable background update
  probes and cloud-feature handshake; required for offline operation.
- `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`: performance
  optimisations for large context windows.

The canonical unit, with the per-line rationale (including the
`OLLAMA_LOAD_TIMEOUT` / `OLLAMA_GPU_OVERHEAD` safety nets), lives in
`deploy/ollama-daemon/ollama.service` and is the source of truth that
`install.sh` deploys.

If you use Warewulf for provisioning, apply the same unit file to the
chroot so it survives re-provision:

```bash
sudo cp /etc/systemd/system/ollama.service \
        /var/local/warewulf/chroots/ubuntu-24.04/etc/systemd/system/ollama.service
sudo wwctl container build ubuntu-24.04
```

For a complete per-node laydown into a provisioning image, use the
`--image-bake` mode, which bakes the ollama unit + optional proxy drop-in +
NVMe model-cache + the `ollama` user and offline-enables the boot services (no
live systemd/GPU needed), then rebuilds the image with `wwctl` if present. The
GPU/CPU fence is not baked: the `--comment=ollama` prolog writes it per job on
the booted node, so it matches that node's real GPU count:

```bash
sudo ./install.sh --image-bake /var/local/warewulf/chroots/ubuntu-24.04/rootfs
```

Tunable: `IMAGE_ENABLE_OLLAMA` (see `site.conf.example`). Shared components
(opencode, install tree, modulefile) are not baked: install them once on the
NFS share with a normal run.

### 3. Pull the canonical model

The model store on NFS needs to be writable by the `ollama` user.
On a node where ollama is running:

```bash
sudo install -d -m 2775 -o ollama -g ollama /shareddata/Ollama_Models
sudo -u ollama ollama pull qwen3.5:122b
# takes 10-30 min depending on the upstream link
```

Confirm:

```bash
sudo -u ollama ollama list
# NAME              ID              SIZE      MODIFIED
# qwen3.5:122b      <hash>          ...       ...
```

We are currently using `qwen3.5:122b` as the default;
`gpt-oss:120b`, `nemotron-3-super:120b`, and `laguna-s-2.1:q4_K_M` are in the
default allow-list as opt-in alternatives via
`export ROCBUDAI_MODEL=<name>` before `module load rocbudai` (`install.sh`
pulls only `MODEL_NAME`; nemotron is imported from a GGUF rather than pulled,
see `deploy/ollama-models/README.md`). Other
options are of course possible: extend `ROCBUDAI_ALLOWED_MODELS` in
the modulefile and follow the same pull + overlay procedure.

### 3a. Apply the rocbudai SYSTEM-prompt overlay

Stock models from ollama.com ship with no `SYSTEM` layer:
the model behaves entirely from its base training, with no
session-level operating rules pinned at the inference root.
rocBudAI ships a small SYSTEM overlay (5 hard rules, ~80 tokens)
that wraps every supported model so the rules are enforced at the
inference root, not just inside `AGENTS.md`.

The `install.sh` script applies the overlay automatically right
after the pull. The manual equivalent is:

```bash
sudo -u ollama OLLAMA_HOST="${host}" \
    ollama create qwen3.5:122b \
        -f "${ROCBUDAI_REPO}/deploy/ollama-models/Modelfile.qwen3.5-122b.rocbudai"
```

Confirm the SYSTEM layer is present:

```bash
sudo -u ollama ollama show qwen3.5:122b --modelfile | grep -A 3 '^SYSTEM'
# SYSTEM """
# You are operating under rocbudai's hard rules. The following
# are turn-invalidating violations regardless of context:
# ...
```

Any future `ollama pull qwen3.5:122b` (e.g. to refresh
the upstream weights) replaces the manifest with the stock
no-SYSTEM version, dropping the overlay. The pull procedure in
`docs/airgap-and-model-pulls.md` documents the mandatory
re-augmentation step that must follow any pull. Skipping it leaves
the model running without the rocbudai operating rules and
behaviour will silently regress.

For the design rationale, the full rule list, and the rollback
procedure, see `deploy/ollama-models/README.md`.

### 4. Stage the OpenCode binary

```bash
OPENCODE_VER=1.14.28
ROCBUDAI_REPO=<path to your rocBudAI checkout>   # for sha256 verify

mkdir -p /tmp/opencode-stage
cd /tmp/opencode-stage
curl -LO https://github.com/sst/opencode/releases/download/v${OPENCODE_VER}/opencode-linux-x64.tar.gz

# Verify the download against the in-repo provenance manifest.
# Aborts with non-zero exit if the upstream tarball ever changes
# under this tag — see archive/opencode-${OPENCODE_VER}-provenance/README.md.
sha256sum -c "${ROCBUDAI_REPO}/archive/opencode-${OPENCODE_VER}-provenance/SHA256SUMS.txt"

tar xzf opencode-linux-x64.tar.gz
test -x opencode

sudo mkdir -p /shared/apps/ubuntu/opt/opencode/${OPENCODE_VER}
sudo cp opencode /shared/apps/ubuntu/opt/opencode/${OPENCODE_VER}/
sudo chown -R root:root /shared/apps/ubuntu/opt/opencode
```

### 5. Stage the rocBudAI install tree

Clone (or copy) the rocBudAI install tree to a place that's
writable by the admin while developing:

```bash
sudo mkdir -p /shared/apps/ubuntu/opt/rocbudai
sudo cp -a /path/to/rocbudai/install/. /shared/apps/ubuntu/opt/rocbudai/
sudo chown -R root:root /shared/apps/ubuntu/opt/rocbudai
```

Stage `rg` into `bin/`: opencode's glob/grep tools otherwise try to
download ripgrep from GitHub, which fails on compute nodes without egress.

```bash
RG_VER=15.1.0
cd /tmp/opencode-stage
curl -LO https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-x86_64-unknown-linux-musl.tar.gz
sha256sum -c "${ROCBUDAI_REPO}/archive/ripgrep-${RG_VER}-provenance/SHA256SUMS.txt"
tar xzf ripgrep-${RG_VER}-x86_64-unknown-linux-musl.tar.gz
sudo install -o root -g root -m 0755 ripgrep-${RG_VER}-x86_64-unknown-linux-musl/rg /shared/apps/ubuntu/opt/rocbudai/bin/rg
```

The install tree's layout, as `find` sees it on disk after this step (the
README stays in the source repo, not in the deployed tree; see the project's
GitHub for the authoritative copy):

```
/shared/apps/ubuntu/opt/rocbudai/
├── bin/
│   ├── rocbudai                 compute-node entry (forwards to rocbudai-tui;
│   │                            hard-errors on a login node with the salloc
│   │                            command the user should run)
│   ├── rocbudai-tui             compute-node TUI launcher (preflight, picker, exec opencode)
│   ├── rocbudai-name-session    records user-given session name in
│   │                            ./.rocbudai-sessions.json (called at Q1/7)
│   ├── rocbudai-prune-sessions  interactively delete stale opencode sessions
│   │                            (project-scoped, or --all-runs for ~/rocbudai-runs/*;
│   │                            --dry-run to preview)
│   ├── rocbudai-airgap-check    user-visible verification that the cluster
│   │                            airgap baseline is in force on the compute node
│   ├── rocbudai-doctor          standalone preflight diagnostic (11 checks)
│   ├── rocbudai-reap-stale      finds / kills leaked KFD-bound profile children
│   ├── rocbudai-ingest-inputs   admin tool: PDF → MD knowledge-base sidecars
│   ├── rocbudai-bench           single-GPU FOM timing on the reserved bench GPU
│   ├── rocbudai-submit          multi-rank / multi-GPU FOM on a separate Slurm allocation
│   └── rg                       ripgrep, staged from upstream (see above)
├── libexec/
│   ├── rocbudai-load-hook.sh    logic the modulefile execs on `module load`
│   ├── rocbudai-detect-topology.sh  GPU/CPU split; writes the ollama fence drop-in
│   └── rocbudai-nudge-watcher   auto-nudge sidecar launched by rocbudai-tui
├── share/man/man1/rocbudai.1    man page
├── share/rocbudai/
│   ├── opencode-default.json    ASK-mode template
│   ├── opencode-allow-all.json  AUTO-RUN-mode template
│   ├── AGENTS-default.md        MI300A agent instructions (persona, loop, discovery, recovery)
│   ├── AGENTS-gfx942-mi300x.md  MI300X persona (gfx942 discrete)
│   ├── AGENTS-gfx90a.md         MI250X/MI210 persona (gfx90a, CDNA2)
│   ├── AGENTS-gfx950.md         MI355X/MI350X persona (gfx950, CDNA4)
│   ├── AGENTS-container-demo.md  compact standalone container quick-test persona
│   ├── AGENTS-default-container.md  full-length container variant (not selected by rocbudai-tui)
│   ├── test-env.sh              env for no-systemd / no-Slurm container testing
│   └── kb/                      per-arch optimization-playbook knowledge base
└── modulefiles/rocbudai/
    ├── dev.lua                  the Lmod modulefile (gets dropped at the site path)
    └── dev                      the Tcl equivalent (Environment Modules / Cray PE)
```

### 6. Drop the modulefile on the site MODULEPATH

Install the modulefile flavour that matches your `module` command: `dev.lua`
for Lmod, or `dev` for Environment Modules / Cray PE (Tcl). `install.sh`
picks it via `MODULE_FLAVOR` (`auto`/`lmod`/`tcl`; auto-detected by default). By
hand, use the Lmod copy:

```bash
SITE_MODULES=/shared/apps/modules/ubuntu/lmodfiles/base
sudo mkdir -p ${SITE_MODULES}/rocbudai
sudo cp /shared/apps/ubuntu/opt/rocbudai/modulefiles/rocbudai/dev.lua \
        ${SITE_MODULES}/rocbudai/dev.lua
sudo chown root:root ${SITE_MODULES}/rocbudai/dev.lua
```

On a Tcl (Environment Modules) site, copy `modulefiles/rocbudai/dev` instead
(to `${SITE_MODULES}/rocbudai/dev`); the two files are kept behaviourally in
sync and the retargeting below applies to whichever one you installed.

If you staged the install tree at a path other than
`/shared/apps/ubuntu/opt/rocbudai`, retarget the modulefile:

```bash
sudo sed -i \
   -e 's|/shared/apps/ubuntu/opt/rocbudai|<your-install-path>|g' \
   -e 's|/shared/apps/ubuntu/opt/opencode/1.14.28/opencode|<your-opencode-path>|g' \
   ${SITE_MODULES}/rocbudai/dev.lua
```

The AGENTS persona is not baked into the modulefile, because staging often
runs on a GPU-less login node where any arch guess is unreliable. Instead
`rocbudai-tui` resolves it at launch from the live GPU on the compute node
(`gfx90a`: MI250X/MI210, `gfx942`: MI300A/MI300X, `gfx950`: MI355X/MI350X) and
seeds the matching spec table and optimization playbooks. To force a specific
persona, `export ROCBUDAI_AGENTS_TEMPLATE=<file>` before `module load rocbudai`.

The `bin/` scripts (`rocbudai`, `rocbudai-tui`, `rocbudai-doctor`,
`rocbudai-name-session`, `rocbudai-prune-sessions`,
`rocbudai-airgap-check`) honour `ROCBUDAI_ROOT` and
`ROCBUDAI_OPENCODE_BIN` env vars and the modulefile sets both, so
retargeting `dev.lua` alone is sufficient: there is no need to also `sed`
the `bin/` scripts.

### 7. Verify

From a login node:

```bash
module avail rocbudai          # should show rocbudai/dev
module help rocbudai           # prints the help text
module load rocbudai           # prints a "this module is for compute nodes;
                               # allocate one first" hint with the salloc
                               # command, then exits without launching the TUI
                               # (login nodes are not a supported run target)
```

From a compute node (inside an allocation):

```bash
salloc -p <gpu-partition> --exclusive --comment=ollama --time=01:00:00
module load rocbudai           # → TUI auto-launches
```

The TUI should open with the agent's welcome banner showing your
hostname, Slurm job ID, and `model: qwen3.5:122b`. Try a few read-only
commands (run without prompting), then a build command (should pause
for `y/Enter`).

For a full end-to-end check (banner content, seven-question discovery
order, ASK-mode prompting, the AUTO-RUN toggle, common errors), see
[`docs/SMOKE-TEST.md`](./docs/SMOKE-TEST.md), a step-by-step gate list
new sysadmins can hand to a tester after the install completes.

### 8. (Optional) Lock down for production

Six independent hardening / quality-of-life features the reference
cluster runs with; each is opt-in, so pick what fits your threat model
and operational needs. The source artefacts listed below are the actual
files deployed on the reference cluster and are reproducible verbatim
on a new site.

The three site-specific paths these features touch are `site.conf`
knobs, not CLI flags: `SLURMSCRIPTS_DIR` (Slurm prolog/epilog root for
`--comment=ollama` gating, default `/shared/share/slurmscripts`),
`MODEL_CACHE_DIR` (per-node NVMe cache destination, default
`/var/local/cache/ollama`), and `KB_INPUTS_DIR` (auto-ingest watch dir,
default `/shareddata/rocbudai/docs/inputs`). Set them in `site.conf`
and `install.sh` retargets the deployed units accordingly; the defaults
below match the reference cluster. A relocated `KB_INPUTS_DIR` also
needs the KB path in the AGENTS personas and README edited by hand, since
`install.sh` does not rewrite those. See `site.conf.example` for the
full knob list.

#### Ollama authorization hardening

Stops casual misuse of the daemon: inference stays open to all allocated
users (`list`, `show`, `ps`, `run`), but mutation (`pull`, `rm`, `push`,
`create`, `cp`) is restricted to admins. Five layers stack together:

1. Bind the daemon to `127.0.0.1:11435` (already done in step 2 above).
2. An nft owner-match ACL on `:11435`, so only the `ollama` and `root` UIDs
   can reach the raw daemon.
3. A small Python reverse-proxy on `:11434` that returns 403 on mutation
   endpoints.
4. A CLI wrapper at `/usr/local/bin/ollama` that rejects mutate verbs from
   non-root users.
5. `2755 ollama:ollama` on the model-store directory.

Source artefacts (in this repo): `deploy/auth/`
(`ollama-acl.{nft,service}`, `ollama-proxy.{py,service}`,
`ollama-wrapper.sh`, plus a `README.md` with the per-file deployment map).

#### Daemon gating via `--comment=ollama`

Stops ollama from running on idle nodes and ties its lifetime to a Slurm
allocation. A `prolog.d/` drop-in starts the daemon (and pre-warms the model
with `systemd-run --no-block` to escape `PrologFlags=Contain`) when the
allocation specifies `--comment=ollama`; the matching `epilog.d/` drop-in
unloads and stops it. `job_submit.lua` rule 2 enforces `--exclusive` and an
SPX-only partition for any `--comment=ollama` job. After deploying,
`sudo systemctl disable ollama` on each node so it no longer auto-starts at
boot.

Source artefacts (in this repo): `deploy/comment-gating/`
(`job_submit.lua`, `rocbudai-ollama-{prolog,epilog}.sh`,
`rocbudai-egress-{prolog,epilog}.sh`, plus a `README.md` documenting the
dispatch blocks to add to your cluster's prolog / epilog so the drop-ins get
invoked).

#### Airgap baseline

Stops the daemon and opencode from making outbound HTTPS once the cluster
goes offline, and gives `--comment=ollama` users a verifiable promise that
source code, prompts, and model output stay on the cluster. Four cooperating
artefacts:

1. A managed `/etc/opencode/opencode.json` that pins `share: "disabled"` and
   14 disabled cloud providers (anthropic, openai, azure, …). OpenCode gives
   the site-wide config precedence, so a project-local `opencode.json` cannot
   re-enable cloud sharing. Auto-update is not a JSON setting in opencode
   1.14.28: the modulefile disables it (with the other phone-home call sites)
   through the `OPENCODE_DISABLE_*` env vars.
2. `OLLAMA_NOPRUNE=1` + `OLLAMA_NO_CLOUD=1` in the ollama systemd unit (step
   2 above), plus the loopback-only bind to `127.0.0.1:11435`: no cloud
   handshake, no background update probe, no external listener.
3. `ollama-egress.service`, a boot-time systemd unit that installs an
   `nft inet ollama_egress` table with an owner-match rule on the `ollama`
   UID. External traffic is REJECTed; only loopback, cluster DNS, and RFC1918
   are permitted. The block is UID-scoped, so it does not affect other users
   or system daemons on the node.
4. `rocbudai-user-egress.service`, a boot-time unit that loads an empty
   `nft inet rocbudai_user_egress` skeleton table. The Slurm egress prolog
   (`--with-comment-gating`) adds a per-job jump chain scoped to the
   launching user's UID for the life of each `--comment=ollama` allocation.
   Without this table pre-loaded, the prolog fails CLOSED (aborts the job)
   and `rocbudai-airgap-check` section 6 stays red.

All four are always on for any `--comment=ollama` allocation; there is no
user opt-in switch. Users can verify the baseline themselves on the compute
node with `rocbudai-airgap-check` (user-visible probes, no sudo) or
`rocbudai-airgap-check --deep` (also dumps the nft table contents, requires
sudo). The tool ships in `bin/rocbudai-airgap-check` and is deployed
alongside the other rocBudAI helpers.

Source artefacts (in this repo): `deploy/airgap/`
(`opencode-managed.json`, `ollama-egress.{nft,service}`,
`rocbudai-user-egress.{nft,service}`, plus a `README.md` with the per-file
deployment map). The design, the model-pull-relock procedure (how an admin
pulls a new model after the cluster is airgapped), and the full list of what
the baseline does not cover are in `docs/airgap-and-model-pulls.md` in this
repo (deployed at `/shareddata/rocbudai/docs/airgap-and-model-pulls.md`). The
main gap is that the user-UID block is per-job: outside an allocation the user
UID has full egress, so stage any external dependencies (pip wheels, git
clones, model downloads) BEFORE allocating with `--comment=ollama`. The
baseline also does not cover the login node, and it trusts cluster admins.

#### Auto-ingest of KB documents

Removes the manual `rocbudai-ingest-inputs` step admins would otherwise need
to run every time they drop a new PDF into the KB. A `systemd.path` watcher on
the login node invokes the existing converter within ~1 sec of
`IN_CLOSE_WRITE` on `/shareddata/rocbudai/docs/inputs/`. A sibling `.timer`
runs the same service hourly as a fallback for PDFs that arrive via NFS from
non-login-node hosts (where inotify on the login node never sees them). The
converter itself is unchanged and idempotent: multiple back-to-back path
events do at most one pass of real work, and a `flock` in the service unit
serialises overlapping invocations.

Source artefacts (in this repo): `deploy/auto-ingest/`
(`rocbudai-ingest-inputs.{path,service,timer}`, plus a `README.md` with the
per-file deployment map and smoke-test recipe).

Deploy it on the login node only. Do NOT bake it into the Warewulf chroot,
since multi-host watchers would race on shared NFS state.

#### Local NVMe model cache

Reduces the user-perceived ollama cold-start from ~9-10 min to ~1 min by
mirroring the NFS-shared model store onto each SPX node's local NVMe at boot
and pointing the ollama daemon at the local copy. The cluster prolog runs
`echo 3 | sudo tee /proc/sys/vm/drop_caches` at every job start, which would
defeat any pure-RAM page-cache pre-warm; local-disk caching survives
`drop_caches`, which is why the design is block-storage-based rather than
memory-based. The measured cold-start and bandwidth numbers are in
`deploy/model-cache/README.md`.

Two files cooperate:

1. `rocbudai-model-cache.service` is a boot-time `Type=oneshot` systemd unit
   that runs
   `rsync -a --delete /shareddata/Ollama_Models/ /var/local/cache/ollama/`,
   ordered `Before=ollama.service` so the cache is fully populated before any
   pre-warm tries to read it. The first boot pays the 9-10 min cold sync;
   subsequent boots take seconds (rsync is delta-only).
2. A drop-in at `/etc/systemd/system/ollama.service.d/model-cache.conf`
   overrides `OLLAMA_MODELS=/var/local/cache/ollama` and adds `Requires=` +
   `After=` on the cache service, so ollama can never start before the cache
   exists.

Source artefacts (in this repo): `deploy/model-cache/`
(`rocbudai-model-cache.service`, `ollama-models-cache.conf`, plus a
`README.md` with the per-file deployment map, smoke-test recipe, and the new
admin model-pull workflow).

When admins pull a new model, the procedure changes: the pull lands in the
local cache on the pull node, then gets `rsync`ed back to NFS, then
`systemctl restart rocbudai-model-cache.service` runs on the other SPX nodes.
See `docs/airgap-and-model-pulls.md` for the full recipe.

#### Daily usage tracking (privacy- and airgap-preserving)

A nightly `cron.daily` job summarises rocBudAI usage into a single root-only
JSONL log with one row per `(date, user)` and counters only: allocation
count, total wall-minutes, clean-exit rate, sessions named, `report.md` byte
total, and `--continue`-resume count. Prompts, responses, source paths, and
`report.md` contents are never logged. The output file
(`/var/log/rocbudai-usage.jsonl`) is mode `0600 root:root`, so unprivileged
users cannot read it; users see no banner change, no opt-out env var, and no
behavioural difference.

A watchdog, invoked at the end of the same cron job, appends a
`hygiene_check` row to the same log enforcing two structural guarantees: no
row exceeds 1024 bytes (so no prompt or response can fit), and every row uses
only the documented per-event allow-listed keys (so a future code change
cannot start capturing content without tripping the check). The same checks
are exposed as section 7 of `rocbudai-airgap-check --deep` for on-demand
admin inspection. Because the watchdog writes its verdict into the same
JSONL, pointing an AI tool at the file is sufficient to answer both "who used
rocbudai" and "is the privacy posture intact", with no separate syslog
channel to monitor. Airgap is preserved end to end: no network egress, no new
daemons, all writes are local.

Source artefacts (in this repo): `deploy/usage/`
(`rocbudai-harvest`, `rocbudai-airgap-probe`). Install:

```bash
sudo install -m 0750 -o root -g root \
    deploy/usage/rocbudai-harvest /etc/cron.daily/rocbudai-harvest
sudo install -m 0750 -o root -g root \
    deploy/usage/rocbudai-airgap-probe /usr/local/sbin/rocbudai-airgap-probe
sudo install -m 0600 -o root -g root /dev/null /var/log/rocbudai-usage.jsonl
```

### Uninstall

```bash
sudo rm -rf /shared/apps/ubuntu/opt/rocbudai
sudo rm -rf /shared/apps/ubuntu/opt/opencode
sudo rm -rf /shared/apps/modules/ubuntu/lmodfiles/base/rocbudai
# optional: stop the daemon and reclaim the model store
sudo systemctl disable --now ollama
sudo rm -rf /shareddata/Ollama_Models   # 65+ GB: confirm before running
```

### Adapting to other clusters

- Different scheduler (PBS, LSF): the modulefile's auto-launch
  logic only checks `SLURM_JOB_ID`; replace with `PBS_JOBID` /
  `LSB_JOBID` in `libexec/rocbudai-load-hook.sh`.
- No Lmod: a Tcl modulefile (`modulefiles/rocbudai/dev`) ships for
  Environment Modules / Cray PE sites; set `MODULE_FLAVOR=tcl` (or leave
  `auto`) so `install.sh` installs it instead of `dev.lua`.
- Different default model: pull whatever fits your VRAM budget
  and either change the modulefile's `setenv("ROCBUDAI_MODEL", …)`
  default or have users pre-export `ROCBUDAI_MODEL` before
  `module load rocbudai`. The conditional `setenv` in the modulefile
  is designed to honour pre-set values.
- Discrete GPUs (no APU/SPX/CPX confusion): drop the SPX-vs-CPX
  warnings in the docs; `OLLAMA_SCHED_SPREAD=1` still helps for any
  multi-GPU node where the model spans more than one device.
