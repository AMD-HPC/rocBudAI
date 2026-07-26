# rocBudAI — testing the installer inside a no-systemd container

> Docs index: see the **Where to start** table in [`../README.md`](../README.md#where-to-start).

This is the dev/CI verification path: how to confirm that
`install.sh` produced a functional install when it was run inside a
container (HPCTrainingDock's `bare_system` image, plain
`docker run`-style containers, etc.) or on any host where PID 1 is
not systemd. For the production verification on a real SPX MI300A
compute node, see [`SMOKE-TEST.md`](./SMOKE-TEST.md) instead.

> **Just want to try rocBudAI quickly?** From inside a Slurm
> allocation, `./install.sh --container` does a one-shot install +
> launch with the `gemma4:12b` test model and no GPU fencing (it sets
> `ROCBUDAI_CONTAINER=1`, which bypasses the Slurm/partition gates and
> ignores any `site.conf`). That path is QUICK TESTING ONLY — see
> [`HOW-TO-TEST-BEFORE-DEPLOY.md`](../HOW-TO-TEST-BEFORE-DEPLOY.md)
> Tier 2. The manual tiers below verify a real install on a
> no-systemd host.

## What "no systemd" buys you and what it costs

When `install.sh` cannot find `/run/systemd/system` it auto-engages
its container/test fallback, see the three-line callout in
[`../INSTALL.md`](../INSTALL.md). Concretely:

- Step 2 installs the unit file at `/etc/systemd/system/ollama.service`
  for documentation (and so an admin can `systemctl enable ollama`
  later) but **does not** run `systemctl daemon-reload` / `restart`.
- Instead, `ollama serve` is launched as the `ollama` user via
  `setsid --fork runuser`, with the env block sourced from the same
  unit file. Logs go to `/var/log/rocbudai/ollama.log`.
- Step 3's `ollama pull` is forwarded `OLLAMA_HOST=…` (matching the
  unit file, e.g. `127.0.0.1:11435`) so the client reaches the local
  daemon directly, not the auth proxy on `:11434` (which is only
  installed by step 8 hardening).

This means: end-to-end install completes inside a plain container,
no `--privileged`, no cgroup gymnastics, no systemd-in-docker
recipe. The cost is that `ollama.service` is not under any
init/supervisor — if the daemon crashes, nothing restarts it. Fine
for testing; not what you want in production.

## Prerequisites

`install.sh` has completed successfully inside the container (you
saw the `==> Done` / `[ ok ] rocBudAI install completed.` banner).
The model you pulled in step 3 was small enough to fit on disk —
`gemma4:12b` (~8 GB, tools-enabled) is the recommended testing
model since the production default
`qwen3.5:122b` (120B-class) is impractical to download into a test
container, and a smaller
tools-less model like `tinyllama` (~640 MB) would silently break
`ollama launch opencode` because opencode wires the model into its
bash/edit/etc. via tool calls. To install with a different model,
edit the `MODEL_NAME=` line in the `CONFIGURATION` block at the top
of `install.sh` before running it; if you need to squeeze under
~17 GB, `qwen3:0.6b` (~500 MB) is the smallest tools-enabled
alternative in the Qwen family.

> **MI300A unified-memory fix.** rocBudAI pins `ollama` to a release
> that already contains the fix for zero-VRAM reporting on MI300A APUs,
> so the stock pinned binary loads models with no rebuild or patch
> step. See [`../INSTALL.md`](../INSTALL.md) step 1 for the details.

## One-time env setup

The doctor and TUI need a handful of `ROCBUDAI_*` and `SLURM_JOB_*`
env vars set so they can run outside their production
modulefile/Slurm context. We ship a sourceable env file that sets
all of them in one go — set it once per shell:

```bash
source /shared/apps/ubuntu/opt/rocbudai/share/rocbudai/test-env.sh
```

You should see a one-line summary echoed:

```
rocbudai test-env loaded: model=gemma4:12b host=http://127.0.0.1:11435 root=/shared/apps/ubuntu/opt/rocbudai slurm=job-1/comment=ollama/part=test
```

This sets:

- `PATH`, `ROCBUDAI_ROOT`, `ROCBUDAI_OPENCODE_BIN` — install
  layout.
- `ROCBUDAI_OLLAMA_HOST=http://127.0.0.1:11435` — daemon, not the
  `:11434` step-8 auth proxy.
- `ROCBUDAI_MODEL=gemma4:12b`, `ROCBUDAI_ALLOWED_MODELS=gemma4:12b`
  — the canonical tools-enabled testing model (override if you
  pulled `qwen3.5:122b` or a different test model).
- `ROCBUDAI_SPX_PARTITIONS=test` — TUI partition allow-list.
- `SLURM_JOB_ID=1`, `SLURM_JOB_COMMENT=ollama`,
  `SLURM_JOB_PARTITION=test` — fake Slurm allocation context so the
  TUI's hard `--comment=ollama` and SPX-partition gates pass.

**You do not need to install Slurm in the container.** Both
`rocbudai-doctor` and `rocbudai-tui` fall back to reading these
`SLURM_JOB_*` env vars when `scontrol` is not on the `PATH`.

