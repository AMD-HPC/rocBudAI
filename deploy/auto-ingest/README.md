# Auto-ingest on file drop

Source artefacts that auto-convert PDFs landing in
`/shareddata/rocbudai/docs/inputs/` to `.md` sidecars without needing
an admin to invoke `rocbudai-ingest-inputs` by hand.

The watched `/shareddata/rocbudai/docs/inputs/` dir is the reference-cluster
default; override it with `KB_INPUTS_DIR` in `site.conf` and `install.sh`
retargets the deployed units (and the converter honours the same path via the
`ROCBUDAI_KB_INPUTS_DIR` env override). Note: a relocated KB also needs the path
in the AGENTS personas + README edited by hand — `install.sh` does not rewrite those.

## Files

| File | Lives at (deployed) | Role |
|---|---|---|
| `rocbudai-ingest-inputs.path` | `/etc/systemd/system/` (login node only) | systemd.path watcher; fires on `IN_CLOSE_WRITE` in the KB inputs dir |
| `rocbudai-ingest-inputs.service` | `/etc/systemd/system/` (login node only) | `oneshot` runner that exec's the existing `rocbudai-ingest-inputs` |
| `rocbudai-ingest-inputs.timer` | `/etc/systemd/system/` (login node only) | hourly fallback sweep for the NFS-inotify edge case |

The actual converter (`rocbudai-ingest-inputs`) is **unchanged** and
ships from `bin/rocbudai-ingest-inputs` in this repo (deployed at
`/shared/apps/ubuntu/opt/rocbudai/bin/`). It is already idempotent
(`--force`-gated re-conversion via mtime comparison), so multiple
back-to-back triggers from the path unit do at most one pass of real
work.

## Why login node only

`systemd.path` uses inotify under the hood. **Inotify on NFS only
sees changes made on the local host.** If we deployed the path-watch
on every SPX node, none of them would catch admin-side PDF drops
that happen on the login node. And if we deployed on multiple hosts
that all had local-write paths into the dir, they'd race — duplicate
ingest passes, possible mid-write reads.

Login node is the canonical entry point for admins:
- They `scp` files in over SSH → IN_CLOSE_WRITE on the login node →
  watcher fires.
- They `cp` from `/home/<them>/...` to the KB → same.

The timer unit (`OnUnitActiveSec=1h`) is the fallback for the
genuinely unusual case where a PDF arrives via a different host —
e.g. a remote rsync that mounts NFS directly without going through
the login node. 1-hour latency is acceptable for a workflow that's
already manual today.

## Slurm comment grammar

N/A. This feature lives entirely outside Slurm; it runs whenever a
PDF lands, irrespective of any job state.

## Deployment

```bash
# 1. Install the units (login node only)
sudo cp deploy/auto-ingest/rocbudai-ingest-inputs.path \
        /etc/systemd/system/
sudo cp deploy/auto-ingest/rocbudai-ingest-inputs.service \
        /etc/systemd/system/
sudo cp deploy/auto-ingest/rocbudai-ingest-inputs.timer \
        /etc/systemd/system/

# 2. Reload systemd
sudo systemctl daemon-reload

# 3. Enable + start
sudo systemctl enable --now rocbudai-ingest-inputs.path
sudo systemctl enable --now rocbudai-ingest-inputs.timer

# 4. Verify
systemctl status rocbudai-ingest-inputs.path
systemctl status rocbudai-ingest-inputs.timer
systemctl list-timers --all | grep rocbudai
```

## Smoke test

```bash
# As admin on the login node:
echo 'dummy' > /tmp/dummy.txt
ps2pdf /tmp/dummy.txt /tmp/dummy.pdf  # or any small valid PDF
cp /tmp/dummy.pdf /shareddata/rocbudai/docs/inputs/

# Within ~2-3 seconds:
journalctl -u rocbudai-ingest-inputs.service -n 30 --no-pager
ls -l /shareddata/rocbudai/docs/inputs/dummy.{pdf,md}

# Cleanup:
rm /shareddata/rocbudai/docs/inputs/dummy.{pdf,md}
```

## Rollback

```bash
sudo systemctl disable --now rocbudai-ingest-inputs.timer
sudo systemctl disable --now rocbudai-ingest-inputs.path
sudo rm /etc/systemd/system/rocbudai-ingest-inputs.{path,service,timer}
sudo systemctl daemon-reload
```

The on-disk converter (`rocbudai-ingest-inputs`) is untouched by
this rollback; admins can still run it by hand.

## Known limitations

- **NFS inotify**: only fires for changes made on the host running
  the watcher. Mitigated by the hourly timer fallback.
- **Sub-directory recursion**: not supported by `systemd.path`
  natively. The KB is flat today; if subdirs are introduced, either
  add per-subdir `PathChanged=` lines or switch to
  `inotifywait -m -r` in a custom unit.
- **Trigger amplification**: when the script writes `.md` sidecars,
  those writes themselves trigger more path events. Convergence is
  guaranteed by the converter's mtime check (`-nt`) — second run is
  a near-instant no-op — but the journal will show a second invocation
  per ingest cycle. Not a bug; document for confused admins.
