---
source: hand-curated by admin (derived from SKILLS_ROCBUDAI.md + AGENTS-gfx90a persona; public AMD material)
source_path: n/a
source_mtime: "2026-07-14T00:00:00-05:00"
extracted_with: "n/a (hand-written admin notes)"
extracted_at: "2026-07-14T00:00:00-05:00"
workload_type: general
admin_curated: true
---

# Performance Optimization Plays — MI250X (gfx90a, CDNA2)

## Purpose

Give the agent ideas on what optimizations to try on **MI250X** (and MI210 /
MI250), the CDNA2 discrete GPUs. Two big structural facts drive everything
here: the MI250X package has **two GCDs that are two separate HIP devices**
(not one GPU), and CDNA2 has **no FP8 matrix and no Infinity Cache**. Its
strength is **FP64**. Do not propose FP8 / microscaling plays on this arch.

---

## Core Operating Principles

1. **Measure, then classify, before optimizing.** Never propose an optimization without (a) a profile or microbenchmark that motivates it, or (b) a clearly stated hypothesis that you will then validate with a benchmark. From that profile, first decide the dominant kernel's bottleneck *class* (see "How to pick a play" below) — the class, not a remembered technique, dictates what to try.
2. **Validate numerical correctness after every change.** Scientific codes have tight tolerances. Always run a regression check (bitwise where possible, otherwise tolerance-based) before declaring a win.
3. **Document everything.** Every optimization session produces a markdown report: hypothesis, measurements, change, validation, result, follow-ups.
4. **Know the hardware.** MI250X is a **multi-die** CDNA2 GPU: 2 GCDs per package, each a separate device. Strong FP64, **no FP8**, **no Infinity Cache**.

---

## Hardware Reference

> Numbers below are **peak theoretical**, taken from AMD's public CDNA2 /
> Instinct MI200 Series material. Cite them as peak theoretical and verify
> against the vendor datasheet before quoting in a report.

### MI250X (CDNA2 discrete) — gfx90a

**Compute**

- **2 GCDs** (Graphics Compute Dies) per OAM package — **each GCD is a separate HIP device** (so a "single" MI250X presents as 2 GPUs)
- **110 CUs per GCD** (220 per package)
- Wavefront: **64 threads**
- Per-CU: 4 SIMD16; LDS: **64 KB/CU**, 32 banks × 4 B
- MFMA: FP64/FP32/FP16/BF16/INT8 — **no FP8** (CDNA2 predates FP8 matrix)
- **Strong FP64 matrix** — CDNA2's flagship HPC feature

**Memory**

- **64 GB HBM2e per GCD** (128 GB per package)
- ~1.6 TB/s per GCD (~3.2 TB/s aggregate across both GCDs)
- L2: **8 MB per GCD**
- **No Infinity Cache (MALL)** — CDNA2 has no last-level MALL; problem-level reuse must fit HBM or L2
- Infinity Fabric links between the 2 GCDs and across sockets

**Multi-die caveat**: the 2 GCDs do **not** share memory transparently. Cross-GCD
work needs MPI/RCCL or explicit peer copies (`hipMemcpyPeer`). Treat the package
as two GPUs, not one.

### Critical Differences vs NVIDIA A100/H100

| Property     | A100          | H100          | MI250X (per GCD)      |
| ------------ | ------------- | ------------- | --------------------- |
| Warp/wave    | 32            | 32            | 64                    |
| Shared/LDS   | ≤164 KB       | ≤228 KB       | 64 KB                 |
| L2           | 40 MB         | 50 MB         | 8 MB per GCD          |
| HBM          | 40/80 GB      | 80 GB         | 64 GB per GCD         |
| BW           | 2.0 TB/s      | 3.35 TB/s     | ~1.6 TB/s per GCD     |
| Tensor       | TF32/FP16     | WGMMA + FP8   | MFMA (**no FP8**)     |
| FP64         | strong        | strong        | **very strong**       |

**Difference vs MI300**: no FP8, no Infinity Cache, lower per-die BW, and the
2-GCD topology. Any FP8 / MX-format play or any Infinity-Cache-sized reuse
assumption is **wrong** here.

---

## Toolchain & Profiling Stack

Always check tool availability first: `which rocprofv3 rocprof-compute rocprof-sys hipcc amdclang++` and `rocminfo | grep -E 'gfx|Marketing'`.

## How to pick a play (do this BEFORE the list below)

Profile, then classify the dominant kernel from the numbers (rocprofv3 + roofline / achieved-vs-peak) — do not pick a play by name or walk the list in order. Match the class to the bottleneck:

- **Memory/bandwidth-bound** (achieved HBM BW near the ~1.6 TB/s per-GCD peak, or low arithmetic intensity): reduce *bytes moved* first — coalescing (6), remove redundant passes, reuse via cache/tiling (1). No Infinity Cache means less forgiving of streaming access — coalescing matters more than on MI300.
- **Compute-bound** (achieved FLOPs near peak, high VALU/MFMA utilization): occupancy (3), MFMA (5, **FP16/BF16/FP64 only**), divergence (9), mixed precision (11).
- **Launch/latency-bound** (many short <50 µs kernels): fusion or graphs (8).
- **Transfer / cross-GCD-bound** (H2D/D2H or GCD↔GCD traffic dominates): 14, 15, 17.

Do **not** reach for FP8 or microscaling plays on gfx90a — the hardware lacks the matrix support.

