#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# rocbudai-detect-topology.sh — emit the rocBudAI GPU/CPU split as
# sourceable KEY=VALUE lines. N-1 GPUs serve the LLM; the last GPU is
# reserved idle for rocbudai-bench.
#
# Output keys (CPU lists are best-effort; empty only when NUMA cannot be
# derived by ANY method below, in which case callers fall back to GPU-only
# isolation with no CPU pin):
#   ROCBUDAI_GPU_COUNT, ROCBUDAI_LLM_DEVICES, ROCBUDAI_BENCH_GPU,
#   ROCBUDAI_LLM_CPUS, ROCBUDAI_BENCH_CPUS, ROCBUDAI_TOPO_METHOD
#
# Consumed by install.sh (to write the ollama.service GPU-split drop-in)
# and rocbudai-bench (runtime defaults).
#
# DEVICE -> NUMA RESOLUTION (2026-07-23 fix)
#   The bench GPU MUST be pinned to its NUMA-local CPU cores, or a
#   memory-bound unified-memory FOM can run ~20x slower whenever first-touch
#   allocations land on a NUMA node remote to the bench GPU (measured on
#   MI300A SPX: 2.9 s local vs 57 s remote for the Jacobi FOM).
#
#   The previous implementation assumed (a) each GPU exposes
#   `/sys/class/drm/renderD<128+idx>/device/numa_node` and (b) render minors
#   are contiguous (128,129,130,...). Both broke on the Ubuntu-24.04 /
#   ROCm-7.2 amdgpu stack: on MI300A SPX the GPU render minors are
#   128,136,144,152 (stride 8) and only THOSE expose `numa_node` — the
#   intervening renderD129..135 are not GPU nodes and have no `numa_node`,
#   so `numa_of_device(3)` (renderD131) returned empty and the ENTIRE CPU
#   pin was silently blanked.
#
#   We now resolve each ROCr device's NUMA node through a cascade so no
#   single fragile sysfs path can blank the pin:
#     1. KFD topology `drm_render_minor` -> renderD<minor>/device/numa_node
#        (authoritative; handles NON-contiguous render minors).
#     2. Enumerate renderD* that actually expose a numeric device/numa_node,
#        ascending minor (== ROCr device order); take the idx-th.
#     3. Legacy contiguous assumption renderD<128+idx>/device/numa_node.
#     4. Identity last resort: if #NUMA nodes == #GPUs (homogeneous APU),
#        assume ROCr device i <-> NUMA node i.
#   ROCBUDAI_TOPO_METHOD reports which rung produced the pin
#   (sysfs | identity | none) so rocbudai-bench / install.sh can warn when
#   the CPU pin is missing or heuristic.
#
#   Device order is the identity ROCr order, valid before any
#   ROCR_VISIBLE_DEVICES fencing (install time and a fresh bench shell).
#
# The three sysfs roots are overridable (ROCBUDAI_SYSFS_KFD / _DRM / _NODE)
# purely so the resolution cascade can be unit-tested against a fixture;
# they default to the real kernel paths.

set -u

SYS_KFD="${ROCBUDAI_SYSFS_KFD:-/sys/class/kfd/kfd/topology/nodes}"
SYS_DRM="${ROCBUDAI_SYSFS_DRM:-/sys/class/drm}"
SYS_NODE="${ROCBUDAI_SYSFS_NODE:-/sys/devices/system/node}"

count_gpus() {
    local n
    if command -v rocm-smi >/dev/null 2>&1; then
        n="$(rocm-smi --csv --showid 2>/dev/null | tail -n +2 | grep -c '^card' || true)"
        if [[ "${n:-0}" -gt 0 ]]; then echo "$n"; return 0; fi
    fi
    n=0
    local p sc
    for p in "${SYS_KFD}"/*/properties; do
        [[ -r "$p" ]] || continue
        sc="$(awk '/^simd_count/ {print $2; exit}' "$p" 2>/dev/null)"
        [[ -n "$sc" && "$sc" -gt 0 ]] && n=$((n + 1))
    done
    echo "$n"
}

# Number of NUMA nodes that expose a cpulist.
count_numa_nodes() {
    local n=0 d
    for d in "${SYS_NODE}"/node[0-9]*; do
        [[ -r "$d/cpulist" ]] && n=$((n + 1))
    done
    echo "$n"
}

# GPU DRM render minors in ROCr device order: KFD GPU nodes (simd_count>0)
# sorted by numeric node id. Echoes space-separated minors ("128 136 ...").
gpu_render_minors() {
    local nid p sc minor
    while IFS= read -r nid; do
        p="${SYS_KFD}/${nid}/properties"
        [[ -r "$p" ]] || continue
        sc="$(awk '/^simd_count/ {print $2; exit}' "$p" 2>/dev/null)"
        [[ -n "$sc" && "$sc" -gt 0 ]] || continue
        minor="$(awk '/^drm_render_minor/ {print $2; exit}' "$p" 2>/dev/null)"
        [[ "$minor" =~ ^[0-9]+$ ]] && printf '%s ' "$minor"
    done < <(ls "${SYS_KFD}" 2>/dev/null | grep -E '^[0-9]+$' | sort -n)
}

# NUMA node id backing a given DRM render minor, or empty.
numa_of_render() {
    local minor="$1" nn
    nn="$(cat "${SYS_DRM}/renderD${minor}/device/numa_node" 2>/dev/null)"
    [[ "$nn" =~ ^[0-9]+$ ]] && echo "$nn"
}

# renderD minors (ascending) that actually expose a numeric numa_node.
render_minors_with_numa() {
    local d minor
    for d in "${SYS_DRM}"/renderD[0-9]*; do
        [[ -e "$d" ]] || continue
        minor="${d##*/renderD}"
        [[ "$minor" =~ ^[0-9]+$ ]] || continue
        [[ -n "$(numa_of_render "$minor")" ]] && echo "$minor"
    done | sort -n | tr '\n' ' '
}

