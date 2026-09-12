# Handoff — state as of 2026-09-12

Volatile status. `CLAUDE.md` holds the durable context (architecture,
conventions, invariants); read that first.

| | |
|---|---|
| Active branch | `feature/n-walls-mediamtx-snapshot` |
| Branch head | `58662b9` Port connection monitoring (mpv IPC + watchdog) |
| `main` head | `1995523` — last known-deployable state |
| Remote | https://github.com/MaisUmGajo/RaspiDipalys |

## Setting up on a new machine — do this first

**1. Set the git identity, or commits will be wrong.** The personal identity is
configured *repo-locally*, and repo-local config lives in `.git/config`, which
**is not carried by a clone**. On a fresh clone, commits would silently use
whatever global identity that machine has (on the current laptop that's the
CEIIA work account). After cloning:

```bash
git config --local user.name "Miguel Costa"
git config --local user.email "28893895+MaisUmGajo@users.noreply.github.com"
```

**2. Check out the working branch:**

```bash
git checkout feature/n-walls-mediamtx-snapshot
```

**3. If you are reusing an OLD clone rather than a fresh one**, note this
branch's history was rewritten (all commits were re-authored, then
force-pushed). A plain `git pull` will make a mess:

```bash
git fetch origin && git reset --hard origin/feature/n-walls-mediamtx-snapshot
```

## What is built

Everything below is on the branch and committed.

**Server** — any number of walls, each a config file run by the templated
`videowall-encode@.service`; enable/disable without losing config; MediaMTX
relay so multiple clients can watch one wall; mosaic snapshot tee'd off the
encode pipeline; per-camera ffprobe diagnostics; web UI with full wall CRUD,
live stats and real client info from the relay's API; privileged actions gated
by `videowall-ctl`.

**Pi client** — picks a wall by name per HDMI output from a dropdown of what
the server offers; tests a source before applying; a watchdog that detects
frozen / degraded / corrupt streams over mpv's IPC socket and reconnects them
in place; dashboard shows measured stream health rather than "the process
exists".

**Installers** — preflight checks aimed at minimal Debian VMs, `--check` mode,
ERR traps that report step/line/command/signal, logging to
`/var/log/videowall-install.log`.

## What is verified, and what is not

**Verified** (statically or by harness): shell syntax across all scripts;
Jinja block balance; config-key agreement between encode script, both UI
templates and every example file; ffmpeg filtergraph and output ordering via
dry-run harness across snapshot/VAAPI permutations; `videowall-ctl` rejecting
12 hostile inputs (path traversal, injection, unit-name trickery, arg
splitting, over-length); ffprobe result classification; watchdog detection
across 10 sample sequences with no false reconnects.

**Never executed**: *all* of the Python. Both Flask apps and the watchdog have
never run, because the dev machine has no Python interpreter. Expect at least
one import or template error on first real start.

**Never run on hardware**: the whole system. Also unverified — MediaMTX's
config schema against the pinned version, `-atomic_writing` availability on the
target ffmpeg, and the Pi dual-head question below.

## Open decisions

**1. Zaphod dual-head on Pi 4 — the biggest unknown.** The Pi client pins each
X screen to one HDMI connector via `ZaphodHeads`. This has never been tested,
and the sibling `displaycameras-modern` project, when run on real Pi 4
hardware, used a *single combined X screen with `xrandr`* instead — which hints
Zaphod may not work on the modern KMS stack.

*Test:* boot the Pi with both monitors. If only one lights up, run
`DISPLAY=:0 xrandr`: both connectors listed but the second `Screen` never
active confirms it. *Fallback:* single X screen + `xrandr`, in which case
`displaycameras-modern`'s second-monitor placement fixes are the playbook — or
go X-less with `--vo=drm`, which would also serve the small-board case.

**2. Pi Zero W / Pi 1 support** — deferred by decision. Full analysis recorded
in `v3-server-pi-webui/README.md` ("Client hardware"). Scope is one output /
one stream, not N.

**3. Should `main` be updated?** The branch has diverged a long way. Merging is
reasonable once the system runs on hardware, not before.

## Next steps

**1. Set up the server (in progress, blocked).** Needs SSH access from the
working machine. Known LAN hosts: `192.168.1.174` and `192.168.1.177` answer
SSH but rejected this laptop's key; `.150` and `.160` did not answer at all.
Unresolved: *which* host is the Debian 13 server, the SSH username, and getting
a public key into its `authorized_keys`. Password auth is not usable from the
agent's shell (no TTY).

Prefer connecting over the **Tailscale** address rather than the LAN one — that
is the path the Pi will actually use, so it exercises the real link.

**2. The server is in a PARTIAL state.** Tuesday's install died partway (the
SIGPIPE bug, since fixed) at "Deploying web UI", so packages, users and config
files probably exist while credentials, sudoers and the systemd units do not.
Inspect before re-running. The installer is idempotent, so a re-run is the
intended repair; start with:

```bash
sudo ./install.sh --check      # changes nothing, reports environment readiness
```

Note the server needs the branch checked out, and the MediaMTX step will stop
once on purpose to make you verify the download's SHA256 before it installs an
unverified binary.

**3. Phase 0 checks on the server**, worth doing while connected:

```bash
ls -lai /run/videowall && sudo systemctl restart videowall-encode@4k && ls -lai /run/videowall
ffmpeg -hide_banner -h muxer=image2 | grep -i atomic
```

The first confirms whether a restart of one wall pulls the shared runtime
directory out from under the others (`RuntimeDirectoryPreserve=yes` is already
set on the branch to prevent it). The second decides whether the snapshot's
atomic-write path is available or `SNAPSHOT=0` is needed.

**4. Then the Pi client**, and the dual-head question above.
