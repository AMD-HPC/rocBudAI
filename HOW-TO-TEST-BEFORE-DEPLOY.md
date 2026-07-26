# How to test rocBudAI before you deploy

> Docs index: see the **Where to start** table in [`README.md`](./README.md#where-to-start).

Read this before you run `install.sh` on a real cluster. It is a
**four-tier ladder**: each tier is cheaper and safer than the next,
and each one catches a different class of bug. Climb the ladder in
order — do not skip to Tier 4 (a real compute node) without passing
Tiers 1–3 first.

| Tier | What you run | Needs a GPU? | Needs Slurm? | Changes the system? | Proves |
|---|---|---|---|---|---|
| **1 — Dry run** | `./install.sh --dry-run …` | No | No | **No** | The flags, paths, arch→persona mapping, and step plan are correct |
| **2 — Container quick-test** | `./install.sh --container` | Yes (inside `salloc`) | Yes (you're in an allocation) | Only inside a throwaway container | The full install runs end-to-end and the TUI launches |
| **3 — Full-stack container** | manual install in a container + `test-env.sh` | Optional | No (faked via env) | Only inside the container | `rocbudai-doctor` + `rocbudai-tui` pass every gate on a no-systemd host |
| **4 — Real cluster smoke test** | `salloc` on a real node + `module load rocbudai` | **Yes** | **Yes (real)** | **Yes (the deploy)** | Production behaviour: systemd, multi-GPU spread, auth proxy, `--comment=ollama` gating |

The canonical **test model** everywhere below is `gemma4:12b`
(~8 GB, tools-enabled). The production cluster default is the much
larger `qwen3.5:122b`. Use the small one for all testing: it must
expose `tools` in Ollama (which `ollama launch opencode` requires),
and being small it keeps the cold-start short. The container
quick-test pairs it with a compact, self-contained demo persona
(`AGENTS-container-demo.md`) rather than the full ~2,100-line arch
persona, so a small model follows the demo flow reliably.

---

## Tier 1 — Dry run (no GPU, no Slurm, no changes)

**Goal:** confirm the installer will do what you expect *without
touching the system*. `--dry-run` prints every step it would take
(packages, paths, the modulefile it would write, the GPU
architecture it detected, and the AGENTS persona it would bake in)
and exits without making changes.

```bash
cd ~/rocBudAI

# Preview a vanilla install (arch autodetected)
./install.sh --dry-run

# Preview the full reference-cluster install
./install.sh --dry-run --with-hardening

# Preview a forced architecture (skips rocminfo autodetect)
./install.sh --dry-run --gfx-arch gfx950
./install.sh --dry-run --gfx-arch gfx942        # MI300X / MI300A
./install.sh --dry-run --gfx-arch gfx90a        # MI250X

# Preview a different Slurm partition gate
./install.sh --dry-run --partition my_gpu_q
```

**Pass criteria:**

- The script exits 0 with no errors.
- The detected/selected GPU architecture is what you expect.
- The AGENTS persona it reports baking into the modulefile matches
  the   architecture (e.g. `AGENTS-gfx950.md` for `--gfx-arch gfx950`,
  `AGENTS-default.md` (MI300A APU) vs `AGENTS-gfx942-mi300x.md`
  (MI300X discrete) for the two gfx942 SKUs).
- The install paths and partition match your site.

This tier needs no hardware and changes nothing, so run it freely
and re-run it after every flag change.

---

## Tier 2 — Container quick-test (fast end-to-end smoke)

**Goal:** confirm the *whole install runs* and the TUI launches,
inside a throwaway ROCm container, without risking the host. This
is the fastest way to see a working agent.

**Prerequisite:** you are inside a Slurm allocation on a GPU node
(the container needs the GPU devices passed through), and Docker or Podman are
available.

```bash
# From inside an salloc on a GPU node:
cd ~/rocBudAI
./install.sh --container
```

This one-shot path:

- pulls a ROCm dev image (override with `--rocm-version`,
  `--distro`, `--distro-version`),
- installs rocBudAI inside it with the test model `gemma4:12b`,
- disables GPU fencing and autodetects the architecture,
- clones the [AMD HPC training examples](https://github.com/amd/HPCTrainingExamples/tree/main),
- sets `ROCBUDAI_CONTAINER=1` (which bypasses the Slurm/partition
  gates), and
- drops you into a shell where you run `rocbudai-tui` directly.

```bash
# Inside the container shell it leaves you in:
rocbudai-tui
```

**Pass criteria:** you reach the rocBudAI welcome banner and the
`Q1/7` session prompt, answer the discovery questions, and the agent
responds using the local `gemma4:12b`. Exit with `/exit`.

This is QUICK TESTING ONLY — the container has no systemd
supervising the daemon and no GPU fencing. It is not a deployment.

Full details: [`docs/CONTAINER-TEST.md`](./docs/CONTAINER-TEST.md).

---

## Tier 3 — Full-stack container test (every gate, no-systemd host)

**Goal:** exercise the *production preflight gates* (`rocbudai-doctor`
and the TUI's six hard checks) on a no-systemd host, with the Slurm
context faked via environment variables. This catches
gate/allow-list/partition bugs that Tier 2 skips (because
`ROCBUDAI_CONTAINER=1` bypasses them).

**Prerequisite:** you ran `install.sh` **manually** inside a container
(not `--container`, so `ROCBUDAI_CONTAINER` is unset) and pulled
`gemma4:12b`.

The flow is: `source …/share/rocbudai/test-env.sh` (sets the
`ROCBUDAI_*` + fake `SLURM_JOB_*` vars), then climb three sub-tiers —
daemon liveness + one inference, `rocbudai-doctor`, then `rocbudai-tui`.

**The step-by-step, pass criteria, and teardown live in
[`docs/CONTAINER-TEST.md`](./docs/CONTAINER-TEST.md)** — follow that
document for Tier 3; this section is only the entry point.

---

## Tier 4 — Real cluster smoke test (the actual deploy)

**Goal:** post-deploy verification on a real SPX compute node with
real systemd + real Slurm — the only tier that exercises what
containers cannot: systemd-supervised ollama, multi-GPU spread
(`OLLAMA_SCHED_SPREAD`), `OLLAMA_KEEP_ALIVE`, the `--comment=ollama`
daemon gating, the auth proxy on `:11434`, and the airgap baseline.

**Prerequisite:** `INSTALL.md` is complete on the cluster (promoted
install tree, opencode, modulefile, and the pinned production model
`qwen3.5:122b` on disk).

**The pre-flight checklist, the exact `salloc`, pass criteria, and the
common-error playbook live in
[`docs/SMOKE-TEST.md`](./docs/SMOKE-TEST.md)** — follow that document
to the letter for Tier 4; this section is only the entry point.
