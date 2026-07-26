#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# Static hygiene checks (no GPU/network): locks in the IP-review remediations,
# validates opencode JSON, and keeps KB files in sync with kb/README.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
SHARE="${ROOT}/share/rocbudai"; KB="${SHARE}/kb"

fail=0; pass=0
ok()  { printf '  [ ok ] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
absent() {  # absent <label> <regex>
    local h; h="$(grep -rnE "$2" "${ROOT}" --exclude-dir=tests --exclude-dir=.git 2>/dev/null || true)"
    [[ -z "${h}" ]] && ok "$1" || { bad "$1"; echo "${h}" | sed 's/^/        /'; }
}

echo "repo-hygiene:"
absent "no @amd.com emails"        '@amd\.com'
absent "no amd-internal refs"      'amd-internal'
absent "no unreleased ROCm 7.13"   '(^|[^0-9.])7\.13([^0-9]|$)'
absent "no stale tag qwen3.5:9b"   'qwen3\.5:9b'
absent "no stale tag qwen3.6"      'qwen3\.6'
grep -qE 'ROCBUDAI_MODEL.*gemma4:12b' "${SHARE}/test-env.sh" \
    && ok "test-env.sh pins gemma4:12b" || bad "test-env.sh no longer pins gemma4:12b"

for j in "${SHARE}"/opencode-*.json; do
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${j}" 2>/dev/null \
        && ok "valid JSON: $(basename "${j}")" || bad "invalid JSON: $(basename "${j}")"
done

while IFS= read -r name; do
    [[ -f "${KB}/${name}" ]] && ok "KB present: ${name}" || bad "KB referenced but missing: ${name}"
done < <(grep -oE '[a-z0-9_]+__[a-z0-9._-]+__amd-public__[0-9]{8}\.md' "${KB}/README.md" | sort -u)
for f in "${KB}"/*.md; do
    b="$(basename "${f}")"; [[ "${b}" == "README.md" ]] && continue
    grep -q "${b}" "${KB}/README.md" && ok "KB documented: ${b}" || bad "KB not in README: ${b}"
done

echo "repo-hygiene: ${pass} passed, ${fail} failed"
exit $(( fail > 0 ? 1 : 0 ))
