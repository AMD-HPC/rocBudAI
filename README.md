<table border="0" cellspacing="0" cellpadding="0">
<tr>
<td valign="top">

# rocBudAI: ROCm AI buddy

rocBudAI is an AI-powered performance-engineering assistant for AMD GPU
clusters, packaged as a single Lmod module (`module load rocbudai`). It wires
the [OpenCode](https://opencode.ai/) coding TUI to a locally hosted reasoning
LLM ([Ollama](https://ollama.com) running `qwen3.5:122b` by default),
pre-seeded with knowledge of the AMD profiling stack (`rocprofv3`,
`rocprof-compute`, `rocprof-sys`, `rocpd`, and `rocm-smi`). Sites can extend
the knowledge base with their own data and optimization playbooks. After a
seven-question discovery interview, the agent iteratively builds, profiles,
analyzes, and optimizes the user's code and writes a per-step `report.md`, all
on the allocated compute node: no source code leaves the cluster.

The current focus is AMD data center GPUs (CDNA2, CDNA3, and CDNA4), with
MI300A as the default architecture. Extending it to RDNA GPUs would need a
dedicated `AGENTS.md` persona, knowledge base, and playbooks.

</td>
<td valign="top" width="240">
<img src="rocBudAI-v10.png" width="220" alt="rocBudAI logo">
</td>
</tr>
</table>

---

## Where to start

| You are… | Read |
|---|---|
| An end user on a cluster that already has rocBudAI | [Quick Start](#quick-start-end-users) below |
| A sysadmin deploying rocBudAI on your cluster | [`INSTALL.md`](./INSTALL.md) |
| Testing a build before deploying | [`HOW-TO-TEST-BEFORE-DEPLOY.md`](./HOW-TO-TEST-BEFORE-DEPLOY.md) (4-tier ladder) |
| Verifying a finished install on a real node | [`docs/SMOKE-TEST.md`](./docs/SMOKE-TEST.md) |
| Testing on a no-systemd / container host | [`docs/CONTAINER-TEST.md`](./docs/CONTAINER-TEST.md) |
| Curating the agent's knowledge base | [`docs/kb-inputs.md`](./docs/kb-inputs.md) |
| Understanding the airgap / threat model | [`docs/airgap-and-model-pulls.md`](./docs/airgap-and-model-pulls.md) |

Questions or problems? Open an issue on the rocBudAI GitHub repository.

## Quick Start (end users)

rocBudAI ships as a Lmod module loaded from inside a GPU allocation. Replace
`<your-spx-partition>` with the SPX partition the admin exposed for rocBudAI.
If rocBudAI is not yet installed on the cluster, see
[Installation](#installation).

```bash
# 1. From a login node, allocate an exclusive GPU node.
#    --comment=ollama tells the cluster's Slurm prolog to start the
#    ollama daemon on the node. Adjust the partition and time limit.
salloc -p <your-spx-partition> \
       --exclusive --comment=ollama \
       --time=01:00:00

# 2. cd into your source tree (rocBudAI works wherever you point it;
#    it never copies your code).
cd ~/my-app

# 3. Load the module. The OpenCode TUI auto-launches with the agent
#    pre-configured for the AMD profiling workflow.
module load rocbudai
```

The agent asks seven discovery questions, one at a time:

```
Q1/7  session name         (short label used by the next-time picker; e.g. "matmul-block-size")
Q2/7  application type     (HIP/C++? PyTorch? Fortran+OpenMP? MPI?)
Q3/7  ROCm version         (which rocm/<ver> module to load)
Q4/7  other modules        (compilers, MPI, libraries…)
Q5/7  build instructions   (your build command, or path to a build script)
Q6/7  run command          (how to launch the binary with a representative input)
Q7/7  figure of merit      (what number defines "faster" for your app)
```

After Q7 the agent echoes the plan, asks for confirmation, and then runs the
build, profile, analyze, optimize, and re-profile loop. Every non-trivial
command pauses for `y/Enter` approval (ASK mode); read-only commands (`ls`,
`module list`, `rocm-smi`, `cat`) run without prompting. The agent keeps a
running `report.md` in the working directory.

Exit with `/exit` or Ctrl-D. Loading the module again from the same project
directory, in a later allocation, shows a numbered picker of prior sessions
(named at Q1/7):

```bash
module load rocbudai         # show picker if prior sessions exist; else fresh
rocbudai                     # same as module load, once the module is loaded
rocbudai --continue          # resume last session (skip picker)
rocbudai --new               # force a fresh session (skip picker)
rocbudai-prune-sessions      # interactively delete stale sessions in this dir
                             # (--all-runs scope, --dry-run preview)
```

The full flag references are `rocbudai --help` and `./install.sh --help`;
these commands are the source of truth.

### Auto-run mode

In auto-run mode commands run without per-call approval, but dangerous
patterns (`rm -rf /`, `module purge`, `mkfs`, `shutdown`) stay hard-denied.
It applies from the next session:

```bash
/exit                            # inside the TUI
export ROCBUDAI_AUTORUN=1        # back to ASK: unset (or =0)
rocbudai --continue              # same session, new permission mode
```

### Auto-nudge

A sidecar watcher (`libexec/rocbudai-nudge-watcher`, started in the
background by `rocbudai-tui`) follows the opencode event stream. If a turn
ends and the session then stays idle for 240 s with no new user input, it
posts `continue` so the model picks up where it left off. It fires at most
once per user message, so an unattended session gets one extra response, not
a runaway loop. The nudge is a plain `POST /session/<sid>/prompt_async`, the
same call the TUI makes when the user types `continue`. opencode 1.14.28 has
no hidden system-message channel for outside posters, so the nudge appears as
a visible user message in the transcript.

The watcher is stdlib-only Python with a parent-PID watchdog: it exits with
the TUI and leaves no orphaned process after `/exit`. It does not
authenticate, because it talks only to `127.0.0.1` and the kernel-level
user-egress nft block keeps that loopback channel inside the node. To tune or
disable it, export any of these before `module load rocbudai` (details in
`man rocbudai`):

```bash
export ROCBUDAI_NUDGE_AFTER_S=60     # idle seconds before nudging (default 240; e.g. 360 = fewer interruptions)
export ROCBUDAI_NUDGE_TEXT="please continue with the report"   # custom text (default "continue")
export ROCBUDAI_NUDGE_DISABLE=1      # turn the watcher off entirely
export ROCBUDAI_NUDGE_LOG=$HOME/.cache/rocbudai/nudge.log   # diagnostics
```

### Airgap baseline

Every `--comment=ollama` allocation inherits a cluster-wide airgap that keeps
source code, prompts, model output, and user-side commands on the cluster
while the job runs. It has four pieces:

- A managed `/etc/opencode/opencode.json` sets `share: disabled` and disables
  14 cloud providers (anthropic, openai, …). The modulefile also sets
  `OPENCODE_DISABLE_{AUTOUPDATE,LSP_DOWNLOAD,MODELS_FETCH,EXTERNAL_SKILLS,SHARE}=1`,
  which suppresses every known opencode phone-home call site.
- The Ollama daemon runs with `OLLAMA_NOPRUNE=1` and `OLLAMA_NO_CLOUD=1`,
  bound to `127.0.0.1:11435` (loopback only).
- `ollama-egress.service` installs an nft owner-match egress block on the
  `ollama` UID at boot.
- `rocbudai-user-egress.service` loads an nft skeleton table at boot. The
  Slurm prolog adds a per-job chain that blocks the user UID's external
  egress for the life of each `--comment=ollama` allocation, and the epilog
  removes it.

Both nft blocks still permit loopback, cluster DNS, and RFC1918. Users can
verify the baseline on a live allocation:

```bash
rocbudai-airgap-check              # user-visible probes (does not need sudo)
rocbudai-airgap-check --deep       # also inspect nft contents (needs sudo)
```

The tool reports pass / fail / warn per check; exit code 0 means the airgap
is intact. The user-UID block is in force only while a `--comment=ollama` job
runs. Outside an allocation the user UID has full egress (by design, so admin
tooling and pre-staging dependencies work), so external dependencies (pip
wheels, git over HTTPS, model downloads) must be fetched *before* allocating
with `--comment=ollama`. The full threat model and residual risks (login-node
trust, cluster admins, recursive DNS) are in
[`docs/airgap-and-model-pulls.md`](docs/airgap-and-model-pulls.md).

---

## Installation

See [INSTALL.md](./INSTALL.md) for the full deployment recipe (prerequisites,
step-by-step Ollama + OpenCode + module setup, and the six optional
production-hardening features), or run [`install.sh`](./install.sh) to deploy
it automatically.

---

## Architecture

The diagram below reflects the AMD reference deployment (AAC6); the shape
generalizes to other systems (substitute your own partition, paths, and GPU
fencing).

```
USER  ── salloc … --comment=ollama --exclusive──>  Compute node (MI300A SPX)
                                                       │
              prolog: ollama_start_for_job + prewarm   │
                                                       ▼
                              ┌──────────────────────────────────────┐
                              │ ollama daemon (UID 997)              │
                              │ bind 127.0.0.1:11435                 │
                              │ fenced to APUs 0,1,2                 │
                              │   (ROCR_VISIBLE_DEVICES=0,1,2 +      │
                              │    AllowedCPUs=0-71,96-167)          │
                              │   → APU 3 reserved for rocbudai-bench│
                              │ OLLAMA_{MODELS=local-NVMe-cache,     │
                              │   SCHED_SPREAD=1, KEEP_ALIVE=-1,     │
                              │   MAX_LOADED_MODELS=1,               │
                              │   NOPRUNE=1, NO_CLOUD=1}             │
                              └────────────▲─────────────────────────┘
                                           │ filtered (403 on mutate)
                              ┌────────────┴─────────────┐
                              │ ollama-proxy             │
                              │ bind 127.0.0.1:11434     │
                              └────────────▲─────────────┘
                                           │
                  module load rocbudai ────┤
                       │                   │
                       ▼                   │
                  bin/rocbudai-tui  (TTY-guard, preflight, allow-list,
                       │             session picker, bootstrap opencode.json +
                       │             AGENTS.md + .rocbudai-runtime.md,
                       │             exec `ollama launch opencode …` with a
                       │             cold-start seed prompt; see Editing tips)
                       ▼
                  opencode TUI
                       │   ─── /etc/opencode/opencode.json (managed) ──
                       │       share:"disabled", 14 disabled_providers
                       │   ─── nft inet ollama_egress ──
                       │       UID 997 → external = REJECT
                       │       UID 997 → loopback/DNS/RFC1918 = ACCEPT
                       │   ─── nft inet rocbudai_user_egress (per job) ──
                       │       user UID → external = REJECT
                       │   ─── rocbudai-airgap-check ──
                       │       user-visible verification of the airgap baseline
                       ▼
              build → profile → analyze → patch → loop → report.md
```

The launcher passes `--model "$ROCBUDAI_MODEL"` (checked against the admin
allow-list `ROCBUDAI_ALLOWED_MODELS`) to `ollama launch opencode` and writes
the same model into the session `opencode.json`. Because the managed config
disables every cloud provider, only models in the local Ollama store are
reachable.

---

## Sysadmin guide

This section covers the day-to-day operation of rocBudAI.

### Knowledge base: dropping new documents

The agent reads from `/shareddata/rocbudai/docs/inputs/` at session start: it
lists the directory, then reads the relevant `.md` sidecars.

- A `.pdf` dropped on the login node triggers a `systemd.path` watcher
  (`IN_CLOSE_WRITE`), and `rocbudai-ingest-inputs` writes a `.md` sidecar
  within seconds. Conversion is idempotent: it re-converts only when the
  source is newer.
- A `.pdf` written over NFS from a host other than the login node is caught
  by the hourly `rocbudai-ingest-inputs.timer` within 60 min.
- A `.md`, `.txt`, or `.html` file needs no conversion and is visible at the
  next session. Name it `<workload-type>__<topic>__<source>__<yyyymmdd>.md`,
  following [kb-inputs.md](./docs/kb-inputs.md).
- `rocbudai-ingest-inputs --force`, run manually on the login node, forces a
  re-ingest.

| Scenario | Visible to the agent |
|---|---|
| Drop while no TUI is running | Next `rocbudai` session |
| Drop while user X has a TUI running | Next session of user X (the running one already snapshotted) |
| Replace a `.pdf` with an updated version | Re-ingested on the next path event (mtime check) |
| User wants the running session to see the new doc | Tell the agent in chat: "list `/shareddata/rocbudai/docs/inputs/` and read any new files" |

Operational checks: `journalctl -u rocbudai-ingest-inputs.service -n 20` for
recent runs, and `systemctl list-timers rocbudai-ingest-inputs` for the next
scheduled sweep. The naming convention and what to put in the KB are in
`docs/kb-inputs.md`; the units are in `deploy/auto-ingest/`.

### Customising the agent: the `AGENTS.md` workflow

The agent's persona, hard rules, seven-question script, recovery procedures,
and report-format spec live in a set of per-architecture persona files, one
of which is seeded as the session `AGENTS.md`:

```
share/rocbudai/AGENTS-default.md            MI300A  (gfx942, CDNA3 APU)      ← canonical reference
share/rocbudai/AGENTS-gfx942-mi300x.md      MI300X  (gfx942, CDNA3 discrete)
share/rocbudai/AGENTS-gfx90a.md             MI250X / MI210 (gfx90a, CDNA2)
share/rocbudai/AGENTS-gfx950.md             MI355X / MI350X (gfx950, CDNA4)
share/rocbudai/AGENTS-container-demo.md     compact standalone container quick-test persona
share/rocbudai/AGENTS-default-container.md  full-length container variant (not selected by rocbudai-tui)
```

The four arch personas share the bulk of their content (persona, loop,
discovery, profiling-tool inventory, report schema). They differ only in the
arch-specific parts: the peak-theoretical spec table, the "common confusions"
gotchas, the `rocprof-compute` workload-dir suffix, and the
optimization-playbook KB they cite (`share/rocbudai/kb/`).

`bin/rocbudai-tui` resolves the persona at session start:

1. An explicit `ROCBUDAI_AGENTS_TEMPLATE=<file>` (a power-user export) is
   honored verbatim.
2. Otherwise the persona is auto-selected from the GPU architecture:
   `ROCBUDAI_GFX_ARCH` if set, else live `rocminfo` (gfx942 is narrowed to
   MI300A APU vs MI300X discrete via the rocminfo Marketing-Name/APU
   marker). If the arch cannot be detected, the MI300A persona is picked,
   with a warning.

`install.sh` does not bake a persona into the modulefile: staging often runs
on a GPU-less login node, so the persona is always resolved at launch on the
compute node (`--gfx-arch` / autodetect at install time is a preflight check
only).

In container quick-test mode (`--container`, `ROCBUDAI_CONTAINER=1`),
`rocbudai-tui` uses the compact `AGENTS-container-demo.md` persona alone (no
modules, pre-answered discovery, saxpy walkthrough) instead of the full arch
persona. The demo is a tiny saxpy example, and a small, fast demo model
follows a short focused prompt far more reliably (and starts faster) than the
~2,200-line arch persona.

The resolved persona is copied to `$CWD/AGENTS.md` at session start and
auto-refreshes when the source template is newer (mtime check). Users can pin
a local copy with `chmod 0444 AGENTS.md` or `ROCBUDAI_AGENTS_NOREFRESH=1`.

Editing tips:

- Edit the template, then `touch` it. The newer mtime triggers the
  auto-refresh on each user's next session, with no service to restart and no
  chroot to rebuild. Edits reach every next session within seconds, so test
  on yourself first and keep a `.bak` copy for non-trivial changes.
- Coordinate with the seed prompt in `bin/rocbudai-tui`. The TUI injects a
  cold-start notice ("Waiting for the model to warm up — on a cold node this
  takes ~1 min …") as opencode's first user turn. opencode renders
  `--prompt` as a visible user message, which is intentional: a user watching
  during the ~1 min cold start sees that the launcher has not hung. The
  model's first-turn instructions live in §0 of the `AGENTS-*.md` files
  ("Session opening" / "FIRST-TURN HARD RULES"): treat the seed as
  decoration, never echo, paraphrase, or acknowledge it, never narrate
  warm-up status, silently read `.rocbudai-runtime.md`, and emit the §0
  welcome plus `Q1/7` in the same assistant message. If §0 is renumbered or
  the welcome-banner shape changes, update the `ROCBUDAI_SEED_PROMPT` text in
  `bin/rocbudai-tui` to match.
- Hard denylists are enforced by opencode, not by the LLM. To add or remove
  a denied pattern (`rm -rf /`, `module purge`, etc.), edit
  `share/rocbudai/opencode-default.json` (ASK template) and
  `opencode-allow-all.json` (auto-run template); editing `AGENTS.md` alone
  does not change what the TUI permits.
- Keep §1 rule 9 intact (affirmative-response synonyms: "ok", "go ahead",
  "sure", "do it", etc. all count as `yes`). New approval flows should
  reference rule 9 rather than re-hardcoding "yes".
- Keep the `[FACT]`/`[INFERENCE]`/`[OPINION]` tagging (a §1 hard rule). It
  shows up in every report the agent writes; removing it weakens report
  quality.
- Section map: `## 0` session opening (with resume detection), `## 1` hard
  rules (rule 8: KFD-leak recovery), `## 2`-`## 5` discovery, module setup,
  build, and profile loop (`5.1`: crashed-profile recovery), `## 6` report
  format, `## 7` workload-specific tool cheatsheet (incl. KB resolution),
  `## 8` session wrap-up.

### Slurm comment tags

| Comment | Effect | Enforced where |
|---|---|---|
| (none) | Plain Slurm allocation, no ollama, no rocBudAI | n/a |
| `--comment=ollama` | Starts the ollama daemon on the node, pre-warms the model, and applies the [airgap baseline](#airgap-baseline). Requires `--exclusive` on an SPX partition. | `job_submit.lua` rule 2 + `prolog.d/rocbudai-ollama-prolog.sh` |

CPX/TPX modes are rejected by `job_submit.lua` rule 1, because ollama's GGML
runner aborts above 16 visible devices (MI300A CPX exposes 24). The source of
truth is `deploy/comment-gating/`. The boot-time airgap pieces (managed
opencode config and both nft egress units) are in `deploy/airgap/`; the
per-job user chain comes from the egress prolog in `deploy/comment-gating/`.

### Diagnostics and cleanup

- `rocbudai-doctor`: 11-check preflight (Slurm allocation, GPUs, ollama
  daemon, model presence and allow-list, opencode binary, working directory,
  install tree, leaked KFD processes, project `report.md`, local model
  manifest blobs). Run it before and after any privileged change.
- `rocbudai-airgap-check`: verifies the [airgap baseline](#airgap-baseline)
  on the current allocation; `--deep` (sudo) also dumps the nft tables.
- `rocbudai-reap-stale`: finds and (with `--reap`) kills leaked KFD-bound
  profile children. Required after any `HSA_STATUS_ERROR_*` / `signal 15`
  from `rocprofv3` or `mpirun`. See `AGENTS-default.md` §1 rule 8 and §5.1 for
  when the agent invokes it.
- Logs: `journalctl -u {ollama,ollama-proxy,ollama-egress}` on the compute
  node; `/var/log/slurm-llnl/{slurmctld,slurmd}.log` for allocation issues.
  The auto-ingest unit logs to the journal on the login node only.

### Installed files

The shared install tree lives at `/shared/apps/ubuntu/opt/rocbudai/`
(root-owned, world-readable; `module load rocbudai` puts its executables on
`PATH`). Its full annotated layout is in [INSTALL.md](./INSTALL.md) step 5.
opencode lives at `/shared/apps/ubuntu/opt/opencode/1.14.28/opencode` and the
modulefile at `/shared/apps/modules/ubuntu/lmodfiles/base/rocbudai/dev.lua`.

The per-node files below reflect the reference cluster, whose compute-node
images are deployed with Warewulf (baked into the chroot). On other sites the
mechanism (Warewulf, Ansible, a golden image, …), paths, and UIDs will differ:

```
/etc/systemd/system/ollama.service                      :11435, SPREAD, NOPRUNE, NO_CLOUD
/etc/systemd/system/ollama.service.d/10-gpu-split.conf  GPU/CPU fence (written by rocbudai-detect-topology.sh)
/etc/systemd/system/ollama.service.d/model-cache.conf   OLLAMA_MODELS=/var/local/cache/ollama
/etc/systemd/system/ollama-proxy.service                Python proxy on :11434
/etc/systemd/system/ollama-acl.service                  nft owner-match on :11435
/etc/systemd/system/ollama-egress.service               nft owner-match egress block (ollama UID)
/etc/systemd/system/rocbudai-user-egress.service        nft skeleton table for the per-job user-UID block
/etc/systemd/system/rocbudai-model-cache.service        boot-time NFS→local-NVMe rsync
/etc/opencode/opencode.json                             managed config
/etc/nftables.d/{ollama-acl,ollama-egress,rocbudai-user-egress}.nft
/usr/local/bin/{ollama,ollama-real,ollama-proxy}
/var/local/cache/ollama/                                local NVMe model cache (~65 GB)
```

Cluster-wide (NFS-shared; the Ollama models live on NFS):

```
/shareddata/Ollama_Models/                       2755 ollama:ollama, qwen3.5:122b (+ gpt-oss:120b, nemotron-3-super:120b)
/shareddata/rocbudai/                            KB inputs (drop docs here)
/shared/share/slurmscripts/{prolog,epilog}/{prolog,epilog}.sh
/shared/share/slurmscripts/{prolog.d,epilog.d}/rocbudai-{ollama,egress}-{prolog,epilog}.sh
/etc/slurm/job_submit.lua                        Rules: 1=cpx/tpx, 2=ollama
```

Login node only (not in the chroot; these run on the user's entry host):

```
/etc/systemd/system/rocbudai-ingest-inputs.path     KB watcher (inotify)
/etc/systemd/system/rocbudai-ingest-inputs.service  oneshot ingest runner
/etc/systemd/system/rocbudai-ingest-inputs.timer    hourly fallback sweep
```

---

## Reference deployment decisions

These choices reflect the reference cluster and are not requirements: a site
can substitute its own partition, model, fencing layout, and paths. They are
listed so an admin replicating the setup has a known-good reference.

- Model and compute mode: `qwen3.5:122b` by default, on SPX nodes only; the
  other allow-listed models (`gpt-oss:120b`, `nemotron-3-super:120b`,
  `laguna-s-2.1:q4_K_M`) are opt-in via `ROCBUDAI_MODEL`. CPX is rejected at
  submit (see [Slurm comment tags](#slurm-comment-tags)).
- Dedicated bench GPU: the daemon and the agent are fenced off the last GPU,
  so in-session FOMs measured by `rocbudai-bench` on that GPU are free of
  inference contention. Multi-rank / multi-GPU FOMs use `rocbudai-submit`,
  which offloads to a separate Slurm GPU allocation (same median/[FACT]
  summary). On the remaining GPUs, `OLLAMA_MAX_LOADED_MODELS=1` keeps exactly
  one model resident; the prolog pre-warms only the default, and opt-in
  models cold-load on demand (INSTALL.md step 2).
- Allocation contract: `--comment=ollama --exclusive` on the SPX partition.
  The TUI runs on the compute node, never on the login node, and
  `module load rocbudai` is the canonical entry point.
- Authorization: users may run `ollama list/show/ps/run`; only admins may
  `pull/rm/push/create/cp` (INSTALL.md step 8, `deploy/auth/`).
- Knowledge base: static Markdown injection (PDFs converted to `.md`
  sidecars), not RAG (`docs/kb-inputs.md`).
- Airgap: always on, no user opt-in, verifiable end-to-end with
  `rocbudai-airgap-check` (see [Airgap baseline](#airgap-baseline)). The
  design and the model-pull relock procedure are in
  `docs/airgap-and-model-pulls.md`.

---

## Final remarks

- Each opencode bash tool call runs in a fresh shell, so a `module load` in
  one call is invisible to the next. This matters on sites with a
  hierarchical module tree, where packages built for a ROCm version become
  visible only after that ROCm module is loaded. An `AGENTS.md` hard rule
  requires `&&`-chained commands, but the LLM may still break the chain. The
  most common misfire is an empty `$ROCM_PATH` in a standalone call, which
  the agent could misdiagnose as a shell that needs `source`-ing; the persona
  names that symptom explicitly and points at the `&&`-chain fix.
- opencode v1.14.28 ships as a binary release. The deployed
  `/shared/apps/ubuntu/opt/opencode/1.14.28/opencode` is byte-identical
  (`sha256: f59b8c68…007cf0`) to both the `sst/opencode` and
  `anomalyco/opencode` v1.14.28 release artifacts, since the two repos publish
  the same artifact at this tag. Future bumps pin upstream to `sst/opencode`
  (the canonical project); the full provenance record is in
  [`archive/opencode-1.14.28-provenance/`](./archive/opencode-1.14.28-provenance/README.md).

---

## License

MIT; see [`LICENSE`](./LICENSE). Copyright (c) 2026 AMD.
