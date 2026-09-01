#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# install.sh — Install rocBudAI from this checkout onto an AMD GPU cluster.
#
# Literal translation of INSTALL.md: steps 1-7 (mandatory) followed by
# step 8 (opt-in hardening, gated by --with-hardening). Run from inside
# the rocbudai_github checkout, on a node that has both `apt`/`systemctl`
# (compute-node-style) AND write access to the shared filesystem
# (/shared, /shareddata) — the same place a sysadmin would follow
# INSTALL.md by hand.
#
# To deviate from INSTALL.md defaults (install root, model name, etc.),
# edit the constants in the CONFIGURATION block below. There are no
# per-path CLI flags by design — sites that need different paths
# usually need ALL the paths different, which is a config edit, not a
# flag soup.
#
# Usage:   install.sh [options]
# Help:    install.sh --help

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these to deviate from INSTALL.md defaults.
# ---------------------------------------------------------------------------

INSTALL_ROOT="/shared/apps/ubuntu/opt/rocbudai"
OPENCODE_ROOT="/shared/apps/ubuntu/opt/opencode"
OPENCODE_VERSION="1.14.28"
# Pinned ollama version, installed via the upstream install.sh (which honours
# the OLLAMA_VERSION env var). Pinned for reproducibility, same as
# OPENCODE_VERSION. This release already contains the MI300A unified-memory fix
# (issue #8735 / PR #13463, merged upstream), so no source rebuild is needed.
OLLAMA_VERSION="0.31.1"
# Outbound HTTP(S) proxy for install-time fetches. Empty = direct egress (the
# default). When set it is applied to: the ollama vendor installer, the opencode
# download, AND a systemd drop-in so the DAEMON uses it — step 3's `ollama pull`
# is performed by the daemon, not the shell, so without the drop-in a proxied
# site's model pull hangs reaching registry.ollama.ai.
SITE_HTTP_PROXY=""
SITE_NO_PROXY="localhost,127.0.0.1"
SITE_MODULES="/shared/apps/modules/ubuntu/lmodfiles/base"
# Module system flavour: lmod (installs dev.lua), tcl (installs the Tcl
# dev, for Environment Modules / Cray PE), or auto (detect at step 6).
MODULE_FLAVOR="auto"
# The --container wrapper re-invokes this script with MODEL_NAME=<small model>
# in the environment. Capture it so it still wins after site.conf is sourced
# (precedence: built-in default < site.conf < container/env).
_MODEL_NAME_ENV="${MODEL_NAME:-}"
MODEL_NAME="qwen3.5:122b"
# Warewulf compute-node image rootfs. The step-2 sidecar bakes the ollama unit
# here and rebuilds the image so it survives re-provisioning. Warewulf 4.x lays
# images out as <chroots>/<image-name>/rootfs, so the image NAME passed to
# `wwctl container build` is derived from this path (see the sidecar). Point it
# at a nonexistent path (or "") to skip the bake.
WAREWULF_CHROOT="/var/local/warewulf/chroots/ubuntu-24.04/rootfs"

# Slurm partition(s) rocBudAI is allowed to launch on (comma-separated).
# This is the value baked into the deployed modulefile's
# ROCBUDAI_SPX_PARTITIONS — change it for your cluster with --partition.
# Leave empty (--partition '') to disable the partition gate entirely.
# The model needs enough full-GPU (SPX) devices; sliced modes (e.g. MI300A
# CPX/TPX) make the runner abort, so the default targets the reference
# MI300A SPX partition.
SPX_PARTITIONS="PPAC_MI300A_SPX"

# GPU architecture. Empty = autodetect via rocminfo (see detect_gfx_arch).
# Override with --gfx-arch. Must be one of SUPPORTED_GFX_ARCHS or install
# aborts.
GFX_ARCH=""
SUPPORTED_GFX_ARCHS="gfx90a gfx942 gfx950"

# --container quick-test mode (see run_container_mode). Defaults for the
# ROCm dev image pulled from Docker Hub; overridable via the matching CLI
# flags. CONTAINER_MODEL is the tools-enabled test model pulled for sampling.
# The container demo runs a COMPACT, self-contained persona
# (AGENTS-container-demo.md, not the full ~2100-line arch persona), so a
# small fast model suffices and keeps the cold-start short. gemma4:12b
# (~8 GB) loads far quicker than the 27B we used before and follows the
# slimmed demo flow reliably; the install-time pre-warm in
# run_container_mode hides what little cold-start remains.
CONTAINER=0
ROCM_VERSION="7.2.4"
DISTRO="ubuntu"
DISTRO_VERSION="24.04"
CONTAINER_MODEL="gemma4:12b"

# --- Step-8 hardening paths (site layout) ----------------------------------
# Each only matters for the matching --with-* feature. Override in site.conf
# for a site whose shared-filesystem layout differs from the reference cluster.
#
# Slurm site prolog/epilog root — the --comment=ollama daemon-gating drop-ins
# are installed under ${SLURMSCRIPTS_DIR}/{prolog.d,epilog.d} (--with-comment-gating).
SLURMSCRIPTS_DIR="/shared/share/slurmscripts"
# Per-node local NVMe cache DESTINATION for the model store (--with-model-cache).
# The rsync SOURCE is taken from OLLAMA_MODELS in the unit file (MODELS_DIR), so
# it tracks the model store automatically — only the destination is set here.
MODEL_CACHE_DIR="/var/local/cache/ollama"
# Knowledge-base inputs dir watched by the auto-ingest units (--with-auto-ingest).
# NOTE: the agent-side path also appears in the AGENTS personas + README, which
# this script does NOT rewrite — a relocated KB needs those edited too.
KB_INPUTS_DIR="/shareddata/rocbudai/docs/inputs"

# --- Provisioning image-bake knobs (--image-bake CHROOT) -------------------
# GPU dies per node; used to compute the static LLM/bench GPU split
# (LLM on dies 0..N-2, rocbudai-bench on die N-1). <2 skips the split.
IMAGE_GPU_COUNT=4
# systemd AllowedCPUs= for the LLM dies. Empty = GPU isolation only (safe);
# NUMA topology is node-specific, so derive it on a booted node with
# libexec/rocbudai-detect-topology.sh (its ROCBUDAI_LLM_CPUS value) and set here.
IMAGE_ALLOWED_CPUS=""
# 1 = enable ollama.service at boot in the image; 0 = leave disabled so the
# --comment=ollama Slurm prolog starts it per job.
IMAGE_ENABLE_OLLAMA=1

# NOTE: the on-disk model store path is NOT a CONFIGURATION knob. It is
# read from deploy/ollama-daemon/ollama.service (the OLLAMA_MODELS=…
# Environment= line) at script start, see MODELS_DIR derivation in the
# Internals block below. To change it, edit the unit file — that file
# is the single source of truth, since the daemon itself reads from
# whatever value lives there. Having a parallel knob in this script
# would silently desync the daemon's view from the script's view.

# These hardening toggles are normally driven by --with-hardening (all on
# or all off). If a site wants à-la-carte hardening, flip individual
# values here. See INSTALL.md §8 for what each one does.
WITH_AUTH=0
WITH_COMMENT_GATING=0
WITH_AIRGAP=0
WITH_AUTO_INGEST=0
WITH_MODEL_CACHE=0
WITH_USAGE=0

# ---------------------------------------------------------------------------
# Internals — do not edit below this line for normal installs.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# One file to hold all site-specific values: copy site.conf.example to
# site.conf and edit it. Sourced here so it overrides the CONFIGURATION
# defaults above; CLI flags (parsed below) and the container's MODEL_NAME env
# (_MODEL_NAME_ENV) still win.
#
# site.conf applies to real HOST installs only. The --container quick-test is
# hermetic: it ignores site.conf (the repo — and thus any site.conf — is
# bind-mounted into the container, but we skip it) so a site's production
# config can never leak into the throwaway test. We detect --container from
# the raw args (not yet parsed here) and ROCBUDAI_CONTAINER=1 (set by the
# in-container re-invocation).
_skip_site_conf="${ROCBUDAI_CONTAINER:-0}"
for _a in "$@"; do [[ "${_a}" == "--container" ]] && _skip_site_conf=1; done
if [[ -f "${SCRIPT_DIR}/site.conf" && "${_skip_site_conf}" != "1" ]]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/site.conf"
fi
unset _a _skip_site_conf
MODEL_NAME="${_MODEL_NAME_ENV:-${MODEL_NAME}}"

INSTALL_ROOT_DEFAULT="/shared/apps/ubuntu/opt/rocbudai"
MODEL_NAME_DEFAULT="qwen3.5:122b"
OPENCODE_ROOT_DEFAULT="/shared/apps/ubuntu/opt/opencode"
OPENCODE_VERSION_DEFAULT="1.14.28"
# Value shipped in the modulefile's setenv("ROCBUDAI_SPX_PARTITIONS", …);
# step 6 rewrites it to SPX_PARTITIONS when they differ.
SPX_PARTITIONS_DEFAULT="PPAC_MI300A_SPX"

# Shipped-default literals for the step-8 path knobs, used to sed-retarget the
# deployed unit files when a site overrides them. These MUST match the literal
# paths baked into the deploy/* artefacts.
MODEL_CACHE_DIR_DEFAULT="/var/local/cache/ollama"
KB_INPUTS_DIR_DEFAULT="/shareddata/rocbudai/docs/inputs"
# The OLLAMA_MODELS value shipped in deploy/ollama-daemon/ollama.service, which
# is also the rsync-source literal in deploy/model-cache/rocbudai-model-cache.service.
MODELS_DIR_SHIPPED="/shareddata/Ollama_Models"

# Derive MODELS_DIR from the systemd unit file (single source of truth;
# see the NOTE in CONFIGURATION above). If the unit file's grammar ever
# changes, this regex is the place to update.
OLLAMA_UNIT_FILE="${REPO_ROOT}/deploy/ollama-daemon/ollama.service"
if [[ ! -f "${OLLAMA_UNIT_FILE}" ]]; then
    echo "ERROR: ${OLLAMA_UNIT_FILE} not found — am I in the rocbudai_github checkout?" >&2
    exit 1
