---
source: hand-curated by admin (derived from SKILLS_ROCBUDAI.md + AGENTS-gfx950 persona; public AMD material)
source_path: n/a
source_mtime: "2026-07-14T00:00:00-05:00"
extracted_with: "n/a (hand-written admin notes)"
extracted_at: "2026-07-14T00:00:00-05:00"
workload_type: general
admin_curated: true
---

# Performance Optimization Plays — MI355X (gfx950, CDNA4)

## Purpose

Give the agent ideas on what optimizations to try on **MI355X** (and MI350X),
the CDNA4 discrete GPUs. Three CDNA4 changes dominate the optimization space:
**microscaling (MX) FP4/FP6/FP8** matrix formats, a much larger **160 KB LDS**,
and **8 XCDs**. One caution: **FP64 matrix throughput is roughly halved vs
MI300X** — HPC FP64 code that was matrix-bound can regress here.

---

## Core Operating Principles

1. **Measure, then classify, before optimizing.** Never propose an optimization without (a) a profile or microbenchmark that motivates it, or (b) a clearly stated hypothesis that you will then validate with a benchmark. From that profile, first decide the dominant kernel's bottleneck *class* (see "How to pick a play" below) — the class, not a remembered technique, dictates what to try.
2. **Validate numerical correctness after every change.** Scientific codes have tight tolerances. Always run a regression check (bitwise where possible, otherwise tolerance-based) before declaring a win. This matters doubly for MX-format (FP4/FP6) changes.
3. **Document everything.** Every optimization session produces a markdown report: hypothesis, measurements, change, validation, result, follow-ups.
4. **Know the hardware.** MI355X is a **discrete** CDNA4 GPU: 160 KB LDS, MX-FP4/6/8 matrix formats, 288 GB HBM3E, 8 XCDs — and **halved FP64 matrix vs MI300X**.

---

## Hardware Reference

> Numbers below are **peak theoretical**, taken from AMD's public CDNA4 /
> Instinct MI350 Series material. Cite them as peak theoretical and verify
> against the vendor datasheet before quoting in a report. MI350X and MI355X
> share the die; MI350X is air-cooled (~1000 W, 2200 MHz), MI355X is
> direct-liquid-cooled (~1400 W, 2400 MHz).

### MI355X (CDNA4 discrete) — gfx950

**Compute**

- **256 CDNA4 CUs** in **8 XCDs** (32 CUs each)
- Wavefront: **64 threads**
- Per-CU: 4 SIMD32, similar occupancy envelope to CDNA3
- LDS: **160 KB/CU** — a large increase from MI300's 64 KB (major change)
- MFMA: FP64/FP32/FP16/BF16/FP8/INT8 **plus MX-FP4 / MX-FP6 / MX-FP8** microscaling
- **FP64 matrix ~halved vs MI300X** — see Playbook 17

**Memory**

- **288 GB HBM3E**, ~8 TB/s peak BW
- L2: **4 MB per XCD** (32 MB total across 8 XCDs)
- Infinity Cache (MALL) present; size varies by SKU

**MI355X-unique**:

- **Microscaling (OCP MX) formats**: FP4/FP6/FP8 with a shared E8M0 exponent per 32-element block → ~2× throughput vs plain FP8 for inference
- **160 KB LDS** enables CUDA-style large shared-mem tiles to port more directly
- **288 GB HBM** enables larger model / problem residency on a single GPU
- **8 XCDs** (vs 6 on MI300A) — schedule with grid dims divisible by 8 for even distribution

### Critical Differences vs NVIDIA H100/B200

| Property    | H100              | B200        | MI355X                     |
| ----------- | ----------------- | ----------- | -------------------------- |
| Warp/wave   | 32                | 32          | 64                         |
| Shared/LDS  | ≤228 KB           | ≤228 KB     | **160 KB**                 |
| L2          | 50 MB mono        | 50 MB mono  | 4 MB × 8 XCD + IC          |
| HBM         | 80 GB             | 192 GB      | 288 GB                     |
| BW          | 3.35 TB/s         | 8 TB/s      | 8 TB/s                     |
| Tensor      | WGMMA             | WGMMA + FP4 | MFMA + **MX-FP4/6/8**      |
| Memory model| discrete          | discrete    | discrete                   |