Every variable above is a `: ?{...}` assignment, so anything you
exported by hand before sourcing wins — handy for overriding
`ROCBUDAI_MODEL` if you pulled something other than `gemma4:12b`:

```bash
export ROCBUDAI_MODEL=qwen3.5:122b
export ROCBUDAI_ALLOWED_MODELS=qwen3.5:122b
source /shared/apps/ubuntu/opt/rocbudai/share/rocbudai/test-env.sh
```

## Tier 1 — daemon liveness + one round-trip inference

The minimum bar: is the daemon answering and can it actually run
the model? No rocBudAI plumbing involved.

```bash
curl -s http://127.0.0.1:11435/api/version
curl -s http://127.0.0.1:11435/api/tags | python3 -m json.tool
OLLAMA_HOST=127.0.0.1:11435 ollama run "$ROCBUDAI_MODEL" "answer in exactly five words"
```

`api/version` should return JSON with a `version` field. `api/tags`
should list the model you pulled. `ollama run` should print five
words (or thereabouts) and exit cleanly. If any of these fails, the
problem is below rocBudAI — check `/var/log/rocbudai/ollama.log`.

## Tier 2 — the standalone rocBudAI preflight (with Slurm context faked)

`rocbudai-doctor` is the canonical "is the install healthy?" gate.
It walks 11 checks: Slurm allocation, AMD GPUs, ollama daemon,
model availability, model allow-list, opencode binary, working
directory, install tree, leaked KFD processes, project `report.md`,
and local manifest-blob completeness.

Because `test-env.sh` populated `SLURM_JOB_ID=1`,
`SLURM_JOB_COMMENT=ollama`, and `SLURM_JOB_PARTITION=test` (plus
`ROCBUDAI_SPX_PARTITIONS=test` so the partition matches the
allow-list), the doctor exercises the Slurm allocation block here
in Tier 2 — *not* in Tier 3. On a real cluster these same vars
come from Slurm itself / the modulefile; in the test container we
stand in for them via env vars.

```bash
rocbudai-doctor
```

With `test-env.sh` sourced you should see check 1 come out fully
green:

```
1. Slurm allocation
  [ ok ]   in Slurm allocation: job 1
  [ ok ]   allocation comment contains 'ollama' (resolved via scontrol: 'ollama')
  [ ok ]   on a supported SPX MI300A partition: 'test'
```

A red `[FAIL]` or yellow `[warn]` line is paired with a one-line
`hint:` describing the fix. Common test-container expected warns
(non-blocking): GPU count < 4 (only one `/dev/dri` device passed
into the container), `current dir is $HOME` (you're not inside a
project yet).

To deliberately exercise the "not in a Slurm allocation" failure
path (verify the hint text reads right):

```bash
( unset SLURM_JOB_ID; rocbudai-doctor )
```

## Tier 3 — launch the TUI

If Tier 2 is green, Tier 3 is just running the launcher:

```bash
rocbudai-tui
```

`rocbudai-tui` re-runs the same hard preflight as the doctor's
check 1 (Slurm allocation + `--comment=ollama` + SPX partition),
plus checks (d) the model is in the admin allow-list, (e) the
opencode binary is executable, and (f) the ollama daemon is
reachable. All six gates are already satisfied by the `test-env.sh`
you sourced above, so this should drop you straight into the
rocBudAI welcome banner and the Q1/7 session-name prompt. Type a
session name, answer the discovery questions, and the agent will
start responding using the local `$ROCBUDAI_MODEL` model. Exit with
`/exit` or Ctrl-D.

This is the same code path that `module load rocbudai` triggers on
a real compute node (the modulefile sets the same env vars, then
the load hook runs `rocbudai-tui`). On a real compute node
`SLURM_JOB_ID` / `SLURM_JOB_COMMENT` / `SLURM_JOB_PARTITION` are
populated by Slurm itself (and the TUI also falls back to
`scontrol show job` for the comment, since `salloc`-spawned shells
don't always inherit `SLURM_JOB_COMMENT`); `test-env.sh` just
stands in for that machinery.

If the TUI bails with an error mentioning `--comment is '(none)'`,
`partition is 'test', which is not an SPX MI300A partition`, or
`ROCBUDAI_MODEL=... is not in the admin allow-list`, double-check
that you `source`d `test-env.sh` in the *same* shell you're running
`rocbudai-tui` from (env vars from a previous `module load` or a
parent shell may shadow the test ones).

## Tearing down the daemon

`install.sh`'s no-systemd path leaves `ollama serve` running in the
background (via `setsid --fork`). To stop it cleanly:

```bash
pgrep -u ollama -f 'ollama serve' | xargs -r sudo kill
```

Or just exit the container — the process tree dies with it.

## When to graduate to the real smoke test

Once tiers 1-3 pass inside the container, the next step is the
production smoke test on an actual SPX MI300A compute node with
real systemd + Slurm: see [`SMOKE-TEST.md`](./SMOKE-TEST.md). That
covers things this doc cannot exercise: multi-GPU spread, KEEP_ALIVE
behaviour, the `--comment=ollama` daemon gating, the auth proxy,
airgap baseline, etc.
