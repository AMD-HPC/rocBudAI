# `deploy/ollama-models/` — augmented Modelfiles

This directory contains the per-model `Modelfile` overlays that wrap
the stock ollama.com models with rocbudai's SYSTEM-level operating
rules.

## What lives here

- `Modelfile.gpt-oss-120b.rocbudai` — applied on top of `gpt-oss:120b` (production)
- `Modelfile.qwen3.5-122b.rocbudai` — applied on top of `qwen3.5:122b` (production)
- `Modelfile.nemotron-3-super-120b.rocbudai` — applied on top of `nemotron-3-super:120b` (production)
- `Modelfile.gemma4-12b.rocbudai` — applied on top of `gemma4:12b` (**`--container` quick-test only**)

All files use Ollama's `FROM <stock-model>` + `SYSTEM """..."""`
two-directive shape. The base `TEMPLATE`, `LICENSE`, and `PARAMS`
layers are inherited unchanged via `FROM`; the only thing the overlay
adds is a `vnd.ollama.image.system` layer with the rocbudai rules.

The three production overlays carry a **short** hard-rules summary and
defer to `AGENTS.md` for the full persona. The `gemma4-12b` overlay is
different: it is the **self-contained demo persona** (welcome + 7-question
flow + profiling loop), because the `--container` quick-test cannot rely on
opencode loading `AGENTS.md` (see the comment header in that Modelfile, and
`share/rocbudai/AGENTS-container-demo.md`, which it must stay in sync with).

## When these get applied

Three moments:

1. **Fresh install** — `install.sh` step 3 (after `ollama pull`)
   automatically runs `ollama create <model> -f Modelfile.<model>.rocbudai`
   for every supported model name (`gpt-oss:120b`, `qwen3.5:122b`,
   `nemotron-3-super:120b`). Custom `MODEL_NAME` values that don't
   have a matching Modelfile are skipped with a warning. The `--container`
   quick-test runs the same step inside the container with
   `MODEL_NAME=gemma4:12b`, so the `gemma4-12b` overlay is applied there too.

2. **Admin re-pull** (airgap rollback or upstream model refresh) —
   any `ollama pull` from ollama.com replaces the manifest with the
   stock no-SYSTEM version. The admin pull procedure in
   `docs/airgap-and-model-pulls.md` documents the mandatory
   re-augmentation step that must follow any pull.

3. **SYSTEM-rules update** — when this Modelfile changes (e.g. a new
   rocbudai rule lands and we want it at the SYSTEM-prompt level),
   re-run `ollama create` on every node via your site's
   parallel-ssh / pdsh loop (admin-only).

## Why a SYSTEM-level overlay (vs. AGENTS.md alone)

`AGENTS.md` is loaded by opencode as a regular file/tool input — the
model sees it as content **inside** the conversation, after every
prior user turn and tool result. A `SYSTEM` prompt sits at the
inference root, **before** any user message. Models follow `SYSTEM`
rules statistically more reliably than rules embedded mid-conversation.

The 5 rules in the SYSTEM overlay are the **most-violated subset** of
the full 24-rule `AGENTS.md`. The overlay is intentionally short
(~80 tokens out of the model's 256K context) so it does not
crowd out user input. The full ruleset stays in `AGENTS.md` with
all the rationale, examples, and observed-violation history.

## Rollback

Three levels (in order of cost):

1. **Per-node, fast** (~30 sec): re-create the model with a Modelfile
   that contains only `FROM <stock-model>` and no SYSTEM directive.
   This drops the SYSTEM layer.

   ```bash
   echo "FROM gpt-oss:120b" | sudo -u ollama \
       OLLAMA_HOST=127.0.0.1:11435 ollama create gpt-oss:120b -f -
   ```

2. **All nodes, fast** (~2 min): same as #1 in a 3-node ssh loop.

3. **Re-pull from ollama.com** (~30 min per model): admin pull workflow
   in `docs/airgap-and-model-pulls.md`. Replaces the manifest with the
   stock no-SYSTEM version. Use only if level #1 produces an
   unrecoverable manifest state.

## Changing the SYSTEM rules

To add / remove / edit a rule:

1. Edit the Modelfile here (REPO source).
2. Mirror to install-tree if applicable (this dir is REPO-only by
   convention; the live nodes pull from REPO via the admin runbook).
3. Re-run `ollama create` on every SPX node (parallel ssh loop).
4. Smoke-test: `ollama run <model> "what are your hard rules?"` —
   the response should mention the 5 rules verbatim.

## Which rules are in the overlay

The 5 rules in the SYSTEM block are the most-violated subset of the
full `AGENTS.md` ruleset, each mapping to a specific `AGENTS.md` rule:

| SYSTEM rule | Maps to AGENTS.md rule |
|---|---|
| 1 (one-Q-per-turn) | §0 + §2 "Never fabricate user turns" |
| 2 (median FOM only) | Rule 17 + Headline-number paragraph |
| 3 (no raw Edit on report.md) | Rule 10 + Mechanical schema check |
| 4 (iter01 profile first) | Rule 20 + iter01 sub-paragraph |
| 5 (re-Read modified files) | Rule 10 narrow + Rule 24 broad |
