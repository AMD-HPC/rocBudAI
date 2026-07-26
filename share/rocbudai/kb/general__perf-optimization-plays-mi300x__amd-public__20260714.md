---
source: hand-curated by admin (derived from SKILLS_ROCBUDAI.md + AGENTS-gfx942-mi300x persona; public AMD material)
source_path: n/a
source_mtime: "2026-07-14T00:00:00-05:00"
extracted_with: "n/a (hand-written admin notes)"
extracted_at: "2026-07-14T00:00:00-05:00"
workload_type: general
admin_curated: true
---

# Performance Optimization Plays — MI300X (gfx942, CDNA3 discrete)

## Purpose

Give the agent ideas on what optimizations to try on **MI300X**, the discrete
CDNA3 GPU. Same ISA as MI300A (gfx942) but a **discrete** part: host↔device
transfers cost real time, memory is not unified, and nodes are typically
8-GPU with all-to-all Infinity Fabric. The MI300A-specific unified-memory
plays do **not** apply here — see the MI300X-specific section.

---

## Core Operating Principles

1. **Measure, then classify, before optimizing.** Never propose an optimization without (a) a profile or microbenchmark that motivates it, or (b) a clearly stated hypothesis that you will then validate with a benchmark. From that profile, first decide the dominant kernel's bottleneck *class* (see "How to pick a play" below) — the class, not a remembered technique, dictates what to try.
2. **Validate numerical correctness after every change.** Scientific codes have tight tolerances. Always run a regression check (bitwise where possible, otherwise tolerance-based) before declaring a win.
3. **Document everything.** Every optimization session produces a markdown report: hypothesis, measurements, change, validation, result, follow-ups.
4. **Know the hardware.** MI300X is a **discrete** CDNA3 GPU with 192 GB HBM3; host↔device copies over PCIe/xGMI are NOT free (unlike the MI300A APU).

---

## Hardware Reference

> Numbers below are **peak theoretical**, taken from AMD's public CDNA3 / Instinct
> MI300 Series material. Cite them as peak theoretical and verify against the
> vendor datasheet before quoting in a report.

### MI300X (CDNA3 discrete) — gfx942

**Compute**

- 304 CDNA3 CUs in 8 XCDs (38 CUs each)
- Wavefront: **64 threads**
- Per-CU: 4 SIMD32, max 8 waves/SIMD → 2048 threads/CU
- VGPRs: 512/SIMD; SGPRs: 800/CU
- LDS: **64 KB/CU**, 32 banks × 4 B
- MFMA: FP64/FP32/FP16/BF16/FP8/INT8

**Memory**

- **192 GB HBM3**, ~5.3 TB/s
- **256 MB Infinity Cache** (MALL)
- L2: **4 MB per XCD** (32 MB total across 8 XCDs)
- L1 vector: 32 KB/CU; Scalar: 16 KB shared

**Discrete-GPU facts**: NOT unified memory. Host↔device transfers go over
PCIe Gen5 / xGMI. Managed memory (`hipMallocManaged`) works but pages migrate
at real cost. Nodes are typically **8× MI300X** with all-to-all Infinity
Fabric (xGMI) between GPUs — plan for intra-node collectives and P2P.

### Critical Differences vs NVIDIA H100/B200

| Property    | H100              | B200        | MI300X                   |
| ----------- | ----------------- | ----------- | ------------------------ |
| Warp/wave   | 32                | 32          | 64                       |
| Shared/LDS  | ≤228 KB           | ≤228 KB     | 64 KB                    |
| L2          | 50 MB mono        | 50 MB mono  | 4 MB × 8 XCD + 256 MB IC |
| HBM         | 80 GB             | 192 GB      | 192 GB                   |
| BW          | 3.35 TB/s         | 8 TB/s      | 5.3 TB/s                 |
| Tensor      | WGMMA             | WGMMA + FP4 | MFMA (incl. FP8)         |
| Memory model| discrete (PCIe)   | discrete    | discrete (PCIe/xGMI)     |

**Difference vs MI300A**: same gfx942 ISA and 64 KB LDS, but MI300X is
**discrete** (192 GB vs 128 GB unified). Any play that assumes zero-copy
CPU↔GPU or "spill to host is free" is an **MI300A-only** play — do not apply
it here.

---

## Toolchain & Profiling Stack

