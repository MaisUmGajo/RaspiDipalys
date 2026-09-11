# Video Wall v3 — server + Pi clients + web UIs

Builds on [`../v2-server-pi`](../v2-server-pi) (archived). A Debian server
composites camera feeds into mosaics and relays them; one or more Raspberry Pi
clients display them, one wall per HDMI output. Both machines have a small web
UI.

```
cameras (RTSP) ─┐
                ├─► videowall-encode@<wall>  ──RTSP (loopback)──► MediaMTX ──SRT──► Pi 1
cameras (RTSP) ─┘   (one instance per wall)                          │              Pi 2 …
                                                                     └── HTTP API ──► server web UI
```

## What this version adds over v2

**Any number of walls, not a fixed pair.** A wall is just a
`/etc/videowall/wall-<slug>.env` file plus a camera list. One templated systemd
unit (`videowall-encode@.service`) runs them all, so adding a wall creates no
new unit files. Walls can be **configured but not running** (`ENABLED=false`)
— settings and camera list retained, service stopped and not started at boot.

**Multiple clients per wall,** via a MediaMTX relay. This is why the relay
exists: a raw ffmpeg SRT listener accepts *exactly one* connection, so
previously only one Pi could ever watch a wall. Encoders now publish once into
MediaMTX, which fans each wall out to as many subscribers as you like, and they
can reboot independently without disturbing the encoder or each other.

**No per-wall ports.** A wall is addressed by *name* on the relay, so every
client reads from one shared SRT port:

```
srt://<server>:8890?streamid=read:<wall>&latency=<ms>
```

**Server web UI** — create/edit/enable/disable/delete walls; live dashboard
with server stats, per-encoder state, a mosaic snapshot, and per-camera
diagnostics.

**Pi web UI** — pick which wall feeds each HDMI output from a dropdown of what
the server actually offers, test a source before applying, and see per-output
status.

## The server web UI

- `/` — dashboard, polling `/api/status` every 3s: server stats, and per wall
  its enabled state, systemd state, restart count, encoder fps/bitrate, who is
  connected, and a **mosaic snapshot** with a cell-grid overlay numbering each
  cell in camera-list order (so a mis-placed or black tile is obvious).
- `/config` — per-wall settings and camera list, wall creation and deletion,
  enable/disable, and the global settings (RTSP transport, SRT latency, VAAPI,
  relay endpoints, snapshot options).
- **"Check feeds"** — probes each of a wall's cameras in parallel and lays the
  results out in that wall's own grid shape, so a red tile sits where you'd
  look on the actual wall.

### The snapshot

Tee'd off the existing encode pipeline (`split` inside the filtergraph), so it
costs no extra camera connections and no extra decoding — only a small JPEG
encode every `SNAPSHOT_INTERVAL_S`. Because encoders now *publish* to a
listening relay rather than waiting for a client to connect, **the snapshot
works even with no client watching**. `SNAPSHOT=0` is a kill switch that
reverts the pipeline to exactly its previous shape.

### Client info is measured, not inferred

Earlier versions guessed "is a client connected?" from the freshness of
ffmpeg's progress file, because ffmpeg cannot report anything about SRT peers.
The relay can: the dashboard reads MediaMTX's API for real reader counts,
client addresses and bytes sent. If the relay itself is unreachable the UI says
so, rather than implying nobody is watching.

### What the per-camera probe can and cannot tell you

It runs `ffprobe` against each camera URL and reports two things separately —
is the address/port reachable, and is a stream actually being published —
plus the detected codec/resolution/fps.

- It uses the **same RTSP transport as the encoder** (`RTSP_TRANSPORT`).
  Without that, ffprobe would default to UDP-first while the encoder uses TCP,
  and a camera could pass the probe yet still break the wall.
- There is a third **inconclusive** state, for a host that answers but sends no
  stream in time. Forcing that into "unreachable" was misleading when triaging
  nine cameras.
- It is **on demand only**, never on the dashboard poll, with a cooldown: each
  probe opens another short-lived RTSP connection per camera on the Protect
  controller, on top of the permanent ones the encoders hold.
- Camera URLs are **redacted** in responses and raw ffprobe stderr is never
  returned — UniFi Protect RTSP paths are themselves credentials.
- Why no raw UDP "is the port open?" test: for SRT/UDP a silent open port and a
  firewalled one are indistinguishable from outside, so it would produce
  confident wrong answers. The SRT handshake is the only honest signal, which
  is why reachability and stream detection are tested together.

