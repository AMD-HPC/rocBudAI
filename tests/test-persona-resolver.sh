#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# Unit test for the arch->persona resolver in bin/rocbudai-tui. Sources only the
# block between the ">>> rocbudai persona-resolver" sentinels (so the launcher's
# body never runs), stubs rocminfo/warn, and asserts the mapping. No GPU needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
TUI="${ROOT}/bin/rocbudai-tui"
SHARE="${ROOT}/share/rocbudai"

fail=0; pass=0
check() {  # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then printf '  [ ok ] %s\n' "$1"; pass=$((pass+1))
    else printf '  [FAIL] %s (expected %q, got %q)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

resolver="$(awk '/# >>> rocbudai persona-resolver/{f=1;next} /# <<< rocbudai persona-resolver/{f=0} f' "${TUI}")"
[[ -n "${resolver}" ]] || { echo "FATAL: resolver sentinels missing in ${TUI}" >&2; exit 2; }
warn() { :; }
# shellcheck disable=SC1090
source /dev/stdin <<<"${resolver}"

stubdir="$(mktemp -d)"; trap 'rm -rf "${stubdir}"' EXIT; PATH="${stubdir}:${PATH}"
set_rocminfo() {  # empty arg removes the stub
    [[ -z "${1:-}" ]] && { rm -f "${stubdir}/rocminfo"; return; }
    printf '#!/usr/bin/env bash\ncat <<__RI__\n%s\n__RI__\n' "$1" >"${stubdir}/rocminfo"
    chmod +x "${stubdir}/rocminfo"
}

echo "persona-resolver:"
set_rocminfo ""
check "explicit gfx90a" "AGENTS-gfx90a.md" "$(ROCBUDAI_GFX_ARCH=gfx90a _persona_for_arch)"
check "explicit gfx950" "AGENTS-gfx950.md" "$(ROCBUDAI_GFX_ARCH=gfx950 _persona_for_arch)"
set_rocminfo "  Marketing Name:  AMD Instinct MI300A"
check "gfx942 + APU -> MI300A" "AGENTS-default.md" "$(ROCBUDAI_GFX_ARCH=gfx942 _persona_for_arch)"
set_rocminfo "  Marketing Name:  AMD Instinct MI300X"
check "gfx942 discrete -> MI300X" "AGENTS-gfx942-mi300x.md" "$(ROCBUDAI_GFX_ARCH=gfx942 _persona_for_arch)"
set_rocminfo "  Name:    gfx950"
check "autodetect gfx950" "AGENTS-gfx950.md" "$(unset ROCBUDAI_GFX_ARCH; _persona_for_arch)"
set_rocminfo "  Name:    gfx90a"
check "autodetect gfx90a" "AGENTS-gfx90a.md" "$(unset ROCBUDAI_GFX_ARCH; _persona_for_arch)"
set_rocminfo ""
check "undetectable -> default" "AGENTS-default.md" "$(unset ROCBUDAI_GFX_ARCH; _persona_for_arch)"

for f in AGENTS-gfx90a.md AGENTS-gfx950.md AGENTS-gfx942-mi300x.md AGENTS-default.md; do
    [[ -f "${SHARE}/${f}" ]] && { printf '  [ ok ] persona exists: %s\n' "${f}"; pass=$((pass+1)); } \
                             || { printf '  [FAIL] missing persona: %s\n' "${f}"; fail=$((fail+1)); }
done

echo "persona-resolver: ${pass} passed, ${fail} failed"
exit $(( fail > 0 ? 1 : 0 ))
