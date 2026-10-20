# Auto-ingest on a timer

Source artefacts that auto-convert PDFs landing in
`/shareddata/rocbudai/docs/inputs/` to `.md` sidecars without needing
an admin to invoke `rocbudai-ingest-inputs` by hand. An hourly systemd
timer sweeps the KB inputs dir and converts anything new.

The swept `/shareddata/rocbudai/docs/inputs/` dir is the reference-cluster
default; override it with `KB_INPUTS_DIR` in `site.conf` and `install.sh`
retargets the deployed units (and the converter honours the same path via the
`ROCBUDAI_KB_INPUTS_DIR` env override). Note: a relocated KB also needs the path
in the AGENTS personas + README edited by hand — `install.sh` does not rewrite those.

## Files

| File | Lives at (deployed) | Role |
|---|---|---|
| `rocbudai-ingest-inputs.service` | `/etc/systemd/system/` (login node only) | `oneshot` runner that exec's the existing `rocbudai-ingest-inputs` |
| `rocbudai-ingest-inputs.timer` | `/etc/systemd/system/` (login node only) | hourly sweep that triggers the service |

The actual converter (`rocbudai-ingest-inputs`) is unchanged and
ships from `bin/rocbudai-ingest-inputs` in this repo (deployed at
`/shared/apps/ubuntu/opt/rocbudai/bin/`). It is already idempotent
(`--force`-gated re-conversion via mtime comparison), so a sweep that
finds nothing new is a near-instant no-op.

## Why a timer and not a `systemd.path` watcher

An earlier design also shipped a `rocbudai-ingest-inputs.path` unit that
fired on `IN_CLOSE_WRITE` for near-instant ingest on login-node drops. We
removed it for two reasons.

First, it was a boot-time hazard on infra nodes. A `.path` unit watching an
NFS-backed directory implicitly acquires a `Requires=`/`After=` dependency on
the mount backing that directory. Enabled into `multi-user.target` on a node
that is also the NFS server and runs dnsmasq, that dependency can close a
systemd ordering cycle; systemd breaks cycles by deleting jobs
non-deterministically, and when the deleted jobs are `nfs-server` and
`dnsmasq`, the node boots with an empty `exportfs` and no DNS. The cycle is
latent: some boots get lucky and start the right jobs, which makes it a nasty
intermittent failure to diagnose.

Second, the watcher bought little on an NFS share. `systemd.path` uses inotify,
and inotify on NFS only sees changes made on the local host. Admin drops that
arrive via a different host (a remote rsync mounting NFS directly) never fire
it. The hourly timer catches every case regardless of origin, so it was already
the real ingest path.

## Why login node only

The timer must run on exactly one host. If we enabled it on every SPX node they
would race: duplicate ingest passes over the same NFS dir and possible
mid-write reads. The login node is the canonical entry point: admins `scp`
files in over SSH, or `cp` them from `/home/<them>/...` into the KB, so a single
sweeper there sees every drop. 1-hour latency is acceptable for a workflow
that is already manual today.

## Slurm comment grammar

N/A. This feature lives entirely outside Slurm; it runs on its timer
irrespective of any job state.

## Deployment

```bash
# 1. Install the units (login node only)
sudo cp deploy/auto-ingest/rocbudai-ingest-inputs.service \
        /etc/systemd/system/
sudo cp deploy/auto-ingest/rocbudai-ingest-inputs.timer \
        /etc/systemd/system/

# 2. Reload systemd
sudo systemctl daemon-reload

# 3. Enable + start the timer (it pulls in the service)
sudo systemctl enable --now rocbudai-ingest-inputs.timer

# 4. Verify
systemctl status rocbudai-ingest-inputs.timer
systemctl list-timers --all | grep rocbudai
```

## Smoke test

```bash
# As admin on the login node:
echo 'dummy' > /tmp/dummy.txt
ps2pdf /tmp/dummy.txt /tmp/dummy.pdf  # or any small valid PDF
cp /tmp/dummy.pdf /shareddata/rocbudai/docs/inputs/

# Trigger the ingest now instead of waiting for the next hourly sweep:
sudo systemctl start rocbudai-ingest-inputs.service
journalctl -u rocbudai-ingest-inputs.service -n 30 --no-pager
ls -l /shareddata/rocbudai/docs/inputs/dummy.{pdf,md}

# Cleanup:
rm /shareddata/rocbudai/docs/inputs/dummy.{pdf,md}
```

## Rollback

```bash
sudo systemctl disable --now rocbudai-ingest-inputs.timer
sudo rm /etc/systemd/system/rocbudai-ingest-inputs.{service,timer}
sudo systemctl daemon-reload
```

The on-disk converter (`rocbudai-ingest-inputs`) is untouched by
this rollback; admins can still run it by hand.

## Known limitations

- **Ingest latency**: up to 1 hour between a PDF drop and its `.md` sidecar
  (plus `OnBootSec=15min` after a reboot). Admins who want it immediately run
  `rocbudai-ingest-inputs` by hand or `systemctl start
  rocbudai-ingest-inputs.service`.
- **Sub-directory recursion**: the converter already walks recursively, so
  subdirs under the KB inputs dir are ingested on the next sweep.
