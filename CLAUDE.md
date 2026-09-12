# RaspiDipalys — project context

A surveillance video wall: a Debian server composites UniFi G3 Flex RTSP
cameras into mosaics and relays them; Raspberry Pi clients display one mosaic
per HDMI output. Both machines run a small Flask web UI.

**Current work lives on the `feature/n-walls-mediamtx-snapshot` branch.**
`main` is the last known-deployable state (simpler: fixed pair of walls, direct
SRT, one client per wall). See `docs/HANDOFF.md` for where things stand right
now and what to do next.

## Layout

```
v1-standalone-pi/     archived — everything on one Pi
v2-server-pi/         archived — server composites, Pi displays
v3-server-pi-webui/   CURRENT
  common/             Python shared by BOTH machines' web UIs
  server/             Debian server: encoders, relay, web UI
  pi/                 Raspberry Pi client: display loops, watchdog, web UI
```

`common/*.py` is deployed to `/opt/videowall/webui/` on both machines by each
installer. Do not duplicate it per-tree — it holds behavioural logic (ffprobe
error classification) that must not diverge between server and client.

## Architecture (v3)

```
cameras ──RTSP──► videowall-encode@<wall>  ──RTSP(loopback)──► MediaMTX ──SRT──► Pi 1
                  (one systemd instance          │                                Pi 2 …
                   per wall, ffmpeg xstack)      └── HTTP API ──► server web UI
```

- **A wall is data**, not code: `/etc/videowall/wall-<slug>.env` plus
  `cameras-<slug>.conf`. Any number of walls; one templated unit runs them all.
  `ENABLED=false` keeps a wall configured but stopped.
- **No per-wall ports.** A wall is addressed by *name* on the relay; every
  client reads one shared SRT port: `srt://<server>:8890?streamid=read:<wall>`.
- **The relay exists so several clients can watch one wall** — a raw ffmpeg SRT
  listener accepts exactly one connection.
- **Pi client**: one fullscreen mpv per HDMI output, plus a watchdog that
  monitors each player over mpv's JSON IPC socket and reconnects frozen or
  degraded streams in place.

## Working conventions

**There is no Python interpreter on the Windows dev machine.** Consequence:
no `.py` in this repo has ever been executed. Verify Python by (a) careful
review, and (b) porting the *algorithm* to Node and running it against
representative cases — that is how `probe_source()`'s classification and the
watchdog's detection logic were validated. Say plainly in commit messages and
to the user that the Python is unrun.

**Verify shell by dry-run harness, not by eye.** ffmpeg argument construction
is checked by replacing the final `exec ffmpeg` with a printer and inspecting
the generated filtergraph/output ordering. Do this for any change to
`videowall-encode.sh`.

**SIGPIPE is the local hazard.** Under `set -o pipefail`, a pipeline whose
*reader* exits early kills the *writer* with signal 13 → exit 141 → `set -e`
aborts with no message. This silently killed an installer mid-run. Never write
`cmd | head -c N` or `producer | grep -q` in these scripts; capture output to a
variable and match with `case`. Both installers carry an ERR trap that decodes
signals, so a repeat shows up as "killed by signal 13 = SIGPIPE".

**Installers are idempotent and have a `--check` mode** that runs preflight
only and changes nothing. They target minimal Debian VMs, so they repair a
PATH missing the sbin directories (the `su` vs `su -` trap) and check things a
stripped image tends to lack. Full transcript at
`/var/log/videowall-install.log`.

**Licensing**: Apache 2.0. Connection-monitoring code is ported from the
sibling `displaycameras-modern` project (a separate repo, typically at
`~/displaycameras-modern`). Anything further ported from it must be recorded
in `NOTICE`.

## Invariants worth not breaking

- **In `videowall-encode.sh`, the snapshot output must come AFTER the publish
  output.** ffmpeg derives `-progress`'s `frame=`/`fps=` from the *first* video
  output, so reordering silently makes the dashboard report the JPEG writer's
  rate as the encoder's.
- **The filtergraph fans out with `split`**, not a second `-map` of the same
  label (a label is consumed by the first `-map`). With VAAPI the split must
  happen *before* `hwupload`.
- **Wall slugs must satisfy the same regex in the UI and in `videowall-ctl`**
  (`^[a-z0-9][a-z0-9_-]{0,31}$`), or the UI can offer names the privileged
  helper will refuse.
- **The web UI never gets mpv socket access or raw camera URLs.** The Pi
  watchdog publishes a health file the UI reads; probe results carry redacted
  URLs, because UniFi Protect RTSP paths *are* the credential.
- **Probes use the configured `RTSP_TRANSPORT`.** ffprobe defaults to UDP-first
  while encoders use TCP; without this the probe tests a different transport
  than the thing being diagnosed.
- **mpv's `auto` hwdec does not engage the Pi's V4L2 decoder** — it silently
  falls back to software. Use `v4l2m2m-copy`.

## Security posture

Both UIs are plain HTTP + Basic Auth, intended to be reachable **over Tailscale
only**. Privileged actions go through narrow gates: on the server, one
root-owned `videowall-ctl` that validates verb and slug (sudoers grants only
that script); on the Pi, only `pkill -x -u videowall mpv`. The Pi holds a
read-only API token for the server, never the admin password.
