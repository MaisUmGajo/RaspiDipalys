# Video Wall v2 — server + Pi split

Splits the work across two machines instead of doing everything on the Pi
(see [`../v1-standalone-pi`](../v1-standalone-pi) for the all-in-one version):

- **`server/`** — a Debian server ingests all 13 UniFi G3 Flex RTSP streams,
  composites them into two mosaics (3840x2160 3x3, 1920x1080 2x2),
  H.264-encodes each, and publishes them over the network.
- **`pi/`** — the Raspberry Pi 4 just pulls the two already-composited
  streams and decodes+displays one per HDMI output. No compositing, no
  scaling, no per-camera decode on the Pi at all.

This moves the demanding part — 13 concurrent decodes + scaling +
compositing — onto hardware that isn't sharing a single mobile-class
decoder block, and leaves the Pi with the lightest possible job: two decode
sessions, direct to screen.

## Why this is lower-risk than the all-in-one Pi version

The Pi 4's biggest constraint is its single shared V4L2 M2M hardware
decoder. In v1 that block has to juggle up to 13 concurrent sessions; here
it only ever does 2. The Pi also no longer runs `ffmpeg` at all — `mpv`
decodes each incoming stream straight to display. The tradeoff is
operational, not technical: now there are two machines to keep running
instead of one, and a network hop with real bandwidth/latency in between.

## Transport: SRT