cpulist_of_numa() {
    cat "${SYS_NODE}/node$1/cpulist" 2>/dev/null
}

# Ordered render-minor tables used by numa_of_device (device idx -> minor).
read -r -a KFD_MINORS <<< "$(gpu_render_minors)"
read -r -a NUMA_MINORS <<< "$(render_minors_with_numa)"

# NUMA node for ROCr device idx via the resolution cascade (rungs 1-3).
numa_of_device() {
    local idx="$1" nn
    if [[ -n "${KFD_MINORS[idx]:-}" ]]; then
        nn="$(numa_of_render "${KFD_MINORS[idx]}")"
        [[ -n "$nn" ]] && { echo "$nn"; return 0; }
    fi
    if [[ -n "${NUMA_MINORS[idx]:-}" ]]; then
        nn="$(numa_of_render "${NUMA_MINORS[idx]}")"
        [[ -n "$nn" ]] && { echo "$nn"; return 0; }
    fi
    numa_of_render "$((128 + idx))"
}

GPU_COUNT="$(count_gpus)"
GPU_COUNT="${GPU_COUNT:-0}"
NUMA_COUNT="$(count_numa_nodes)"
NUMA_COUNT="${NUMA_COUNT:-0}"

LLM_DEVICES=""
BENCH_GPU=""
LLM_CPUS=""
BENCH_CPUS=""
TOPO_METHOD="none"

if [[ "$GPU_COUNT" -ge 2 ]]; then
    BENCH_GPU=$((GPU_COUNT - 1))
    for ((i = 0; i < GPU_COUNT - 1; i++)); do
        LLM_DEVICES="${LLM_DEVICES:+${LLM_DEVICES},}${i}"
    done

    bench_node=""
    llm_nodes=""

    # Rungs 1-3: per-device sysfs resolution. Every device must map to a
    # valid NUMA node and the bench node must be disjoint from the LLM nodes.
    resolved=1
    bench_node="$(numa_of_device "$BENCH_GPU")"
    if [[ -n "$bench_node" ]]; then
        for ((i = 0; i < GPU_COUNT - 1; i++)); do
            nn="$(numa_of_device "$i")"
            if [[ -z "$nn" || "$nn" == "$bench_node" ]]; then resolved=0; break; fi
            case " $llm_nodes " in *" $nn "*) : ;; *) llm_nodes="${llm_nodes} ${nn}" ;; esac
        done
    else
        resolved=0
    fi

    if [[ "$resolved" -eq 1 ]]; then
        TOPO_METHOD="sysfs"
    elif [[ "$NUMA_COUNT" -eq "$GPU_COUNT" ]]; then
        # Rung 4 — identity: homogeneous APU (one NUMA node per GPU), so
        # ROCr device i is local to NUMA node i. Yields the correct pin on
        # kernels that no longer expose device/numa_node for every render node.
        bench_node="$BENCH_GPU"
        llm_nodes=""
        for ((i = 0; i < GPU_COUNT - 1; i++)); do
            llm_nodes="${llm_nodes} ${i}"
        done
        TOPO_METHOD="identity"
    fi

    if [[ "$TOPO_METHOD" != "none" ]]; then
        BENCH_CPUS="$(cpulist_of_numa "$bench_node")"
        LLM_CPUS=""
        for nn in $llm_nodes; do
            c="$(cpulist_of_numa "$nn")"
            [[ -n "$c" ]] && LLM_CPUS="${LLM_CPUS:+${LLM_CPUS},}${c}"
        done
        # If the cpulists themselves are missing, degrade to no-pin rather
        # than emit a half-populated split.
        if [[ -z "$BENCH_CPUS" || -z "$LLM_CPUS" ]]; then
            BENCH_CPUS=""
            LLM_CPUS=""
            TOPO_METHOD="none"
        fi
    fi
fi

echo "ROCBUDAI_GPU_COUNT=${GPU_COUNT}"
echo "ROCBUDAI_LLM_DEVICES=${LLM_DEVICES}"
echo "ROCBUDAI_BENCH_GPU=${BENCH_GPU}"
echo "ROCBUDAI_LLM_CPUS=${LLM_CPUS}"
echo "ROCBUDAI_BENCH_CPUS=${BENCH_CPUS}"
echo "ROCBUDAI_TOPO_METHOD=${TOPO_METHOD}"
