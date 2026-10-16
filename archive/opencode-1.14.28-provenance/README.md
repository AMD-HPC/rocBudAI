# opencode v1.14.28 provenance

This directory is the in-repo manifest for the third-party `opencode`
binary that rocBudAI ships. It exists so any site can verify the
download chain (from upstream tarball to extracted binary) without
trusting the network at install time. The 700-byte stub keeps the
supply-chain chain of custody auditable from the repo alone.

## Artifact identity

| Artifact                       | sha256                                                             |
| ------------------------------ | ------------------------------------------------------------------ |
| `opencode-linux-x64.tar.gz`    | `3f9a7139612d4421a46408d46eeed27bd958bdbe7f43514cd5e5a10ad1540e5b` |
| `opencode` (post-extraction)   | `f59b8c6875294c24d7048703df3d9806d4c449ef93106001cc587a6151007cf0` |

The tarball hash is the machine-readable line in `SHA256SUMS.txt` (used
by the install steps below). The binary hash is informational, for
auditors who want to spot-check what extraction produced.

The tarball is published identically by both `sst/opencode` (the
canonical upstream) and `anomalyco/opencode` at the v1.14.28 tag. rocBudAI pins to
`sst/opencode` for future bumps.

## How install steps use this

`install.sh` (step 4) and `INSTALL.md` §4 both run:

```bash
sha256sum -c <repo>/archive/opencode-1.14.28-provenance/SHA256SUMS.txt
```

from the staging directory immediately after `curl`-ing the tarball
and before `tar xzf`. A mismatch aborts the install.

## Where the binary lands after install

Site-dependent. Defaults to `${OPENCODE_ROOT}/${OPENCODE_VERSION}/opencode`
where the variables are defined in `install.sh` CONFIGURATION
(default `/shared/apps/ubuntu/opt/opencode/1.14.28/opencode`, matching
the reference deployment). On other sites, set `OPENCODE_ROOT`
in `site.conf`.