The server publishes each mosaic as H.264-in-MPEG-TS over **SRT**
(`srt://`), with the server in `listener` mode (it waits, doesn't need to
know the Pi's IP) and the Pi's mpv as `caller` (it connects out to the
server). SRT gives packet-loss recovery and automatic reconnection on top
of plain UDP, while still being handled entirely by ffmpeg/mpv's own
libsrt support — no extra relay server/daemon to install or maintain.

**Check both machines have SRT support before relying on this** (both
install scripts do this automatically and warn if not):
```bash
ffmpeg -hide_banner -protocols | grep -i srt
```
If it's missing on either end, the fallback is plain UDP/MPEG-TS — change
the server's `-f mpegts "srt://0.0.0.0:${PORT}?mode=listener&..."` to
`-f mpegts "udp://<pi-ip>:${PORT}"` in `server/bin/videowall-encode.sh`,
and the Pi's `srt://...` mpv URL to `udp://@:${PORT}`. You lose automatic
reconnect and loss recovery, and the server now needs to know the Pi's
static IP up front — otherwise the pipeline is identical.

## Bandwidth / latency expectations

Each mosaic is H.264 at a modest bitrate (8 Mbps default for the 4K wall,
4 Mbps for 1080p — set in the two `videowall-encode-*.service` files), for
12 Mbps combined, sustained, 24/7. On a shared LAN that's trivial; **use
wired Ethernet for the Pi** either way, since a flaky Wi-Fi link is the
most common source of "why did the wall freeze" incidents in setups like
this. If server and Pi are at different sites (see the Tailscale section
below), that 12 Mbps has to fit through both sites' actual internet
uplinks, which is a much tighter budget than a LAN.

End-to-end latency is roughly: camera→server RTSP buffering + compositing
+ x264 encode latency + `SRT_LATENCY_MS` + mpv decode, plus whatever the
network path between server and Pi adds. On a LAN, total is on the order
of half a second to a second. Across sites over the open internet, expect
more, and more variable — fine for a monitoring wall, not for anything
requiring frame-accurate sync.

## Connecting server and Pi across sites (e.g. over Tailscale)

If the server and Pi aren't on the same LAN, this design still works
unchanged — SRT is just UDP, and something like Tailscale (WireGuard)
tunnels UDP transparently, so `mode=listener`/`mode=caller` don't care.
A few things change in practice, though:

- **`SERVER_HOST`**: use the server's Tailscale IP (`100.x.y.z`) or
  MagicDNS name in `/etc/videowall/pi.env` — stable across either box
  changing physical networks, and no router port-forwarding needed.
- **Direct vs relay — this is the main risk**: Tailscale prefers a direct
  peer-to-peer path between the two nodes, in which case overhead is
  negligible. But if either site's NAT/firewall won't allow that (common
  with CGNAT, symmetric NAT, or a locked-down office firewall), it falls
  back to relaying through Tailscale's DERP servers over the public
  internet. That turns your 12 Mbps combined video into 12 Mbps hitting
  *both* sites' internet links continuously, plus a real latency penalty
  from the relay hop. After deploying, check which you actually got:
  ```bash
  tailscale status
  ```
  and look for `direct` vs a relay (`relay "xx"`) in the peer's connection
  info. If you're stuck on relay and it's costing you too much
  latency/bandwidth, Tailscale supports self-hosting a `derper` relay
  closer to both sites — worth it only if this becomes a real problem.
- **Check your actual uplink before trusting the default bitrates**: the
  server's *upload* capacity at its site is what matters most — it has to
  sustain ~12 Mbps out continuously. Run a speed test at both sites and
  keep committed video bitrate to a comfortable fraction (not 100%) of
  measured upload, so it doesn't compete with everything else on that
  link. If it doesn't fit, lower `BITRATE_KBPS` in the two
  `/etc/systemd/system/videowall-encode-*.service` files (e.g. 4000/2000
  instead of 8000/4000) and/or lower `FPS` in `videowall-server.env` —
  both directly trade off against the bitrate you need.
- **Bump `SRT_LATENCY_MS`**: the shipped default (400ms) assumes a
  real internet path, not a LAN — raise it further (700-1000) if you see
  stuttering or artifacts and `tailscale ping` shows meaningfully more
  than a few ms between the two sites.
- No extra encryption needed on top of SRT's own `passphrase` option —
  Tailscale already encrypts the whole path end-to-end.

## Setup order

**Server first, then Pi** — the Pi's mpv just retries every 2s if it can't
connect, so booting it before the server is up is harmless but pointless.

1. On the Debian server:
   ```bash
   cd server
   sudo ./install.sh
   sudo nano /etc/videowall/cameras-4k.conf      # 9 RTSP URLs
   sudo nano /etc/videowall/cameras-1080p.conf   # 4 RTSP URLs
   sudo systemctl enable --now videowall-encode-4k.service
   sudo systemctl enable --now videowall-encode-1080p.service
   journalctl -u videowall-encode-4k -f   # confirm it's running without errors
   ```
2. On the Raspberry Pi:
   ```bash
   cd pi
   sudo ./install.sh
   sudo nano /etc/videowall/pi.env   # set SERVER_HOST
   ```
   Then follow the connector-name verification steps `install.sh` prints
   (same caveat as v1 — DRM connector names vary by driver version and must
   be confirmed with `xrandr` before the dual-screen Xorg config can be
   trusted) and reboot.

## Tuning / troubleshooting

- **Server CPU**: `videowall-server.env`'s `FPS` (default 15) is the main
  lever — compositing + `libx264` encode of two mosaics at high fps is the
  server's real cost. If the server has an Intel iGPU, set `VAAPI=1` to
  offload encode via VAAPI (requires `/dev/dri/renderD128` to exist and
  VAAPI drivers installed — test this after enabling, vaapi encode option
  compatibility varies by driver/ffmpeg version).
- **Bitrate**: edit the `ExecStart` line in the relevant
  `/etc/systemd/system/videowall-encode-*.service`, then
  `systemctl daemon-reload && systemctl restart videowall-encode-4k`.
- **Pi decode**: `pi.env`'s `HWDEC` defaults to the safe `v4l2m2m-copy`.
  Since the Pi only decodes one stream per screen now, try the zero-copy
  `v4l2m2m` mode for lower CPU — revert if a screen goes blank.
- **Firewall**: on a plain LAN, SRT rides over UDP on the ports you chose
  (6000/6001 by default) even though the URL scheme says `srt://` — open
  those as UDP, not TCP, on the server. Over Tailscale, you don't need to
  open anything on the server's normal network interface at all — traffic
  arrives via the `tailscale0` interface, so if a local firewall is active,
  scope any rule to that interface rather than opening the ports globally.

## What I couldn't verify without the actual hardware/network

- Whether your specific Debian server's and Raspberry Pi OS's ffmpeg
  builds include libsrt — check with the command above before depending on
  it; the UDP fallback is documented if not.
- Real-world CPU load on the server for 13 concurrent decodes + 2 x264
  encodes — depends entirely on the server's actual CPU, hence `FPS` and
  `VAAPI` being exposed as tunables rather than fixed.
- Exact DRM connector names on the Pi (same caveat as v1).
- Whether Tailscale will establish a direct connection or fall back to
  DERP relay between your two specific sites, and each site's actual
  spare upload/download capacity — both determine whether the default
  bitrates are usable as-is or need lowering (see the Tailscale section
  above).
