# rocBudAI knowledge base — inputs

This document describes how the agent's knowledge base works and how
to populate it. The KB is **site-populated**: rocBudAI does not ship
prior-knowledge content in the repo (license-cleared reference material
may follow as a separate dataset; until then, each site curates its own).

## TL;DR — what to do

```bash
# 1. Drop your PDFs / slides / Markdown / text into the inputs dir.
#    Default path on the reference cluster:
cp some_amd_profiling_slides.pdf \
   /shareddata/rocbudai/docs/inputs/<workload-type>__<topic>__<source>__<yyyymmdd>.pdf

# 2. Convert PDFs to .md sidecars so the text-only LLM can read them.
#    rocbudai-ingest-inputs is on PATH after `module load rocbudai`.
rocbudai-ingest-inputs

# 3. (optional) Inspect the .md to make sure the extraction is sensible.
ls /shareddata/rocbudai/docs/inputs/
```

## What goes here

- AMD / ROCm profiling slides and tutorials (PDF + auto-generated MD).
- Internal write-ups on tool quirks ("`rocprof-compute` needs
  `--num-mpi-procs` if your app forks", etc.).
- Example reports that show the level of analysis we want.
- Per-workload-type playbooks: HIP/C++, PyTorch, MPI, Fortran, TF/JAX.
- ROCm release notes when they change tool flags.

## Naming convention

```
<workload-type>__<topic>__<source>__<yyyymmdd>.<ext>
```

Workload-type tags (used by the agent to filter what to read):

- `hip-cpp`           — HIP/C++ kernels
- `hip-fortran`       — HIP-Fortran / OpenMP target
- `pytorch`           — PyTorch / Python ML
- `tensorflow`        — TensorFlow
- `jax`               — JAX
- `mpi`               — MPI multi-rank
- `omp`               — OpenMP target offload (non-HIP)
- `general`           — applies to any workload (e.g. `rocm-smi`,
                       `omniperf` overview, system-config notes)

Examples:

- `hip-cpp__rocprofv3-quickstart__amd-public__20260301.pdf`
- `pytorch__torch-profiler-recipes__pytorch-org__20260115.md`
- `mpi__rocprof-sys-mpi__amd-blog__20260420.pdf`
- `general__rocm-7.2-release-notes__amd__20260225.md`

## Why PDFs need a `.md` sidecar

The LLMs behind rocBudAI (currently `qwen3.5:122b` default plus
`gpt-oss:120b` / `nemotron-3-super:120b` opt-in; run `module show
rocbudai` to see what is active and `module help rocbudai` for the
admin allow-list) are
**text-only**. They have no image encoder and no PDF parser.
opencode does have a PDF attachment path, but it only fires for
vision-capable models; with a text-only model the PDF would either
be rejected or hallucinated over.

So the rule is:

- **PDFs are archival** — humans can open them, the agent does not.
- **Agents only read the `.md` sidecar** that lives next to each `.pdf`.
- If you forget to convert, the agent will see the `.pdf` filename in
  `ls` output and ignore it. AGENTS.md instructs rocBudAI to do this.

## How conversion works

`rocbudai-ingest-inputs` (in `/shared/apps/ubuntu/opt/rocbudai/bin/`,
on `PATH` after `module load rocbudai`):

- walks the input dir (recursively),
- finds every `*.pdf` whose `*.md` sidecar is missing or older,
- runs `pdftotext -layout` (poppler) to extract text preserving
  column structure,
- prepends YAML front-matter with source filename, mtime, page count,
  and tool version — so the agent (and humans) know where the text
  came from,
- writes the result as `*.md` next to the PDF,
- if the PDF has no extractable text (scanned / image-only), writes a
  `*.NEEDS-OCR` marker instead and skips it. Re-export the PDF from
  source, or run `ocrmypdf` if you really need OCR.

The script is **air-gap-safe** — it makes no network calls. Safe to
run when the cluster is offline.

## Maintenance

- The default input dir on the reference cluster is
  `/shareddata/rocbudai/docs/inputs/` (group-writable to a configured
  admin group; SGID is set so files inherit the group). Sites can
  point `rocbudai-ingest-inputs --dir <path>` (or the
  `ROCBUDAI_KB_INPUTS_DIR` env var) elsewhere if their shared-filesystem
  layout differs; at install time this is the `KB_INPUTS_DIR` knob in
  `site.conf`, which retargets the auto-ingest units to match.
- Old / superseded docs should be moved to an `archive/` sibling dir,
  not deleted, so we can trace which guidance was active for a given
  report.
- Re-run `rocbudai-ingest-inputs` whenever you add a PDF or replace
  one with a newer version. With `--force` it re-converts everything.

## When does the agent see new docs?

- **Static injection model.** The agent reads files from the inputs
  dir via opencode's `Read` tool, on demand, when `AGENTS.md` tells it
  to (Phase 0 discovery + during the profile loop). Files are pulled
  wholesale into the model's context window.
- **Per-session caching.** Each new TUI session starts with a fresh
  `ls` of the inputs dir. New docs added between sessions are picked
  up automatically.
- **Inside a running session.** The agent has its initial `ls` and
  reads cached. New files dropped mid-session are NOT noticed
  proactively. You can ask the agent in chat to re-list the dir and
  read anything new.
- **PDFs without `.md` sidecar are invisible to the agent.** They
  appear in `ls` output but `AGENTS.md` instructs the agent not to
  read them, and to surface the gap to the user instead. Run
  `rocbudai-ingest-inputs` to fix.

If/when the KB grows past ~500 KB or many distinct workload types
onboard, this gets upgraded to proper RAG (sqlite-vec + Ollama
embeddings).

## Why Markdown sidecars and not, say, `.txt`?

YAML front-matter gives the agent context (which slide deck did this
text come from, how old, how many pages). The agent uses this to
(a) cite the source in the report, (b) decide whether outdated material
is relevant ("rocprof v1.x" notes are mostly irrelevant on a cluster
that uses `rocprofv3` and `rocprof-compute`).
