#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# rocbudai-load-hook.sh — called by the rocbudai Lmod modulefile at load time.
#
# Why this is a separate file (and not inline in the modulefile):
#   Lmod's execute{cmd=...} block is collapsed to a single eval line in the
#   user's shell, which breaks any inline `if/then/fi` control flow. By
#   shipping the logic as a real shell script we get readable bash and we
#   keep the modulefile small.
#
# This script runs in a subshell (Lmod evals `bash <this-script>`), so its
# environment changes do not leak back into the user's shell — that is the
# right behaviour for the ROCBUDAI_ACTIVE recursion guard.
#
# Inputs (set by the modulefile via setenv before this hook runs):
#   ROCBUDAI_ROOT, ROCBUDAI_MODEL, ROCBUDAI_OLLAMA_HOST,
#   ROCBUDAI_OPENCODE_BIN, PATH (with rocbudai-tui on it).

set -u

# If the user reached this compute node via ssh (e.g. `pam_slurm_adopt` letting
# them in because they have a running allocation here), SLURM_JOB_ID is NOT
# propagated into the shell — only the cgroup is (and on some configs not even
# that). Recover the jobid via squeue: their unique RUNNING job on this node.
if [[ -z "${SLURM_JOB_ID:-}" ]] && command -v squeue >/dev/null 2>&1; then
    _adopted=$(squeue -h -w "$(hostname -s)" -u "$USER" -t R -o '%i' 2>/dev/null)
    if [[ -n "$_adopted" && $(printf '%s\n' "$_adopted" | wc -l) -eq 1 ]]; then
        export SLURM_JOB_ID="$_adopted"
    fi
    unset _adopted
fi

if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    echo "[rocBudAI] this module is for compute nodes; you are on a login node." >&2
    echo "[rocBudAI] allocate a compute node first (-p selects the SPX MI300A" >&2
    echo "[rocBudAI] partition; --comment=ollama starts the ollama daemon):" >&2
    echo "[rocBudAI]   salloc -p PPAC_MI300A_SPX --exclusive --comment=ollama --time=01:00:00" >&2
    echo "[rocBudAI] then on the compute node prompt:" >&2
    echo "[rocBudAI]   cd <project-dir> && module load rocbudai" >&2
elif [[ -n "${ROCBUDAI_ACTIVE:-}" ]]; then
    echo "[rocBudAI] already inside a rocbudai session (ROCBUDAI_ACTIVE set); not re-launching." >&2
elif [[ ! -t 0 || ! -t 1 ]]; then
    echo "[rocBudAI] loaded (no TTY; not auto-launching). Run 'rocbudai-tui' to start." >&2
else
    export ROCBUDAI_ACTIVE=1
    rocbudai-tui
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "[rocBudAI] TUI exited with code $rc" >&2
    fi
fi
