-- rocbudai/dev — rocBudAI (AMD GPU profiling/optimisation AI assistant)
--
-- Loading this module on a compute node with an interactive TTY auto-launches
-- the OpenCode TUI, pre-configured for the ROCm profiling workflow.
--
-- Loading on a login node (no SLURM_JOB_ID) just sets PATH and prints a hint;
-- the user is expected to allocate a compute node first.

help([[
rocBudAI — AMD GPU profiling/optimisation AI assistant (dev, rolling prototype).

Workflow:

  # 1. On the login node, allocate an SPX MI300A compute node:
  salloc -p PPAC_MI300A_SPX --exclusive --comment=ollama --time=01:00:00
  # (you land on the compute node prompt automatically)

  # 2. On the compute node, cd into your project and load the module:
  cd <project-dir>
  module load rocbudai                        # → launches the OpenCode TUI

On a no-flag `module load rocbudai`, if there are prior sessions
associated with the launching cwd you'll see an interactive picker
(numbered, sorted most-recent-first) and can resume a session by name.
Sessions are named via the first of seven discovery questions
(Q1/7); you can also bypass the picker:

  rocbudai --continue       # resume last session in this dir
  rocbudai --new            # force a fresh session

In the TUI the agent runs a seven-question discovery interview
(session name, app type, ROCm version, other modules, build, run,
figure of merit — see `man rocbudai`) then iteratively builds,
profiles, analyses, and optimises your code.

To leave the TUI:        /exit  (or Ctrl-D)
To opt into auto-run:    export ROCBUDAI_AUTORUN=1 ; module load rocbudai
To prune old sessions:   rocbudai-prune-sessions     (--all-runs, --dry-run)
To verify the airgap:    rocbudai-airgap-check       (--deep needs sudo)

Auto-nudge: if a turn ends and the session stays idle for 240 s, the
launcher injects a "continue" prompt so the agent picks up where it
left off (the nudge is a normal user message, so you will see it in
the transcript). Tune or disable per session via:

    export ROCBUDAI_NUDGE_AFTER_S=60         # tighter loop (default 240 s)
    export ROCBUDAI_NUDGE_DISABLE=1          # turn off entirely

Documentation:
  man rocbudai                                  (full reference)
  /shared/apps/ubuntu/opt/rocbudai/share/rocbudai/AGENTS-default.md
                                                (MI300A AGENTS persona; the
                                                 launcher seeds the persona
                                                 matching this node's GPU arch)
  https://github.com/AMD-HPC/rocbudai            (project repo: README,
                                                 INSTALL, design notes)
]])

whatis("Name        : rocbudai")
whatis("Version     : dev (rolling)")
whatis("Description : AMD GPU profiling/optimisation AI assistant (OpenCode + Ollama)")
whatis("URL         : man rocbudai (or https://github.com/AMD-HPC/rocbudai)")

load("rocm")

local root = "/shared/apps/ubuntu/opt/rocbudai"

