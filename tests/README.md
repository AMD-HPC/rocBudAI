# rocBudAI tests

**Offline suite** (CI, no GPU/ROCm/network) — `tests/run.sh`:

- `test-persona-resolver.sh` — asserts the arch→persona mapping in
  `bin/rocbudai-tui` (sources just the resolver, stubs `rocminfo`).
- `test-repo-hygiene.sh` — locks in the IP-review remediations (no `@amd.com`,
  `amd-internal`, `7.13`, stale model tags), validates `opencode-*.json`, and
  keeps `kb/` in sync with `kb/README.md`.

`.github/workflows/ci.yml` runs this plus `shellcheck` on every push/PR.

**Live preflight** (needs a running Ollama + the model pulled) —
`tests/check-model.sh`: confirms `ROCBUDAI_MODEL` exists and is tools-enabled
(a model without `tools` breaks `ollama launch opencode`):

```bash
ROCBUDAI_OLLAMA_HOST=http://127.0.0.1:11435 ROCBUDAI_MODEL=gemma4:12b \
    tests/check-model.sh
```
