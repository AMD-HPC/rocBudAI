# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
# rocBudAI — sourceable env for no-systemd / no-Slurm container testing.
#
# Usage (from inside the test container, after install.sh succeeded):
#
#     source /shared/apps/ubuntu/opt/rocbudai/share/rocbudai/test-env.sh
#     rocbudai-doctor          # Tier 2
#     rocbudai-tui             # Tier 3 (auto-fakes Slurm context)
#
# What this sets and why:
#
#   - PATH                       Make rocbudai-doctor / rocbudai-tui
#                                callable without an absolute path.
#   - ROCBUDAI_ROOT              Used by some agents/scripts to find
#                                share/, libexec/, AGENTS-default.md.
#   - ROCBUDAI_OPENCODE_BIN      Absolute path to the staged opencode
#                                binary (modulefile would set this in
#                                production).
#   - ROCBUDAI_OLLAMA_HOST       Daemon is on :11435 in test mode
#                                (no step-8 auth proxy on :11434).
#   - ROCBUDAI_MODEL             What the doctor/TUI assumes is pulled.
#   - ROCBUDAI_ALLOWED_MODELS    Allow-list, so the TUI's hard model
#                                gate accepts ROCBUDAI_MODEL.
#   - ROCBUDAI_SPX_PARTITIONS    Allow-list, so the TUI accepts the
#                                'test' partition name we fake below.
#   - SLURM_JOB_ID               Pretend we're inside an allocation.
#   - SLURM_JOB_COMMENT=ollama   Pretend we asked for --comment=ollama
#                                (so the TUI's hard --comment gate
#                                passes).
#   - SLURM_JOB_PARTITION=test   Pretend our allocation is on the
#                                'test' partition (matches the SPX
#                                allow-list above).
#
# Tier 2 (doctor) hint: if you want to exercise the "not in a Slurm
# allocation" failure path on purpose (e.g. to test the doctor's
# hint text), `unset SLURM_JOB_ID` after sourcing this file and re-
# run `rocbudai-doctor`. The other ROCBUDAI_* vars are unaffected.
#
# This file deliberately uses the staged install paths under
# /shared/apps/ubuntu/opt/rocbudai (matching INSTALL_ROOT and
# OPENCODE_ROOT defaults in install.sh). If you ran install.sh with
# overridden paths, override the same vars below.

# --- rocBudAI install layout (Tier 2 + Tier 3 — always needed) ---
export ROCBUDAI_ROOT="${ROCBUDAI_ROOT:-/shared/apps/ubuntu/opt/rocbudai}"
export ROCBUDAI_OPENCODE_BIN="${ROCBUDAI_OPENCODE_BIN:-/shared/apps/ubuntu/opt/opencode/1.14.28/opencode}"

case ":${PATH}:" in
    *:"${ROCBUDAI_ROOT}/bin":*) : ;;
    *) PATH="${ROCBUDAI_ROOT}/bin:${PATH}" ;;
esac
export PATH

# --- daemon + model (Tier 2 + Tier 3) ---
export ROCBUDAI_OLLAMA_HOST="${ROCBUDAI_OLLAMA_HOST:-http://127.0.0.1:11435}"
# gemma4:12b is the canonical testing model: a small (~8 GB) tools-enabled
# model. 'tools' support is required by `ollama launch opencode`, which uses
# tool calls to wire the model into opencode's bash/edit/etc. tools;
# tinyllama (640 MB) does NOT have tools enabled and would silently break the
# launcher in subtle ways. We use a small model on purpose: the container
# demo runs the COMPACT AGENTS-container-demo.md persona (not the full
# ~2100-line arch persona), so a small fast model follows the demo flow
# reliably AND keeps the cold-start short — the previous 27B made the
# quick-test cold-start painful.
export ROCBUDAI_MODEL="${ROCBUDAI_MODEL:-gemma4:12b}"
export ROCBUDAI_ALLOWED_MODELS="${ROCBUDAI_ALLOWED_MODELS:-gemma4:12b}"

# --- TUI partition allow-list (Tier 3 — must match SLURM_JOB_PARTITION) ---
export ROCBUDAI_SPX_PARTITIONS="${ROCBUDAI_SPX_PARTITIONS:-test}"

# --- Fake Slurm context (Tier 3 — drives the TUI hard gates) ---
export SLURM_JOB_ID="${SLURM_JOB_ID:-1}"
export SLURM_JOB_COMMENT="${SLURM_JOB_COMMENT:-ollama}"
export SLURM_JOB_PARTITION="${SLURM_JOB_PARTITION:-test}"

# Print a one-line summary so the user sees what changed.
printf 'rocbudai test-env loaded: model=%s host=%s root=%s slurm=job-%s/comment=%s/part=%s\n' \
    "${ROCBUDAI_MODEL}" \
    "${ROCBUDAI_OLLAMA_HOST}" \
    "${ROCBUDAI_ROOT}" \
    "${SLURM_JOB_ID}" \
    "${SLURM_JOB_COMMENT}" \
    "${SLURM_JOB_PARTITION}"
