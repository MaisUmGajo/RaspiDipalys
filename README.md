# RaspiDipalys — RTSP video wall

Displays UniFi G3 Flex camera streams as two grids across a Raspberry Pi
4's two HDMI outputs: a 3x3 grid on a 4K display, a 2x2 grid on a 1080p
display. Three implementations, in separate subfolders, each self-contained
with its own README/install scripts:

## [`v1-standalone-pi/`](v1-standalone-pi) — everything on the Pi (archived)

One Raspberry Pi 4 does all the work: pulls all 13 camera streams, builds
both mosaics, decodes and displays them. Simplest to deploy (one machine),
but the Pi's single shared hardware decoder has to juggle 13 concurrent
sessions.

## [`v2-server-pi/`](v2-server-pi) — server does the compositing, Pi just displays (archived)

A Debian server ingests all 13 camera streams, builds both mosaics, and
publishes each as a single H.264 stream over SRT. The Pi just pulls the
two pre-built streams and decodes+displays one per output — 2 decode
sessions instead of 13. Covers connecting server and Pi across sites (e.g.
over Tailscale).

## [`v3-server-pi-webui/`](v3-server-pi-webui) — current: adds web UIs on both machines

Same split architecture as v2, plus a small web interface on **each**
machine:

- **Server UI** — edit each wall's camera list/bitrate/fps/port without
  SSH; live dashboard (server stats, per-encoder status, best-effort "is
  the Pi connected" indicator).
- **Pi UI** — edit the source-stream config, and **test each source
  before applying it**: it probes the address/port and reports whether
  it's reachable and whether a live stream is detected (codec/resolution/
  fps/bitrate). Plus a Pi stats/display-status dashboard.

Start with whichever version you're actually deploying — each folder's
README has full setup instructions.
