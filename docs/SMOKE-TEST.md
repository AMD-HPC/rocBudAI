# rocBudAI — end-to-end smoke test

> Docs index: see the **Where to start** table in [`../README.md`](../README.md#where-to-start).

This is the post-deploy verification a user (or sysadmin) runs once
on a fresh cluster, after `INSTALL.md` is complete, to confirm the
module loads correctly, opencode wires to ollama, and the agent
behaves as designed.

Replace the placeholders with your site's values:

- `<your-spx-partition>` — the Slurm partition that exposes MI300A
  in SPX mode (4 APUs in a 4 socket node). On the reference cluster:
  `PPAC_MI300A_SPX`.
- `<your-username>` — the user running the test.

## Pre-flight checklist

These should all be true after `INSTALL.md` is done. If any fails,
go back and re-run the matching install step.

| Check | Expected | How to verify |
|---|---|---|
| Promoted install tree | `/shared/apps/ubuntu/opt/rocbudai/` exists | `ls /shared/apps/ubuntu/opt/rocbudai/` |
| Promoted opencode | `…/opt/opencode/1.14.28/opencode` exists, executable | `test -x /shared/apps/ubuntu/opt/opencode/1.14.28/opencode` |
| Promoted modulefile | `module avail rocbudai` shows `rocbudai/dev` | `module avail rocbudai 2>&1` |
| Pinned model on disk | `qwen3.5:122b` in `/shareddata/Ollama_Models/` | `sudo -u ollama ollama list` |
| Ollama configured | `OLLAMA_SCHED_SPREAD=1`, `OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_MAX_LOADED_MODELS=1`, `ROCR_VISIBLE_DEVICES=0,1,2` | `systemctl show ollama \| grep ^Environment` |

## Step-by-step

### 1. Allocate a compute node

From the login node, as `<your-username>`:

```bash
salloc -p <your-spx-partition> \
       --exclusive --comment=ollama \
       --time=01:00:00 -J rocbudai-smoketest
```

If the cluster has `LaunchParameters=use_interactive_step` configured,
you are already on the compute node when `salloc` returns. Confirm:

```bash
hostname        # should be a compute node, NOT a login node
echo $SLURM_JOB_ID
```

> **Why SPX, not CPX?** CPX exposes 24 virtual GPUs; ollama's GGML
> runner aborts above 16 visible devices. SPX exposes 4 full-APU
> devices per node — that is what `--comment=ollama` requires
> (enforced by `job_submit.lua` Rule 2).

### 2. Pick a working directory

Two options:

**Option A (recommended) — fresh dir under your home.** The module
will bootstrap `opencode.json` and `AGENTS.md` for you:

```bash
mkdir -p ~/rocbudai-runs/smoketest-$(date +%Y%m%d_%H%M%S)
cd ~/rocbudai-runs/smoketest-*/
ls -la                                  # should be empty
```

**Option B — point at an existing project.** Just `cd` to your own
source tree. The module's bootstrap is non-destructive: it only writes
`opencode.json` / `AGENTS.md` if they don't already exist (or if the
shipped templates are newer, in which case they auto-refresh — pin
with `chmod 0444 opencode.json` or `export ROCBUDAI_AGENTS_NOREFRESH=1`
to keep a custom one).

### 3. Load the module — TUI should auto-launch

```bash
module load rocbudai
```

What you should see:

```text
[rocbudai-tui] wrote opencode.json (ASK mode, model=qwen3.5:122b)
[rocbudai-tui] wrote AGENTS.md (AGENTS-default.md)
[rocbudai-tui] rocbudai (dev) on <hostname> (job <jobid>)
[rocbudai-tui] model: qwen3.5:122b   cwd: /home/<your-username>/rocbudai-runs/smoketest-...
[rocbudai-tui] launching via: ollama launch opencode --model qwen3.5:122b
[rocbudai-tui] type /exit or Ctrl-D in the TUI to leave.

(... opencode TUI starts here, agent emits welcome banner, then asks Q1/7 ...)
```

> The `wrote AGENTS.md (...)` line names the persona `rocbudai-tui`
> selected for this node's GPU. On the MI300A reference cluster that is
> `AGENTS-default.md`; on other archs it is `AGENTS-gfx90a.md` (MI250X),
> `AGENTS-gfx942-mi300x.md` (MI300X), or `AGENTS-gfx950.md` (MI355X).

### 4. Verify the TUI is configured correctly

The agent should speak first (no need to type to get it started). The
welcome banner must include a `Session info:` block with hostname /
Slurm job ID / model / cwd, then the agent should immediately ask
**Q1/7** (session name). Reply with a short label like
`smoketest-<date>`. The agent should run `rocbudai-name-session
"<your label>"` (no approval prompt — it's pre-allowed) and then ask
**Q2/7** (application type) in the same message. Reply normally — one
question at a time; the agent must wait for each answer before moving on.

Try a few read-only commands inside the TUI; they should run without
any approval prompt:

```text
> can you run pwd
> can you run hostname
> module list
```

Then propose something non-trivial (a build command, a `module load
<rocm/...>`, an edit). The TUI should pause and ask
`Allow this command? [y/N]` before running.

### 5. Things to verify (the gate)

Tick each item — if any is wrong, capture the failing terminal output
and report which step failed.

- [ ] `hostname` confirms you are on a compute node, not a login node.
- [ ] `module avail rocbudai` shows `rocbudai/dev` (no `module use` needed).
- [ ] `module load rocbudai` does **not** print any `eval: line ... syntax error`.
- [ ] The TUI starts on its own (no manual `ollama launch opencode`).
- [ ] The agent's first message is the welcome banner (not "big pickle",
      not a generic "how can I help").
