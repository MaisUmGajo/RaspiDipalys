#!/bin/bash
# Run with sudo on a fresh Raspberry Pi OS Lite (64-bit, Bookworm) install,
# from inside this repo directory: sudo ./install.sh
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
  mpv ffmpeg unclutter \
  libraspberrypi-bin

# xserver-xorg-legacy defaults to allowing only console-active users to
# start X, which is what we want (no network X, no arbitrary users).
echo "==> Creating dedicated '$VW_USER' user"
id -u "$VW_USER" >/dev/null 2>&1 || useradd -m -G video,render,input,tty -s /bin/bash "$VW_USER"

echo "==> Installing config files"
install -d -m 755 /etc/videowall
install -d -m 755 /opt/videowall/bin

install -m 755 "$REPO_DIR/bin/videowall-grid.sh" /opt/videowall/bin/videowall-grid.sh
install -m 644 "$REPO_DIR/config/xorg-dualhead.conf" /etc/X11/xorg.conf.d/10-dualhead.conf

for f in cameras-4k.conf cameras-1080p.conf; do
  if [ ! -f "/etc/videowall/$f" ]; then
    install -m 644 "$REPO_DIR/config/$f.example" "/etc/videowall/$f"
    echo "    wrote /etc/videowall/$f (edit this with your real camera RTSP URLs)"
  else
    echo "    /etc/videowall/$f already exists, leaving it alone"
  fi
done
if [ ! -f /etc/videowall/videowall.env ]; then
  install -m 644 "$REPO_DIR/config/videowall.env.example" /etc/videowall/videowall.env
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

1. Edit /etc/videowall/cameras-4k.conf and /etc/videowall/cameras-1080p.conf
   with your real UniFi Protect RTSP URLs (9 and 4 lines respectively).

2. Connect both monitors, reboot, and after first login as 'videowall'
   confirm the DRM connector names with `DISPLAY=:0 xrandr` (see the
   comment at the top of /etc/X11/xorg.conf.d/10-dualhead.conf) — update
   the ZaphodHeads lines in that file if they don't say HDMI-1/HDMI-2.

3. If a specific pixel resolution/refresh isn't being picked up
   automatically via EDID, force it via /boot/firmware/cmdline.txt, e.g.
   append (all on the existing single line, space-separated):
     video=HDMI-A-1:3840x2160@30 video=HDMI-A-2:1920x1080@60
   using whatever connector names you confirmed in step 2.

4. Reboot. The 'videowall' user autologins on tty1 and starts the wall.
EOF
