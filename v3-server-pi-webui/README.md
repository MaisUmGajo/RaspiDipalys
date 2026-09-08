# Video Wall v3 — server + Pi + web UIs

Builds on [`../v2-server-pi`](../v2-server-pi) (now archived) by adding a
small web interface on **both** machines.

**Server web UI** (`server/webui/`) — for:

- **Configuring** each wall's camera list, grid size, canvas resolution,
  SRT port, bitrate and fps, plus the shared transport/latency/VAAPI
  settings — without SSHing in and hand-editing files or systemd units.
- **Runtime status**: server CPU/memory/temperature/uptime, each
  encoder's systemd state and restart count, and live encode stats
  (frame count, fps, bitrate, speed) read straight from ffmpeg.
- **Client info, best-effort**: whether the Pi is actually connected and
  pulling each stream. See the honesty note below — this is
  connected/not-connected only, not per-client detail.

**Pi (client) web UI** (`pi/webui/`) — for:

- **Configuring** the source streams: server host, the two SRT ports, SRT
  latency and hardware-decode mode — without hand-editing `pi.env`.
- **Testing a source before applying it**: a "Test this source" button
  probes the address/port and reports whether it's reachable *and* whether
  a live video stream is actually being published there (with detected
  codec / resolution / fps / bitrate). Also tests arbitrary
  srt/rtsp/udp/http URLs — handy for checking a camera feed directly.
- **Runtime status**: Pi CPU/memory/temperature/uptime and whether each
  screen's display process is currently running.

The Pi's display path (dual-screen Xorg, autologin, mpv) is otherwise the
same as v2 — the only change is that each display loop now re-reads
`pi.env` on every reconnect, so the web UI can apply a config change by
just restarting the mpv processes (no reboot).

## What changed on the server vs v2

`server/bin/videowall-encode.sh` used to take its grid size, canvas
resolution, port and bitrate as positional arguments baked into each
`videowall-encode-*.service` unit's `ExecStart` line — fine for a
one-time setup, awkward for a web UI to edit safely (it would need to
rewrite systemd units and reload the daemon on every change). Now each
wall's settings live in their own file:

- `/etc/videowall/wall-4k.env`, `/etc/videowall/wall-1080p.env` — rows,
  cols, canvas size, port, bitrate, fps, and which camera list file to use.
- `/etc/videowall/videowall-server.env` — shared settings: RTSP
  transport, SRT latency, VAAPI toggle (same as v2).

The systemd units are now static (`ExecStart=.../videowall-encode.sh 4k`)
and never need touching again — the web UI (or you, by hand) only ever
edits the `.env`/`.conf` files in `/etc/videowall/` and restarts the
corresponding service.

`videowall-encode.sh` also now passes `-progress /run/videowall/progress-<wall>.txt`
to ffmpeg, which is how the web UI gets live frame/fps/bitrate numbers —
see `read_progress()` in `server/webui/app.py`. `/run/videowall` is
created automatically by the systemd units' `RuntimeDirectory=` directive.

## The server web UI

A small Flask app (`server/webui/app.py`, plain server-rendered HTML —
no JS framework, no build step) served by `gunicorn`:

- `/` — dashboard: server stats + per-wall status, auto-refreshing every
  3s via a `fetch()` poll against `/api/status`.
- `/config` — edit each wall's settings and camera list, and the shared
  global settings. Saving validates the input (camera count must equal
  rows×cols, numeric ranges checked) and, on success, restarts exactly
  the affected encoder service(s).

### Honesty note: "client connected" is inferred, not measured

ffmpeg doesn't expose per-client SRT statistics (connected IP, RTT,
packet loss) through any simple API. What it does do: in `mode=listener`,
ffmpeg's SRT output blocks opening (and therefore blocks the whole
pipeline from producing frames) until a client actually connects. So the
dashboard treats "the progress file was updated in the last 5 seconds"
as a reasonable stand-in for "the Pi is connected and actively pulling
this stream" — accurate for connected/not-connected, but it cannot tell
you *who* is connected, their link quality, or how many clients (SRT
listener mode here only ever expects one). Getting real per-client stats
would mean replacing the ffmpeg listener with `srt-live-transmit` (from
the `srt-tools` package) and its `-statsfile` output — deliberately not
done here to keep this "small," as asked; worth doing later if you need
real RTT/loss numbers.

## The Pi (client) web UI

A second small Flask app (`pi/webui/app.py`, same style, also `gunicorn`
on port 8080 of the Pi):

- `/` — dashboard: Pi stats + whether each screen's mpv display process is
  currently running.
- `/config` — set server host, the two SRT ports, SRT latency and the mpv
  hardware-decode mode, with a **"Test this source"** button per stream and
  a free-form URL tester. "Save only" rewrites `pi.env`; "Save & apply"
  additionally restarts the displays so the change takes effect at once.

### How the source test works (and its honest limits)

The test runs `ffprobe` against the source URL with a timeout and reports
two things the way you asked — *is the address/port reachable* and *is a
stream actually detected*:

- For an SRT source, one `ffprobe` does both jobs at once: completing the
  SRT caller handshake proves the address/port is reachable, and reading
  stream metadata proves something is really being published there (it
  reports the detected codec / resolution / fps / bitrate). If the
  handshake never completes, ffprobe's error tells us the port isn't
  reachable; if it connects but no video stream is found, that's reported
  distinctly. See `probe_source()` in `pi/webui/app.py`.