**Useful to know:** a dead camera usually takes down the *whole* wall, not one
cell — `xstack` needs all its inputs, so when one RTSP source ends the encoder
exits and systemd restarts it. So the symptom of one bad feed is a climbing
restart count, and the probe is what tells you *which* URL is at fault. That is
also why there's no automated black-cell detection: it would be unavailable
exactly when the wall is broken.

## The Pi (client) web UI

- `/` — Pi stats and per-output status (which wall, and whether mpv is running).
- `/config` — server host, relay port, read-only API token, a **wall dropdown
  per output** populated from the server, SRT latency, and hardware decode
  mode. "Test this source" probes the selected wall; "Save & apply" restarts
  the displays.

Applying config needs no reboot: each display loop re-reads `pi.env` on every
reconnect, so applying is just restarting the mpv processes. If the server is
unreachable the dropdowns degrade to free-text boxes, so the Pi is never
unconfigurable because of a server outage.

Because the relay allows many readers, testing a wall works **even while it is
on screen** — the probe is simply one more subscriber.

## Security

- **Auth**: HTTP Basic on both UIs, password stored only as a hash in
  `/etc/videowall/webui.env`. Each machine has its own independent login, and
  each installer prints its password once.
- **Client token**: the server also issues a **read-only bearer token** that
  authorises only `/api/walls`. Pis hold that, never the admin password.