prepend_path("PATH", pathJoin(root, "bin"))
-- /shared/apps/ubuntu/man is the install destination for share/man/man1/rocbudai.1
-- (it's in MANPATH on login nodes by default but NOT on compute nodes), so we
-- prepend it here so `man rocbudai` works in a compute-node session too.
prepend_path("MANPATH", "/shared/apps/ubuntu/man")
setenv("ROCBUDAI_ROOT", root)
setenv("ROCBUDAI_OPENCODE_BIN", "/shared/apps/ubuntu/opt/opencode/1.14.28/opencode")
setenv("ROCBUDAI_OLLAMA_HOST", "http://127.0.0.1:11434")

-- opencode 1.14.28 phone-home suppression.
-- The five OPENCODE_DISABLE_* env vars below are recognised by the opencode
-- binary (verified via `strings` against the v1.14.28 binary on this cluster)
-- and disable every known automatic outbound HTTP call opencode would
-- otherwise make:
--   AUTOUPDATE      — version check against github.com/repos/anomalyco/opencode
--                     (this is the one that prompted users for "update / skip"
--                     and broke session creation when "skip" was pressed).
--   LSP_DOWNLOAD    — opencode pulls LSP servers (clangd, lua-language-server,
--                     texlab, tinymist, zls, kotlin-lsp) from github releases.
--   MODELS_FETCH    — opencode fetches its model catalog from opencode.ai.
--   EXTERNAL_SKILLS — external "skills" plugin downloads.
--   SHARE           — belt-and-suspenders for the JSON config's
--                     "share": "disabled" key (which IS honoured in 1.14.28,
--                     but doubling up costs nothing).
-- Note: this is the SOFT/CONFIG layer of the airgap. The HARD/KERNEL layer
-- (so a buggy/adversarial opencode cannot reach the internet even if it
-- tried) lives in rocbudai-user-egress.service + the Slurm prolog/epilog,
-- which together install a per-job nft chain that REJECTs external egress
-- from the user UID for the duration of every --comment=ollama allocation.
-- The two layers are independent: either alone is sufficient against the
-- documented threats, both together is defence in depth.
setenv("OPENCODE_DISABLE_AUTOUPDATE",      "1")
setenv("OPENCODE_DISABLE_LSP_DOWNLOAD",    "1")
setenv("OPENCODE_DISABLE_MODELS_FETCH",    "1")
setenv("OPENCODE_DISABLE_EXTERNAL_SKILLS", "1")
setenv("OPENCODE_DISABLE_SHARE",           "1")

-- Set ROCBUDAI_MODEL only if the user hasn't already exported a value.
-- The canonical default is qwen3.5:122b (promoted from opt-in to default
-- 2026-06-08, replacing gpt-oss:120b). gpt-oss:120b — the previous
-- default; OpenAI gpt-oss MoE — and nemotron-3-super:120b remain
-- available as opt-in alternatives.
-- Override path: `export ROCBUDAI_MODEL=<name>; module load rocbudai`.
-- The named model must be pulled into the model store
-- (default `/shareddata/Ollama_Models`) AND must appear in
-- ROCBUDAI_ALLOWED_MODELS below.
if os.getenv("ROCBUDAI_MODEL") == nil or os.getenv("ROCBUDAI_MODEL") == "" then
    setenv("ROCBUDAI_MODEL", "qwen3.5:122b")
end

-- ROCBUDAI_ALLOWED_MODELS is the admin-curated comma-separated allow-list
-- of model names that rocbudai-tui will accept. Currently pulled into
-- /shareddata/Ollama_Models: qwen3.5:122b (default since 2026-06-08),
-- gpt-oss:120b (previous default, now opt-in), and nemotron-3-super:120b
-- (opt-in); admins extend the list as they pull additional models per
-- /shareddata/rocbudai/docs/airgap-and-model-pulls.md.
-- Set unconditionally (no os.getenv check): users cannot legitimately
-- override which models are installed on the cluster. Soft enforcement
-- only (the launcher prints a friendly error and refuses to launch); a
-- determined user could `unset ROCBUDAI_ALLOWED_MODELS` to bypass, but
-- they would still hit "model not found" since admins control which
-- models are actually pulled (the admin-only CLI wrapper + nft ACL).
setenv("ROCBUDAI_ALLOWED_MODELS", "qwen3.5:122b,gpt-oss:120b,nemotron-3-super:120b")

-- ROCBUDAI_SPX_PARTITIONS is the comma-separated list of Slurm partitions
-- where rocbudai-tui will agree to launch. The model (qwen3.5:122b) needs
-- 4×32 GB MI300A in SPX mode; on CPX (24 GPUs) or TPX (8 GPUs) the GGML
-- runner aborts with "model failed to load — resource limitations or
-- internal error". Keep this in sync with the OLLAMA_PARTITIONS table
-- in deploy/comment-gating/job_submit.lua (the submit-time enforcer).
setenv("ROCBUDAI_SPX_PARTITIONS", "PPAC_MI300A_SPX")

-- rocbudai-submit multi-GPU bench partition; "" => cluster default.
setenv("ROCBUDAI_SUBMIT_PARTITION", "")

-- AGENTS persona is resolved at runtime by rocbudai-tui from the live GPU on the
-- compute node (see _persona_for_arch), so it is NOT baked here. rocbudai-tui
-- seeds the matching file as the session AGENTS.md (container quick-test mode
-- uses the standalone AGENTS-container-demo.md). A user may still force one:
--   export ROCBUDAI_AGENTS_TEMPLATE=<file>; module load rocbudai

-- Auto-launch the TUI on compute nodes with an interactive TTY (recursion-
-- guarded by ROCBUDAI_ACTIVE). The actual logic lives in a real shell script
-- because Lmod collapses execute{cmd=...} onto a single eval line, which
-- breaks any inline `if/then/fi`.
if mode() == "load" then
    execute{
        cmd = "bash " .. pathJoin(root, "libexec/rocbudai-load-hook.sh"),
        modeA = {"load"},
    }
end
