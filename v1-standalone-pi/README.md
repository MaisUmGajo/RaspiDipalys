# Video Wall — Raspberry Pi 4 dual-output RTSP wall

Dedicated single-purpose appliance: a Raspberry Pi 4 boots straight to two
independent HDMI outputs, each showing a live grid of UniFi G3 Flex camera
streams. No desktop, no login prompt, no other tasks on this Pi.

- **HDMI0 → 4K display**: 3x3 grid (9 cameras), "medium" quality stream.
- **HDMI1 → 1080p display**: 2x2 grid (4 cameras), "low" quality stream.

## How it works

- Raspberry Pi OS **Lite** (64-bit, Bookworm) — no desktop environment.
- One Xorg server is configured with **two independent "Zaphod" screens**,
  each pinned to one physical HDMI connector (`/etc/X11/xorg.conf.d/10-dualhead.conf`).
  Because each screen has exactly one client, there's no need for a window
  manager or manual window placement — whatever runs on `:0.0` simply *is*
  the 4K output, and `:0.1` *is* the 1080p output.
- For each output, one `ffmpeg` process pulls in all of that wall's RTSP
  streams, hardware-decodes them (Pi 4's V4L2 M2M decoder), scales +
  letterboxes each into a uniform cell, and tiles them into a single mosaic
  frame with the `xstack` filter. The composited video is piped as raw
  frames straight into `mpv`, which just displays it fullscreen — `mpv`
  does no compositing work itself.
- The Pi boots to a console, autologins as a dedicated `videowall` user,
  whose `.bash_profile` starts X, whose `.xinitrc` launches both
  `ffmpeg | mpv` pipelines (`bin/videowall-grid.sh`), each wrapped in a
  restart loop so a camera reboot or network blip only drops that one wall
  for a couple of seconds instead of the whole thing.

## Repo layout

```
install.sh                          installs packages, users, configs, autologin
bin/videowall-grid.sh                builds+runs one wall's ffmpeg|mpv pipeline
config/xorg-dualhead.conf            -> /etc/X11/xorg.conf.d/10-dualhead.conf
config/config.txt.append             appended into /boot/firmware/config.txt
config/cameras-4k.conf.example       -> /etc/videowall/cameras-4k.conf   (9 URLs)
config/cameras-1080p.conf.example    -> /etc/videowall/cameras-1080p.conf (4 URLs)
config/videowall.env.example         -> /etc/videowall/videowall.env    (tunables)
home/xinitrc                         -> ~videowall/.xinitrc
home/bash_profile                    -> ~videowall/.bash_profile
```

## Dependencies

Everything below is installed automatically by `install.sh`, listed here so
you know what's actually running on the appliance:

| Package | Why |
|---|---|
| `xserver-xorg`, `xserver-xorg-legacy` | Minimal X server + console-user permission to start it without a login manager |
| `x11-xserver-utils` | `xset` — disables screen blanking/DPMS |
| `xinit` | `startx` |
| `mpv` | Fullscreen display of the composited video |
| `ffmpeg` | RTSP ingest, hardware decode, scaling, grid compositing (`xstack`) |
| `unclutter` | Hides the mouse cursor (there is no mouse, but X still draws one) |
| `libraspberrypi-bin` | `vcgencmd`, useful for thermal/clock diagnostics while tuning |

No desktop environment, display manager, or window manager is installed —
none of them are needed for this design.

## Setup

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. In the
   imager's advanced options, enable SSH and set hostname/locale — you'll
   want SSH for initial setup even though the Pi runs headless-of-keyboard
   afterwards.
2. Copy this repo onto the Pi (`git clone`/`scp`), then:
   ```bash
   cd RaspiDipalys
   sudo ./install.sh
   ```
3. Edit the two camera lists with your real streams:
   ```bash
   sudo nano /etc/videowall/cameras-4k.conf      # 9 RTSP URLs
   sudo nano /etc/videowall/cameras-1080p.conf   # 4 RTSP URLs
   ```
   Get the URLs from **UniFi Protect → camera → Settings → RTSP**: enable
   the "Medium" alias for the 9 cameras on the 4K wall and the "Low" alias
   for the 4 cameras on the 1080p wall. Each enabled quality tier gets its
   own URL, of the form `rtsp://<protect-host>:7447/<alias>`.
4. Connect both monitors and reboot.
5. **Confirm the DRM connector names** before trusting the dual-screen
   config — they vary by kernel/driver version (`HDMI-1`/`HDMI-2` vs
   `HDMI-A-1`/`HDMI-A-2`). After first boot, log in as `videowall` and run:
   ```bash
   DISPLAY=:0 xrandr
   ```
   If the names don't match `HDMI-1`/`HDMI-2`, edit the two `ZaphodHeads`
   lines in `/etc/X11/xorg.conf.d/10-dualhead.conf` and reboot again.
6. If a monitor isn't coming up at the resolution you expect via EDID
   negotiation, force it in `/boot/firmware/cmdline.txt` (single line,
   space-separated, using the connector names from step 5):
   ```
   video=HDMI-A-1:3840x2160@30 video=HDMI-A-2:1920x1080@60
   ```

From then on the Pi boots straight into the wall with no interaction
required.

## Tuning / troubleshooting performance

Decoding + scaling + compositing **13 simultaneous streams** (9 + 4) on one
Pi 4 is genuinely demanding, and the right settings depend on your actual
camera stream resolutions/bitrates (check them in Protect's stream quality
settings). Everything tunable lives in `/etc/videowall/videowall.env`:

- **`FPS`** (default 12) — lower this first if the wall stutters. A
  surveillance monitoring wall doesn't need 30fps; 8–15fps is usually
  indistinguishable in practice and directly cuts decode/scale/compositing
  load.
- **`HWDECODE`** (default 1) — the Pi 4 has a *single shared* hardware H.264
  decoder block. It may not cleanly handle 13 concurrent sessions even
  though each stream individually is small. If streams stall, error, or
  drop frames, try `HWDECODE=0` — software-decoding several low-resolution,
  low-fps streams on the Pi's 4 CPU cores is often *more* reliable than
  contending for one shared hardware decoder, even though it sounds
  counterintuitive.
- **`RTSP_TRANSPORT`** — `tcp` (default) avoids UDP packet-loss artifacts;
  switch to `udp` only if you need lower latency and your network is solid.
- If the 4K wall alone is too much, drop it to displaying the "low" tier
  instead of "medium" (edit `cameras-4k.conf` to point at low-quality
  aliases) — the destination canvas is what matters for perceived quality
  in a 9-way small grid, not the source resolution.

Watch `top`/`vcgencmd measure_temp`/`vcgencmd get_throttled` while tuning —
thermal throttling under sustained load is a common silent cause of dropped
frames on a Pi 4 without a fan/heatsink case, and this appliance runs flat
out 24/7.

## Notes / things I couldn't verify without the actual hardware

- Exact DRM connector names and whether your specific monitors' EDID needs
  the `cmdline.txt` override — see step 5/6 above.
- How many concurrent hardware-decode sessions the Pi 4's V4L2 M2M decoder
  will sustain with your cameras' actual resolutions/bitrates — this is the
  main open risk in the design and the reason `HWDECODE` and `FPS` are
  exposed as easy knobs rather than hardcoded.
- Your UniFi Protect RTSP alias URLs are specific to your controller/camera
  configuration and have to be pulled from the Protect UI directly.
