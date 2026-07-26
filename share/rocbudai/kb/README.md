# Base knowledge base (shipped in-repo)

This directory is the **default knowledge base** that ships with rocBudAI. It
covers only profiling/optimization tooling that is present in a stock ROCm
installation, so it is safe to use anywhere ROCm is installed — including the
`--container` quick-test mode, which has no access to the admin-curated KB on
`/shareddata/rocbudai/docs/inputs/`.

All documents here are derived from **public** AMD material (public training
decks / hand-written public notes), hence the `amd-public` origin tag in each
filename. A full host install may layer a larger admin-curated KB on top of this
base set (see the resolution order in `AGENTS-default.md` §7).

## Contents

| File | Tool / topic |
|------|--------------|
| `general__rocprof-compute-knowledge-base__amd-public__20260428.md` | `rocprof-compute` (omniperf successor) |
| `general__rocprofv3-rocprof-sys-knowledge-base__amd-public__20260428.md` | `rocprofv3` / `rocprof-sys` tracing |
| `general__rocpd-knowledge-base__amd-public__20260428.md` | `rocpd` profiling database |
| `general__perf-optimization-plays__amd-public__20260609.md` | Generic optimization plays (MI300A-flavored; used by the arch-agnostic container persona) |
| `general__perf-optimization-plays-mi300a__amd-public__20260714.md` | Optimization plays — MI300A (gfx942 CDNA3 APU) |
| `general__perf-optimization-plays-mi300x__amd-public__20260714.md` | Optimization plays — MI300X (gfx942 CDNA3 discrete) |
| `general__perf-optimization-plays-mi250x__amd-public__20260714.md` | Optimization plays — MI250X (gfx90a CDNA2) |
| `general__perf-optimization-plays-mi355x__amd-public__20260714.md` | Optimization plays — MI355X (gfx950 CDNA4) |

Each hardware persona (`AGENTS-default.md`, `AGENTS-gfx942-mi300x.md`,
`AGENTS-gfx90a.md`, `AGENTS-gfx950.md`) reads its own arch-suffixed doc via the
§7 KB resolution; the container persona (`AGENTS-default-container.md`) reads the
unsuffixed generic doc.

## Naming convention

`<workload>__<topic>__<origin>__<YYYYMMDD>.md`, matching the host KB layout under
`/shareddata/rocbudai/docs/inputs/` so the agent can read both the same way.
