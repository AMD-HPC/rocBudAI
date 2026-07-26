#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# Offline test runner — runs every static/unit test that needs no GPU, no
# ROCm, and no network. This is what CI runs on every push/PR.
#
# Live behavior checks that need a running Ollama + model live under
# tests/eval/ and are NOT run here (see tests/eval/README.md).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
for t in "${HERE}"/test-*.sh; do
    echo "==> ${t##*/}"
    bash "${t}" || rc=1
    echo
done

if (( rc == 0 )); then
    echo "ALL OFFLINE TESTS PASSED"
else
    echo "SOME TESTS FAILED" >&2
fi
exit "${rc}"