fi
MODELS_DIR="$(sed -n 's/^Environment="OLLAMA_MODELS=\([^"]*\)".*/\1/p' "${OLLAMA_UNIT_FILE}" | head -1)"
if [[ -z "${MODELS_DIR}" ]]; then
    echo "ERROR: could not parse OLLAMA_MODELS= from ${OLLAMA_UNIT_FILE}" >&2
    exit 1
fi

DRY_RUN=0
ASSUME_YES=0
IMAGE_BAKE=0
IMAGE_BAKE_CHROOT=""

usage() {
    cat <<EOF
install.sh — Install rocBudAI per INSTALL.md.

Runs INSTALL.md steps 1-7 (mandatory) by default. Step 8 hardening
features are opt-in via --with-hardening.

Options:
  -y, --yes           Don't prompt before starting.
      --dry-run       Print every command without executing.
      --with-hardening
                      Also install ALL step 8 features: ollama auth
                      hardening, --comment=ollama daemon gating, airgap
                      baseline, auto-ingest path watcher (login node
                      only), local NVMe model cache, daily usage
                      tracking. See INSTALL.md §8 for details. For
                      à-la-carte hardening, leave this flag off and
                      flip individual WITH_* vars in CONFIGURATION.
      --gfx-arch ARCH GPU architecture (default: autodetect via rocminfo).
                      Supported: ${SUPPORTED_GFX_ARCHS}. Anything else aborts.
                      HOST INSTALL ONLY — not valid with --container (see below).
      --partition P   Slurm partition(s) rocBudAI may launch on, comma-
                      separated (default: ${SPX_PARTITIONS}). Baked into the
                      deployed modulefile. Use --partition '' to disable the
                      partition gate. (No effect with --container.)

  Container quick-test mode (NOT for production):
      --container     From inside an existing Slurm allocation, pull a ROCm dev
                      image, run rocBudAI inside it (small model
                      '${CONTAINER_MODEL}', no GPU fencing, arch autodetected),
                      clone the AMD HPC training examples, and drop into a shell
                      where 'rocbudai-tui' runs directly (no module load).
      --rocm-version V    ROCm version for the image (default: ${ROCM_VERSION}).
      --distro D          Distro for the image (default: ${DISTRO}).
      --distro-version V  Distro version for the image (default: ${DISTRO_VERSION}).

  Provisioning image-bake mode (flat, no live services):
      --image-bake CHROOT
                      Lay the PER-NODE ollama pieces into a provisioning image
                      chroot (e.g. a Warewulf <chroots>/<img>/rootfs) and enable
                      the boot-time services OFFLINE. Does NOT start any service,
                      reload systemd, or pull a model — a chroot has no PID-1
                      systemd or GPU, so those happen at first boot on a real
                      node (the model already lives on the NFS store). Bakes the
                      ollama unit + optional proxy drop-in + static GPU split +
                      NVMe model-cache + the 'ollama' user. Tunables:
                      IMAGE_GPU_COUNT, IMAGE_ALLOWED_CPUS, IMAGE_ENABLE_OLLAMA
                      (see CONFIGURATION). Shared components (opencode/tree/
                      modulefile) are NOT baked; install them once on the NFS
                      share with a normal run.

      The ONLY flags that apply with --container are --rocm-version, --distro,
      --distro-version (and --dry-run to preview). --gfx-arch is rejected;
      --partition and --with-hardening are ignored (with a warning), because
      the container assumes an already-allocated GPU node and is a quick test,
      not a real deployment.

  -h, --help          This help.

Examples:
  sudo ./install.sh --yes                       # vanilla install (autodetect arch)
  sudo ./install.sh --yes --with-hardening      # full reference-cluster install
  sudo ./install.sh --yes --partition my_gpu_q  # install for a different Slurm partition
  sudo ./install.sh --yes --gfx-arch gfx950     # force the GPU arch (skip autodetect)
  ./install.sh --dry-run --with-hardening       # preview without changing anything
  ./install.sh --container                      # quick-test in a container (inside salloc)
  ./install.sh --container --rocm-version 6.4.1 # quick-test pinning the image tag

To override paths (install root, model name, etc.), edit the
CONFIGURATION block at the top of this script. Defaults match
INSTALL.md verbatim.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        --with-hardening)
            WITH_AUTH=1; WITH_COMMENT_GATING=1; WITH_AIRGAP=1
            WITH_AUTO_INGEST=1; WITH_MODEL_CACHE=1; WITH_USAGE=1
            shift ;;
        --gfx-arch)
            GFX_ARCH="${2:?--gfx-arch requires an argument}"; shift 2 ;;
        --partition)
            SPX_PARTITIONS="${2-}"; shift 2 ;;
        --container)
            CONTAINER=1; shift ;;
        --rocm-version)
            ROCM_VERSION="${2:?--rocm-version requires an argument}"; shift 2 ;;
        --distro)
            DISTRO="${2:?--distro requires an argument}"; shift 2 ;;
        --distro-version)
            DISTRO_VERSION="${2:?--distro-version requires an argument}"; shift 2 ;;
        --image-bake)
            IMAGE_BAKE=1; IMAGE_BAKE_CHROOT="${2:?--image-bake requires a chroot path}"; shift 2 ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            echo "Try: $0 --help" >&2
            exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours / logging helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_RESET=""
fi

section() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"; }
info()    { printf '    %s\n' "$*"; }
warn()    { printf '%s[warn]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
ok()      { printf '%s[ ok ]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
die()     { printf '%s[fail]%s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }
# version_ge A B → true if version A >= version B (dotted numeric, via sort -V).
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# ---------------------------------------------------------------------------
# sudo / run helpers (honour --dry-run; auto-prefix sudo when not root)
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        SUDO=""
        warn "Not running as root and 'sudo' not found — privileged commands will fail."
    fi
fi

# Print a command in dim grey, then run it (or just print under --dry-run).
run() {
    printf '    %s$ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        "$@"
    fi
}

# Same, but prefix with sudo when needed.
run_root() {
    if [[ -n "${SUDO}" ]]; then
        run "${SUDO}" "$@"
    else
        run "$@"
    fi
}

# Run a shell pipeline string (when we genuinely need shell features like
# heredocs or pipes) under sudo. Use sparingly — prefer run_root for simple
# argv calls.
run_root_sh() {
    local cmd="$*"
    printf '    %s$ %s%s%s\n' "${C_DIM}" "${SUDO:+sudo }" "${cmd}" "${C_RESET}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        if [[ -n "${SUDO}" ]]; then
            ${SUDO} bash -c "${cmd}"
        else
            bash -c "${cmd}"
        fi
    fi
}

confirm() {
    local prompt="$1"
    if [[ ${ASSUME_YES} -eq 1 ]]; then
        info "[--yes] ${prompt}: assuming yes"
        return 0
    fi
    read -r -p "    ${prompt} [y/N] " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# systemd detection + ollama-unit env extraction
# ---------------------------------------------------------------------------

# have_systemd: returns 0 if PID 1 is a working systemd we can drive
# via systemctl, 1 otherwise. The /run/systemd/system directory is
# the canonical "systemd is booted" indicator (sd_booted(3)); checking
# it avoids spawning systemctl in containers / chroots where systemctl
# either is missing or hangs trying to reach a non-existent bus.
#
# When this returns 1, step 2 and step 3 fall back to a "launch
# 'ollama serve' as a plain background process" path so install.sh
# still completes end-to-end inside test containers (HPCTrainingDock,
# plain docker/podman, dev workstations, etc.).
have_systemd() {
    [[ -d /run/systemd/system ]]
}

# Emit every Environment="KEY=VALUE" line from the canonical ollama
# unit file as a bare "KEY=VALUE" record. The unit file is the single
# source of truth for the daemon's env (same rule MODELS_DIR follows
# at script start) — both the systemd dispatch and the no-systemd
# launcher consult it via this helper.
ollama_env_kvs() {
    sed -n 's/^Environment="\([^"]*\)".*/\1/p' "${OLLAMA_UNIT_FILE}"
}

# Look up one Environment= value by key, e.g.
#   $(ollama_env_value OLLAMA_HOST)  →  "127.0.0.1:11435"
# Empty string if the key is not set in the unit file.
ollama_env_value() {
    local key="$1"
    ollama_env_kvs | sed -n "s/^${key}=\\(.*\\)/\\1/p" | head -1
}

# detect_gfx_arch: echo the first GPU agent's gfx arch (e.g. gfx942) from
# rocminfo, or nothing if undetectable. Ignores the amdgcn ISA / *-generic
# Name lines and CPU agents.
detect_gfx_arch() {
    local rocminfo=""
    if command -v rocminfo >/dev/null 2>&1; then
        rocminfo="rocminfo"
    elif [[ -x /opt/rocm/bin/rocminfo ]]; then
        rocminfo="/opt/rocm/bin/rocminfo"
    else
        return 1
    fi
    "${rocminfo}" 2>/dev/null | awk '
        /^[[:space:]]*Name:[[:space:]]+gfx[0-9a-f]+[[:space:]]*$/ { gfx=$2 }
        /Device Type:[[:space:]]+GPU/ { if (gfx != "") { print gfx; exit } }'
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

preflight() {
    section "Preflight"
    info "Repo root      : ${REPO_ROOT}"
    info "Install root   : ${INSTALL_ROOT}"
    info "OpenCode root  : ${OPENCODE_ROOT}"
    info "OpenCode ver   : ${OPENCODE_VERSION}"
    info "Site modules   : ${SITE_MODULES}"
    info "Models dir     : ${MODELS_DIR}"
    info "Model          : ${MODEL_NAME}"
    info "Slurm part(s)  : ${SPX_PARTITIONS:-<none — partition gate disabled>}"
    info "Slurmscripts   : ${SLURMSCRIPTS_DIR}"
    info "Model cache dir: ${MODEL_CACHE_DIR}"
    info "KB inputs dir  : ${KB_INPUTS_DIR}"
    info "Dry-run        : $([[ ${DRY_RUN} -eq 1 ]] && echo yes || echo no)"
    info "Sudo prefix    : ${SUDO:-<none, running as root>}"

    # Resolve + validate the GPU arch (explicit --gfx-arch wins, else
    # autodetect). Unsupported arch aborts before any change is made.
    if [[ -z "${GFX_ARCH}" ]]; then
        GFX_ARCH="$(detect_gfx_arch || true)"
    fi
    [[ -n "${GFX_ARCH}" ]] || die "could not detect GPU arch via rocminfo; pass --gfx-arch (supported: ${SUPPORTED_GFX_ARCHS})"
    case " ${SUPPORTED_GFX_ARCHS} " in
        *" ${GFX_ARCH} "*) info "GPU arch       : ${GFX_ARCH}" ;;
        *) die "unsupported GPU arch '${GFX_ARCH}'. Supported: ${SUPPORTED_GFX_ARCHS}" ;;
    esac

    # Verify we look like the rocBudAI source tree.
    for d in bin libexec share/rocbudai modulefiles/rocbudai deploy/ollama-daemon; do
        [[ -d "${REPO_ROOT}/${d}" ]] || die "Expected '${REPO_ROOT}/${d}' to exist — am I really in the rocbudai_github checkout?"
    done

    # Step 8 hardening features mutate /usr/local/bin/ollama (auth
    # wrapper rename), drop systemd units, and enable services. None
    # of that is meaningful without systemd, and the auth rename in
    # particular leaves the system in a half-broken state if we let
    # it run and then trip over systemctl. Detect early.
    if ! have_systemd; then
        local hardening_requested=0
        (( WITH_AUTH          )) && hardening_requested=1
        (( WITH_AIRGAP        )) && hardening_requested=1
        (( WITH_AUTO_INGEST   )) && hardening_requested=1
        (( WITH_MODEL_CACHE   )) && hardening_requested=1
        if (( hardening_requested )); then
            warn "Step 8 hardening features require systemd, but no /run/systemd/system was found."
            warn "On this host, the following will be SKIPPED (logged again at each step):"
            (( WITH_AUTH        )) && warn "    - --with-auth          (ollama auth wrapper + proxy + acl)"
            (( WITH_AIRGAP      )) && warn "    - --with-airgap        (nft egress + ollama-egress.service)"
            (( WITH_AUTO_INGEST )) && warn "    - --with-auto-ingest   (rocbudai-ingest-inputs.{path,timer})"
            (( WITH_MODEL_CACHE )) && warn "    - --with-model-cache   (rocbudai-model-cache.service)"
            warn "Steps 1-7 will still run normally. Re-run on a systemd host (or"
            warn "without --with-hardening) to install the gated features."
            WITH_AUTH=0
            WITH_AIRGAP=0
            WITH_AUTO_INGEST=0
            WITH_MODEL_CACHE=0
        fi
    fi

    if [[ ${ASSUME_YES} -eq 0 && ${DRY_RUN} -eq 0 ]]; then
        confirm "Proceed with install?" || die "User aborted."
    fi
}

# ---------------------------------------------------------------------------
# Service-user resolution
# ---------------------------------------------------------------------------
#
# The upstream ollama installer creates the 'ollama' system user only as
# part of its systemd setup. On a no-systemd container that user does not
# exist, so anything that runs the daemon/CLI as 'ollama' (runuser, sudo -u,
# install -o) fails with "invalid user 'ollama'". Resolve once: use 'ollama'
# when it exists (production), else fall back to the current (root) user.
_OLLAMA_SVC_USER=""
ollama_svc_user() {
    if [[ -z "${_OLLAMA_SVC_USER}" ]]; then
        if id ollama >/dev/null 2>&1; then
            _OLLAMA_SVC_USER=ollama
        else
            _OLLAMA_SVC_USER="$(id -un)"
        fi
    fi
    printf '%s' "${_OLLAMA_SVC_USER}"
}

ollama_svc_group() {
    local u; u="$(ollama_svc_user)"
    if [[ "${u}" == ollama ]]; then printf 'ollama'; else id -gn; fi
}

# Resolve the ollama binary to an ABSOLUTE path. `sudo -u ollama … ollama` runs
# with sudo's secure_path (typically /sbin:/bin:/usr/sbin:/usr/bin), which does
# NOT include /usr/local/bin where the vendor installer puts ollama — so a bare
# name yields "sudo: ollama: command not found". The absolute path sidesteps it.
ollama_bin() {
    if command -v ollama >/dev/null 2>&1; then
        command -v ollama
    elif [[ -x /usr/local/bin/ollama ]]; then
        printf '/usr/local/bin/ollama'
    else
        printf 'ollama'
    fi
}

# Run the ollama CLI as the resolved service user, forwarding OLLAMA_HOST.
# When the service user is the current user we skip sudo entirely (sudo may
# not even be installed in a minimal container).
run_ollama_cli() {
    local host="$1"; shift
    local u obin; u="$(ollama_svc_user)"; obin="$(ollama_bin)"
    if [[ "${u}" == "$(id -un)" ]]; then
        run_root env "OLLAMA_HOST=${host}" "${obin}" "$@"
    else
        run_root sudo -u "${u}" "OLLAMA_HOST=${host}" -- "${obin}" "$@"
    fi
}

# ---------------------------------------------------------------------------
# No-systemd launcher (used by step 2's fallback path)
# ---------------------------------------------------------------------------

# Launch 'ollama serve' as the 'ollama' user without systemd, sourcing
# the env block (OLLAMA_MODELS, OLLAMA_HOST, OLLAMA_SCHED_SPREAD, …)
# from the canonical unit file. Used by step 2 when have_systemd
# returns false (test containers, dev workstations, …).
#
# The daemon is detached via 'setsid --fork' so it survives this
# script's exit, and stdout/stderr go to /var/log/rocbudai/ollama.log.
# We then poll the daemon's HTTP API until it answers (max 60 s) so
# that step 3's 'ollama pull' has someone to talk to.
start_ollama_no_systemd() {
    # The upstream ollama installer creates the 'ollama' system user only
    # as part of its systemd setup, so in a no-systemd container that user
    # does not exist. Fall back to running the throwaway test daemon as the
    # current (root) user — which also sidesteps render/video GPU-group
    # membership. Production always has systemd and the 'ollama' user.
    local svc_user svc_group launch_prefix
    svc_user="$(ollama_svc_user)"
    svc_group="$(ollama_svc_group)"
    if [[ "${svc_user}" == ollama ]]; then
        launch_prefix="setsid --fork runuser -u ollama --"
    else
        warn "user 'ollama' does not exist (the upstream installer skips it without"
        warn "systemd); running the test daemon as '${svc_user}' instead."
        launch_prefix="setsid --fork"
    fi

    info "Starting 'ollama serve' as user '${svc_user}' (no systemd; container/test mode)."

    run_root install -d -m 2775 -o "${svc_user}" -g "${svc_group}" "${MODELS_DIR}"
    run_root install -d -m 0755 -o root          -g root          /var/log/rocbudai
    run_root install -m 0644    -o "${svc_user}" -g "${svc_group}" /dev/null /var/log/rocbudai/ollama.log

    # Build the "KEY=VAL KEY=VAL …" arg list for `env` from the unit
    # file. Same source of truth as the systemd path.
    local env_args=() kv
    while IFS= read -r kv; do
        [[ -n "${kv}" ]] && env_args+=("${kv}")
    done < <(ollama_env_kvs)
    info "Env from unit file: ${env_args[*]}"

    # setsid --fork detaches from this script's session; runuser (when the
    # ollama user exists) drops privileges; env applies the unit-file env;
    # the >> redirect (opened by the root shell) is inherited as-is.
    local cmd="${launch_prefix} env ${env_args[*]} /usr/local/bin/ollama serve >>/var/log/rocbudai/ollama.log 2>&1"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        run_root_sh "${cmd}"
    else
        printf '    %s$ %s%s\n' "${C_DIM}" "${cmd}" "${C_RESET}"
    fi

    local host
    host="$(ollama_env_value OLLAMA_HOST)"
    host="${host:-127.0.0.1:11435}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        info "[--dry-run] would poll http://${host}/api/version until ready"
        return 0
    fi

    info "Waiting (up to 60s) for ollama HTTP API at http://${host} ..."
    local i
    for i in $(seq 1 60); do
        if curl -fsS --max-time 2 "http://${host}/api/version" >/dev/null 2>&1; then
            ok "ollama daemon up on http://${host}"
            return 0
        fi
        sleep 1
    done

    warn "Timed out waiting for ollama on http://${host}. Last 40 lines of log:"
    [[ -r /var/log/rocbudai/ollama.log ]] && tail -40 /var/log/rocbudai/ollama.log >&2 || true
    return 1
}

# ---------------------------------------------------------------------------
# Step 1 hardening — assert ollama's GPU backend actually loads
# ---------------------------------------------------------------------------
#
# Guards against the silent "ROCm backend fails to load -> CPU fallback"
# failure mode: ollama can be perfectly installed and the daemon can come
# up "active", yet enumerate ZERO GPUs — e.g. a stale/mismatched ollama
# bundle whose rocm libs dangle (libggml-hip.so's deps unresolved), or a
# newer ollama that drops integrated GPUs (MI300A APUs) unless
# OLLAMA_IGPU_ENABLE=1. When that happens a large model loads 100% on CPU
# and every turn takes 10-15 min, so the daemon looks healthy but the TUI
# just hangs on "model warming up". We catch it at install time instead of
# letting a user discover it the hard way.
#
# Only enforced when ROCm actually sees the hardware: if rocminfo reports a
# gfx agent but ollama's own discovery finds no ROCm device, that is the
# dangerous mismatch -> hard fail. If rocminfo finds no GPU at all (CI /
# GPU-less container / dev box) we skip silently — step 1 already warned
# about missing ROCm above, and a no-GPU host is a legitimate test target.
#
# Escape hatch: ROCBUDAI_SKIP_GPU_PROBE=1 bypasses the assertion.
probe_ollama_gpu_or_die() {
    if [[ "${ROCBUDAI_SKIP_GPU_PROBE:-0}" == "1" ]]; then
        info "GPU backend probe skipped (ROCBUDAI_SKIP_GPU_PROBE=1)."
        return 0
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        info "[dry-run] would run a one-shot ollama GPU discovery and fail if 0 GPUs enumerate."
        return 0
    fi

    # Only meaningful when ROCm sees the hardware. Reuse the same rocminfo
    # lookup convention as detect_gfx_arch (PATH, then /opt/rocm/bin).
    local rocminfo=""
    if command -v rocminfo >/dev/null 2>&1; then
        rocminfo="rocminfo"
    elif [[ -x /opt/rocm/bin/rocminfo ]]; then
        rocminfo="/opt/rocm/bin/rocminfo"
    fi
    if [[ -z "${rocminfo}" ]] || ! "${rocminfo}" 2>/dev/null | grep -qE 'Name:[[:space:]]+gfx'; then
        info "No ROCm GPU agent visible to rocminfo — skipping ollama GPU probe (GPU-less host)."
        return 0
    fi

    # Prefer the real binary: after step 8 auth-hardening the public
    # /usr/local/bin/ollama is a wrapper that forwards 'serve' to
    # ollama-real; before it, the vendor binary is 'ollama'. ollama-real
    # makes the probe wrapper-independent.
    local obin=""
    if [[ -x /usr/local/bin/ollama-real ]]; then
        obin="/usr/local/bin/ollama-real"
    elif command -v ollama >/dev/null 2>&1; then
        obin="$(command -v ollama)"
    fi
    if [[ -z "${obin}" ]]; then
        warn "ollama binary not found on PATH — cannot run GPU probe."
        return 0
    fi

    # MI300A (and other APU) dies are 'integrated' GPUs, which recent ollama
    # drops unless OLLAMA_IGPU_ENABLE=1. Mirror the deployed unit's value so
    # the probe reflects production; default to 1 (rocBudAI's APU target —
    # harmless on discrete GPUs, which have no integrated device to enable).
    local igpu
    igpu="$(ollama_env_value OLLAMA_IGPU_ENABLE 2>/dev/null || true)"
    [[ -n "${igpu}" ]] || igpu=1

    info "Probing ollama GPU discovery (one-shot serve on 127.0.0.1:11499) …"
    local tmpout tmpmodels ngpu
    tmpout="$(mktemp)"
    tmpmodels="$(mktemp -d)"
    # Throwaway serve on a nonstandard port with an empty model dir: this only
    # exercises GPU discovery, loads no model, and touches neither the real
    # model store nor the :11435 daemon. `timeout` ends it after discovery.
    run_root_sh "OLLAMA_DEBUG=1 OLLAMA_IGPU_ENABLE='${igpu}' OLLAMA_HOST=127.0.0.1:11499 OLLAMA_MODELS='${tmpmodels}' timeout 30 '${obin}' serve > '${tmpout}' 2>&1 || true"

    # Count only *enabled* ROCm devices — the 'inference compute' lines.
    # Deliberately NOT the 'dropping integrated GPU' lines (those also carry
    # library=ROCm but mean the device was discarded).
    ngpu="$(grep -cE 'msg="inference compute".*library=ROCm' "${tmpout}" 2>/dev/null || true)"
    [[ -n "${ngpu}" ]] || ngpu=0

    if [[ "${ngpu}" -ge 1 ]]; then
        ok "ollama enumerated ${ngpu} ROCm GPU device(s) — GPU backend loads correctly."
        rm -rf "${tmpout}" "${tmpmodels}"
        return 0
    fi

    # Zero enabled ROCm devices despite rocminfo seeing the hardware: broken.
    local dbg="/tmp/rocbudai-ollama-gpu-probe.log"
    cp -f "${tmpout}" "${dbg}" 2>/dev/null || true
    warn "ollama discovered NO usable ROCm GPUs, yet rocminfo sees gfx hardware."
    warn "This is the silent CPU-fallback failure mode: models would load on CPU"
    warn "and every turn would take many minutes (the TUI hangs on 'model warming"
    warn "up'). Common causes:"
    warn "  - stale/mismatched ollama ROCm bundle — dangling deps under"
    warn "    /usr/local/lib/ollama/rocm*; check 'ldd .../libggml-hip.so'."
    warn "  - integrated GPUs (MI300A APUs) dropped without OLLAMA_IGPU_ENABLE=1."
    warn "Discovery log (last 20 lines; full copy at ${dbg}):"
    tail -20 "${tmpout}" >&2 2>/dev/null || true
    rm -rf "${tmpout}" "${tmpmodels}"
    die "ollama GPU backend probe failed (0 usable ROCm devices). Fix the bundle, or set ROCBUDAI_SKIP_GPU_PROBE=1 to bypass."
}

# ---------------------------------------------------------------------------
# Step 1 — Install Ollama (compute nodes)
# ---------------------------------------------------------------------------

step_1_install_ollama() {
    section "Step 1/7 — Install Ollama (compute node)"

    # Ollama is **not** in stock Ubuntu 22.04 / 24.04 apt repositories,
    # and we don't want this script to depend on whether a given cluster
    # happens to mirror it via a custom apt source. The canonical path
    # is the upstream vendor installer, which:
    #   - places the binary at /usr/local/bin/ollama (matches the path
    #     used by the step-2 systemd unit and the step-8 auth wrapper),
    #   - creates the 'ollama' system user,
    #   - drops a vendor systemd unit (harmlessly overwritten by step 2).
    #
    # A sysadmin who has already pre-staged ollama via their own
    # provisioning mechanism (Warewulf base image, custom apt source,
    # manual rsync, etc.) is caught by the `command -v ollama` early
    # exit below — we don't try to second-guess that case.
    if command -v ollama >/dev/null 2>&1; then
        info "ollama already on PATH at $(command -v ollama). Skipping install."
        # A bare 'curl|sh' (no OLLAMA_VERSION) installs 'latest' AND overwrites
        # our unit — the recurring MI300A CPU-fallback regression.
        local _have
        _have="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [[ -n "${_have}" && "${_have}" != "${OLLAMA_VERSION}" ]]; then
            warn "Installed ollama ${_have} != pinned ${OLLAMA_VERSION}. Re-pin with:"
            warn "  curl -fsSL https://ollama.com/install.sh | sudo OLLAMA_VERSION=${OLLAMA_VERSION} sh"
            warn "then re-run this script so step 2 re-asserts our unit."
        fi
    else
        # Host prereqs for the vendor installer:
        #   - zstd: recent vendor installers ship the binary as
        #     ollama-linux-amd64.tar.zst and abort if zstd is missing.
        #   - curl + ca-certificates: needed to fetch the install
        #     script over HTTPS.
        # apt-get update first because minimal Ubuntu rootfs images
        # (incl. the bare_system Dockerfile) ship with empty
        # /var/lib/apt/lists/ and the install fails otherwise.
        if command -v apt-get >/dev/null 2>&1; then
            info "Refreshing apt cache and installing host prerequisites (zstd, curl, ca-certificates)."
            run_root apt-get update
            run_root apt-get install -y zstd curl ca-certificates
        fi

        info "Installing ollama ${OLLAMA_VERSION} via the upstream vendor installer (pinned)."
        if ! command -v curl >/dev/null 2>&1; then
            die "curl is required for the upstream Ollama installer but is not on PATH. Install it (e.g. 'apt-get install -y curl') and re-run."
        fi
        # When SITE_HTTP_PROXY is set, prefix both the curl fetch and the piped
        # installer (which downloads the ollama tarball) so both reach the net.
        local _px=""
        [[ -n "${SITE_HTTP_PROXY}" ]] && _px="https_proxy='${SITE_HTTP_PROXY}' http_proxy='${SITE_HTTP_PROXY}' no_proxy='${SITE_NO_PROXY}' "
        run_root_sh "${_px}curl -fsSL https://ollama.com/install.sh | ${_px}OLLAMA_VERSION='${OLLAMA_VERSION}' sh"

        # The vendor installer probes for an AMD/NVIDIA GPU via lspci/lshw
        # (neither of which we ship in the bare_system rootfs) and, if it
        # can't find one, prints:
        #   WARNING: Unable to detect NVIDIA/AMD GPU. Install lspci or
        #            lshw to automatically detect and install GPU
        #            dependencies.
        # That message is benign on a rocBudAI cluster IF ROCm is already
        # installed (which is the assumption — see "Prerequisites" in
        # INSTALL.md). Verify here so the user gets a clear ROCm-specific
        # next step instead of trying to debug an opaque upstream warning.
        info "Verifying ROCm is installed (required for AMD GPU acceleration)."
        if command -v rocminfo >/dev/null 2>&1; then
            if rocminfo >/dev/null 2>&1; then
                ok "rocminfo runs — ROCm appears installed and usable."
            else
                warn "rocminfo is on PATH but failed to run. Check /dev/kfd permissions,"
                warn "kernel module 'amdgpu', and that the user is in the 'render' and 'video' groups."
            fi
        else
            warn "rocminfo not found — ROCm does not appear to be installed."
            warn "ollama will fall back to CPU inference (slow) or fail to load larger models."
            warn "Install ROCm before continuing. Two supported paths:"
            warn ""
            warn "  1. HPCTrainingDock rocm_setup.sh (recommended; same script the"
            warn "     reference cluster's base image uses):"
            warn "       https://github.com/amd/HPCTrainingDock/blob/main/rocm/scripts/rocm_setup.sh"
            warn ""
            warn "  2. Spack (for sites that already manage their software stack"
            warn "     with Spack):"
            warn "       spack install rocm     # then 'spack load rocm' before re-running install.sh"
            warn ""
            warn "After ROCm is installed and 'rocminfo' works, re-run this script;"
            warn "step 1 will detect the existing ollama binary and skip the vendor"
            warn "install, then continue with the rest of the recipe."
        fi
    fi

    info "Verifying 'ollama' system user owns /usr/share/ollama …"
    if id ollama >/dev/null 2>&1; then
        ok "user 'ollama' exists"
    else
        warn "user 'ollama' does not exist — install may not have created it"
    fi

    if [[ -d /usr/share/ollama ]]; then
        local owner
        owner="$(stat -c '%U:%G' /usr/share/ollama 2>/dev/null || echo unknown)"
        if [[ "${owner}" != "ollama:ollama" ]]; then
            warn "/usr/share/ollama owner is '${owner}', not ollama:ollama — fixing."
            run_root chown -R ollama:ollama /usr/share/ollama
        else
            ok "/usr/share/ollama owner = ollama:ollama"
        fi
    else
        warn "/usr/share/ollama does not exist (probably ok on a fresh image; daemon will create it)."
    fi

    # Hardening: assert the GPU backend actually loads before we go on to
    # configure the daemon. Fails loudly on the silent CPU-fallback bug
    # (broken rocm bundle / integrated-GPU drop) rather than at runtime.
    probe_ollama_gpu_or_die
}

# ---------------------------------------------------------------------------
# Step 2 — Configure Ollama for shared models + multi-GPU spread
# ---------------------------------------------------------------------------

step_2_configure_ollama() {
    if have_systemd; then
        section "Step 2/7 — Configure Ollama systemd unit"
    else
        section "Step 2/7 — Configure Ollama (no systemd; container/test mode)"
    fi

    local src="${REPO_ROOT}/deploy/ollama-daemon/ollama.service"
    local dst="/etc/systemd/system/ollama.service"
    [[ -f "${src}" ]] || die "Missing canonical unit file: ${src}"

    # We install the unit file in BOTH branches: it's the single source
    # of truth for the env block (the no-systemd launcher re-parses it),
    # and dropping it in the canonical location means an admin can later
    # `systemctl enable ollama` if/when a real systemd shows up.
    info "Installing ${dst} from ${src}"
    run_root install -d -m 0755 /etc/systemd/system
    run_root install -m 0644 -o root -g root "${src}" "${dst}"

    # When SITE_HTTP_PROXY is set, give the DAEMON the proxy via a drop-in: this
    # is what makes step 3's `ollama pull` work, since the daemon (not the shell)
    # performs the download. A drop-in survives re-deploys of the unit above.
    if [[ -n "${SITE_HTTP_PROXY}" ]]; then
        local proxy_dir="/etc/systemd/system/ollama.service.d"
        info "Installing proxy drop-in ${proxy_dir}/10-proxy.conf (HTTP(S)_PROXY=${SITE_HTTP_PROXY})"
        run_root install -d -m 0755 "${proxy_dir}"
        local proxy_tmp; proxy_tmp="$(mktemp)"
        {
            echo "[Service]"
            echo "Environment=\"HTTP_PROXY=${SITE_HTTP_PROXY}\""
            echo "Environment=\"HTTPS_PROXY=${SITE_HTTP_PROXY}\""
            echo "Environment=\"NO_PROXY=${SITE_NO_PROXY}\""
        } > "${proxy_tmp}"
        run_root install -m 0644 -o root -g root "${proxy_tmp}" "${proxy_dir}/10-proxy.conf"
        rm -f "${proxy_tmp}"
    fi

    if have_systemd; then
        run_root systemctl daemon-reload
        run_root systemctl restart ollama

        if [[ ${DRY_RUN} -eq 0 ]]; then
            if systemctl is-active --quiet ollama; then
                ok "ollama.service is active"
            else
                warn "ollama.service is NOT active — check 'journalctl -u ollama'"
            fi
            # Verify the daemon inherited our unit's env; a vendor-stub unit
            # drops these and the .d drop-ins alone don't restore them. The
            # expected host is derived from the unit file (single source of truth).
            local _want_host _oenv
            _want_host="$(ollama_env_value OLLAMA_HOST)"
            _oenv="$(systemctl show ollama -p Environment 2>/dev/null)"
            if [[ -n "${_want_host}" && "${_oenv}" != *"OLLAMA_HOST=${_want_host}"* ]]; then
                warn "ollama env missing OLLAMA_HOST=${_want_host} (vendor-stub unit? TUI won't reach the daemon)."
            fi
            if [[ "${_oenv}" != *"OLLAMA_IGPU_ENABLE=1"* ]]; then
                warn "ollama env missing OLLAMA_IGPU_ENABLE=1 (integrated GPUs / APUs fall back to CPU)."
            fi
        fi
    else
        warn "PID 1 is not systemd (no /run/systemd/system found). Skipping"
        warn "systemctl daemon-reload / restart and launching 'ollama serve'"
        warn "as a plain background process instead. This is the test-container"
        warn "fallback; production compute nodes should have systemd."
        start_ollama_no_systemd || die "Failed to start ollama daemon."
    fi

    # Warewulf image bake: auto-detected. If wwctl is installed AND the image
    # rootfs exists, replicate the unit file there so it survives node
    # re-provisioning, then rebuild the bootable image. Sites without Warewulf
    # skip this silently.
    #
    # Warewulf 4.x lays images out as <chroots>/<image-name>/rootfs, so the
    # image NAME `wwctl container build` expects is the *parent* dir's name
    # (basename of WAREWULF_CHROOT is just "rootfs"). Fall back to the plain
    # basename if a site points WAREWULF_CHROOT straight at an image dir.
    if command -v wwctl >/dev/null 2>&1 && [[ -d "${WAREWULF_CHROOT}" ]]; then
        local ww_image
        if [[ "$(basename "${WAREWULF_CHROOT}")" == "rootfs" ]]; then
            ww_image="$(basename "$(dirname "${WAREWULF_CHROOT}")")"
        else
            ww_image="$(basename "${WAREWULF_CHROOT}")"
        fi
        section "Step 2 sidecar — Warewulf image '${ww_image}' detected, baking unit file"
        local chroot_dst="${WAREWULF_CHROOT}/etc/systemd/system/ollama.service"
        run_root install -D -m 0644 -o root -g root "${src}" "${chroot_dst}"
        run_root wwctl container build "${ww_image}"
    fi
}

# ---------------------------------------------------------------------------
# Step 2b — Reserve one GPU for rocbudai-bench (GPU/CPU fencing)
# ---------------------------------------------------------------------------
#
# Fences the ollama daemon onto GPUs 0..N-2 (ROCR_VISIBLE_DEVICES) and, when
# the CPU topology is cleanly derivable, onto the matching NUMA cores
# (AllowedCPUs), leaving the last GPU + its cores quiet for rocbudai-bench.
# Written as a systemd drop-in so it is independent of the canonical unit.
# Skipped without systemd or when ROCBUDAI_NO_FENCING=1 (container mode):
# there the LLM and bench share all GPUs on the node.
configure_gpu_split() {
    if [[ "${ROCBUDAI_NO_FENCING:-0}" == "1" ]]; then
        info "GPU/CPU fencing disabled (ROCBUDAI_NO_FENCING=1); LLM and bench share all GPUs."
        return 0
    fi
    if ! have_systemd; then
        info "No systemd — skipping GPU/CPU fencing drop-in (LLM and bench share all GPUs)."
        return 0
    fi

    section "Step 2b/7 — Reserve one GPU for rocbudai-bench"

    local topo
    topo="$(bash "${REPO_ROOT}/libexec/rocbudai-detect-topology.sh" 2>/dev/null || true)"
    local ROCBUDAI_GPU_COUNT="" ROCBUDAI_LLM_DEVICES="" ROCBUDAI_BENCH_GPU=""
    local ROCBUDAI_LLM_CPUS="" ROCBUDAI_BENCH_CPUS=""
    eval "${topo}"

    if [[ "${ROCBUDAI_GPU_COUNT:-0}" -lt 2 ]]; then
        warn "Detected ${ROCBUDAI_GPU_COUNT:-0} GPU(s); need >=2 to reserve a bench GPU — skipping fencing."
        return 0
    fi

    info "LLM GPUs: ${ROCBUDAI_LLM_DEVICES}   bench GPU: ${ROCBUDAI_BENCH_GPU}"
    local dropin="/etc/systemd/system/ollama.service.d/10-gpu-split.conf"
    local tmp
    tmp="$(mktemp)"
    {
        echo "[Service]"
        echo "Environment=\"ROCR_VISIBLE_DEVICES=${ROCBUDAI_LLM_DEVICES}\""
        if [[ -n "${ROCBUDAI_LLM_CPUS}" ]]; then
            echo "AllowedCPUs=${ROCBUDAI_LLM_CPUS}"
        fi
    } > "${tmp}"
    if [[ -z "${ROCBUDAI_LLM_CPUS}" ]]; then
        warn "CPU topology not cleanly derivable — GPU isolation only (no AllowedCPUs)."
    fi
    run_root install -D -m 0644 -o root -g root "${tmp}" "${dropin}"
    rm -f "${tmp}"

    run_root systemctl daemon-reload
    run_root systemctl restart ollama
}

# ---------------------------------------------------------------------------
# Step 3 — Pull the canonical model
# ---------------------------------------------------------------------------

step_3_pull_model() {
    section "Step 3/7 — Create model store and pull '${MODEL_NAME}'"

    run_root install -d -m 2775 -o "$(ollama_svc_user)" -g "$(ollama_svc_group)" "${MODELS_DIR}"

    # The ollama CLI honours OLLAMA_HOST to find the daemon. Our unit
    # file binds the daemon to 127.0.0.1:11435 (not the default 11434),
    # so we forward OLLAMA_HOST to the service user (via run_ollama_cli).
    # Without this, the pull would silently hit no daemon on :11434 before
    # step 8 deploys the auth-hardening proxy.
    local host
    host="$(ollama_env_value OLLAMA_HOST)"
    host="${host:-127.0.0.1:11435}"

    info "Pulling ${MODEL_NAME} as user '$(ollama_svc_user)' via OLLAMA_HOST=${host}"
    info "(this may take 10-30 min on a fresh cluster)…"
    run_ollama_cli "${host}" pull "${MODEL_NAME}"

    # Apply rocbudai SYSTEM-prompt augmentation (Phase 9.4b, 2026-05-13).
    # Stock models from ollama.com ship with no SYSTEM layer; the
    # overlay Modelfile in deploy/ollama-models/ adds the rocbudai
    # operating rules at the inference root. Skipped automatically
    # for any MODEL_NAME without a matching overlay (so admins can
    # still install with custom model names without an overlay file).
    # See deploy/ollama-models/README.md for rationale and rollback.
    apply_rocbudai_system_overlay "${host}" "${MODEL_NAME}"

    info "Listing models on the daemon …"
    run_ollama_cli "${host}" list
}

# ---------------------------------------------------------------------------
# Helper: apply the rocbudai SYSTEM-prompt overlay to a freshly-pulled model.
#
# Lives next to step_3 because that is the only call site today (fresh
# install). Admin re-pulls / SYSTEM-rules updates use a site-maintained
# parallel-ssh runbook, not this script.
# ---------------------------------------------------------------------------

apply_rocbudai_system_overlay() {
    local host="$1"
    local model_name="$2"
    local sanitized="${model_name//:/-}"
    local modelfile="${REPO_ROOT}/deploy/ollama-models/Modelfile.${sanitized}.rocbudai"

    if [[ ! -f "${modelfile}" ]]; then
        warn "No rocbudai SYSTEM overlay at ${modelfile} for ${model_name};"
        warn "skipping SYSTEM augmentation. The model will run with stock"
        warn "(no-SYSTEM) behaviour. To add rocbudai operating rules at the"
        warn "inference root, drop a Modelfile at the path above and re-run"
        warn "step 3 (or run \`ollama create ${model_name} -f <file>\` by hand)."
        return 0
    fi

    info "Applying rocbudai SYSTEM overlay to ${model_name}"
    info "  source: ${modelfile}"
    run_ollama_cli "${host}" create "${model_name}" -f "${modelfile}"
}

# ---------------------------------------------------------------------------
# Step 4 — Stage the OpenCode binary
# ---------------------------------------------------------------------------

step_4_stage_opencode() {
    section "Step 4/7 — Stage OpenCode v${OPENCODE_VERSION}"

    local dest_dir="${OPENCODE_ROOT}/${OPENCODE_VERSION}"
    local dest_bin="${dest_dir}/opencode"

    if [[ -x "${dest_bin}" ]]; then
        info "${dest_bin} already exists; skipping download. (Remove the file by hand to force a re-stage.)"
        return 0
    fi

    local stage
    stage="$(mktemp -d -t opencode-stage.XXXXXX)"
    info "Staging dir: ${stage}"

    local url="https://github.com/sst/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz"
    local _cx=()
    [[ -n "${SITE_HTTP_PROXY}" ]] && _cx=(--proxy "${SITE_HTTP_PROXY}")
    run curl -fL ${_cx[@]+"${_cx[@]}"} --output "${stage}/opencode-linux-x64.tar.gz" "${url}"

    # Verify the download against the in-repo provenance manifest before
    # extracting. See archive/opencode-${OPENCODE_VERSION}-provenance/README.md.
    local sums_file="${REPO_ROOT}/archive/opencode-${OPENCODE_VERSION}-provenance/SHA256SUMS.txt"
    if [[ -f "${sums_file}" ]]; then
        info "Verifying opencode-linux-x64.tar.gz against ${sums_file}"
        if [[ ${DRY_RUN} -eq 0 ]]; then
            ( cd "${stage}" && sha256sum -c "${sums_file}" ) \
                || die "sha256 mismatch: opencode-linux-x64.tar.gz differs from the in-repo provenance manifest. Refusing to install."
        fi
    else
        warn "No provenance manifest at ${sums_file}; skipping integrity check."
        warn "Add archive/opencode-${OPENCODE_VERSION}-provenance/SHA256SUMS.txt to enforce supply-chain verification."
    fi

    run tar -C "${stage}" -xzf "${stage}/opencode-linux-x64.tar.gz"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        [[ -x "${stage}/opencode" ]] || die "Extracted bundle missing executable opencode binary"
    fi

    run_root mkdir -p "${dest_dir}"
    run_root cp "${stage}/opencode" "${dest_bin}"
    run_root chown -R root:root "${OPENCODE_ROOT}"
    run_root chmod 0755 "${dest_bin}"

    if [[ ${DRY_RUN} -eq 0 ]]; then
        rm -rf "${stage}"
    fi
}

# ---------------------------------------------------------------------------
# Step 5 — Stage the rocBudAI install tree
# ---------------------------------------------------------------------------

step_5_stage_install_tree() {
    section "Step 5/7 — Stage install tree at ${INSTALL_ROOT}"

    run_root mkdir -p "${INSTALL_ROOT}"

    # The deployed install tree contains: bin/, libexec/, share/, modulefiles/.
    # (Per INSTALL.md §5; README/INSTALL.md/LICENSE etc. stay in the source repo.)
    #
    # Use `cp -R`, NOT `cp -a`: `-a` implies --preserve=all (ownership, ACLs,
    # xattrs, timestamps). Shared install filesystems (NFS/SMB/Lustre, etc.)
    # commonly don't support ACLs/xattrs, so `-a` aborts with
    # "preserving permissions ... Operation not supported". `-R` copies content
    # + POSIX mode bits only; ownership and exec bits are restored explicitly
    # below, so nothing we actually need is lost.
    for sub in bin libexec share modulefiles; do
        [[ -d "${REPO_ROOT}/${sub}" ]] || die "Source '${REPO_ROOT}/${sub}' missing"
        info "Copying ${sub}/ → ${INSTALL_ROOT}/${sub}/"
        run_root cp -R "${REPO_ROOT}/${sub}/." "${INSTALL_ROOT}/${sub}/"
    done

    run_root chown -R root:root "${INSTALL_ROOT}"

    # Normalise perms independent of the copy FS and the caller's umask: make
    # the tree group/world-readable (and dirs traversable), then force the
    # launchers/helpers in bin/ and libexec/ executable.
    run_root chmod -R a+rX "${INSTALL_ROOT}"
    run_root find "${INSTALL_ROOT}/bin" "${INSTALL_ROOT}/libexec" -type f -exec chmod 0755 {} +
}

# ---------------------------------------------------------------------------
# Step 6 — Drop the modulefile on the site MODULEPATH
# ---------------------------------------------------------------------------

# Resolve MODULE_FLAVOR: "lmod" (dev.lua) or "tcl" (Tcl dev). "auto" sniffs the
# environment (Lmod exports LMOD_*; Tcl Environment Modules export MODULES_CMD/
# MODULESHOME), falling back to lmod. Sudo can scrub these — sites on Tcl should
# set MODULE_FLAVOR=tcl in site.conf rather than relying on auto.
resolve_module_flavor() {
    case "${MODULE_FLAVOR}" in
        lmod|tcl) printf '%s' "${MODULE_FLAVOR}"; return 0 ;;
    esac
    if [[ -n "${LMOD_CMD:-}${LMOD_DIR:-}${LMOD_VERSION:-}" ]] || command -v lmod >/dev/null 2>&1; then
        printf 'lmod'
    elif [[ -n "${MODULES_CMD:-}" ]] || command -v modulecmd >/dev/null 2>&1; then
        printf 'tcl'
    else
        printf 'lmod'
    fi
}

step_6_drop_modulefile() {
    local flavor; flavor="$(resolve_module_flavor)"
    local modfile; [[ "${flavor}" == tcl ]] && modfile="dev" || modfile="dev.lua"
    section "Step 6/7 — Install ${flavor} modulefile to ${SITE_MODULES}/rocbudai/${modfile}"

    local src="${INSTALL_ROOT}/modulefiles/rocbudai/${modfile}"
    local dst_dir="${SITE_MODULES}/rocbudai"
    local dst="${dst_dir}/${modfile}"
    [[ -f "${src}" ]] || die "Missing ${flavor} modulefile: ${src}"

    run_root mkdir -p "${dst_dir}"
    run_root cp "${src}" "${dst}"
    run_root chown root:root "${dst}"

    # Path retargets are plain literal substitutions — flavour-agnostic.
    if [[ "${INSTALL_ROOT}" != "${INSTALL_ROOT_DEFAULT}" ]]; then
        info "Retargeting install root inside ${dst}"
        run_root sed -i "s|${INSTALL_ROOT_DEFAULT}|${INSTALL_ROOT}|g" "${dst}"
    fi
    local opencode_bin_default="${OPENCODE_ROOT_DEFAULT}/${OPENCODE_VERSION_DEFAULT}/opencode"
    local opencode_bin_target="${OPENCODE_ROOT}/${OPENCODE_VERSION}/opencode"
    if [[ "${opencode_bin_target}" != "${opencode_bin_default}" ]]; then
        info "Retargeting opencode binary inside ${dst}"
        run_root sed -i "s|${opencode_bin_default}|${opencode_bin_target}|g" "${dst}"
    fi

    # Value retargets use flavour-specific setenv syntax: Lmod setenv("K","V")
    # vs Tcl rb_setenv K "V" (the Tcl helper that also records the launch env).
    local sp_from sp_to sub_from sub_to mdl_from mdl_to allow_from allow_to
    if [[ "${flavor}" == tcl ]]; then
        sp_from='rb_setenv ROCBUDAI_SPX_PARTITIONS "[^"]*"'
        sp_to="rb_setenv ROCBUDAI_SPX_PARTITIONS \"${SPX_PARTITIONS}\""
        sub_from='rb_setenv ROCBUDAI_SUBMIT_PARTITION "[^"]*"'
        sub_to="rb_setenv ROCBUDAI_SUBMIT_PARTITION \"${SUBMIT_PARTITION:-}\""
        mdl_from="rb_setenv ROCBUDAI_MODEL ${MODEL_NAME_DEFAULT}"
        mdl_to="rb_setenv ROCBUDAI_MODEL ${MODEL_NAME}"
        allow_from='rb_setenv ROCBUDAI_ALLOWED_MODELS "'
        allow_to="rb_setenv ROCBUDAI_ALLOWED_MODELS \"${MODEL_NAME},"
    else
        sp_from='setenv("ROCBUDAI_SPX_PARTITIONS", "[^"]*")'
        sp_to="setenv(\"ROCBUDAI_SPX_PARTITIONS\", \"${SPX_PARTITIONS}\")"
        sub_from='setenv("ROCBUDAI_SUBMIT_PARTITION", "[^"]*")'
        sub_to="setenv(\"ROCBUDAI_SUBMIT_PARTITION\", \"${SUBMIT_PARTITION:-}\")"
        mdl_from="setenv(\"ROCBUDAI_MODEL\", \"${MODEL_NAME_DEFAULT}\")"
        mdl_to="setenv(\"ROCBUDAI_MODEL\", \"${MODEL_NAME}\")"
        allow_from='setenv("ROCBUDAI_ALLOWED_MODELS", "'
        allow_to="setenv(\"ROCBUDAI_ALLOWED_MODELS\", \"${MODEL_NAME},"
    fi

    # Bake the site's Slurm partition(s) so the modulefile (and thus the
    # launcher/doctor) gates on the right partition.
    if [[ "${SPX_PARTITIONS}" != "${SPX_PARTITIONS_DEFAULT}" ]]; then
        info "Setting ROCBUDAI_SPX_PARTITIONS='${SPX_PARTITIONS}' inside ${dst}"
        run_root sed -i "s|${sp_from}|${sp_to}|" "${dst}"
    fi

    # Bake the site's multi-GPU bench partition (empty => cluster default).
    if [[ -n "${SUBMIT_PARTITION:-}" ]]; then
        info "Setting ROCBUDAI_SUBMIT_PARTITION='${SUBMIT_PARTITION}' inside ${dst}"
        run_root sed -i "s|${sub_from}|${sub_to}|" "${dst}"
    fi

    # Bake the site's model into the default + allow-list so the pulled model
    # and the module default can't desync (single source: MODEL_NAME).
    if [[ "${MODEL_NAME}" != "${MODEL_NAME_DEFAULT}" ]]; then
        info "Setting ROCBUDAI_MODEL='${MODEL_NAME}' inside ${dst}"
        run_root sed -i "s|${mdl_from}|${mdl_to}|" "${dst}"
        run_root sed -i "s|${allow_from}|${allow_to}|" "${dst}"
    fi

    # AGENTS persona is intentionally NOT baked: install.sh commonly stages the
    # shared tree from a GPU-less login node, so any install-time arch guess is
    # unreliable. rocbudai-tui resolves it at launch from the live GPU on the
    # compute node (see _persona_for_arch), honouring a ROCBUDAI_AGENTS_TEMPLATE
    # override.
    info "AGENTS persona : resolved at runtime by rocbudai-tui (not baked)"
}

# ---------------------------------------------------------------------------
# Step 7 — Verify
# ---------------------------------------------------------------------------

step_7_verify() {
    section "Step 7/7 — Verify"

    info "module avail rocbudai (login-node POV)"
    # The probe needs both Lmod itself AND a sane MODULEPATH that points
    # at SITE_MODULES. In test containers the latter is typically unset
    # (no /etc/lmod/lmod.conf, no /etc/profile.d/lmod.sh sourced for
    # root). Don't fire the probe in that case — it just emits a scary
    # "MODULEPATH not set" error that misleads the user into thinking
    # the install failed.
    if command -v module >/dev/null 2>&1 || [[ -n "${LMOD_CMD:-}" ]]; then
        if run_root_sh "bash -lc 'case \":\${MODULEPATH:-}:\" in *:${SITE_MODULES}:*) exit 0;; *) exit 1;; esac'" >/dev/null 2>&1; then
            run_root_sh "bash -lc 'module avail rocbudai 2>&1 | head -20' || true"
        else
            warn "Lmod present but MODULEPATH does not include ${SITE_MODULES}."
            warn "Skipping 'module avail' probe (would emit a misleading error)."
            warn "Verify on a real Lmod-configured shell:"
            warn "    export MODULEPATH=${SITE_MODULES}:\${MODULEPATH}"
            warn "    module avail rocbudai && module help rocbudai"
        fi
    else
        warn "Lmod ('module') not available in this shell — skip the module-avail probe."
        warn "Verify on a real Lmod shell:  module avail rocbudai && module help rocbudai"
    fi

    info "Files placed:"
    run_root_sh "ls -ld ${INSTALL_ROOT} ${OPENCODE_ROOT}/${OPENCODE_VERSION} ${SITE_MODULES}/rocbudai/dev.lua 2>&1 || true"

    if [[ ${DRY_RUN} -eq 0 ]]; then
        if have_systemd; then
            if systemctl is-active --quiet ollama; then
                ok "ollama.service active"
            else
                warn "ollama.service NOT active — TUI will not be able to talk to a daemon."
            fi
        else
            # No systemd — probe the HTTP endpoint the no-systemd launcher
            # in step 2 brought up. This is the right "is the daemon up?"
            # check for test containers and dev workstations.
            local host
            host="$(ollama_env_value OLLAMA_HOST)"
            host="${host:-127.0.0.1:11435}"
            if curl -fsS --max-time 3 "http://${host}/api/version" >/dev/null 2>&1; then
                ok "ollama daemon answering on http://${host}"
            else
                warn "ollama daemon not reachable on http://${host} — TUI will not be able to talk to a daemon."
            fi
        fi
    fi

    info "End-to-end smoke test (manual, on a compute node inside an allocation):"
    cat <<EOF
        salloc -p <gpu-partition> --exclusive --comment=ollama --time=01:00:00
        module load rocbudai          # → TUI auto-launches
        # See docs/SMOKE-TEST.md for the full gate list.
EOF
}

# ---------------------------------------------------------------------------
# Step 8 (optional) — feature installers
# ---------------------------------------------------------------------------

step_8_auth() {
    section "Step 8 — Ollama 5-layer authorization hardening"
    if ! have_systemd; then
        warn "No systemd detected — skipping. The auth chain (wrapper + proxy + acl)"
        warn "fundamentally requires systemd to bring up ollama-proxy.service and"
        warn "ollama-acl.service. Re-run on a real compute node with systemd."
        return 0
    fi
    local d="${REPO_ROOT}/deploy/auth"

    # Layer 4: rename real binary, drop wrapper.
    if [[ -x /usr/local/bin/ollama && ! -e /usr/local/bin/ollama-real ]]; then
        info "Renaming /usr/local/bin/ollama -> /usr/local/bin/ollama-real (one-shot)"
        run_root mv /usr/local/bin/ollama /usr/local/bin/ollama-real
    fi
    run_root install -m 0755 -o root -g root "${d}/ollama-wrapper.sh"  /usr/local/bin/ollama
    run_root install -m 0755 -o root -g root "${d}/ollama-proxy.py"    /usr/local/bin/ollama-proxy

    run_root install -m 0644 -o root -g root "${d}/ollama-acl.service"   /etc/systemd/system/ollama-acl.service
    run_root install -m 0644 -o root -g root "${d}/ollama-proxy.service" /etc/systemd/system/ollama-proxy.service

    run_root install -d -m 0755 /etc/nftables.d
    run_root install -m 0644 -o root -g root "${d}/ollama-acl.nft" /etc/nftables.d/ollama-acl.nft

    run_root systemctl daemon-reload
    run_root systemctl enable --now ollama-acl.service

    # Layer 5: make the model store group-write-only via ollama (mode 2755 per
    # README, not 2775 as in step 3 — auth hardening tightens it).
    run_root install -d -m 2755 -o ollama -g ollama "${MODELS_DIR}"

    info "Note: ollama-proxy.service is started by the Slurm prolog when --comment=ollama"
    info "is set, NOT enabled at boot. See deploy/comment-gating/."
}

step_8_comment_gating() {
    section "Step 8 — Slurm --comment=ollama daemon gating"
    local d="${REPO_ROOT}/deploy/comment-gating"

    local prolog_dir="${SLURMSCRIPTS_DIR}/prolog.d"
    local epilog_dir="${SLURMSCRIPTS_DIR}/epilog.d"
    local slurm_etc=/etc/slurm

    run_root install -d -m 0755 "${prolog_dir}" "${epilog_dir}" "${slurm_etc}"
    run_root install -m 0755 -o root -g root "${d}/rocbudai-ollama-prolog.sh" "${prolog_dir}/rocbudai-ollama-prolog.sh"
    run_root install -m 0755 -o root -g root "${d}/rocbudai-ollama-epilog.sh" "${epilog_dir}/rocbudai-ollama-epilog.sh"
    run_root install -m 0755 -o root -g root "${d}/rocbudai-egress-prolog.sh" "${prolog_dir}/rocbudai-egress-prolog.sh"
    run_root install -m 0755 -o root -g root "${d}/rocbudai-egress-epilog.sh" "${epilog_dir}/rocbudai-egress-epilog.sh"
    run_root install -m 0644 -o root -g root "${d}/job_submit.lua"             "${slurm_etc}/job_submit.lua"

    warn "Manual step still required:"
    warn "  Add the dispatch blocks shown in deploy/comment-gating/README.md to"
    warn "  your cluster's prolog / epilog (the drop-ins above are not"
    warn "  auto-discovered), then 'scontrol reconfigure' on the slurmctld host."
    warn "  Until you do, the drop-ins above are inert."

    info "After wiring in the dispatch blocks, also run on each SPX node:"
    info "  sudo systemctl disable ollama   # do NOT --now; prolog will start it"
}

step_8_airgap() {
    section "Step 8 — Airgap baseline (managed opencode + nft egress)"
    if ! have_systemd; then
        warn "No systemd detected — skipping (needs ollama-egress.service)."
        return 0
    fi
    local d="${REPO_ROOT}/deploy/airgap"

    run_root install -d -m 0755 /etc/opencode
    run_root install -m 0644 -o root -g root "${d}/opencode-managed.json" /etc/opencode/opencode.json

    run_root install -d -m 0755 /etc/nftables.d
    run_root install -m 0644 -o root -g root "${d}/ollama-egress.nft" /etc/nftables.d/ollama-egress.nft
    run_root install -m 0644 -o root -g root "${d}/ollama-egress.service" /etc/systemd/system/ollama-egress.service

    # Per-job user-UID egress skeleton. Loads the (empty) inet rocbudai_user_egress
    # table at boot; the Slurm egress prolog (step_8_comment_gating) adds a per-job
    # jump chain scoped to the user's UID. Without this table loaded, that prolog
    # fails CLOSED (aborts the job) and rocbudai-airgap-check section 6 stays red.
    run_root install -m 0644 -o root -g root "${d}/rocbudai-user-egress.nft" /etc/nftables.d/rocbudai-user-egress.nft
    run_root install -m 0644 -o root -g root "${d}/rocbudai-user-egress.service" /etc/systemd/system/rocbudai-user-egress.service

    run_root systemctl daemon-reload
    run_root systemctl enable --now ollama-egress.service
    run_root systemctl enable --now rocbudai-user-egress.service
}

step_8_auto_ingest() {
    section "Step 8 — Auto-ingest path watcher (login node only)"
    if ! have_systemd; then
        warn "No systemd detected — skipping (path/timer units need systemd)."
        return 0
    fi
    warn "Reminder: this MUST run on the login node only — multi-host watchers race on NFS."

    local d="${REPO_ROOT}/deploy/auto-ingest"
    for f in rocbudai-ingest-inputs.path rocbudai-ingest-inputs.service rocbudai-ingest-inputs.timer; do
        run_root install -m 0644 -o root -g root "${d}/${f}" "/etc/systemd/system/${f}"
    done

    # Retarget the watched KB inputs dir (in the .path PathChanged, the .service
    # ConditionPathIsDirectory, and the ExecStart --dir) and the install-tree
    # path baked into the .service ExecStart, if the site overrode them.
    if [[ "${KB_INPUTS_DIR}" != "${KB_INPUTS_DIR_DEFAULT}" ]]; then
        info "Retargeting KB inputs dir → ${KB_INPUTS_DIR}"
        run_root sed -i "s#${KB_INPUTS_DIR_DEFAULT}#${KB_INPUTS_DIR}#g" \
            /etc/systemd/system/rocbudai-ingest-inputs.path \
            /etc/systemd/system/rocbudai-ingest-inputs.service
    fi
    if [[ "${INSTALL_ROOT}" != "${INSTALL_ROOT_DEFAULT}" ]]; then
        run_root sed -i "s#${INSTALL_ROOT_DEFAULT}#${INSTALL_ROOT}#g" \
            /etc/systemd/system/rocbudai-ingest-inputs.service
    fi

    run_root systemctl daemon-reload
    run_root systemctl enable --now rocbudai-ingest-inputs.path
    run_root systemctl enable --now rocbudai-ingest-inputs.timer
}

step_8_model_cache() {
    section "Step 8 — Local NVMe model cache"
    if ! have_systemd; then
        warn "No systemd detected — skipping (rocbudai-model-cache.service needs systemd)."
        return 0
    fi
    local d="${REPO_ROOT}/deploy/model-cache"

    run_root install -m 0644 -o root -g root "${d}/rocbudai-model-cache.service" /etc/systemd/system/rocbudai-model-cache.service
    run_root install -d -m 0755 /etc/systemd/system/ollama.service.d
    run_root install -m 0644 -o root -g root "${d}/ollama-models-cache.conf" /etc/systemd/system/ollama.service.d/model-cache.conf

    # Retarget the cache DESTINATION and the rsync SOURCE if the site overrode
    # them. The source tracks OLLAMA_MODELS (MODELS_DIR), so the cache can never
    # desync from a relocated model store.
    if [[ "${MODEL_CACHE_DIR}" != "${MODEL_CACHE_DIR_DEFAULT}" ]]; then
        info "Retargeting model cache dir → ${MODEL_CACHE_DIR}"
        run_root sed -i "s#${MODEL_CACHE_DIR_DEFAULT}#${MODEL_CACHE_DIR}#g" \
            /etc/systemd/system/rocbudai-model-cache.service \
            /etc/systemd/system/ollama.service.d/model-cache.conf
    fi
    if [[ "${MODELS_DIR}" != "${MODELS_DIR_SHIPPED}" ]]; then
        info "Retargeting model-cache rsync source → ${MODELS_DIR}"
        run_root sed -i "s#${MODELS_DIR_SHIPPED}#${MODELS_DIR}#g" \
            /etc/systemd/system/rocbudai-model-cache.service
    fi

    run_root systemctl daemon-reload
    info "First enable runs the initial 9-10 min rsync (subsequent boots: seconds)."
    run_root systemctl enable --now rocbudai-model-cache.service

    # Re-pick up the OLLAMA_MODELS override if ollama is currently running.
    if [[ ${DRY_RUN} -eq 0 ]] && systemctl is-active --quiet ollama; then
        info "Restarting ollama.service to pick up the cache drop-in."
        run_root systemctl restart ollama
    fi
}

step_8_usage() {
    section "Step 8 — Daily usage tracking (cron.daily + airgap probe)"
    local d="${REPO_ROOT}/deploy/usage"
    run_root install -m 0750 -o root -g root "${d}/rocbudai-harvest"       /etc/cron.daily/rocbudai-harvest
    run_root install -m 0750 -o root -g root "${d}/rocbudai-airgap-probe"  /usr/local/sbin/rocbudai-airgap-probe
    run_root install -m 0600 -o root -g root /dev/null                     /var/log/rocbudai-usage.jsonl
}

# ---------------------------------------------------------------------------
# Container quick-test mode (--container)
# ---------------------------------------------------------------------------
#
# QUICK TESTING ONLY — not the supported way to run rocBudAI. Pulls a ROCm
# dev image, bind-mounts this checkout, runs install.sh inside it (no
# systemd, no GPU fencing, small model), clones the HPC training examples,
# and drops the user into an interactive shell from which `rocbudai-tui`
# runs directly (no module system). Must be launched from inside a Slurm
# allocation.
run_container_mode() {
    section "Container quick-test mode"
    warn "Container mode is for QUICK TESTING ONLY — it is NOT the supported way to"
    warn "run rocBudAI. For real use, install on the host (INSTALL.md) and use"
    warn "'module load rocbudai' inside a Slurm allocation."

    # Reject / warn on flags that do not apply to the container path so the
    # user is not surprised by silently-ignored options. --gfx-arch is a hard
    # error: container mode assumes you are already on an salloc'd GPU node, so
    # the arch is always autodetected via rocminfo inside the container.
    [[ -z "${GFX_ARCH}" ]] || die "--gfx-arch cannot be used with --container: the arch is autodetected on the (already allocated) GPU node inside the container. Drop --gfx-arch."
    if (( WITH_AUTH || WITH_COMMENT_GATING || WITH_AIRGAP || WITH_AUTO_INGEST || WITH_MODEL_CACHE || WITH_USAGE )); then
        warn "--with-hardening / step-8 flags are ignored in --container mode (quick test only)."
    fi

    [[ -n "${SLURM_JOB_ID:-}" ]] || die "--container requires an active Slurm allocation. Run 'salloc ...' first, then re-run inside the allocation."

    local image="docker.io/rocm/dev-${DISTRO}-${DISTRO_VERSION}:${ROCM_VERSION}-complete"
    local engine=""
    if command -v podman >/dev/null 2>&1; then
        engine="podman"
    elif command -v singularity >/dev/null 2>&1; then
        engine="singularity"
    else
        die "neither podman nor singularity found — cannot run container mode."
    fi

    info "Engine         : ${engine}"
    info "Image          : ${image}"
    info "Model          : ${CONTAINER_MODEL}"

    # Script run inside the container: install (no GPU fencing, small model;
    # the arch is autodetected via rocminfo, and the MI300A VRAM patch still
    # applies on gfx942 so the model runs on the GPU, not CPU), write a
    # container env profile so rocbudai-tui Just Works, clone the examples,
    # then hand over a shell. The profile sets ROCBUDAI_CONTAINER=1 but NOT
    # ROCBUDAI_AGENTS_TEMPLATE: rocbudai-tui then uses the compact,
    # self-contained AGENTS-container-demo.md persona (NOT the big arch
    # persona) so a small/fast demo model follows the saxpy walkthrough
    # reliably.
    local inner
    inner="$(cat <<INNER
set -e
cd /rocbudai
ROCBUDAI_CONTAINER=1 ROCBUDAI_NO_FENCING=1 MODEL_NAME='${CONTAINER_MODEL}' ./install.sh --yes

# Kick off a background model pre-warm so the cold load (weights -> VRAM)
# overlaps with the apt-get + git clone below instead of stalling the
# user's first TUI turn. The daemon is already up (step 2 launched it
# detached on 127.0.0.1:11435) and the model is pulled (step 3). An empty
# 'prompt' is ollama's load-only request; keep_alive keeps the weights
# resident until the demo starts. We barrier-wait on this just before
# launching the TUI so there is exactly ONE load and opencode's first
# request hits an already-resident model — a pre-warm inside the TUI would
# race opencode for ollama's single load slot and deadlock.
echo "[rocBudAI] Pre-warming ${CONTAINER_MODEL} in the background while the demo sets up…"
ROCBUDAI_PREWARM_RC=/tmp/rocbudai-prewarm.rc
rm -f "\$ROCBUDAI_PREWARM_RC"
( curl -fsS -m 1800 http://127.0.0.1:11435/api/generate \
    -d '{"model":"${CONTAINER_MODEL}","prompt":"","keep_alive":"4h"}' \
    >/tmp/rocbudai-prewarm.log 2>&1; echo \$? >"\$ROCBUDAI_PREWARM_RC" ) &
ROCBUDAI_PREWARM_PID=\$!

mkdir -p /etc/profile.d
cat > /etc/profile.d/rocbudai-container.sh <<'PROF'
export ROCBUDAI_ROOT=${INSTALL_ROOT}
export ROCBUDAI_OPENCODE_BIN=${OPENCODE_ROOT}/${OPENCODE_VERSION}/opencode
export PATH="\$ROCBUDAI_ROOT/bin:\$PATH"
export ROCBUDAI_OLLAMA_HOST=http://127.0.0.1:11435
export ROCBUDAI_MODEL=${CONTAINER_MODEL}
export ROCBUDAI_ALLOWED_MODELS=${CONTAINER_MODEL}
export ROCBUDAI_CONTAINER=1
# No 'module load' in the container, so mirror the modulefile's opencode
# network-feature kill switches here too (rocbudai-tui also sets these, but
# this covers a direct 'opencode' run in the post-demo shell). Without these
# opencode prompts to auto-update on launch and hangs on the network call.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
export OPENCODE_DISABLE_SHARE=1
# The container demo is user-paced; the idle-timeout auto-nudge ("continue")
# only derails a small demo model mid-interview. Off by default here
# (rocbudai-tui also defaults this off when ROCBUDAI_CONTAINER is set).
export ROCBUDAI_NUDGE_DISABLE=1
PROF
# Install a few basics for the interactive test shell (best-effort; the
# ROCm dev image is usually minimal). git is needed for the clone below.
# libdw-dev provides libdw (DWARF/ELF debug-info), which rocprofv3 dlopen's
# for kernel symbolization — without it the demo's 'rocprofv3 ... -- ./saxpy'
# step fails. Install it explicitly here so the profiling walkthrough works.
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git vim less nano procps libdw-dev 2>/dev/null || true
fi
if command -v git >/dev/null 2>&1; then
    if ! git clone --depth 1 https://github.com/amd/HPCTrainingExamples "\$HOME/HPCTrainingExamples"; then
        echo "[rocBudAI] HPCTrainingExamples clone failed (real git error shown above); continuing without examples."
    fi
else
    echo "[rocBudAI] git unavailable in this image; skipping HPCTrainingExamples clone."
fi

# CRITICAL: do NOT run the demo inside the git clone.
#
# opencode anchors BOTH its config (opencode.json) and its instruction/AGENTS.md
# discovery to the GIT WORKTREE ROOT: it starts at cwd and only ever traverses
# UP, stopping at the nearest .git. The clone above is a git repo, so running
# the TUI in \$HOME/HPCTrainingExamples/HIP/saxpy makes opencode look for
# opencode.json / AGENTS.md at the CLONE ROOT (\$HOME/HPCTrainingExamples) and
# never see the ones rocbudai-tui writes in the saxpy subdir. Result: the
# persona never reaches the model and it hallucinates / treats the warm-up seed
# as a status message (root cause found 2026-06-30; see
# deploy/ollama-models/README.md and tests/diagnose-persona.sh).
#
# Fix: copy the saxpy example OUT of the clone into a clean, non-git directory
# and run there, so opencode's worktree root == cwd == where our config lives.
SAXPY_SRC="\$HOME/HPCTrainingExamples/HIP/saxpy"
SAXPY_DIR="\$HOME/rocbudai-saxpy-demo"
if [ -d "\$SAXPY_SRC" ]; then
    rm -rf "\$SAXPY_DIR"
    if cp -R "\$SAXPY_SRC" "\$SAXPY_DIR"; then
        rm -rf "\$SAXPY_DIR/.git"   # belt-and-braces: never a git repo
        # Patch the upstream saxpy IN PLACE (we edit the copy, never the repo)
        # so the demo has a measurable kernel and exactly ONE real optimization
        # to find:
        #   1. n = 256 -> 1<<26  : upstream's 256 elems is a sub-µs blip the
        #      profile can't see past hipMemcpy/launch overhead; 1<<26 (256 MiB
        #      /array) makes the saxpy kernel a real, timeable HBM workload.
        #   2. full grid         : launch one thread per element (256/block).
        #   3. uncoalesced access: scramble the global index into a stride
        #      permutation so neighbouring threads hit far-apart addresses and
        #      most HBM bandwidth is wasted. The assistant's job is to restore
        #      the coalesced 'y[i] += a*x[i]'. The map is a bijection over
        #      [0,n), so the math is unchanged (y := a*x+y) and the program's
        #      built-in accuracy check still prints PASSED for both versions.
        # 'a*x[i]' (kernel) vs 'a_h*x[i]' (CPU ref) makes the access line a
        # unique anchor. Best-effort: if upstream's layout changes and an
        # anchor stops matching, the demo still runs (just less ideal).
        if [ -f "\$SAXPY_DIR/saxpy.hip" ]; then
            sed -i \
                -e 's|int n = 256;|int n = (1 << 26);|' \
                -e 's|int num_groups = 2;|int num_groups = (n + 255) / 256;|' \
                -e 's|int group_size = 128;|int group_size = 256;|' \
                -e 's|y\[i\] += a\*x\[i\];|y[(i % 1024) * (n / 1024) + (i / 1024)] += a*x[(i % 1024) * (n / 1024) + (i / 1024)];|' \
                "\$SAXPY_DIR/saxpy.hip"
            if grep -q '(i % 1024)' "\$SAXPY_DIR/saxpy.hip"; then
                echo "[rocBudAI] demo saxpy scaled to n=1<<26 with an uncoalesced baseline (one real optimization to find)."
            else
                echo "[rocBudAI] warning: could not patch saxpy.hip (upstream layout changed?); using it as-is."
            fi
        fi
    else
        echo "[rocBudAI] could not copy saxpy out of the clone; using the in-clone path (persona may not load)."
        SAXPY_DIR="\$SAXPY_SRC"
    fi
fi
echo
echo "=================================================================="
echo " rocBudAI container quick-test (TESTING ONLY)."
if [ -d "\$SAXPY_DIR" ]; then
    echo " Starting the guided demo from the HIP saxpy example:"
    echo "   \$SAXPY_DIR"
else
    echo " (saxpy example unavailable — the clone may have failed; the demo"
    echo "  will start from your home directory instead.)"
fi
echo " The assistant walks you through the questions and suggests the"
echo " quick-test answers — just press Enter to accept each one."
echo " Type /exit in the TUI to leave; you'll land in a shell afterward."
echo " More examples (if cloned): \$HOME/HPCTrainingExamples"
echo " This is NOT the supported way to run rocBudAI; for real use,"
echo " install on the host and use 'module load rocbudai'."
echo "=================================================================="
echo
# Barrier: ensure the background pre-warm has finished loading the model
# before handing over to the TUI, so the user's first question is fast. If
# the load already finished during apt/clone, this returns immediately.
echo "[rocBudAI] Finishing model warm-up so your first question is fast…"
wait "\$ROCBUDAI_PREWARM_PID" 2>/dev/null || true
if [ -f "\$ROCBUDAI_PREWARM_RC" ] && [ "\$(cat "\$ROCBUDAI_PREWARM_RC" 2>/dev/null)" = "0" ]; then
    echo "[rocBudAI] Model ready."
else
    echo "[rocBudAI] Warm-up did not confirm readiness (see /tmp/rocbudai-prewarm.log);"
    echo "           your first prompt may take a little longer. Continuing."
fi
echo
# Auto-launch the guided quick-test: a login shell sources the container
# env profile (/etc/profile.d/rocbudai-container.sh), cd's into the saxpy
# example (falling back to \$HOME if the clone failed), runs the TUI, then
# drops the user into an interactive login shell so they can re-run
# 'rocbudai-tui' or inspect artefacts after /exit.
export ROCBUDAI_DEMO_DIR="\$SAXPY_DIR"
exec bash -l -c 'cd "\$ROCBUDAI_DEMO_DIR" 2>/dev/null || cd "\$HOME"; rocbudai-tui; exec bash -l'
INNER
)"

    if [[ "${engine}" == "podman" ]]; then
        run podman pull "${image}"
        run podman run --rm -it \
            --device=/dev/kfd --device=/dev/dri \
            --group-add keep-groups --security-opt seccomp=unconfined \
            --ipc=host \
            -v "${REPO_ROOT}:/rocbudai:ro" \
            "${image}" bash -lc "${inner}"
    else
        run singularity exec --rocm --writable-tmpfs \
            --bind "${REPO_ROOT}:/rocbudai" \
            "docker://${image}" bash -lc "${inner}"
    fi
}

# ---------------------------------------------------------------------------
# Provisioning image-bake mode (--image-bake <chroot>)
# ---------------------------------------------------------------------------
#
# Lays the PER-NODE ollama/rocBudAI pieces FLAT into an image chroot and
# offline-enables the boot-time services. It performs NO live operations — no
# `systemctl daemon-reload/start/restart`, no `--now`, no `ollama pull` —
# because a chroot has no PID-1 systemd and no GPU. Everything that needs a
# running daemon happens at first boot on a real node; the model already lives
# on the shared NFS store, so there is nothing to pull per image.
#
# NOT baked: the shared components (opencode, install tree, modulefile) — they
# live on the NFS share and are installed once with a normal run.
run_image_bake() {
    local R="${IMAGE_BAKE_CHROOT%/}"
    section "Image-bake mode — flat laydown into ${R}"
    warn "Flat bake only: no services are started, no systemd reload, no model"
    warn "pull. Live steps happen at first boot on a real node."

    [[ -n "${R}" ]] || die "--image-bake requires a chroot path."
    [[ -d "${R}" ]] || die "chroot '${R}' does not exist."
    [[ -d "${R}/etc" && -d "${R}/usr" ]] || \
        die "'${R}' does not look like a root filesystem (missing etc/ or usr/)."
    command -v systemctl >/dev/null 2>&1 || \
        die "systemctl not found on this host — needed for offline 'systemctl --root enable'."

    local dd="${REPO_ROOT}/deploy/ollama-daemon"
    local mc="${REPO_ROOT}/deploy/model-cache"
    [[ -f "${dd}/ollama.service" ]] || die "missing ${dd}/ollama.service"
    [[ -f "${mc}/rocbudai-model-cache.service" ]] || die "missing ${mc}/rocbudai-model-cache.service"

    # 1. ollama service user/group (offline via useradd --root). The unit's
    #    SupplementaryGroups=render video are added by systemd at runtime, so we
    #    only need the primary ollama user/group in the image.
    section "1/5 — ollama service user"
    run_root_sh "grep -q '^ollama:' '${R}/etc/group'  || groupadd -R '${R}' -r ollama"
    run_root_sh "grep -q '^ollama:' '${R}/etc/passwd' || useradd  -R '${R}' -r -g ollama -s /usr/sbin/nologin -d /usr/share/ollama ollama"

    # 2. ollama.service + optional site proxy drop-in
    section "2/5 — ollama unit + proxy drop-in"
    run_root install -D -m 0644 -o root -g root "${dd}/ollama.service" "${R}/etc/systemd/system/ollama.service"
    run_root install -d -m 0755 "${R}/etc/systemd/system/ollama.service.d"
    if [[ -n "${SITE_HTTP_PROXY}" ]]; then
        local ptmp; ptmp="$(mktemp)"
        {
            echo "[Service]"
            echo "Environment=\"HTTP_PROXY=${SITE_HTTP_PROXY}\""
            echo "Environment=\"HTTPS_PROXY=${SITE_HTTP_PROXY}\""
            echo "Environment=\"NO_PROXY=${SITE_NO_PROXY}\""
        } >"${ptmp}"
        run_root install -m 0644 -o root -g root "${ptmp}" "${R}/etc/systemd/system/ollama.service.d/10-proxy.conf"
        rm -f "${ptmp}"
        info "proxy drop-in: HTTP(S)_PROXY=${SITE_HTTP_PROXY} NO_PROXY=${SITE_NO_PROXY}"
    else
        info "SITE_HTTP_PROXY empty — skipping proxy drop-in (direct egress)."
    fi

    # 3. Static GPU/CPU split. ROCR_VISIBLE_DEVICES (LLM on dies 0..N-2) is safe
    #    to derive from the die count alone; AllowedCPUs is NUMA-topology-
    #    specific, so it is only written when IMAGE_ALLOWED_CPUS is supplied.
    section "3/5 — GPU/CPU split drop-in"
    if [[ "${IMAGE_GPU_COUNT}" -ge 2 ]]; then
        local llm="" i
        for ((i=0; i<IMAGE_GPU_COUNT-1; i++)); do llm+="${llm:+,}$i"; done
        local gtmp; gtmp="$(mktemp)"
        {
            echo "[Service]"
            echo "Environment=\"ROCR_VISIBLE_DEVICES=${llm}\""
            [[ -n "${IMAGE_ALLOWED_CPUS}" ]] && echo "AllowedCPUs=${IMAGE_ALLOWED_CPUS}"
        } >"${gtmp}"
        run_root install -m 0644 -o root -g root "${gtmp}" "${R}/etc/systemd/system/ollama.service.d/10-gpu-split.conf"
        rm -f "${gtmp}"
        info "GPU split: ROCR_VISIBLE_DEVICES=${llm} (rocbudai-bench GPU=$((IMAGE_GPU_COUNT-1)))"
        [[ -n "${IMAGE_ALLOWED_CPUS}" ]] && info "AllowedCPUs=${IMAGE_ALLOWED_CPUS}" || \
            warn "AllowedCPUs not set (GPU isolation only). To add CPU pinning: run libexec/rocbudai-detect-topology.sh on a booted node, set IMAGE_ALLOWED_CPUS, re-bake."
    else
        info "IMAGE_GPU_COUNT<2 — skipping GPU split (LLM + bench share all GPUs)."
    fi

    # 4. NVMe model cache (unit + drop-in), retargeted to this site's paths.
    section "4/5 — NVMe model cache"
    run_root install -D -m 0644 -o root -g root "${mc}/rocbudai-model-cache.service" "${R}/etc/systemd/system/rocbudai-model-cache.service"
    run_root install -D -m 0644 -o root -g root "${mc}/ollama-models-cache.conf"     "${R}/etc/systemd/system/ollama.service.d/model-cache.conf"
    if [[ "${MODEL_CACHE_DIR}" != "${MODEL_CACHE_DIR_DEFAULT}" ]]; then
        info "Retargeting model cache dir → ${MODEL_CACHE_DIR}"
        run_root sed -i "s#${MODEL_CACHE_DIR_DEFAULT}#${MODEL_CACHE_DIR}#g" \
            "${R}/etc/systemd/system/rocbudai-model-cache.service" \
            "${R}/etc/systemd/system/ollama.service.d/model-cache.conf"
    fi
    if [[ "${MODELS_DIR}" != "${MODELS_DIR_SHIPPED}" ]]; then
        info "Retargeting model-cache rsync source → ${MODELS_DIR}"
        run_root sed -i "s#${MODELS_DIR_SHIPPED}#${MODELS_DIR}#g" \
            "${R}/etc/systemd/system/rocbudai-model-cache.service"
    fi
    run_root install -d -m 0755 "${R}${MODEL_CACHE_DIR}"

    # NVMe mount point + a DISABLED example .mount stub. The device/filesystem is
    # site-specific (and formatting is destructive), so we never guess it — the
    # admin fills What= and enables it. cache_mnt is the parent of the cache dir.
    local cache_mnt="${MODEL_CACHE_DIR%/*}"
    run_root install -d -m 0755 "${R}${cache_mnt}"
    local munit
    munit="$(systemd-escape -p --suffix=mount "${cache_mnt}" 2>/dev/null || echo "$(echo "${cache_mnt}" | sed 's#^/##; s#/#-#g').mount")"
    local mtmp; mtmp="$(mktemp)"
    {
        echo "# EXAMPLE local-NVMe mount for the rocBudAI model cache (DISABLED)."
        echo "# The NVMe device + filesystem are node-specific and formatting is"
        echo "# destructive, so set What= yourself, then enable in the chroot:"
        echo "#   sudo systemctl --root=${R} enable ${munit}"
        echo "[Unit]"
        echo "Description=rocBudAI model-cache scratch (${cache_mnt})"
        echo "Before=rocbudai-model-cache.service"
        echo ""
        echo "[Mount]"
        echo "What=/dev/disk/by-label/ROCBUDAI_CACHE   # TODO set to this node's NVMe"
        echo "Where=${cache_mnt}"
        echo "Type=ext4"
        echo "Options=defaults,noatime"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } >"${mtmp}"
    run_root install -m 0644 -o root -g root "${mtmp}" "${R}/etc/systemd/system/${munit}.example"
    rm -f "${mtmp}"
    info "wrote DISABLED mount stub: /etc/systemd/system/${munit}.example (set What=, drop .example, enable)"

    # 5. Offline-enable boot services (creates .wants symlinks only; no activation).
    section "5/5 — offline enable (symlinks only, no activation)"
    run_root systemctl --root="${R}" enable rocbudai-model-cache.service
    if [[ "${IMAGE_ENABLE_OLLAMA}" == "1" ]]; then
        run_root systemctl --root="${R}" enable ollama.service
        info "ollama.service enabled at boot."
    else
        info "ollama.service left DISABLED (IMAGE_ENABLE_OLLAMA=0) — the Slurm --comment=ollama prolog starts it per job."
    fi

    # Optional: rebuild the Warewulf image if wwctl is available.
    if command -v wwctl >/dev/null 2>&1; then
        local img
        if [[ "$(basename "${R}")" == "rootfs" ]]; then
            img="$(basename "$(dirname "${R}")")"
        else
            img="$(basename "${R}")"
        fi
        if confirm "Run 'wwctl container build ${img}' now?"; then
            run_root wwctl container build "${img}"
        else
            info "Skipped image build. When ready: sudo wwctl container build ${img}"
        fi
    else
        info "wwctl not found — rebuild the image with your provisioning tool to pick up these files."
    fi

    section "Image-bake done"
    ok "Baked ollama + model-cache into ${R} (flat, offline-enabled)."
    info "Still required (once, off-image):"
    info "  - mount an NVMe at ${cache_mnt} on the nodes (customize the .mount stub)."
    info "  - model already on the NFS store (${MODELS_DIR}); no per-image pull."
    info "  - shared components (opencode, install tree, modulefile) install once on NFS via a normal run."
    [[ "${IMAGE_ENABLE_OLLAMA}" == "1" ]] || \
        info "  - wire the Slurm --comment=ollama prolog/epilog on slurmctld (see deploy/comment-gating)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    if [[ ${IMAGE_BAKE} -eq 1 ]]; then
        run_image_bake
        exit $?
    fi

    if [[ ${CONTAINER} -eq 1 ]]; then
        run_container_mode
        exit $?
    fi

    preflight

    step_1_install_ollama
    step_2_configure_ollama
    configure_gpu_split
    step_3_pull_model
    step_4_stage_opencode
    step_5_stage_install_tree
    step_6_drop_modulefile
    step_7_verify

    [[ ${WITH_AUTH}            -eq 1 ]] && step_8_auth
    [[ ${WITH_COMMENT_GATING}  -eq 1 ]] && step_8_comment_gating
    [[ ${WITH_AIRGAP}          -eq 1 ]] && step_8_airgap
    [[ ${WITH_AUTO_INGEST}     -eq 1 ]] && step_8_auto_ingest
    [[ ${WITH_MODEL_CACHE}     -eq 1 ]] && step_8_model_cache
    [[ ${WITH_USAGE}           -eq 1 ]] && step_8_usage

    section "Done"
    ok "rocBudAI install completed."

    # Tailor the "what next" guidance to the environment we just ran in.
    # The production path (systemd + Slurm + real compute node) wants
    # 'salloc + module load rocbudai'. A no-systemd or no-Slurm host
    # (test container, dev workstation, CI) cannot use that workflow;
    # there's a separate three-tier verification doc for those cases.
    local _has_slurm=0
    if command -v salloc >/dev/null 2>&1 || command -v sbatch >/dev/null 2>&1; then
        _has_slurm=1
    fi

    if have_systemd && (( _has_slurm )); then
        local _part="${SPX_PARTITIONS%%,*}"
        info "Next: from a compute node inside an allocation, run 'module load rocbudai':"
        info "    salloc -p ${_part:-<gpu-partition>} --exclusive --comment=ollama -t 1:00:00"
        info "    cd <project-dir> && module load rocbudai"
        info "Full smoke test gate list: ${INSTALL_ROOT}/docs/SMOKE-TEST.md (if present)."
        info ""
        info "For help choosing which documents to include in your rocBudAI"
        info "knowledge base, open an issue on the rocBudAI GitHub repository."
    else
        info "Next: this host is missing $(have_systemd && echo Slurm || (( _has_slurm )) && echo systemd || echo "systemd and Slurm"),"
        info "so the production 'salloc + module load rocbudai' workflow does not"
        info "apply here. For container / dev-host testing (three tiers —"
        info "daemon probe, rocbudai-doctor, rocbudai-tui), follow:"
        info "    ${INSTALL_ROOT}/docs/CONTAINER-TEST.md"
        info "Start by sourcing the test env once per shell:"
        info "    source ${INSTALL_ROOT}/share/rocbudai/test-env.sh"
        info "On a real production compute node (systemd + Slurm) use"
        info "'module load rocbudai' inside a salloc'd shell instead; the full"
        info "production gate list is in ${INSTALL_ROOT}/docs/SMOKE-TEST.md."
    fi
}

main "$@"
