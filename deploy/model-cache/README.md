# Local NVMe model cache

Source artefacts that mirror the NFS-shared Ollama model store
(`/shareddata/Ollama_Models/`) onto each SPX node's local NVMe at boot
and reroute the ollama daemon to read from there. Cuts cold-start
from ~9-10 min to ~30 s.

## Why this exists (measured)

Measured on a reference MI300A SPX node (idle, post-`drop_caches`):

| Source | Bandwidth | 65 GB read time |
|---|---|---|
| NFS (`/shareddata/Ollama_Models`) | 112 MB/s | ~580 s (~9.7 min) |
| Local NVMe (`/dev/nvme0n1p3`)     | 2.5 GB/s | ~26 s |

Many cluster prologs run `echo 3 > /proc/sys/vm/drop_caches` at every
job start (the reference cluster does), which means RAM-only page-cache
pre-warming gets wiped before `ollama.service` can use it. A local-disk
mirror survives `drop_caches` and is the right shape for the problem.

## Files

The `/var/local/cache/ollama` destination below is the reference-cluster default;
override it with `MODEL_CACHE_DIR` in `site.conf` and `install.sh` retargets both
files. The rsync SOURCE is derived from `OLLAMA_MODELS` in the base unit, so it
tracks the model store automatically and is not set here.

| File | Lives at (deployed) | Role |
|---|---|---|
| `rocbudai-model-cache.service` | `/etc/systemd/system/` (each SPX node + chroot) | Boot-time `rsync /shareddata/Ollama_Models/ → /var/local/cache/ollama/` (Type=oneshot, runs Before=ollama.service) |
| `ollama-models-cache.conf`     | `/etc/systemd/system/ollama.service.d/model-cache.conf` (each SPX node + chroot) | Drop-in that overrides `OLLAMA_MODELS=/var/local/cache/ollama` and adds Requires/After on the cache service |

The cache service is **per-node**, not cluster-wide. Each SPX node
holds its own 65 GB local copy of the model store.

## Disk footprint

gpt-oss:120b on disk: one ~61 GB weights blob plus 4 small
config/template/license/params blobs. Total ~62 GB.

On `/dev/nvme0n1p3` (mounted at `/`), 685 GB free of 1.8 TB.
Plenty of headroom for additional models (Llama 3.x 70B, etc.) if
they're added later.

## Slurm comment grammar

N/A. This is invisible to the user — just makes existing
`--comment=ollama` allocations start fast.

## Deployment

```bash
# Per SPX node (admin must SSH in or use ssh-from-login):
sudo cp deploy/model-cache/rocbudai-model-cache.service \
        /etc/systemd/system/

sudo mkdir -p /etc/systemd/system/ollama.service.d/
sudo cp deploy/model-cache/ollama-models-cache.conf \
        /etc/systemd/system/ollama.service.d/model-cache.conf

sudo systemctl daemon-reload
sudo systemctl enable --now rocbudai-model-cache.service
# (first run does the 9-10 min rsync; subsequent boots: seconds)

# After cache is populated, restart ollama (or wait for next job):
sudo systemctl restart ollama   # only if currently running
```

For Warewulf chroot bake-in (so newly-imaged nodes inherit the
cache infrastructure — first boot still pays the 9-10 min one-time
sync, but every reboot after is fast):

```bash
sudo wwctl image shell ubuntu-24.04 -- bash -lc '
    cp /shareddata/.../rocbudai-model-cache.service /etc/systemd/system/
    mkdir -p /etc/systemd/system/ollama.service.d/
    cp /shareddata/.../ollama-models-cache.conf \
       /etc/systemd/system/ollama.service.d/model-cache.conf
    systemctl enable rocbudai-model-cache.service
'
sudo wwctl image build ubuntu-24.04
```

## Smoke test

```bash
# Stop ollama, drop caches, start ollama from scratch, time the first
# inference. Run as admin via ssh-from-login on a quiet node.

sudo systemctl stop ollama
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

t0=$(date +%s.%N)
sudo systemctl start ollama
while ! curl -sf http://127.0.0.1:11435/api/version >/dev/null; do
    sleep 0.2
done

# First /api/generate call — this is the user-perceived cold-start.
# Real prompt (not empty), keep_alive 4h to mimic the prolog.
sudo curl -sf -m 600 -X POST http://127.0.0.1:11435/api/generate \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.5:122b","prompt":"Reply with the single word ok",
         "stream":false,"keep_alive":"4h"}' \
    -o /tmp/cold-start.out

t1=$(date +%s.%N)
echo "cold-start total: $(python3 -c "print(f'{$t1 - $t0:.1f}s')")"
```

Expected: ~30 s with the cache, ~9-10 min without.

## Admin model-pull workflow (post-deployment)

Because `OLLAMA_MODELS` now points at the local cache, a new `ollama
pull` lands in `/var/local/cache/ollama/` on the pull node — **not** in
the NFS store. To make it visible cluster-wide you must push the new
blobs back to NFS and re-sync the other nodes:

```bash
sudo rsync -a --update /var/local/cache/ollama/ /shareddata/Ollama_Models/
for n in <other-spx-nodes>; do
    sudo ssh "$n" 'sudo systemctl restart rocbudai-model-cache.service'
done
```

The full recipe — lifting the egress block, the pull itself, and the
mandatory SYSTEM-overlay re-augmentation — lives in
[`../../docs/airgap-and-model-pulls.md`](../../docs/airgap-and-model-pulls.md).

## Rollback

```bash
sudo systemctl disable --now rocbudai-model-cache.service
sudo rm /etc/systemd/system/rocbudai-model-cache.service
sudo rm /etc/systemd/system/ollama.service.d/model-cache.conf
sudo rmdir /etc/systemd/system/ollama.service.d/ 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl restart ollama   # picks up old OLLAMA_MODELS
sudo rm -rf /var/local/cache/ollama   # reclaim 65 GB
```

After rollback, ollama reverts to reading from
`/shareddata/Ollama_Models` over NFS. Next cold-start will be slow
again, but everything else still works.

## Known limitations

- **Cluster-wide model pull requires the post-pull rsync step**
  documented above. If an admin forgets, the new model is invisible
  on other SPX nodes until their next boot.
- **First boot pays ~9-10 min for the initial sync**. Subsequent
  boots: seconds (delta-only). The initial cost is unavoidable
  unless we ship a pre-baked image that already contains the model
  blob — possible but adds 65 GB to every Warewulf image.
- **Cache is read-only from non-admin users.** UID `ollama` and root
  can read; other UIDs would need group membership in `ollama` if
  they ever need direct access. Today nothing else reads the cache.
