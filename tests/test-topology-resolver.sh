#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# Unit test for the device->NUMA resolution cascade in
# libexec/rocbudai-detect-topology.sh. Builds synthetic sysfs fixtures
# (via the ROCBUDAI_SYSFS_KFD/_DRM/_NODE overrides) and asserts the helper
# derives the correct bench/LLM CPU pin. No GPU / ROCm / network needed.
#
# Regression target: the 2026-07-23 MI300A-SPX bug where GPU render minors
# are non-contiguous (128,136,144,152) and only those expose numa_node, so
# the old renderD<128+idx> math blanked ROCBUDAI_BENCH_CPUS and the bench
# ran unpinned (~20x slower on memory-bound FOMs).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
HELPER="${ROOT}/libexec/rocbudai-detect-topology.sh"

fail=0; pass=0
check() {  # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then printf '  [ ok ] %s\n' "$1"; pass=$((pass+1))
    else printf '  [FAIL] %s (expected %q, got %q)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# Force count_gpus down the KFD path regardless of the host: a rocm-smi stub
# that emits nothing makes the card-count 0, so the helper falls back to the
# fixture KFD topology.
stubdir="${TMP}/stub"; mkdir -p "${stubdir}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${stubdir}/rocm-smi"; chmod +x "${stubdir}/rocm-smi"

mk_kfd_gpu() {  # <kfd_root> <node_id> <simd_count> [render_minor]
    local d="$1/$2"; mkdir -p "$d"
    { echo "simd_count $3"; [[ -n "${4:-}" ]] && echo "drm_render_minor $4"; } > "$d/properties"
}
mk_render_numa() {  # <drm_root> <minor> <numa_node>
    local d="$1/renderD$2/device"; mkdir -p "$d"; echo "$3" > "$d/numa_node"
}
mk_render_bare() {  # <drm_root> <minor>   (render node with NO numa_node)
    mkdir -p "$1/renderD$2/device"
}
mk_node() {  # <node_root> <id> <cpulist>
    local d="$1/node$2"; mkdir -p "$d"; echo "$3" > "$d/cpulist"
}

# The four MI300A SPX NUMA nodes (one APU per node).
mk_nodes() {  # <node_root>
    mk_node "$1" 0 "0-23,96-119"
    mk_node "$1" 1 "24-47,120-143"
    mk_node "$1" 2 "48-71,144-167"
    mk_node "$1" 3 "72-95,168-191"
}

EXP_BENCH="72-95,168-191"
EXP_LLM="0-23,96-119,24-47,120-143,48-71,144-167"

run_topo() {  # <kfd> <drm> <node> -> emits KEY=VALUE lines
    ROCBUDAI_SYSFS_KFD="$1" ROCBUDAI_SYSFS_DRM="$2" ROCBUDAI_SYSFS_NODE="$3" \
        PATH="${stubdir}:${PATH}" bash "${HELPER}"
}
field() { grep "^$1=" <<<"$2" | cut -d= -f2-; }

# --- Case 1: real MI300A SPX layout (non-contiguous minors, KFD-authoritative)
K="${TMP}/c1/kfd"; D="${TMP}/c1/drm"; N="${TMP}/c1/node"
mk_kfd_gpu "$K" 4 912 128; mk_kfd_gpu "$K" 5 912 136
mk_kfd_gpu "$K" 6 912 144; mk_kfd_gpu "$K" 7 912 152
mk_render_numa "$D" 128 0; mk_render_numa "$D" 136 1
mk_render_numa "$D" 144 2; mk_render_numa "$D" 152 3
# decoy render nodes with no numa_node, as the real kernel exposes
for m in 129 130 131 132 133 134 135; do mk_render_bare "$D" "$m"; done
mk_nodes "$N"
OUT="$(run_topo "$K" "$D" "$N")"
echo "case 1 — MI300A SPX (non-contiguous render minors):"
check "GPU_COUNT" 4 "$(field ROCBUDAI_GPU_COUNT "$OUT")"
check "BENCH_GPU" 3 "$(field ROCBUDAI_BENCH_GPU "$OUT")"
check "BENCH_CPUS" "$EXP_BENCH" "$(field ROCBUDAI_BENCH_CPUS "$OUT")"
check "LLM_CPUS" "$EXP_LLM" "$(field ROCBUDAI_LLM_CPUS "$OUT")"
check "METHOD=sysfs" "sysfs" "$(field ROCBUDAI_TOPO_METHOD "$OUT")"

# --- Case 2: identity fallback (KFD minors known, but NO numa_node anywhere)
K="${TMP}/c2/kfd"; D="${TMP}/c2/drm"; N="${TMP}/c2/node"
mk_kfd_gpu "$K" 4 912 128; mk_kfd_gpu "$K" 5 912 136
mk_kfd_gpu "$K" 6 912 144; mk_kfd_gpu "$K" 7 912 152
for m in 128 136 144 152; do mk_render_bare "$D" "$m"; done   # no numa_node files
mk_nodes "$N"
OUT="$(run_topo "$K" "$D" "$N")"
echo "case 2 — identity fallback (#NUMA == #GPU, no device numa_node):"
check "BENCH_CPUS" "$EXP_BENCH" "$(field ROCBUDAI_BENCH_CPUS "$OUT")"
check "LLM_CPUS" "$EXP_LLM" "$(field ROCBUDAI_LLM_CPUS "$OUT")"
check "METHOD=identity" "identity" "$(field ROCBUDAI_TOPO_METHOD "$OUT")"

# --- Case 3: legacy contiguous layout (no drm_render_minor; rung-2 enum)
K="${TMP}/c3/kfd"; D="${TMP}/c3/drm"; N="${TMP}/c3/node"
mk_kfd_gpu "$K" 4 912; mk_kfd_gpu "$K" 5 912
mk_kfd_gpu "$K" 6 912; mk_kfd_gpu "$K" 7 912
mk_render_numa "$D" 128 0; mk_render_numa "$D" 129 1
mk_render_numa "$D" 130 2; mk_render_numa "$D" 131 3
mk_nodes "$N"
OUT="$(run_topo "$K" "$D" "$N")"
echo "case 3 — legacy contiguous minors (rung-2 render enumeration):"
check "BENCH_CPUS" "$EXP_BENCH" "$(field ROCBUDAI_BENCH_CPUS "$OUT")"
check "METHOD=sysfs" "sysfs" "$(field ROCBUDAI_TOPO_METHOD "$OUT")"

# --- Case 4: unresolvable -> no pin (no numa_node, #NUMA != #GPU)
K="${TMP}/c4/kfd"; D="${TMP}/c4/drm"; N="${TMP}/c4/node"
mk_kfd_gpu "$K" 4 912 128; mk_kfd_gpu "$K" 5 912 136
mk_kfd_gpu "$K" 6 912 144; mk_kfd_gpu "$K" 7 912 152
for m in 128 136 144 152; do mk_render_bare "$D" "$m"; done
mk_node "$N" 0 "0-95"   # single NUMA node: #NUMA(1) != #GPU(4)
OUT="$(run_topo "$K" "$D" "$N")"
echo "case 4 — unresolvable topology (safe no-pin):"
check "BENCH_CPUS empty" "" "$(field ROCBUDAI_BENCH_CPUS "$OUT")"
check "METHOD=none" "none" "$(field ROCBUDAI_TOPO_METHOD "$OUT")"

echo "topology-resolver: ${pass} passed, ${fail} failed"
exit $(( fail > 0 ? 1 : 0 ))