## Optimization Playbooks

### Playbook 1: Cache-Hierarchy Tile Sizing

**Goal**: tile to fit working set in target cache level.

- L1 (32 KB) for innermost loops; **L2-per-GCD (8 MB)** for block-level reuse. **No Infinity Cache** — there is no 256 MB MALL cushion, so problem-level reuse must fit HBM.

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

### Playbook 5: MFMA Adoption (FP16/BF16/FP64 — no FP8)

**Goal**: ensure matrix cores are used.

- Verify in `--save-temps` `.s` for `v_mfma_`* instructions
- Common shapes on gfx90a: `mfma_f32_16x16x16_f16`, `mfma_f32_32x32x8_f16`, `mfma_f32_16x16x16_bf16`, and **`mfma_f64_16x16x4_f64`** for FP64 matmul
- There are **no** `bf8`/`fp8` MFMA variants — do not target FP8

### Playbook 6: Memory Coalescing Audit

**Goal**: max effective HBM bandwidth.

- 64 lanes × 4 B = 256 B per transaction; align to 256 B. With no MALL, coalescing is especially important.

### Playbook 7: Prefetching / Double-Buffering

**Goal**: hide global memory latency.

- The direct global→LDS path (`global_load_lds`) is more limited on CDNA2 than CDNA3 — verify codegen before relying on it
- Prefer classic **double-buffering**: load tile (n+1) into registers/LDS while computing on tile (n)

### Playbook 8: Kernel Fusion

**Goal**: eliminate intermediate writes and launch overhead.

- Candidates: elementwise chains, GEMM+bias+activation, normalization+activation, reduction+broadcast, attention QK→softmax→V
- Heuristic: if a kernel runs <50 µs and feeds another, fusion is likely a win
- **Anti-pattern**: fusing across very different access patterns (broadcast + reduction) can hurt — measure

### Playbook 9: Divergence Reduction

**Goal**: restore lane utilization.

- Detect: high `VALUInsts` with low `VALUUtilization` (<60%)

### Playbook 10: Atomics Optimization

**Goal**: avoid atomic contention.

- Global atomics on hot addresses serialize through L2
- Fixes: per-block LDS reduction → single global atomic per block

### Playbook 11: Mixed-Precision Scientific Kernels

**Goal**: speed without losing accuracy.

- Iterative refinement: FP32/BF16 inner solve → FP64 residual → correction (Krylov, LU)
- **No FP8** — the lowest-precision matrix path is FP16/BF16
- CDNA2 FP64 is strong, so full-FP64 is often already competitive; measure before dropping precision

### Playbook 12: FFT Optimization (rocFFT)

**Goal**: best plan for problem shape.

- Use `rocfft_plan_create` with explicit batch; cache plans across timesteps
- For 3D FFTs >memory: slab decomposition + RCCL alltoall across GCDs/ranks
- Real-to-complex: use `rocfft_transform_type_real_forward`

### Playbook 13: Sparse Kernels (rocSPARSE)

**Goal**: format selection for SpMV/SpMM.

- Formats: CSR (general), ELL (uniform row length), HYB (mixed), BSR (block-sparse), COO
- Heuristic: if max(nnz/row) < 2× mean → ELL/HYB; if block structure → BSR; else CSR

## MI250X CDNA2 / Multi-GCD-Specific Playbooks

### Playbook 14: Treat Each GCD as a Separate GPU

**Goal**: correct process/device mapping on the 2-GCD package.

- Each GCD is its own HIP device — a 4-OAM node exposes **8 devices**
- One MPI rank per GCD; set `ROCR_VISIBLE_DEVICES=<gcd>` per rank
- NUMA-bind each rank to the GCD's local CPU + HBM (`numactl --cpunodebind --membind`)
- Cross-GCD data movement needs GPU-aware MPI / RCCL / `hipMemcpyPeer` — there is no transparent shared memory across GCDs

### Playbook 15: Cross-GCD & Multi-Node Collectives

**Goal**: keep GCD↔GCD and inter-node traffic on Infinity Fabric, not host.

- Baseline with `rccl-tests` first: if collectives are slow, the app can't be fast
- Verify RCCL topology follows Infinity Fabric links (`NCCL_DEBUG=INFO`); custom systems may need `NCCL_TOPO_FILE`
- Overlap collectives with compute (async collective on a dedicated stream)

### Playbook 16: NUMA & GPU Affinity

**Goal**: bind each process to its GCD's local CPU + HBM domain.

- `rocm-smi --showtoponuma` / `numactl --hardware` to see topology
- On the rocBudAI cluster, `rocbudai-bench` already reserves and NUMA-pins the benchmark device for you

### Playbook 17: Discrete Memory Management

**Goal**: keep PCIe/Infinity-Fabric transfers off the critical path.

- No unified memory — use pinned host memory (`hipHostMalloc`) + `hipMemcpyAsync` overlapped with compute
- Keep resident data on the device across iterations; move only deltas

### Playbook 18: Lean Into FP64

**Goal**: exploit CDNA2's FP64 matrix strength.

- For DGEMM/ZGEMM-heavy HPC (DFT, CFD implicit solvers), ensure rocBLAS/rocSOLVER use the optimized FP64 paths
- MI250X is often competitive with much newer parts on **pure-FP64** codes — don't reflexively drop to lower precision if the FP64 path is already near roofline

# End of Playbooks

This concludes the MI250X playbook knowledge base.
