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

echo "==> Installing packages"
apt-get update
apt-get install -y ffmpeg

echo "==> Checking for SRT support in ffmpeg"
if ! ffmpeg -hide_banner -protocols 2>/dev/null | grep -qi '^  *srt$'; then
  cat <<'EOF' >&2

WARNING: this ffmpeg build does not list "srt" among its protocols.
The scripts here publish over SRT (srt://) by default. Either:
  - install an ffmpeg build with libsrt support, or
  - edit server/bin/videowall-encode.sh and the systemd units to use plain
    UDP/MPEG-TS instead (see the "SRT not available" note in README.md).
Continuing installation, but the encoder services will fail to start until
this is resolved.
EOF
fi

echo "==> Creating dedicated '$VW_USER' user"
id -u "$VW_USER" >/dev/null 2>&1 || useradd -r -M -G video,render -s /usr/sbin/nologin "$VW_USER"

echo "==> Installing config files"
install -d -m 755 /etc/videowall
install -d -m 755 /opt/videowall/bin

install -m 755 "$REPO_DIR/bin/videowall-encode.sh" /opt/videowall/bin/videowall-encode.sh

for f in cameras-4k.conf cameras-1080p.conf; do
  if [ ! -f "/etc/videowall/$f" ]; then
    install -m 644 "$REPO_DIR/config/$f.example" "/etc/videowall/$f"
    echo "    wrote /etc/videowall/$f (edit this with your real camera RTSP URLs)"
  else
    echo "    /etc/videowall/$f already exists, leaving it alone"
  fi
done
if [ ! -f /etc/videowall/videowall-server.env ]; then
  install -m 644 "$REPO_DIR/config/videowall-server.env.example" /etc/videowall/videowall-server.env
fi

install -m 644 "$REPO_DIR/systemd/videowall-encode-4k.service" /etc/systemd/system/videowall-encode-4k.service
install -m 644 "$REPO_DIR/systemd/videowall-encode-1080p.service" /etc/systemd/system/videowall-encode-1080p.service
systemctl daemon-reload

cat <<'EOF'

==> Done. Before starting the services:

1. Edit /etc/videowall/cameras-4k.conf and /etc/videowall/cameras-1080p.conf
   with your real UniFi Protect RTSP URLs (9 and 4 lines respectively).

2. If the Pi reaches this server over a plain LAN and your firewall is
   active, allow inbound UDP on the two SRT ports (6000 and 6001 by
   default — SRT rides over UDP even though the URL scheme reads
   "srt://"):
     ufw allow 6000/udp
     ufw allow 6001/udp
   If instead the Pi connects over Tailscale, skip this — no port needs
   opening on the normal network interface. If a local firewall is active,
   scope any rule to the tailscale0 interface rather than opening globally.

3. Start the encoders:
     systemctl enable --now videowall-encode-4k.service
     systemctl enable --now videowall-encode-1080p.service

4. Check they're actually publishing before wiring up the Pi:
     journalctl -u videowall-encode-4k -f
   (it will sit waiting for a connection — SRT listener mode — until the
   Pi's mpv calls in; that's expected, not an error.)

Bitrates (8000/4000 kbps) and ports (6000/6001) are set in the two
/etc/systemd/system/videowall-encode-*.service files. To change them, edit
the ExecStart line and run `systemctl daemon-reload` + restart the service.
EOF