Always check tool availability first: `which rocprofv3 rocprof-compute rocprof-sys hipcc amdclang++` and `rocminfo | grep -E 'gfx|Marketing'`.

## How to pick a play (do this BEFORE the list below)

Profile, then classify the dominant kernel from the numbers (rocprofv3 + roofline / achieved-vs-peak) — do not pick a play by name or walk the list in order. Match the class to the bottleneck:

- **Memory/bandwidth-bound** (achieved HBM BW near the ~5.3 TB/s peak, or low arithmetic intensity): reduce *bytes moved* first — coalescing (6), remove redundant passes and intermediate arrays, reuse via cache/tiling (1), prefetch (7). Most stencil, elementwise, and BLAS-1 kernels are here.
- **Compute-bound** (achieved FLOPs near peak, high VALU/MFMA utilization): occupancy (3), MFMA (5), divergence (9), mixed precision (11).
- **Launch/latency-bound** (many short <50 µs kernels with gaps between dispatches): fusion or graphs (8), fewer/larger launches.
- **Transfer-bound** (H2D/D2H dominates the timeline, or PCIe/xGMI staging visible in `rocprof-sys`): 14, 15, 16. On a discrete GPU this is often the single biggest win — it is NOT free like on the MI300A APU.

A play applies only if the profile signature matches it; e.g. occupancy/block-size/tiling knobs will not move a bandwidth-bound kernel. If two changes within a class give no measured gain, re-profile and re-classify rather than trying another knob in the same class.

## Optimization Playbooks

### Playbook 1: Cache-Hierarchy Tile Sizing

**Goal**: tile to fit working set in target cache level.

- L1 (32 KB) for innermost loops; L2-per-XCD (4 MB) for block-level reuse; Infinity Cache (256 MB) for problem-level reuse

### Playbook 2: Wavefront-64 Port Audit

**Goal**: find CUDA assumptions of warp=32.

- Grep for: `warpSize`, `__shfl_sync`, `0xffffffff`, `__ballot`, `__activemask`, `cooperative_groups::tile<32>`, hard-coded `32`/`31`

### Playbook 3: Occupancy Tuning

**Goal**: find the occupancy sweet spot (not always max).

- Read `-Rpass-analysis=kernel-resource-usage` for VGPR/SGPR/LDS

### Playbook 4: LDS Bank-Conflict Elimination

**Goal**: eliminate serialization in shared-mem accesses.

- 32 banks × 4 B; conflict when ≥2 lanes hit same bank in same cycle
- Detect via `LDSBankConflict` counter in rocprofv3

### Playbook 5: MFMA Adoption

**Goal**: ensure matrix cores are used.

- Verify in `--save-temps` `.s` for `v_mfma_`* instructions
- Common shapes:
  - MI300X: `mfma_f32_16x16x16_f16`, `mfma_f32_32x32x8_f16`, `mfma_f32_16x16x32_bf8_bf8` (FP8 available on gfx942)

### Playbook 6: Memory Coalescing Audit

**Goal**: max effective HBM bandwidth.

- 64 lanes × 4 B = 256 B per transaction; align to 256 B

### Playbook 7: Prefetching with global_load_lds

**Goal**: hide global memory latency.

- CDNA3 instruction: `global_load_lds` loads from HBM directly into LDS, skipping registers

### Playbook 8: Kernel Fusion

**Goal**: eliminate intermediate writes and launch overhead.

- Candidates: elementwise chains (multiple pointwise ops), GEMM+bias+activation, normalization+activation, reduction+broadcast, attention QK→softmax→V
- Heuristic: if a kernel runs <50 µs and feeds another, fusion is likely a win
- **Anti-pattern**: fusing across very different access patterns (broadcast + reduction) can hurt — measure

### Playbook 9: Divergence Reduction

**Goal**: restore lane utilization.

- Detect: high `VALUInsts` with low `VALUUtilization` (<60%)

### Playbook 10: Atomics Optimization

**Goal**: avoid atomic contention.

- Global atomics on hot addresses serialize through L2
- Fixes: per-block LDS reduction → single global atomic per block; per-CU buffers reduced separately

### Playbook 11: Mixed-Precision Scientific Kernels

**Goal**: speed without losing accuracy.

- Iterative refinement: FP32/BF16 inner solve → FP64 residual → correction (Krylov, LU)
- FP8 GEMM available on gfx942 for tolerant inner loops — validate against FP64 reference
- Validate: full FP64 reference, error norm vs problem-specific tolerance

