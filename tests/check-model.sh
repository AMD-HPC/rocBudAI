#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# Live preflight: does ROCBUDAI_MODEL exist on the Ollama host, and is it
# tools-enabled? A model without `tools` silently breaks `ollama launch
# opencode`. Needs a running daemon, so it is NOT part of the offline suite.
#
#   ROCBUDAI_OLLAMA_HOST=http://127.0.0.1:11435 ROCBUDAI_MODEL=gemma4:12b \
#       tests/check-model.sh
set -uo pipefail

HOST="${ROCBUDAI_OLLAMA_HOST:-http://127.0.0.1:11435}"
MODEL="${ROCBUDAI_MODEL:-qwen3.5:122b}"
rc=0
echo "model preflight: host=${HOST} model=${MODEL}"

if ! ver="$(curl -fsS --max-time 5 "${HOST}/api/version" 2>/dev/null)"; then
    echo "  [FAIL] ollama not reachable at ${HOST}"; exit 1
fi
echo "  [ ok ] ollama reachable (${ver})"

tags="$(curl -fsS --max-time 5 "${HOST}/api/tags" 2>/dev/null || true)"
if printf '%s' "${tags}" | grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"${MODEL}(:latest)?\""; then
    echo "  [ ok ] model present"
else
    echo "  [FAIL] model not pulled (run: ollama pull ${MODEL})"; rc=1
fi

show="$(curl -fsS --max-time 10 "${HOST}/api/show" -d "{\"model\":\"${MODEL}\"}" 2>/dev/null || true)"
if printf '%s' "${show}" | grep -q '"tools"'; then
    echo "  [ ok ] model is tools-enabled"
elif [[ -z "${show}" ]]; then
    echo "  [warn] could not query /api/show — verify tools support manually"
else
    echo "  [FAIL] model does not advertise 'tools' — opencode launch will break"; rc=1
fi
exit "${rc}"