**Difference vs MI300**: bigger LDS (160 vs 64 KB), MX matrix formats, 8 XCDs,
but **lower FP64 matrix throughput**. Tile sizes and FP64 assumptions carried
over from MI300 need rechecking.

---

## Toolchain & Profiling Stack

Always check tool availability first: `which rocprofv3 rocprof-compute rocprof-sys hipcc amdclang++` and `rocminfo | grep -E 'gfx|Marketing'`.

## How to pick a play (do this BEFORE the list below)

Profile, then classify the dominant kernel from the numbers (rocprofv3 + roofline / achieved-vs-peak) — do not pick a play by name or walk the list in order. Match the class to the bottleneck:

- **Memory/bandwidth-bound** (achieved HBM BW near the ~8 TB/s peak, or low arithmetic intensity): reduce *bytes moved* first — coalescing (6), reuse via cache/tiling (1, now with 160 KB LDS), prefetch (7).
- **Compute-bound** (achieved FLOPs near peak, high VALU/MFMA utilization): MFMA (5), **MX microscaling for tolerant GEMMs (14)**, occupancy (3), divergence (9), mixed precision (11).
- **Launch/latency-bound** (many short <50 µs kernels): fusion or graphs (8); check grid dims are divisible by 8 XCDs (16).
- **Transfer-bound** (H2D/D2H dominates): 18 (discrete memory management).

A play applies only if the profile signature matches it. If two changes within a class give no measured gain, re-profile and re-classify rather than trying another knob in the same class.

## Optimization Playbooks

### Playbook 1: Cache-Hierarchy Tile Sizing (160 KB LDS)

**Goal**: tile to fit working set in target cache level.

- L1 (32 KB) for innermost loops; L2-per-XCD (4 MB) for block-level reuse; Infinity Cache for problem-level reuse
- **With 160 KB LDS you can use much larger LDS-resident tiles than on MI300 (64 KB)** — recheck any CUDA/MI300-tuned tile sizes; larger tiles often win here

### Playbook 2: Wavefront-64 Port Audit

**Goal**: find CUDA assumptions of warp=32.

- Grep for: `warpSize`, `__shfl_sync`, `0xffffffff`, `__ballot`, `__activemask`, `cooperative_groups::tile<32>`, hard-coded `32`/`31`

### Playbook 3: Occupancy Tuning

**Goal**: find the occupancy sweet spot (not always max).

- Read `-Rpass-analysis=kernel-resource-usage` for VGPR/SGPR/LDS
- With 160 KB LDS, LDS is less likely to be the occupancy limiter than on MI300 — VGPRs often dominate instead

### Playbook 4: LDS Bank-Conflict Elimination

**Goal**: eliminate serialization in shared-mem accesses.

- 32 banks × 4 B; conflict when ≥2 lanes hit same bank in same cycle
- Detect via `LDSBankConflict` counter in rocprofv3
- Larger 160 KB tiles → more LDS traffic → pad inner dim (`smem[TILE][TILE+1]`) or swizzle strategically

### Playbook 5: MFMA Adoption

**Goal**: ensure matrix cores are used.

- Verify in `--save-temps` `.s` for `v_mfma_`* instructions
- Common shapes: `mfma_f32_16x16x16_f16`, `mfma_f32_32x32x8_f16`, plus gfx950-only `mfma_*_mxfp8`, `mfma_*_mxfp6`, `mfma_*_mxfp4`

### Playbook 6: Memory Coalescing Audit

**Goal**: max effective HBM bandwidth.

- 64 lanes × 4 B = 256 B per transaction; align to 256 B

### Playbook 7: Prefetching with global_load_lds

**Goal**: hide global memory latency.

- CDNA4 instruction: `global_load_lds` loads from HBM directly into LDS, skipping registers — pairs well with large LDS tiles for double-buffering

### Playbook 8: Kernel Fusion

**Goal**: eliminate intermediate writes and launch overhead.

