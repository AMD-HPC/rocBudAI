---
source: hand-curated by admin (derived from the general perf-optimization-plays doc + SKILLS_ROCBUDAI.md; public AMD material)
source_path: n/a
source_mtime: "2026-07-14T00:00:00-05:00"
extracted_with: "n/a (hand-written admin notes)"
extracted_at: "2026-07-14T00:00:00-05:00"
workload_type: general
admin_curated: true
---

# Performance Optimization Plays — MI300A (gfx942, CDNA3 APU)

## Purpose

Give the agent ideas on what optimizations to try on **MI300A**, the CDNA3
APU. The defining feature is **true unified HBM** shared by the 24 Zen4 CPU
cores and the GPU — zero-copy CPU↔GPU, no PCIe bottleneck. The largest wins on
MI300A are usually the APU-specific plays (eliminate copies, CPU+GPU overlap,
prevent page-migration thrashing) that are invisible to anyone porting from
discrete-GPU thinking.

---

## Core Operating Principles

1. **Measure, then classify, before optimizing.** Never propose an optimization without (a) a profile or microbenchmark that motivates it, or (b) a clearly stated hypothesis that you will then validate with a benchmark. From that profile, first decide the dominant kernel's bottleneck *class* (see "How to pick a play" below) — the class, not a remembered technique, dictates what to try.
2. **Validate numerical correctness after every change.** Scientific codes have tight tolerances. Always run a regression check (bitwise where possible, otherwise tolerance-based) before declaring a win.
3. **Document everything.** Every optimization session produces a markdown report: hypothesis, measurements, change, validation, result, follow-ups.
4. **Know the hardware.** MI300A is an APU with unified memory.

---

## Hardware Reference

> Numbers below are **peak theoretical**, taken from AMD's public CDNA3 /
> Instinct MI300 Series material. Cite them as peak theoretical and verify
> against the vendor datasheet before quoting in a report.

### MI300A (CDNA3 APU) — gfx942

**Compute**

- 228 CDNA3 CUs in 6 XCDs (38 CUs each)
- 24 Zen4 cores in 3 CCDs, sharing the package
- Wavefront: **64 threads**
- Per-CU: 4 SIMD32, max 8 waves/SIMD → 2048 threads/CU
- VGPRs: 512/SIMD; SGPRs: 800/CU
- LDS: **64 KB/CU**, 32 banks × 4 B
- MFMA: FP64/FP32/FP16/BF16/FP8/INT8

**Memory**

- **128 GB unified HBM3** (CPU+GPU same physical memory), ~5.3 TB/s
- **256 MB Infinity Cache** (MALL)
- L2: **4 MB per XCD** (24 MB total)
- L1 vector: 32 KB/CU; Scalar: 16 KB shared

**APU-unique**: zero-copy CPU↔GPU, true unified memory, no PCIe bottleneck.

### Critical Differences vs NVIDIA H100/B200

| Property    | H100              | B200        | MI300A                   |
| ----------- | ----------------- | ----------- | ------------------------ |
| Warp/wave   | 32                | 32          | 64                       |
| Shared/LDS  | ≤228 KB           | ≤228 KB     | 64 KB                    |
| L2          | 50 MB mono        | 50 MB mono  | 4 MB × 6 XCD + 256 MB IC |
| HBM         | 80 GB             | 192 GB      | 128 GB unified           |
| BW          | 3.35 TB/s         | 8 TB/s      | 5.3 TB/s                 |
| Tensor      | WGMMA             | WGMMA + FP4 | MFMA                     |
| Unified mem | UVM (PCIe/NVLink) | UVM         | True unified             |

---

## Toolchain & Profiling Stack

Always check tool availability first: `which rocprofv3 rocprof-compute rocprof-sys hipcc amdclang++` and `rocminfo | grep -E 'gfx|Marketing'`.

## How to pick a play (do this BEFORE the list below)

Profile, then classify the dominant kernel from the numbers (rocprofv3 + roofline / achieved-vs-peak) — do not pick a play by name or walk the list in order. Match the class to the bottleneck:

- **Memory/bandwidth-bound** (achieved HBM BW near the ~5.3 TB/s peak, or low arithmetic intensity): reduce *bytes moved* first — coalescing (6), remove redundant passes and intermediate arrays, reuse via cache/tiling (1), prefetch (7). Most stencil, elementwise, and BLAS-1 kernels are here.
- **Compute-bound** (achieved FLOPs near peak, high VALU/MFMA utilization): occupancy (3), MFMA (5), divergence (9), mixed precision (11).
- **Launch/latency-bound** (many short <50 µs kernels with gaps between dispatches): fusion or graphs (8), fewer/larger launches.
- **Transfer/migration-bound** (H2D/D2H, page faults): 14, 17, 18.

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
  - MI300A: `mfma_f32_16x16x16_f16`, `mfma_f32_32x32x8_f16`, `mfma_f32_16x16x32_bf8_bf8`

### Playbook 6: Memory Coalescing Audit

**Goal**: max effective HBM bandwidth.

- 64 lanes × 4 B = 256 B per transaction; align to 256 B

### Playbook 7: Prefetching with global_load_lds

**Goal**: hide global memory latency.

