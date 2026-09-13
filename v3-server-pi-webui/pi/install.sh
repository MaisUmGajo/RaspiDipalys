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
VW_WEB_USER="videowall-web"
VW_GROUP="videowall"
VW_HOME="/home/$VW_USER"

echo "==> Installing packages"
apt-get update
# ffmpeg is installed for ffprobe (the web UI's source-stream test), not for
# the display path — mpv still does all decoding.
apt-get install -y \
  xserver-xorg xserver-xorg-legacy x11-xserver-utils xinit \
  mpv unclutter \
  libraspberrypi-bin \
  ffmpeg python3-flask python3-psutil gunicorn sudo

GUNICORN_BIN="$(command -v gunicorn3 || command -v gunicorn || true)"
if [ -z "$GUNICORN_BIN" ]; then
  echo "Could not find a 'gunicorn' or 'gunicorn3' binary after install — aborting." >&2
  exit 1
fi

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

echo "==> Creating dedicated users"
# The display user (videowall) also owns the 'videowall' primary group.
id -u "$VW_USER" >/dev/null 2>&1 || useradd -m -G video,render,input,tty -s /bin/bash "$VW_USER"
# The web UI runs as its own account, only sharing the videowall group so it
# can read/write the config files in /etc/videowall.
id -u "$VW_WEB_USER" >/dev/null 2>&1 || useradd -r -M -g "$VW_GROUP" -s /usr/sbin/nologin "$VW_WEB_USER"

echo "==> Installing config files"
# Group-writable so the web UI (in the videowall group) can rewrite pi.env.
install -d -m 775 -o root -g "$VW_GROUP" /etc/videowall
install -m 644 "$REPO_DIR/config/xorg-dualhead.conf" /etc/X11/xorg.conf.d/10-dualhead.conf

if [ ! -f /etc/videowall/pi.env ]; then
  install -m 664 -o root -g "$VW_GROUP" "$REPO_DIR/config/pi.env.example" /etc/videowall/pi.env
  echo "    wrote /etc/videowall/pi.env (set SERVER_HOST here or via the web UI)"
else
  echo "    /etc/videowall/pi.env already exists, leaving it alone"
fi

# Screen layout lives outside pi.env because the web UI rewrites that file
# from a fixed template on save and would drop any extra keys.
if [ ! -f /etc/videowall/display.env ]; then
  install -m 664 -o root -g "$VW_GROUP" "$REPO_DIR/config/display.env.example" /etc/videowall/display.env
  echo "    wrote /etc/videowall/display.env (per-output resolutions)"
else
  echo "    /etc/videowall/display.env already exists, leaving it alone"
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

echo "==> Deploying web UI"
install -d -m 755 /opt/videowall/webui
cp -r "$REPO_DIR/webui/"* /opt/videowall/webui/
chown -R "$VW_WEB_USER:$VW_GROUP" /opt/videowall/webui

if [ ! -f /etc/videowall/webui.env ]; then
  WEBUI_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
  PASSWORD_HASH="$(python3 -c "import sys; from werkzeug.security import generate_password_hash; print(generate_password_hash(sys.argv[1]))" "$WEBUI_PASSWORD")"
  {
    echo "WEBUI_USER=admin"
    echo "WEBUI_PASSWORD_HASH=$PASSWORD_HASH"
  } > /etc/videowall/webui.env
  chmod 640 /etc/videowall/webui.env
  chown root:"$VW_GROUP" /etc/videowall/webui.env
  echo
  echo "    Generated web UI login — save this now, it will not be shown again:"
  echo "      user:     admin"
  echo "      password: $WEBUI_PASSWORD"
  echo
else
  echo "    /etc/videowall/webui.env already exists, leaving it alone"
fi

echo "==> Installing sudoers rule (web UI may restart displays only)"
TMP_SUDOERS="$(mktemp)"
cp "$REPO_DIR/sudoers/videowall-pi-webui" "$TMP_SUDOERS"
if visudo -cf "$TMP_SUDOERS" >/dev/null; then
  install -m 440 "$TMP_SUDOERS" /etc/sudoers.d/videowall-pi-webui
  rm -f "$TMP_SUDOERS"
else
  echo "sudoers file failed validation, NOT installing — the Apply/restart button won't work until fixed." >&2
  rm -f "$TMP_SUDOERS"
fi

echo "==> Installing web UI systemd unit"
sed "s#GUNICORN_BIN#$GUNICORN_BIN#" "$REPO_DIR/systemd/videowall-pi-webui.service" > /etc/systemd/system/videowall-pi-webui.service
systemctl daemon-reload
systemctl enable videowall-pi-webui.service

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

1. Configure the source streams — either edit /etc/videowall/pi.env
   directly, or (easier) open the web UI at http://<this-pi>:8080/ and use
   the Config & test page: set SERVER_HOST + ports, click "Test this
   source" on each to confirm the server is reachable and streaming, then
   "Save & apply". Log in with the admin credentials printed above (stored
   only as a hash in /etc/videowall/webui.env — if lost, delete that file
   and re-run this script for a new one). Expose port 8080 over Tailscale
   only, never the open internet (plain HTTP + Basic Auth).

2. Make sure the server's two encoder services are already running and
   confirmed publishing (see server/README.md) before you boot the Pi —
   otherwise mpv will just sit retrying the connection every 2s, which is
   harmless but you'll see a black screen until the server is up.

3. Set each output's resolution in /etc/videowall/display.env. It ships with
   3840x2160 for both. Connector names are NOT configured anywhere —
   ~videowall/.xinitrc asks xrandr which outputs are connected and uses the
   first as the PORT_4K wall and the second, placed to its right, as the
   PORT_1080P wall. Swap the two HDMI cables if the walls come up on the
   wrong screens.

   Note this is a single X screen spanning both outputs, with one mpv pinned
   to each via --fs-screen — not two independent X screens. Zaphod mode does
   not work on a Pi 4's vc4 driver; see the comments in
   /etc/X11/xorg.conf.d/10-dualhead.conf.

4. Connect both monitors and reboot. If a screen stays blank or comes up at
   the wrong resolution, log in as 'videowall' and run `DISPLAY=:0 xrandr` to
   see what modes that output really offers, then put one of them in
   display.env. Do not rely on xrandr's --auto here: once a mode has been
   set, this driver stops advertising a preferred mode and --auto can settle
   on something far smaller (seen: two 4K panels dropping to 1920x1080).

5. Reboot. The 'videowall' user autologins on tty1 and starts the wall.
EOF
