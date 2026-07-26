# Ollama daemon — base systemd unit

`ollama.service` here is the canonical override for the package-default
unit shipped by `apt-get install ollama`. It is the foundation that
the auth hardening (`deploy/auth/`), `--comment=ollama` daemon gating
(`deploy/comment-gating/`), and the airgap baseline (`deploy/airgap/`)
all extend.

## Where it goes

Each MI300A SPX compute node, plus the Warewulf chroot:

```
/etc/systemd/system/ollama.service
```

After dropping it in:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama       # or: sudo systemctl disable ollama, if comment-gating is enabled
```

The `--comment=ollama` daemon gating (`deploy/comment-gating/`) wants
the daemon **disabled at boot** — the prolog starts it per-job. If
you skip that hardening feature, leave the daemon enabled so it's
always available.

## Why each Environment= line is here

| Var | Purpose |
|---|---|
| `OLLAMA_MODELS=/shareddata/Ollama_Models` | NFS-shared model store (single source of truth across the cluster). |
| `OLLAMA_HOST=127.0.0.1:11435` | Loopback only on a non-default port. The Python reverse-proxy (`deploy/auth/ollama-proxy.py`) sits on `:11434` and forwards filtered traffic here. If you skip the `deploy/auth/` hardening, change to `0.0.0.0:11434`. |
| `HSA_XNACK` | **Deliberately NOT set.** ollama's HIP backend (ggml) uses explicit `hipMalloc`, not managed-memory / demand paging, so XNACK gives the daemon nothing — on MI300A or discrete GPUs. On discrete parts (MI300X/MI355X) forcing it also perturbs `rocprofv3`. It's a per-workload user choice (`export HSA_XNACK=1` in your own shell if a kernel needs it). |
| `ROCR_VISIBLE_DEVICES=0,1,2` | **Dedicated-bench-APU isolation.** Fence the daemon onto APUs 0,1,2 so APU 3 stays quiet for `rocbudai-bench`. On MI300A SPX each APU is one ROCr device (0..3); this hides die 3's VRAM from the daemon. |
| `AllowedCPUs=0-71,96-167` | Cgroup cpuset (systemd `[Service]` directive, **not** an `Environment=` line) that keeps the daemon's host threads off die-3 cores (72-95,168-191) so it cannot steal that APU's shared HBM either. The bench owns GPU 3 + cores 72-95,168-191. |
| `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` | Long-context perf optimisations. |
| `OLLAMA_SCHED_SPREAD=1` | Spread one model across all visible GPUs (now the three fenced dies 0,1,2). **Required** for the 120B-class models; without it the model falls back to CPU on cold load. |
| `OLLAMA_KEEP_ALIVE=-1` | Keep the model resident in VRAM for the life of the allocation. The Slurm epilog stops the daemon at job end, so `-1` only pins models within an active job. Amortises the cold-load. |
| `OLLAMA_NUM_PARALLEL=1` | One user, one prompt at a time — `>1` just shards KV cache across slots with no throughput win and steals HBM. |
| `OLLAMA_MAX_LOADED_MODELS=1` | With the daemon confined to three dies, keep exactly ONE model resident (the default, pre-warmed by the prolog); opt-in models cold-load on demand. |
| `OLLAMA_NOPRUNE=1` | Disable background "is this model still upstream?" probe. Required for offline / airgap. |
| `OLLAMA_NO_CLOUD=1` | Disable cloud-feature handshake. Required for offline / airgap. |
| `OLLAMA_LOAD_TIMEOUT=15m` + `OLLAMA_GPU_OVERHEAD=4294967296` | Cold-start safety nets: a generous load timeout plus 4 GiB/die HIP scratch + rocBLAS/MIOpen headroom. See the unit file comments for the full rationale. |

## What's NOT here

- No `EnvironmentFile=` — the env is fully self-contained.
- No `HSA_XNACK` — not needed by the daemon (see the table above),
  and forcing it perturbs `rocprofv3` on discrete GPUs. Any
  pre-existing `/etc/profile.d/ollama.sh` that exports `HSA_XNACK=1`
  to all user login shells should be removed during install; leave
  XNACK a per-workload choice users make in their own shell.
- No `systemctl enable` — the `--comment=ollama` daemon gating (if
  deployed) disables this at boot.

## Verify after install

```bash
systemctl is-active ollama                   # → active (no gating) or inactive (gating deployed)
systemctl show ollama | grep '^Environment'  # one line, all 13 vars present
systemctl show ollama -p AllowedCPUs         # → AllowedCPUs=0-71 96-167 (bench-APU fence)
systemctl show ollama -p Environment | tr ' ' '\n' | grep ROCR_VISIBLE_DEVICES  # → ROCR_VISIBLE_DEVICES=0,1,2
sudo -u ollama curl -s http://127.0.0.1:11435/api/version
```