- [ ] The banner mentions ASK mode and the `ROCBUDAI_AUTORUN=1` override.
- [ ] The banner's `Session info:` table has the real hostname,
      Slurm job ID, model = `qwen3.5:122b`, and the current cwd.
- [ ] Right after the banner, the agent asks **Q1/7** (session name),
      runs `rocbudai-name-session` without prompting (pre-allowed),
      then proceeds through the remaining six questions one at a time,
      in order: name → app type → ROCm version → other modules →
      build → run → FOM.
- [ ] After Q1/7 reply, `./.rocbudai-sessions.json` exists in cwd and
      contains an entry mapping the active session id to the name you
      gave (`cat .rocbudai-sessions.json`).
- [ ] Exit (`/exit`), then `module load rocbudai` again from the
      same cwd: a numbered picker appears showing your named session;
      pick it; the agent says "Welcome back to **<name>** — picking
      up where we left off."
- [ ] When you propose any non-trivial command (build, profile, edit),
      the TUI prompts for permission (does NOT auto-run).
- [ ] Read-only commands (`ls`, `module list`, `rocm-smi`, `cat`) run
      without a prompt.
- [ ] The agent prints `Report so far: <absolute-path>/report.md` after
      each step (not a placeholder, the real cwd).
- [ ] `cat opencode.json` in another shell shows
      `"model": "ollama/qwen3.5:122b"`,
      `permission.bash."*": "ask"`,
      explicit `deny` entries for `module purge` / `module reset` /
      `rm -rf /…` / `mkfs*` / `shutdown` / `reboot`.

### 6. Optional — try the AUTO-RUN override

To opt into auto-run (commands run without per-call approval, but
with `deny` patterns still enforced), `/exit` the TUI, then:

```bash
export ROCBUDAI_AUTORUN=1
rocbudai --continue
```

The TUI's bootstrap should now print
`[rocbudai-tui] wrote opencode.json (AUTO-RUN mode, model=qwen3.5:122b)`,
and the agent's banner should say AUTO-RUN. Toggle back with
`export ROCBUDAI_AUTORUN=0` (or `unset ROCBUDAI_AUTORUN`) and
`rocbudai --continue` again.

### 7. Exit the TUI

```text
> /exit
```

(or Ctrl-D twice, depending on TUI focus). You should land back at
the compute-node shell prompt with the module still loaded:

```bash
module list                # should show rocbudai/dev
echo "$ROCBUDAI_ACTIVE"    # should be empty (the load-hook scopes it)
```

### 8. Release the allocation

```bash
exit                       # back to login node
# (or wait for the --time limit to expire)
```

## Common errors and what to do

### "module: command not found"

You forgot `source /etc/profile` or aren't on a real shell. Run:

```bash
source /etc/profile.d/lmod.sh
```

### "[rocbudai-tui] error: ollama daemon not reachable at http://127.0.0.1:11434"

The ollama daemon isn't running on this node. Three quick checks:

```bash
systemctl is-active ollama          # should say "active"
sudo systemctl status ollama        # for the full picture
sudo systemctl restart ollama       # if it's not active and you have sudo
```

If the `--comment=ollama` daemon gating is deployed (see
`deploy/comment-gating/`), the daemon is started by the prolog when
you allocated with `--comment=ollama`. A "not reachable" error here
means the prolog drop-in failed; check
`journalctl -t rocbudai-ollama-prolog` on the compute node.

### "[rocbudai-tui] warning: model 'qwen3.5:122b' is not in the ollama registry on this node"

The model isn't visible to the ollama daemon. Usual fixes:

- `sudo systemctl restart ollama`
- Check that `OLLAMA_MODELS=/shareddata/Ollama_Models` (or your site's
  path) is set in the daemon environment:
  `systemctl show ollama | grep OLLAMA_MODELS`.

### "[rocBudAI] loaded on a non-allocated host (no SLURM_JOB_ID)"

You're on the login node, not a compute node. Go back to step 1 and
`salloc` first.

### "[rocBudAI] already inside a rocBudAI session (ROCBUDAI_ACTIVE set)"

You ran `module load rocbudai` from inside a TUI shell-tool. The
recursion guard correctly refused. To re-enter, `/exit` first, or
`unset ROCBUDAI_ACTIVE` if you know what you're doing.

### TUI starts but shows "big pickle" instead of `qwen3.5:122b`

The opencode → ollama wiring failed. Check that `rocbudai-tui` is
launching opencode via `ollama launch opencode --model …` (it should —
the launcher does this for you). If `cat opencode.json` shows the
right model but the TUI still shows "big pickle", `/exit` and re-run
`module load rocbudai` once.

### Agent asks Q4 / Q5 / Q6 all at once

That's a discovery-flow regression. `AGENTS.md` §2 has hard rules
that say one question per turn. If you see batched questions, the
shipped template was overridden — check
`diff AGENTS.md /shared/apps/ubuntu/opt/rocbudai/share/rocbudai/AGENTS-default.md`
and either delete your local copy (so the next `module load rocbudai`
re-bootstraps it) or `chmod 0444` it once it's correct.