- Candidates: elementwise chains, GEMM+bias+activation, normalization+activation, reduction+broadcast, attention QK→softmax→V
- Heuristic: if a kernel runs <50 µs and feeds another, fusion is likely a win
- **Anti-pattern**: fusing across very different access patterns can hurt — measure

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
- On CDNA4, mixed precision matters **more** because FP64 matrix is halved (Playbook 17)
- Validate: full FP64 reference, error norm vs problem-specific tolerance

### Playbook 12: FFT Optimization (rocFFT)

**Goal**: best plan for problem shape.

- Use `rocfft_plan_create` with explicit batch; cache plans across timesteps
- Real-to-complex: `rocfft_transform_type_real_forward`

### Playbook 13: Sparse Kernels (rocSPARSE)

**Goal**: format selection for SpMV/SpMM.

- Formats: CSR (general), ELL (uniform row length), HYB (mixed), BSR (block-sparse), COO
- Heuristic: if max(nnz/row) < 2× mean → ELL/HYB; if block structure → BSR; else CSR

## MI355X CDNA4-Specific Playbooks

### Playbook 14: Microscaling (MX) Formats — FP4 / FP6 / MX-FP8

**Goal**: exploit CDNA4's microscaling matrix path (biggest MI355X-only lever).

- MX block = **32 elements + one shared E8M0 exponent**; ~2× throughput vs plain FP8
- Use the `hipBLASLt` MX GEMM API or Composable Kernel MX templates
- Quantization: per-block absmax, round-to-nearest, store as packed nibbles (FP4)
- **Validate**: compare against a BF16 baseline; expect <0.5% accuracy drop on well-calibrated models — this is a *correctness-sensitive* play, never ship without the check
- Best fit: LLM/inference GEMMs and MoE experts; poor fit for tight-tolerance HPC

### Playbook 15: Large-LDS Tile Resize (160 KB)

**Goal**: use the 160 KB LDS budget CUDA and MI300 kernels leave on the table.

- Kernels ported from CUDA (≤228 KB smem) or MI300 (64 KB LDS) are usually under-tiled here
- Re-sweep GEMM/stencil tiles upward; larger LDS-resident tiles cut HBM traffic and can enable CUDA-style shared-mem algorithms that didn't fit on MI300

### Playbook 16: 8-XCD Grid Scheduling

**Goal**: even work distribution across all 8 XCDs.

- MI355X has **8 XCDs** (vs 6 on MI300A) — grid dims / block counts divisible by 8 avoid a tail where some XCDs idle
- For persistent-kernel / grid-stride designs, target a multiple of (8 × CUs-per-XCD) waves

### Playbook 17: FP64 Caution (halved matrix throughput)

**Goal**: avoid a silent regression on FP64-heavy HPC.

- CDNA4 FP64 **matrix** throughput is roughly halved vs MI300X — an FP64 matmul that was matrix-bound on MI300X can run slower here
- Mitigate with mixed precision / iterative refinement (Playbook 11) where tolerances allow
- Do **not** assume MI300-level FP64; measure the FP64 path explicitly before promising HPC speedups

### Playbook 18: Discrete Memory Management

**Goal**: keep host↔device transfers off the critical path (discrete GPU).

- No unified memory — use pinned host memory (`hipHostMalloc`) + `hipMemcpyAsync` overlapped with compute
- Managed memory migrates at real cost; prefer explicit `hipMalloc` + transfers for hot buffers, or `hipMemAdvise`/`hipMemPrefetchAsync` if you must use managed
- On the rocBudAI cluster, `rocbudai-bench` reserves and NUMA-pins the benchmark GPU for you

### Playbook 19: PyTorch / vLLM with MX Quantization

**Goal**: exploit CDNA4 inference features in the ML stack.

- `export PYTORCH_HIP_ALLOC_CONF=expandable_segments:True`
- **TunableOp** with an MX-aware `hipBLASLt` (`hipblaslt --version` must support MX) — tune once, lock
- **vLLM**: 288 GB enables large KV cache / large experts; `--quantization mxfp4`/`mxfp6` (CDNA4 only), `--kv-cache-dtype fp8`, `VLLM_USE_AITER=1` for AMD-tuned attention/MoE
- Always validate accuracy after enabling any MX / FP8 path

# End of Playbooks

This concludes the MI355X playbook knowledge base.