- **Why there's no separate raw UDP "port open?" check**: SRT rides over
  UDP, and a bare UDP port probe is meaningless — a silent (open) UDP port
  and a firewalled one look identical from outside, so it would produce
  confident-but-wrong answers. The SRT handshake via ffprobe is the only
  reliable reachability signal, which is why reachability and
  stream-detection are tested together rather than as two independent
  network checks.
- **Single-listener caveat**: the server publishes each wall in SRT
  `listener` mode, which accepts exactly one connection. While a wall is
  actually being *displayed*, the Pi's mpv already holds that one slot, so
  the web UI does **not** fire a second probe at it (that would be refused
  and tells you nothing) — instead it reports that the live display itself
  already confirms the source is reachable and streaming, and notes you can
  stop the display to run a full codec/resolution probe. So: run the test
  during setup/troubleshooting, before that wall's display has connected,
  to get the full stream details.

## Security

- **Auth**: HTTP Basic, credentials in `/etc/videowall/webui.env`
  (`WEBUI_PASSWORD_HASH` — only ever stored hashed). Each machine's
  `install.sh` generates its own random password on first install and
  prints it once. The server and Pi have independent logins.
- **Least-privilege actions**: each web UI runs as its own system user
  (`videowall-web`), separate from the `videowall` user that runs the
  encoders / displays, and each gets an exact-match `sudoers.d` rule with
  no wildcards:
  - Server (`server/sudoers/videowall-webui`): may only restart/inspect
    the two specific encoder services.
  - Pi (`pi/sudoers/videowall-pi-webui`): may only run
    `pkill -x -u videowall mpv` (the "restart displays" action) — nothing
    else as root. The stream test (`ffprobe`) and reading process state
    need no privilege at all.
- **Network exposure**: bind both UIs to Tailscale only, not the open
  internet — there's no TLS here (plain HTTP + Basic Auth), which is fine
  inside an already-encrypted Tailscale tunnel but not otherwise. If a
  firewall is active on either box, only allow TCP 8080 from your tailnet.
- **No CSRF protection**: the config forms (on both UIs) don't use CSRF
  tokens. Given Basic Auth + Tailscale-only exposure, the practical risk
  is low (worst case: an attacker who can get your browser to submit a
  request changes a camera URL or bitrate — annoying, not a compromise),
  but it's a real gap if you ever exposed this more broadly. Not fixed
  here to keep the apps small; would mean pulling in Flask-WTF or
  hand-rolling tokens.
- **Fresh-install assumption**: both `install.sh` scripts assume a fresh
  machine. If you already have v2 running on the same box, review the
  user/group setup before re-running — they don't migrate an existing
  `videowall` user's config.

## Setup

Same order as v2 — server first, then Pi:

```bash
cd server
sudo ./install.sh
# edit /etc/videowall/cameras-4k.conf and cameras-1080p.conf, or do this
# from the web UI after starting it
sudo systemctl enable --now videowall-encode-4k.service
sudo systemctl enable --now videowall-encode-1080p.service
sudo systemctl enable --now videowall-webui.service
```

Then open `http://<server>:8080/` (over Tailscale) and log in with the
credentials the server's `install.sh` printed.

On the Pi:

```bash
cd pi
sudo ./install.sh
```

The Pi's `install.sh` prints its own admin password and enables the Pi web
UI automatically. After it finishes you can either edit `/etc/videowall/pi.env`
by hand or open `http://<pi>:8080/` (over Tailscale) and use the **Config &
test** page — set the server host and ports, click "Test this source" on
each to confirm the server is reachable and streaming, then "Save & apply".
The rest of the Pi setup (confirming DRM connector names with `xrandr`,
forcing modes via `cmdline.txt`, rebooting) is unchanged from v2 and is
printed by the installer.

## What I couldn't verify without the actual hardware/network

- Everything already listed in v2's README (SRT/libsrt availability, real
  CPU load under 13 concurrent decodes, DRM connector names, Tailscale
  direct-vs-relay behavior) still applies here — nothing about the web UI
  changes those.
- Whether ffmpeg's SRT listener really blocks output-open until a client
  connects is based on well-documented general behavior for
  connection-oriented network output protocols, not something tested
  against your specific ffmpeg build — worth confirming once deployed
  (start an encoder with no Pi connected, check the dashboard shows
  "waiting for connection", then start the Pi and confirm it flips to
  "connected").
- The Pi source-test interpretation logic (reachable vs. no-stream vs.
  unreachable, and the fps/bitrate parsing) was validated against
  representative ffprobe outputs, but the exact ffprobe error strings your
  build emits for each failure may differ — if a genuinely-unreachable
  source is ever mislabeled "reachable, no stream", add that build's error
  text to `_UNREACHABLE_HINTS` in `pi/webui/app.py`.
- The "already displaying → skip the probe" shortcut depends on the web UI
  being able to see the `videowall` user's mpv processes via `/proc`. That
  works on a stock Raspberry Pi OS; if you've hardened `/proc` with
  `hidepid`, the probe would run anyway and likely be refused by the
  server's single SRT listener — harmless, but it would report the live
  wall as unreachable, so test with that wall's display stopped.