- CDNA3+ instruction: `global_load_lds` loads from HBM directly into LDS, skipping registers

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
- Fixes: per-block LDS reduction → single global atomic per block; per-CU buffers reduced separately; `atomicAdd_system` only when truly needed
- MI300A unified mem: avoid `atomicAdd_system` to host-touched addresses (causes migration)

### Playbook 11: Mixed-Precision Scientific Kernels

**Goal**: speed without losing accuracy.

- Iterative refinement: FP32/BF16 inner solve → FP64 residual → correction (Krylov, LU)
- Validate: full FP64 reference, error norm vs problem-specific tolerance

### Playbook 12: FFT Optimization (rocFFT)

**Goal**: best plan for problem shape.

- Use `rocfft_plan_create` with `rocfft_transform_type_complex_forward` and explicit batch
- Plan caching: reuse plans across timesteps
- For 3D FFTs >memory: use slab decomposition + RCCL alltoall, not in-GPU multi-kernel
- Real-to-complex: use `rocfft_transform_type_real_forward` (saves ~2× memory and compute)
- Tune via `ROCFFT_LAYER=4` env to log plan choices

### Playbook 13: Sparse Kernels (rocSPARSE)

**Goal**: format selection for SpMV/SpMM.

- Formats: CSR (general), ELL (uniform row length), HYB (mixed), BSR (block-sparse), COO
- Heuristic: if max(nnz/row) < 2× mean → ELL/HYB; if block structure → BSR; else CSR

## MI300A APU-Specific Playbooks

### Playbook 14: Eliminate Redundant H2D/D2H on MI300A

**Goal**: exploit unified HBM.

- Grep for `hipMemcpy.*HostToDevice` / `DeviceToHost`
- Replace with `hipMalloc` to leverage GPU aware MPI or `hipHostMalloc` + `hipHostGetDevicePointer`
- Set `HSA_XNACK=1` for demand paging
- Caveat: APIs still cost ~µs each; remove the call entirely if possible

### Playbook 15: CPU+GPU Concurrent Execution on MI300A

**Goal**: use 24 Zen4 cores while GPU computes.

- Pattern: launch GPU work on stream → return to CPU → OpenMP-parallel CPU task → `hipStreamSynchronize` before next iteration

### Playbook 16: NUMA & APU Affinity

**Goal**: bind processes to local APU's HBM domain.

- use `rocbudai-bench` that is already doing this for you on the one APU reserved for benchmarking

### Playbook 17: Prevent Migration Thrashing on MI300A

**Goal**: stop CPU/GPU page ping-pong under XNACK.

- **Symptom**: high page-fault count in `rocm-smi --showpagefaults`, kernel time variance >20% across iterations, unexplained CPU stalls
- **Fixes**:
  - `hipMemAdvise(ptr, sz, hipMemAdviseSetPreferredLocation, devId)` — pin to GPU HBM
  - `hipMemAdvise(ptr, sz, hipMemAdviseSetReadMostly, 0)` — for read-only shared data (creates cached copies)
  - `hipMemAdvise(ptr, sz, hipMemAdviseSetAccessedBy, devId)` — establishes mapping without migration
  - `hipMemPrefetchAsync(ptr, sz, devId, stream)` — explicit migration at known sync points

### Playbook 18: Zero-Copy Data Pipelines on MI300A

**Goal**: build I/O → preprocess → GPU compute pipelines with no copies.

- File I/O directly into GPU-visible memory: `hipHostMalloc(&buf, sz, hipHostMallocCoherent)`, then `read()`/`fread()` into `buf`, then launch kernel on `buf`
- For HDF5/NetCDF: register the read buffer with `hipHostRegister`; or use direct-IO with aligned hugepages
- For Python (NumPy → GPU): `np.frombuffer` on hipMalloc'd region exposed via `__array_interface__`; or use CuPy/PyTorch tensors backed by managed memory
- **Anti-pattern detector**: any `hipMemcpy` immediately after a file read or socket recv — flag and refactor
- **Streaming dataloader pattern**: ring buffer of pinned/managed regions, prefetch N+1 while GPU consumes N

### Playbook 19: PyTorch on ROCm — Build & Verify

**Goal**: ensure correct ROCm-backed PyTorch.

- Verify: `python -c "import torch; print(torch.version.hip, torch.cuda.is_available(), torch.cuda.get_device_name())"`
- Common issues:
  - Wrong wheel (CUDA wheel installed, no GPUs visible) → reinstall from `https://download.pytorch.org/whl/rocm6.x` or use /rocm7.x

### Playbook 20: PyTorch TunableOp & hipBLASLt

**Goal**: best GEMM kernel per shape.

- load the pytorch module with tunable op

### Playbook 21: torch.compile / Inductor on ROCm

**Goal**: get fusion and Triton-generated kernels.

- Default backend works on ROCm; uses Triton-AMD
- Useful flags:
  ```python
  torch._inductor.config.max_autotune = True
  torch._inductor.config.coordinate_descent_tuning = True
  torch._inductor.config.triton.unique_kernel_names = True   # easier profiling
  ```
- Inspect generated code: `TORCH_LOGS=output_code,schedule python ...`
- Common issues: graph breaks (use `torch._dynamo.explain`), recompiles (check `torch._dynamo.config.cache_size_limit`)
- Validate: kernel count drops, fused kernels appear in profile, end-to-end speedup >10% (else compile overhead may dominate)

# End of Playbooks

This concludes the MI300A playbook knowledge base.