- **Least privilege**: each UI runs as its own `videowall-web` account,
  separate from the `videowall` account that runs encoders/displays.
  - Server: sudoers grants exactly one root-owned script,
    `/usr/local/sbin/videowall-ctl`, which validates its verb against an
    allowlist and its wall name against a strict slug pattern before touching
    systemd. Dynamic wall names can't be enumerated in sudoers, so the
    validation lives in code rather than in sudoers glob matching. Keep that
    script root-owned and not writable by `videowall-web` or it stops being a
    gate.
  - Pi: sudoers grants only `pkill -x -u videowall mpv` (the "restart
    displays" action). Probing and reading status need no privilege at all.
- **Relay exposure**: MediaMTX's RTSP publish port and HTTP API are bound to
  **loopback**; only the SRT read port (8890) is reachable from the network.
  Subscribing is unauthenticated, which is fine while that port is only
  reachable over Tailscale but is **not** safe to expose to the internet.
- **Network**: bind both UIs and the relay's read port to Tailscale only.
  There's no TLS here (plain HTTP + Basic Auth), which is acceptable inside an
  encrypted tunnel and nowhere else. Scope firewall rules to `tailscale0`
  rather than opening ports globally.
- **No CSRF tokens** on the config forms. Given Basic Auth plus Tailscale-only
  exposure the practical risk is low (worst case someone tricks your browser
  into changing a bitrate), but it is a real gap if ever exposed more broadly.
- Both installers assume a **fresh machine**; they don't migrate an existing
  v2 install's users/config.

## Setup

Clone the **whole repo** on each machine — the installers deploy shared Python
helpers from `common/`.

Server first:

```bash
cd server
sudo ./install.sh          # prints the admin password + client read token
sudo systemctl enable --now mediamtx.service
sudo systemctl enable --now videowall-encode@4k.service
sudo systemctl enable --now videowall-encode@1080p.service
sudo systemctl enable --now videowall-webui.service
```

`install.sh` will **refuse to install an unverified MediaMTX binary**: it
downloads the pinned release, prints the SHA256, and stops so you can check it
against the release page, then re-run with `MEDIAMTX_SHA256=<hash>`. You can
also pre-stage the tarball in `/opt/videowall/dist/`.

Then each Pi:

```bash
cd pi
sudo ./install.sh
```

Open `http://<pi>:8080/`, set the server host, paste the read token, pick a
wall per output, test, and apply. The DRM connector-name and forced-mode steps
are unchanged and printed by the installer.

A new wall needs no files by hand — create it in the server UI, which writes
the config and enables `videowall-encode@<name>.service` for you.

## Client hardware

The client assumes a **Raspberry Pi 4**: two HDMI outputs, 64-bit Raspberry Pi
OS, and enough headroom to run Xorg, mpv and a Flask web UI at once.

**Older boards (Pi Zero W, Pi 1) are not supported yet** — deliberately
deferred until the Pi 4 client is proven on hardware. What it would take,
recorded so this doesn't need re-deriving:

- **One HDMI output, one stream — no parallel decode is in scope.** These
  boards are only ever expected to display a single wall, so the work is
  "support an output count of 1", not "support N". The two display loops, the
  `OUTPUTS` map in `pi/webui/app.py`, and especially `xorg-dualhead.conf` are
  all wrong there — its `ZaphodHeads "HDMI-A-2"` names a connector that
  doesn't exist, which would fail or leave a dead screen.
  Usefully, this means the decode ceiling is set by ONE stream's resolution,
  which is a server-side config choice (make a small wall), not a client
  limitation to engineer around.
- **`gpu_mem=256` in `config.txt.append` is actively harmful there.** On a
  512MB Zero W it leaves 256MB for Linux, which will not comfortably hold X +
  Python + mpv. Needs ~64–128 on those boards. `max_framebuffers=2` and the
  second `hdmi_force_hotplug:1=1` are also meaningless with one output.
- **Drop X entirely on single-output boards.** With one output there's no need
  for X's multi-screen handling: mpv can render straight to KMS with
  `--vo=drm`, removing Xorg and unclutter, and avoiding the GL path (VideoCore
  IV's GLES2 through Mesa is slow). Pair with `--hwdec=v4l2m2m` rather than
  `-copy`, so frames go zero-copy via DRM PRIME instead of being memcpy'd by a
  single core. That also replaces the autologin→startx dance with a plain
  systemd service — lighter *and* simpler.
- **`--workers 2` is too many** for gunicorn on 512MB; use 1, or skip the web
  UI on such boards.
- **ARMv6/32-bit**: BCM2835 needs Raspberry Pi OS **32-bit**. The 64-bit image
  won't boot, and Debian's own armhf port requires ARMv7. Tailscale's ARMv6
  build would need verifying too.
- **No networking at all** on Pi Zero (non-W) and Pi 1 Model A — they cannot
  be clients. Zero W is 2.4GHz Wi-Fi on a shared USB bus; Pi 1 B/B+ has
  100Mbit Ethernet.
- **Expect it to be marginal.** BCM2835's decoder tops out near 1080p30
  H.264, so ~720p at 10–15fps is the realistic target. Note the efficient
  legacy path (omxplayer / MMAL / dispmanx) was *removed* in Bookworm, so
  modern mpv + V4L2 M2M + DRM is heavier than what made these boards good
  video players years ago. A Pi Zero 2 W avoids nearly all of this.

**The server needs no changes for small clients** — create a small wall (e.g.
`zero` at 1280x720, 2x2, 10fps) and point the board at it. That is
configuration, not code.

## Failure modes worth recognising

| Symptom | Meaning |
|---|---|
| Wall shows "config error" | camera count ≠ rows × columns; the encoder exits 78 and stops cleanly instead of restart-looping |
| Restart count climbing | one camera feed is dropping and taking the wall with it — run "Check feeds" |
| "relay unreachable" | `mediamtx.service` is down; nothing can be published or watched |
| "encoder up, not publishing" | encoder running but the relay has no stream for it yet |
| Snapshot dimmed / "stale" | no fresh frame recently — usually the encoder isn't running |
| Probe says "inconclusive" | host answered, no stream in time — not the same as unreachable |

## What I couldn't verify without the hardware

- **None of the Python has been executed** — there was no interpreter on the
  machine this was written on. Shell syntax, Jinja block balance and config-key
  agreement across scripts/UIs/examples were checked statically, and the
  filtergraph and privilege gate were exercised with dry-run harnesses, but
  both Flask apps still need a real first run.
- **MediaMTX's config schema** varies across versions. The shipped
  `mediamtx.yml` targets v1.x and MediaMTX validates on startup, so a mismatch
  appears immediately in `journalctl -u mediamtx`; the installer keeps
  upstream's reference config at `/etc/videowall/mediamtx.reference.yml` for
  diffing. The API field names the dashboard reads (`/v3/paths/list`,
  `/v3/srtconns/list`) are likewise version-sensitive.
- **`-atomic_writing` availability** on your ffmpeg build — the installer warns
  if the option is missing, and `SNAPSHOT=0` is the escape hatch.
- Whether ffprobe's error strings on your build all match the classifier's
  hints; if a genuinely unreachable source is ever labelled "inconclusive", add
  that text to `_UNREACHABLE_HINTS` in `common/probe.py` (and reinstall on both
  machines, since both use it).
- Everything from v2's README still applies: real CPU load under many
  concurrent decodes, DRM connector names, and Tailscale direct-vs-relay
  behaviour.
