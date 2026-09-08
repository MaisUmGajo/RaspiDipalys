#!/bin/bash
# Run with sudo on a fresh Debian (current stable) server, from inside this
# directory: sudo ./install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (sudo ./install.sh)" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VW_USER="videowall"
VW_WEB_USER="videowall-web"
VW_GROUP="videowall"

echo "==> Installing packages"
apt-get update
apt-get install -y ffmpeg python3-flask python3-psutil gunicorn sudo

GUNICORN_BIN="$(command -v gunicorn3 || command -v gunicorn || true)"
if [ -z "$GUNICORN_BIN" ]; then
  echo "Could not find a 'gunicorn' or 'gunicorn3' binary after installing the gunicorn package — aborting." >&2
  exit 1
fi

echo "==> Checking for SRT support in ffmpeg"
if ! ffmpeg -hide_banner -protocols 2>/dev/null | grep -qi '^  *srt$'; then
  cat <<'EOF' >&2

WARNING: this ffmpeg build does not list "srt" among its protocols.
The scripts here publish over SRT (srt://) by default. Either install an
ffmpeg build with libsrt support, or switch to plain UDP/MPEG-TS (see the
"SRT not available" note in README.md). Continuing installation, but the
encoder services will fail to start until this is resolved.
EOF
fi

echo "==> Creating dedicated users/group"
getent group "$VW_GROUP" >/dev/null || groupadd -r "$VW_GROUP"
id -u "$VW_USER" >/dev/null 2>&1 || useradd -r -M -g "$VW_GROUP" -G video,render -s /usr/sbin/nologin "$VW_USER"
id -u "$VW_WEB_USER" >/dev/null 2>&1 || useradd -r -M -g "$VW_GROUP" -s /usr/sbin/nologin "$VW_WEB_USER"

echo "==> Installing config files"
install -d -m 775 -o root -g "$VW_GROUP" /etc/videowall
install -d -m 755 /opt/videowall/bin
install -d -m 755 /opt/videowall/webui

install -m 755 "$REPO_DIR/bin/videowall-encode.sh" /opt/videowall/bin/videowall-encode.sh

for f in cameras-4k.conf cameras-1080p.conf wall-4k.env wall-1080p.env videowall-server.env; do
  if [ ! -f "/etc/videowall/$f" ]; then
    install -m 664 -o root -g "$VW_GROUP" "$REPO_DIR/config/$f.example" "/etc/videowall/$f"
    echo "    wrote /etc/videowall/$f"
  else
    echo "    /etc/videowall/$f already exists, leaving it alone"
  fi
done
echo "    edit /etc/videowall/cameras-4k.conf and cameras-1080p.conf with your real RTSP URLs"

echo "==> Deploying web UI"
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

echo "==> Installing sudoers rule (web UI restart/status rights, nothing else)"
TMP_SUDOERS="$(mktemp)"
cp "$REPO_DIR/sudoers/videowall-webui" "$TMP_SUDOERS"
if visudo -cf "$TMP_SUDOERS" >/dev/null; then
  install -m 440 "$TMP_SUDOERS" /etc/sudoers.d/videowall-webui
  rm -f "$TMP_SUDOERS"
else
  echo "sudoers file failed validation, NOT installing it — web UI restart/status buttons will not work until this is fixed." >&2
  rm -f "$TMP_SUDOERS"
fi

echo "==> Installing systemd units"
install -m 644 "$REPO_DIR/systemd/videowall-encode-4k.service" /etc/systemd/system/videowall-encode-4k.service
install -m 644 "$REPO_DIR/systemd/videowall-encode-1080p.service" /etc/systemd/system/videowall-encode-1080p.service
sed "s#GUNICORN_BIN#$GUNICORN_BIN#" "$REPO_DIR/systemd/videowall-webui.service" > /etc/systemd/system/videowall-webui.service
systemctl daemon-reload

cat <<'EOF'

==> Done. Before starting anything:

1. Edit /etc/videowall/cameras-4k.conf and /etc/videowall/cameras-1080p.conf
   with your real UniFi Protect RTSP URLs (9 and 4 lines respectively) —
   or do this later from the web UI's Config page instead.

2. If your firewall is active:
   - Plain LAN: allow inbound UDP on the SRT ports (6000/6001 by default).
   - Tailscale: no port needs opening on the normal interface; scope any
     local rule to the tailscale0 interface instead.
   - Web UI: allow inbound TCP 8080 from wherever you'll access it from
     (ideally only over Tailscale, not the open internet).

3. Start everything:
     systemctl enable --now videowall-encode-4k.service
     systemctl enable --now videowall-encode-1080p.service
     systemctl enable --now videowall-webui.service

4. Open http://<this-server>:8080/ and log in with the admin credentials
   printed above (or check /etc/videowall/webui.env's WEBUI_USER — the
   password itself is only ever stored as a hash, so if you lost it,
   delete /etc/videowall/webui.env and re-run this script to generate a
   new one).
EOF