### Playbook 12: FFT Optimization (rocFFT)

**Goal**: best plan for problem shape.

- Use `rocfft_plan_create` with `rocfft_transform_type_complex_forward` and explicit batch
- Plan caching: reuse plans across timesteps
- For 3D FFTs >memory: use slab decomposition + RCCL alltoall, not in-GPU multi-kernel
- Real-to-complex: use `rocfft_transform_type_real_forward` (saves ~2× memory and compute)

### Playbook 13: Sparse Kernels (rocSPARSE)

**Goal**: format selection for SpMV/SpMM.

- Formats: CSR (general), ELL (uniform row length), HYB (mixed), BSR (block-sparse), COO
- Heuristic: if max(nnz/row) < 2× mean → ELL/HYB; if block structure → BSR; else CSR

## MI300X Discrete-GPU-Specific Playbooks

### Playbook 14: Minimize & Overlap Host↔Device Transfers

**Goal**: keep PCIe/xGMI off the critical path (this is NOT free like MI300A).

- Grep for `hipMemcpy.*HostToDevice` / `DeviceToHost` in hot loops — the anti-pattern is a copy per iteration
- Use **pinned** host memory (`hipHostMalloc`) so copies use DMA at full PCIe/xGMI bandwidth
- Overlap copies with compute: issue `hipMemcpyAsync` on a dedicated stream, keep kernels on another, sync via events
- Keep resident data **on the device** across iterations; only move deltas
- For MPI, pass device pointers to a **GPU-aware MPI** so the stack does GPU-direct instead of staging through host (see Playbook 15)

### Playbook 15: Intra-Node Multi-GPU (8× MI300X) Scaling

**Goal**: exploit all-to-all xGMI between the 8 GPUs in a node.

- Enable P2P: `hipDeviceEnablePeerAccess`; use `hipMemcpyPeerAsync` for direct GPU↔GPU
- Collectives: **RCCL** (NCCL-compatible); baseline with `rccl-tests` before touching the app
- One process per GPU, `ROCR_VISIBLE_DEVICES` per rank; bind the rank to the GPU's NUMA-local CPU cores (see Playbook 16)
- Verify RCCL builds rings/trees along xGMI links (`NCCL_DEBUG=INFO`); a bad topology shows up as 2–10× slower large-message BW

### Playbook 16: NUMA & GPU Affinity

**Goal**: bind each process to its GPU's local CPU + HBM domain.

- `rocm-smi --showtoponuma` / `numactl --hardware` to see topology
- Per-rank wrapper: `numactl --cpunodebind=N --membind=N` paired with `ROCR_VISIBLE_DEVICES=<gpu>`
- On the rocBudAI cluster, `rocbudai-bench` already reserves and NUMA-pins the benchmark GPU for you

### Playbook 17: Managed-Memory Migration Control (discrete)

**Goal**: if the code uses `hipMallocManaged`, stop page ping-pong.

- Unlike MI300A, managed memory on a **discrete** GPU migrates pages at real cost
- `hipMemAdvise(ptr, sz, hipMemAdviseSetPreferredLocation, devId)` — pin to GPU HBM
- `hipMemAdvise(ptr, sz, hipMemAdviseSetReadMostly, 0)` — read-only shared data
- `hipMemPrefetchAsync(ptr, sz, devId, stream)` — explicit migration at known sync points
- Prefer plain `hipMalloc` + explicit transfers (Playbook 14) for hot buffers

### Playbook 18: PyTorch / vLLM on MI300X

**Goal**: MI300X is the primary ML training/inference target — get the stack right.

- Verify ROCm-backed torch: `python -c "import torch; print(torch.version.hip, torch.cuda.is_available())"`
- `export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True` (big fragmentation win)
- **TunableOp** (`PYTORCH_TUNABLEOP_ENABLED=1`, tune once then lock) — 5–30% on transformer GEMMs; high payoff on diverse-shape training
- `torch.compile` / Inductor uses Triton-AMD; `max_autotune=True`
- **vLLM**: 192 GB enables large KV cache; `--tensor-parallel-size = GPUs/node`, `--kv-cache-dtype fp8` (validate accuracy), `VLLM_USE_AITER=1` for AMD-tuned attention/MoE kernels

# End of Playbooks

This concludes the MI300X playbook knowledge base.
