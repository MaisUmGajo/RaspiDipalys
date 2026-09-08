#!/bin/bash
# Run with sudo on a fresh Raspberry Pi OS Lite (64-bit, Bookworm) install,
# from inside this directory: sudo ./install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (sudo ./install.sh)" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VW_USER="videowall"
VW_HOME="/home/$VW_USER"

echo "==> Installing packages"
apt-get update
apt-get install -y \
  xserver-xorg xserver-xorg-legacy x11-xserver-utils xinit \
  mpv unclutter \
  libraspberrypi-bin

echo "==> Checking for SRT support in mpv's ffmpeg/libav"
if ! ffmpeg -hide_banner -protocols 2>/dev/null | grep -qi '^  *srt$'; then
  cat <<'EOF' >&2

WARNING: ffmpeg on this system does not list "srt" among its protocols.
mpv uses the same libav libraries, so it likely can't open srt:// URLs
either. Either update to a Raspberry Pi OS build with libsrt support, or
switch to the plain UDP fallback described in README.md (both the server's
encode command and this Pi's mpv URL need to change together).
Continuing installation regardless.
EOF
fi

echo "==> Creating dedicated '$VW_USER' user"
id -u "$VW_USER" >/dev/null 2>&1 || useradd -m -G video,render,input,tty -s /bin/bash "$VW_USER"

echo "==> Installing config files"
install -d -m 755 /etc/videowall
install -m 644 "$REPO_DIR/config/xorg-dualhead.conf" /etc/X11/xorg.conf.d/10-dualhead.conf

if [ ! -f /etc/videowall/pi.env ]; then
  install -m 644 "$REPO_DIR/config/pi.env.example" /etc/videowall/pi.env
  echo "    wrote /etc/videowall/pi.env (edit SERVER_HOST to point at your Debian server)"
else
  echo "    /etc/videowall/pi.env already exists, leaving it alone"
fi

install -m 644 "$REPO_DIR/home/xinitrc" "$VW_HOME/.xinitrc"
install -m 644 "$REPO_DIR/home/bash_profile" "$VW_HOME/.bash_profile"
chown "$VW_USER:$VW_USER" "$VW_HOME/.xinitrc" "$VW_HOME/.bash_profile"

echo "==> Enabling console autologin for '$VW_USER' on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $VW_USER --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl enable getty@tty1.service
systemctl set-default multi-user.target

echo "==> Appending dual-HDMI settings to /boot/firmware/config.txt"
CONFIG_TXT=/boot/firmware/config.txt
MARK_BEGIN="# --- videowall dual-HDMI begin ---"
MARK_END="# --- videowall dual-HDMI end ---"
if ! grep -qF "$MARK_BEGIN" "$CONFIG_TXT"; then
  {
    echo "$MARK_BEGIN"
    cat "$REPO_DIR/config/config.txt.append"
    echo "$MARK_END"
  } >> "$CONFIG_TXT"
else
  echo "    config.txt already has the videowall block, skipping"
fi

cat <<'EOF'

==> Done. Before rebooting:

1. Edit /etc/videowall/pi.env — set SERVER_HOST to the Debian server's IP,
   and confirm PORT_4K/PORT_1080P match the server's
   videowall-encode-*.service units.

2. Make sure the server's two encoder services are already running and
   confirmed publishing (see server/README.md) before you boot the Pi —
   otherwise mpv will just sit retrying the connection every 2s, which is
   harmless but you'll see a black screen until the server is up.

3. Connect both monitors, reboot, and after first login as 'videowall'
   confirm the DRM connector names with `DISPLAY=:0 xrandr` (see the
   comment at the top of /etc/X11/xorg.conf.d/10-dualhead.conf) — update
   the ZaphodHeads lines in that file if they don't say HDMI-1/HDMI-2.

4. If a specific pixel resolution/refresh isn't being picked up
   automatically via EDID, force it via /boot/firmware/cmdline.txt, e.g.
   append (all on the existing single line, space-separated):
     video=HDMI-A-1:3840x2160@30 video=HDMI-A-2:1920x1080@60
   using whatever connector names you confirmed in step 3.

5. Reboot. The 'videowall' user autologins on tty1 and starts the wall.
EOF
