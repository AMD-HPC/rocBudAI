<table border="0" cellspacing="0" cellpadding="0">
<tr>
<td valign="top">

# rocBudAI — ROCm AI buddy

**rocBudAI** is an AI-powered performance-engineering assistant for AMD
GPU clusters, packaged as a single Lmod module (`module load
rocbudai`). It wires the [OpenCode](https://opencode.ai/) coding TUI
to a locally-hosted reasoning LLM ([Ollama](https://ollama.com) running
`qwen3.5:122b` by default), pre-seeded with knowledge of the AMD profiling stack
(`rocprofv3`, `rocprof-compute`, `rocprof-sys`, `rocpd`, and
`rocm-smi`). The knowledge base fed to **rocBudAI** can be customized with 
site specific data and optimization specific playbooks.
After a seven-question discovery interview, the agent
iteratively builds, profiles, analyzes, and optimizes the user's code and
writes a per-step `report.md` — all on the allocated compute node, no
source code ever leaving the cluster. The current focus is AMD data center GPUs
(CDNA2, CDNA3 and CDNA3), **with MI300A as default architecture**, but the idea could be easily 
extended to RDNA GPus as well: for this, dedicated `AGENTS.md` file, knowledge base and playbooks will have to be created. 

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
| An **end user** on a cluster that already has rocBudAI | [Quick Start](#quick-start-end-users) below |
| A **sysadmin deploying** rocBudAI on your cluster | [`INSTALL.md`](./INSTALL.md) |
| **Testing a build before deploying** | [`HOW-TO-TEST-BEFORE-DEPLOY.md`](./HOW-TO-TEST-BEFORE-DEPLOY.md) (4-tier ladder) |
| Verifying a finished install on a real node | [`docs/SMOKE-TEST.md`](./docs/SMOKE-TEST.md) |
| Testing on a no-systemd / container host | [`docs/CONTAINER-TEST.md`](./docs/CONTAINER-TEST.md) |
| Curating the agent's knowledge base | [`docs/kb-inputs.md`](./docs/kb-inputs.md) |
| Understanding the airgap / threat model | [`docs/airgap-and-model-pulls.md`](./docs/airgap-and-model-pulls.md) |

Questions or problems? **Open an issue on the rocBudAI GitHub repository.**

## Quick Start (end users)

rocBudAI ships as a Lmod module you load from inside a GPU allocation.
Replace `<your-spx-partition>` with the SPX partition your admin
exposed for rocBudAI. If rocBudAI is not yet installed on
your cluster, see [Installation](#Installation).

```bash
# 1. From a login node, allocate an exclusive GPU node.
#    --comment=ollama tells the cluster's job_submit logic to start
#    the ollama daemon on the node for you.
#    Use your cluster's SPX partition below.
#    Modify the time limit as needed.
salloc -p <your-spx-partition> \
       --exclusive --comment=ollama \
       --time=01:00:00

# 2. cd into your source tree (rocBudAI works wherever you point it —
#    it never copies your code).
cd ~/my-app

# 3. Load the module. The OpenCode TUI auto-launches with the agent
#    pre-configured for the AMD profiling workflow.
module load rocbudai
```

The agent walks you through seven discovery questions, **one at a time**:

```
Q1/7  session name         (short label used by the next-time picker; e.g. "matmul-block-size")
Q2/7  application type     (HIP/C++? PyTorch? Fortran+OpenMP? MPI?)
Q3/7  ROCm version         (which rocm/<ver> module to load)
Q4/7  other modules        (compilers, MPI, libraries…)
Q5/7  build instructions   (your build command, or path to a build script)
Q6/7  run command          (how to launch the binary with a representative input)
Q7/7  figure of merit      (what number defines "faster" for your app)
```

After Q7 the agent echoes the plan, asks for confirmation, then runs
the build → profile → analyze → optimize → re-profile loop. Every
non-trivial command pauses for your `y/Enter` approval (ASK mode);
read-only commands (`ls`, `module list`, `rocm-smi`, `cat`) run
without prompting. The agent writes a running `report.md` in your cwd.

**Exit:** `/exit` or Ctrl-D. **Resume:** when you re-allocate a node and
`module load rocbudai` again from the same project dir, you'll see a
numbered picker of prior sessions (named via Q1/7) — pick one to resume:

```bash
module load rocbudai         # show picker if prior sessions exist; else fresh
rocbudai --continue          # resume last session (skip picker)
rocbudai --new               # force a fresh session (skip picker)
rocbudai-prune-sessions      # interactively delete stale sessions in this dir
                             # (--all-runs scope, --dry-run preview)
```

Full flag reference: `rocbudai --help`, and `./install.sh
--help` (install flags). These commands are the source of truth.

**Auto-run mode** — commands run without per-call approval, but
dangerous patterns (`rm -rf /`, `module purge`, `mkfs`, `shutdown`)
stay hard-denied. Bake into the next session via:

```bash
/exit                            # inside the TUI
export ROCBUDAI_AUTORUN=1        # back to ASK: unset (or =0)
rocbudai --continue              # same session, new permission mode
```

**Auto-nudge** — a sidecar watcher (`libexec/rocbudai-nudge-watcher`,
launched in the background by `rocbudai-tui`) subscribes to the
opencode event stream. If a turn ends and the session stays idle for
240 s with no new user input, the watcher posts a `"continue"` prompt
so the model picks up where it left off. The nudge fires **at most
once per user message**, so an away-from-keyboard user gets one
unprompted "continue" + one response, not a runaway cascade.

The nudge is a plain `POST /session/<sid>/prompt_async` — the same
call the TUI makes when you type `continue` and press Enter. opencode
1.14.28 exposes no hidden system-message channel to outside posters,
so the nudge shows up as a visible user message in the transcript. To
tune, customise, or disable it per session, set any of these before
`module load rocbudai`:

```bash
export ROCBUDAI_NUDGE_AFTER_S=60     # tighter loop (default: 240)
export ROCBUDAI_NUDGE_AFTER_S=360    # looser, less interruption
export ROCBUDAI_NUDGE_TEXT="please continue with the report"   # custom text
export ROCBUDAI_NUDGE_DISABLE=1      # turn the watcher off entirely
export ROCBUDAI_NUDGE_LOG=$HOME/.cache/rocbudai/nudge.log   # diagnostics
```

The watcher is stdlib-only Python with a parent-PID watchdog, so it
exits cleanly when the TUI does; no orphaned background processes
after `/exit`. The watcher does not authenticate (it speaks to
`127.0.0.1` only); the kernel-level user-egress nft block keeps that
loopback channel inside the node.

**Airgap baseline** — every `--comment=ollama` allocation already
inherits a cluster-wide airgap that keeps source code, prompts, model
output, **and** user-side commands on the cluster while the job runs:

- Managed `/etc/opencode/opencode.json` pins `share: disabled` and
  disables 14 cloud providers (anthropic, openai, …). The modulefile
  also sets `OPENCODE_DISABLE_{AUTOUPDATE,LSP_DOWNLOAD,MODELS_FETCH,
  EXTERNAL_SKILLS,SHARE}=1` so every known opencode phone-home call
  site is suppressed.
- `ollama-egress.service` installs an `nft` owner-match egress block
  on the `ollama` UID at boot; only loopback, cluster DNS, and RFC1918
  are permitted.
- `rocbudai-user-egress.service` loads an `nft` skeleton table at boot
  and the Slurm prolog extends it with a per-job chain that blocks the
  **user UID's** external egress for the duration of every
  `--comment=ollama` allocation (only loopback, cluster DNS, and
  RFC1918 remain reachable). The epilog tears the chain down.
- The Ollama daemon is launched with `OLLAMA_NOPRUNE=1` and
  `OLLAMA_NO_CLOUD=1` and bound to `127.0.0.1:11435` (loopback only).

You can verify the baseline yourself once the allocation is live:

```bash
rocbudai-airgap-check              # user-visible probes (does not need sudo)
rocbudai-airgap-check --deep       # also inspect nft contents (needs sudo)
```

The tool reports pass / fail / warn for each piece. Exit code 0 means
the airgap is intact. **Note**: the user-UID block is in force only while a `--comment=ollama`
job is running. Outside an allocation, your UID has full egress (by
design, so admin tooling and pre-staging dependencies work). If you
need to fetch something external (pip wheels, git over HTTPS, model
downloads), do it **before** allocating with `--comment=ollama`. See
[`docs/airgap-and-model-pulls.md`](docs/airgap-and-model-pulls.md) for the
full threat model and residual risks (login-node trust, cluster admins,
recursive DNS).

---

## Installation

See **[INSTALL.md](./INSTALL.md)** for the full deployment recipe
(prerequisites, step-by-step Ollama + OpenCode + module setup, and the
six optional production-hardening features), or run [`install.sh`](./install.sh) to deploy it for you.

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
                              │ fenced to APUs 0,1,2                  │
                              │   (ROCR_VISIBLE_DEVICES=0,1,2 +       │
                              │    AllowedCPUs=0-71,96-167)           │
                              │   → APU 3 reserved for rocbudai-bench │
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
                       │             "model is warming up" seed prompt — the
                       │             human sees a polite cold-start notice;
                       │             AGENTS.md §0 tells the model to ignore it
                       │             and emit banner + Q1/7)
                       ▼
                  opencode TUI
                       │   ─── /etc/opencode/opencode.json (managed) ──
                       │       autoupdate:false, share:"disabled",
                       │       14 disabled_providers
                       │   ─── nft inet ollama_egress ──
                       │       UID 997 → external = REJECT
                       │       UID 997 → loopback/DNS/RFC1918 = ACCEPT
                       │   ─── rocbudai-airgap-check ──
                       │       user-visible verification of all 4 above
                       ▼
              build → profile → analyze → patch → loop → report.md

   ── on the compute node: `rocbudai` (no flag) behaves like `module load rocbudai` (shows the picker if prior sessions exist); `rocbudai --continue` / `--new` bypass the picker.
```

Model lock is enforced server-side by the managed `opencode.json`, so
the wrapper does not need to strip `--model`/`--provider` argv.

---

## Sysadmin guide

The day-to-day operational story for an admin running rocBudAI.

### Knowledge base — dropping new documents

The agent reads from `/shareddata/rocbudai/docs/inputs/` at session
start (it `ls`s the dir, then `Read`s relevant `.md` sidecars).

- **Drop a `.pdf` on the login node** → a `systemd.path` watcher fires
  `IN_CLOSE_WRITE`, `rocbudai-ingest-inputs` produces a `.md` sidecar
  within seconds (idempotent — only re-converts when source is newer).
- **Drop a `.pdf` via NFS from a non-login-node host** → the hourly
  `rocbudai-ingest-inputs.timer` catches it within ≤60 min.
- **Drop a `.md` / `.txt` / `.html` directly** → no conversion needed;
  visible at the next session, make sure that the file is named as `<workload-type>__<topic>__<source>__<yyyymmdd>.md`,
  following the guidelines in [kb-inputs.md](./docs/kb-inputs.md).
- **Force re-ingest** — `rocbudai-ingest-inputs --force` (manual run on
  the login node).

| Scenario | Visible to the agent |
|---|---|
| Drop while no TUI is running | Next `rocbudai` session |
| Drop while user X has a TUI running | Next session of user X (the running one already snapshotted) |
| Replace a `.pdf` with an updated version | Re-ingested on the next path event (mtime check) |
| User wants the running session to see the new doc | Tell the agent in chat: "list `/shareddata/rocbudai/docs/inputs/` and read any new files" |

Operational checks: `journalctl -u rocbudai-ingest-inputs.service -n
20` for recent runs; `systemctl list-timers rocbudai-ingest-inputs`
for the next scheduled sweep. Naming convention and what to put in
the KB: `docs/kb-inputs.md`. Source-of-truth: `deploy/auto-ingest/`.

### Customising the agent — `AGENTS.md` workflow

The agent's persona, hard rules, seven-question script, recovery
procedures, and report-format spec live in a set of **per-architecture
persona files**, one of which is seeded as the session `AGENTS.md`:

```
share/rocbudai/AGENTS-default.md         MI300A  (gfx942, CDNA3 APU)      ← canonical reference
share/rocbudai/AGENTS-gfx942-mi300x.md   MI300X  (gfx942, CDNA3 discrete)
share/rocbudai/AGENTS-gfx90a.md          MI250X / MI210 (gfx90a, CDNA2)
share/rocbudai/AGENTS-gfx950.md          MI355X / MI350X (gfx950, CDNA4)
share/rocbudai/AGENTS-container-demo.md   compact standalone container quick-test persona
```

They share the bulk of their content (persona, loop, discovery,
profiling-tool inventory, report schema) and differ only in the
arch-specific bits: the peak-theoretical spec table, the "common
confusions" gotchas, the `rocprof-compute` workload-dir suffix, and the
optimization-playbook KB they cite (`share/rocbudai/kb/`).

**Which persona is used.** `bin/rocbudai-tui` resolves it at session
start:

1. An explicit `ROCBUDAI_AGENTS_TEMPLATE=<file>` (a power-user export, or
   the value `install.sh` bakes into the modulefile for the cluster's GPU
   arch) is honored verbatim.
2. Otherwise the persona is auto-selected from the GPU architecture —
   `ROCBUDAI_GFX_ARCH` if set, else live `rocminfo` (gfx942 is narrowed to
   MI300A APU vs MI300X discrete via the rocminfo Marketing-Name/APU
   marker). In case of an undetectable arch, the MI300A persona is picked, with a warning.

`install.sh` bakes the arch's persona into the modulefile at install time
(from `--gfx-arch` / autodetect), so a cluster install seeds the right
file without needing `rocminfo` at launch.

**Container quick-test** (`--container`, `ROCBUDAI_CONTAINER=1`):
`rocbudai-tui` uses the compact, self-contained
`AGENTS-container-demo.md` persona **alone** (no-modules, pre-answered
discovery, saxpy walkthrough) — **not** the full arch persona. The demo
is a tiny saxpy example, so a small/fast demo model follows a short
focused prompt far more reliably (and starts faster) than the
~2,100-line arch persona.

The resolved persona is copied to `$CWD/AGENTS.md` at session start, and
auto-refreshes when a source template is newer (mtime check). Users can
pin a local copy with `chmod 0444 AGENTS.md` or
`ROCBUDAI_AGENTS_NOREFRESH=1`.

Editing tips:

- **Edit the template, then `touch` it.** The newer mtime is what
  triggers auto-refresh on the next user session — no service to
  restart, no chroot to rebuild. Edits propagate to every next user
  session within seconds, so test on yourself first; we suggest you keep a `.bak`
  back-up file for non-trivial changes.
- **Coordinate with the seed prompt in `bin/rocbudai-tui`.** The TUI
  injects a polite cold-start notice ("Waiting for the model to warm
  up — on a cold node this takes ~1 min …") as opencode's first user
  turn. opencode's `--prompt` is rendered as a visible user message
  in the chat history — that is intentional here: the human watching
  the TUI during the ~1 min cold-start window sees the notice and
  knows the launcher hasn't hung. The MODEL's instructions for first
  turn — treat the seed as decoration, do **not** echo / paraphrase /
  acknowledge it, do **not** narrate model warm-up status, silently
  read `.rocbudai-runtime.md` and emit `§0` welcome + `Q1/7` in the
  SAME assistant message — live in `AGENTS-*.md files §0` ("Session
  opening" / "FIRST-TURN HARD RULES"). If you renumber `§0`
  or change the welcome-banner shape, update the `ROCBUDAI_SEED_PROMPT`
  seed text in `bin/rocbudai-tui` to match.
- **Hard denylists are enforced at opencode**, not by the LLM. To
  add or remove a denied pattern (`rm -rf /`, `module purge`, etc.),
  edit `share/rocbudai/opencode-default.json` (ASK template) and
  `opencode-allow-all.json` (auto-run template) — editing AGENTS.md
  alone won't change what the TUI permits.
- **Don't break §9** (affirmative-response synonyms: "ok", "go
  ahead", "sure", "do it" etc. all count as `yes`). New approval
  flows should reference §9 rather than re-hardcoding "yes".
- **Keep `[FACT]`/`[INFERENCE]`/`[OPINION]` tagging** (§1 hard rule).
  It shows up in every report the agent writes; removing it weakens
  the report-quality story.
- Section map: `## 0` session opening (with resume detection),
  `## 1` hard rules, `## 2`-`## 5` discovery + loop, `## 6` report
  format, `## 7` per-app-type cheatsheet, `## 8` recovery (KFD leaks).

### Slurm comment tags

| Comment | Effect | Enforced where |
|---|---|---|
| (none) | Plain Slurm allocation, no ollama, no rocBudAI | n/a |
| `--comment=ollama` | Starts ollama daemon on the node, pre-warms the model, inherits the cluster-wide airgap baseline (managed opencode config + nft owner-match block on the `ollama` UID). Requires `--exclusive` on an SPX partition. | `job_submit.lua` rule 2 + `prolog.d/rocbudai-ollama-prolog.sh` |

CPX/TPX modes are explicitly rejected (`job_submit.lua` rule 1) —
ollama's GGML runner aborts above 16 visible devices. Source-of-truth:
`deploy/comment-gating/`. The airgap baseline itself is a boot-time
artefact of the compute node: `deploy/airgap/` (managed opencode
config) + `deploy/comment-gating/` (`ollama-egress.service`).

### Diagnostics & cleanup

- `rocbudai-doctor` — 11-check preflight (modules, mounts, daemon, GPU
  visibility, KFD leak scan, etc.). Run before/after any privileged
  change.
- `rocbudai-airgap-check` — verifies the cluster airgap baseline is
  in force on the current allocation: managed opencode config,
  `ollama-egress.service` active, `OLLAMA_NOPRUNE=1` /
  `OLLAMA_NO_CLOUD=1` in the daemon unit, ollama bound to loopback.
  `--deep` also dumps the `nft` table contents (requires sudo).
- `rocbudai-reap-stale` — finds and (with `--reap`) kills leaked
  KFD-bound profile children. Required after any
  `HSA_STATUS_ERROR_*` / `signal 15` from `rocprofv3` or `mpirun`.
  See `AGENTS-default.md §8` for when the agent invokes it.
- Logs: `journalctl -u {ollama,ollama-proxy,ollama-egress}` on the
  compute node; `/var/log/slurm-llnl/{slurmctld,slurmd}.log` for
  allocation issues. The auto-ingest unit logs to journal on the
  **login** node only.

### System installed rocBudAI files

These should be root-owned, world-readable. The executable files will be made available when doing `module load
rocbudai`:

```
/shared/apps/ubuntu/opt/rocbudai/
  bin/
    rocbudai                  compute-node entry (forwards to rocbudai-tui;
                              hard-errors on a login node)
    rocbudai-tui              on-node launcher (preflight, picker, exec opencode)
    rocbudai-name-session     records user-given session name in
                              ./.rocbudai-sessions.json (called by the agent at Q1/7)
    rocbudai-prune-sessions   interactively delete old opencode sessions
                              (project scope by default; --all-runs to scope
                              to ~/rocbudai-runs/*; --dry-run for preview)
    rocbudai-airgap-check     user-visible verification of the airgap baseline
                              (--deep also inspects nft table; requires sudo)
    rocbudai-doctor           11-check preflight (incl. KFD leak scan)
    rocbudai-reap-stale       kill leaked KFD-bound profile children
    rocbudai-ingest-inputs    PDF → .md sidecar pipeline (KB)
  libexec/rocbudai-load-hook.sh   Lmod load-time hook
  share/rocbudai/
    AGENTS-default.md         MI300A agent persona (gfx942 APU) 
    AGENTS-gfx942-mi300x.md   MI300X persona (gfx942 discrete)
    AGENTS-gfx90a.md          MI250X/MI210 persona (gfx90a, CDNA2)
    AGENTS-gfx950.md          MI355X/MI350X persona (gfx950, CDNA4)
                              ^ all four arch personas share the SAME agent loop
                                + 7-question discovery; they differ only in the
                                arch spec table + optimization playbooks. The
                                modulefile picks one per detected arch.
    AGENTS-container-demo.md   compact standalone container quick-test persona
    kb/                       per-arch optimization-playbook knowledge base
    opencode-default.json     ASK-mode template
    opencode-allow-all.json   auto-run override template
/shared/apps/ubuntu/opt/opencode/1.14.28/opencode
/shared/apps/modules/ubuntu/lmodfiles/base/rocbudai/dev.lua
```

**Reference deployment layout (example — adapt paths/UIDs/partition to your site).**
The following reflects a cluster where compute-node
images are deployed with Warewulf. These files exist on a per-node basis (baked
into the Warewulf chroot on the reference cluster); on your site
the mechanism (Warewulf, Ansible, a golden image, …) and exact paths will differ:

```
/etc/systemd/system/ollama.service                      :11435, SPREAD, NOPRUNE, NO_CLOUD
/etc/systemd/system/ollama.service.d/model-cache.conf   OLLAMA_MODELS=/var/local/cache/ollama
/etc/systemd/system/ollama-proxy.service                Python proxy on :11434
/etc/systemd/system/ollama-acl.service                  nft owner-match on :11435
/etc/systemd/system/ollama-egress.service               nft owner-match egress block (ollama UID)
/etc/systemd/system/rocbudai-model-cache.service        boot-time NFS→local-NVMe rsync
/etc/opencode/opencode.json                             managed config
/etc/nftables.d/{ollama-acl,ollama-egress}.nft
/usr/local/bin/{ollama,ollama-real,ollama-proxy}
/var/local/cache/ollama/                                local NVMe model cache (~65 GB)
```

Cluster-wide (NFS-shared, recall that the Ollama models live on NFS):

```
/shareddata/Ollama_Models/                       2755 ollama:ollama, qwen3.5:122b (+ gpt-oss:120b, nemotron-3-super:120b)
/shareddata/rocbudai/                            KB inputs (drop docs here)
/shared/share/slurmscripts/{prolog,epilog}/{prolog,epilog}.sh
/shared/share/slurmscripts/{prolog.d,epilog.d}/rocbudai-ollama-{prolog,epilog}.sh
/etc/slurm/job_submit.lua                        Rules: 1=cpx/tpx, 2=ollama
```

Login-node only (NOT in the chroot — these run on the user's entry host):

```
/etc/systemd/system/rocbudai-ingest-inputs.path     KB watcher (inotify)
/etc/systemd/system/rocbudai-ingest-inputs.service  oneshot ingest runner
/etc/systemd/system/rocbudai-ingest-inputs.timer    hourly fallback sweep
```

---

## Reference deployment decisions (your site may differ)

> These are not requirements — substitute your own partition name, model, fencing layout,
> and paths. They are documented here so an admin replicating the setup has a
> known-good reference.

- **Model + compute mode**: `qwen3.5:122b` 
   on SPX nodes only; `gpt-oss:120b` and
  `nemotron-3-super:120b` can be made opt-in via `ROCBUDAI_MODEL`. MI300A CPX
  (24 virtual GPUs) breaks ollama (`MAX_DEVICES=16`) — rejected at
  submit by `job_submit.lua`.
- **Dedicated bench GPU**: ollama + the agent are fenced onto the available GPUs
  0,1,2,.. (`ROCR_VISIBLE_DEVICES=0,1,2,..` + `AllowedCPUs=...` in
  `ollama.service`), leaving **one GPU reserved for `rocbudai-bench`** so
  the in-session FOM is free of inference contention. With three dies
  for the daemon, `OLLAMA_MAX_LOADED_MODELS=1` keeps exactly one model
  resident; the prolog pre-warms only the default (`qwen3.5:122b`), and
  opt-in models cold-load on demand.
- **Allocation contract**: `--comment=ollama --exclusive` on the SPX
  partition. The TUI runs on the **compute node**, never on the
  login node; `module load rocbudai` is the canonical entry point.
- **Authorization**: users → `ollama list/show/ps/run`; admins →
  `pull/rm/push/create/cp`. The default model is `qwen3.5:122b`,
  selectable from the `ROCBUDAI_ALLOWED_MODELS` allow-list; the active
  model is pinned server-side via the managed `opencode.json` (the
  launcher rewrites its `model` field from `ROCBUDAI_MODEL` at start).
- **Knowledge base**: static markdown injection (PDFs → `.md`
  sidecars). Note, this is **not** RAG.
- **Airgap shape**: managed `/etc/opencode/opencode.json` + nft
  owner-match egress block on the `ollama` UID
  (`ollama-egress.service`) + `OLLAMA_NOPRUNE=1` + `OLLAMA_NO_CLOUD=1`
  in the systemd unit + ollama bound to loopback only. Always-on, no
  user opt-in required. Verifiable end-to-end with
  `rocbudai-airgap-check`. Design + the model-pull-relock procedure:
  `docs/airgap-and-model-pulls.md`.

---

## Final remarks 

- Each opencode bash tool call runs in a fresh shell;
  `module load` in one call is invisible to the next. Mitigated by
  an AGENTS.md hard rule requiring `&&`-chained commands; the LLM
  may still break the chain. We need this when the modules
  have a hierarchical structure where all packages installed for a specific
  ROCm version become visible only after the corresponding ROCm module is loaded.
  The most common misfire is an empty `$ROCM_PATH` read in a standalone
  call, which the agent could misdiagnose as a shell that needs
  `source`-ing; the persona now names that symptom explicitly and points
  at the `&&`-chain fix. 
- The airgap baseline blocks the `ollama` UID (always, at boot) and
  the user UID (per-job, while a `--comment=ollama` allocation is
  alive) at the kernel firewall, and pins opencode's cloud-sharing
  flags off. It is always-on and verifiable with `rocbudai-airgap-check`.
  It does not cover the login node or recursive DNS — full threat
  model in
  [`docs/airgap-and-model-pulls.md`](docs/airgap-and-model-pulls.md).
- opencode v1.14.28 is shipped as a binary release. The
  deployed `/shared/apps/ubuntu/opt/opencode/1.14.28/opencode` is
  byte-identical (`sha256: f59b8c68…007cf0`) to **both** the
  `sst/opencode` and `anomalyco/opencode` v1.14.28 release artifacts
  — the two repos publish the same artifact at this tag. Pin upstream
  to `sst/opencode` (the canonical project) for future bumps.

---

## License

MIT — see [`LICENSE`](./LICENSE). Copyright (c) 2026 AMD.
