#!/bin/bash
# Run with sudo on a fresh Debian (current stable) server, from inside this
# directory: sudo ./install.sh
#
# Must be run from a full clone of the repo: it also installs shared Python
# helpers from ../common/.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (sudo ./install.sh)" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$REPO_DIR/../common"
VW_USER="videowall"
VW_WEB_USER="videowall-web"
VW_GROUP="videowall"

# Pin the relay version. Override on the command line to move it.
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.9.3}"
MEDIAMTX_ARCH="${MEDIAMTX_ARCH:-linux_amd64}"
MEDIAMTX_TARBALL="mediamtx_${MEDIAMTX_VERSION}_${MEDIAMTX_ARCH}.tar.gz"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/${MEDIAMTX_TARBALL}"
DIST_DIR=/opt/videowall/dist

if [ ! -d "$COMMON_DIR" ]; then
  echo "Missing $COMMON_DIR — clone the whole repository, not just the" >&2
  echo "server/ subdirectory: the web UI needs the shared helpers there." >&2
  exit 1
fi

echo "==> Installing packages"
apt-get update
apt-get install -y ffmpeg python3-flask python3-psutil gunicorn sudo curl ca-certificates

GUNICORN_BIN="$(command -v gunicorn3 || command -v gunicorn || true)"
if [ -z "$GUNICORN_BIN" ]; then
  echo "Could not find a 'gunicorn' or 'gunicorn3' binary after install — aborting." >&2
  exit 1
fi

echo "==> Checking ffmpeg capabilities"
if ! ffmpeg -hide_banner -h muxer=image2 2>/dev/null | grep -qi atomic_writing; then
  cat <<'EOF' >&2

WARNING: this ffmpeg's image2 muxer has no -atomic_writing option. The mosaic
snapshot uses it to avoid the web UI ever reading a half-written JPEG, and a
rejected option would stop the whole wall from starting. Set SNAPSHOT=0 in
/etc/videowall/videowall-server.env if the encoders fail to start.
EOF
fi

echo "==> Creating dedicated users/group"
getent group "$VW_GROUP" >/dev/null || groupadd -r "$VW_GROUP"
id -u "$VW_USER" >/dev/null 2>&1 || useradd -r -M -g "$VW_GROUP" -G video,render -s /usr/sbin/nologin "$VW_USER"
id -u "$VW_WEB_USER" >/dev/null 2>&1 || useradd -r -M -g "$VW_GROUP" -s /usr/sbin/nologin "$VW_WEB_USER"

echo "==> Installing the MediaMTX relay (${MEDIAMTX_VERSION})"
# The relay is what lets more than one client watch the same wall. It is not
# packaged in Debian, so it comes from the project's own release. Verification
# is mandatory: either pre-stage the tarball, pass MEDIAMTX_SHA256=..., or the
# script stops and shows you the hash to check against the release page.
if [ -x /usr/local/bin/mediamtx ]; then
  echo "    /usr/local/bin/mediamtx already present, leaving it alone"
  echo "    (delete it and re-run to upgrade)"
else
  install -d -m 755 "$DIST_DIR"
  TARBALL_PATH="$DIST_DIR/$MEDIAMTX_TARBALL"
  if [ -f "$TARBALL_PATH" ]; then
    echo "    using pre-staged $TARBALL_PATH"
  else
    echo "    downloading $MEDIAMTX_URL"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TARBALL_PATH" "$MEDIAMTX_URL"
  fi

  ACTUAL_SHA="$(sha256sum "$TARBALL_PATH" | awk '{print $1}')"
  if [ -n "${MEDIAMTX_SHA256:-}" ]; then
    if [ "$ACTUAL_SHA" != "$MEDIAMTX_SHA256" ]; then
      echo "    SHA256 MISMATCH: expected $MEDIAMTX_SHA256, got $ACTUAL_SHA" >&2
      echo "    Refusing to install. Remove $TARBALL_PATH and investigate." >&2
      exit 1
    fi
    echo "    checksum verified against MEDIAMTX_SHA256"
  else
    cat >&2 <<EOF

    STOPPING: the relay binary is unverified.

    Downloaded: $TARBALL_PATH
    SHA256:     $ACTUAL_SHA

    Compare that against the checksum published for ${MEDIAMTX_VERSION} at
      https://github.com/bluenviron/mediamtx/releases/tag/${MEDIAMTX_VERSION}
    then re-run with:
      sudo MEDIAMTX_SHA256=$ACTUAL_SHA ./install.sh

    (This script deliberately does not ship a hardcoded hash it cannot
    vouch for, and will not install an unverified binary for you.)
EOF
    exit 1
  fi

  tar -xzf "$TARBALL_PATH" -C "$DIST_DIR" mediamtx mediamtx.yml
  install -m 755 "$DIST_DIR/mediamtx" /usr/local/bin/mediamtx
  # Keep upstream's reference config for diffing if you bump the version;
  # MediaMTX's config keys have changed across releases.
  install -m 644 "$DIST_DIR/mediamtx.yml" /etc/videowall/mediamtx.reference.yml 2>/dev/null || true
fi

echo "==> Installing config files"
install -d -m 775 -o root -g "$VW_GROUP" /etc/videowall
install -d -m 755 /opt/videowall/bin
install -d -m 755 /opt/videowall/webui

install -m 755 "$REPO_DIR/bin/videowall-encode.sh" /opt/videowall/bin/videowall-encode.sh
# The privileged helper lives outside /opt so it is clearly root-owned and
# separate from the web UI's own files.
install -m 755 -o root -g root "$REPO_DIR/bin/videowall-ctl" /usr/local/sbin/videowall-ctl
install -m 644 "$REPO_DIR/config/mediamtx.yml.example" /etc/videowall/mediamtx.yml.new
if [ ! -f /etc/videowall/mediamtx.yml ]; then
  mv /etc/videowall/mediamtx.yml.new /etc/videowall/mediamtx.yml
else
  rm -f /etc/videowall/mediamtx.yml.new
  echo "    /etc/videowall/mediamtx.yml already exists, leaving it alone"
fi

for f in cameras-4k.conf cameras-1080p.conf wall-4k.env wall-1080p.env videowall-server.env; do
  if [ ! -f "/etc/videowall/$f" ]; then
    install -m 664 -o root -g "$VW_GROUP" "$REPO_DIR/config/$f.example" "/etc/videowall/$f"
    echo "    wrote /etc/videowall/$f"
  else
    echo "    /etc/videowall/$f already exists, leaving it alone"
  fi
done
echo "    edit the cameras-*.conf files with your real RTSP URLs (or use the web UI)"

echo "==> Deploying web UI"
cp -r "$REPO_DIR/webui/"* /opt/videowall/webui/
# Shared helpers, kept in one place so a fix reaches both machines.
install -m 644 "$COMMON_DIR"/*.py /opt/videowall/webui/
chown -R "$VW_WEB_USER:$VW_GROUP" /opt/videowall/webui

if [ ! -f /etc/videowall/webui.env ]; then
  WEBUI_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
  READ_TOKEN="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  HASHES="$(python3 - "$WEBUI_PASSWORD" "$READ_TOKEN" <<'PY'
import sys
from werkzeug.security import generate_password_hash
print(generate_password_hash(sys.argv[1]))
print(generate_password_hash(sys.argv[2]))
PY
)"
  {
    echo "WEBUI_USER=admin"
    echo "WEBUI_PASSWORD_HASH=$(echo "$HASHES" | sed -n 1p)"
    echo "WEBUI_READ_TOKEN_HASH=$(echo "$HASHES" | sed -n 2p)"
  } > /etc/videowall/webui.env
  chmod 640 /etc/videowall/webui.env
  chown root:"$VW_GROUP" /etc/videowall/webui.env
  cat <<EOF

    Generated credentials — SAVE THESE NOW, they are not shown again and are
    stored only as hashes:

      web UI user:      admin
      web UI password:  $WEBUI_PASSWORD

      client read token: $READ_TOKEN
        ^ paste this into each Pi's SERVER_API_TOKEN so it can list walls
          without holding the admin password.

EOF
else
  echo "    /etc/videowall/webui.env already exists, leaving it alone"
fi

echo "==> Installing sudoers rule (web UI may control encoder units only)"
TMP_SUDOERS="$(mktemp)"
cp "$REPO_DIR/sudoers/videowall-webui" "$TMP_SUDOERS"
if visudo -cf "$TMP_SUDOERS" >/dev/null; then
  install -m 440 "$TMP_SUDOERS" /etc/sudoers.d/videowall-webui
else
  echo "sudoers file failed validation, NOT installing it — the web UI's" >&2
  echo "start/stop/restart controls will not work until this is fixed." >&2
fi
rm -f "$TMP_SUDOERS"

echo "==> Installing systemd units"
install -m 644 "$REPO_DIR/systemd/videowall-encode@.service" /etc/systemd/system/videowall-encode@.service
install -m 644 "$REPO_DIR/systemd/mediamtx.service" /etc/systemd/system/mediamtx.service
sed "s#GUNICORN_BIN#$GUNICORN_BIN#" "$REPO_DIR/systemd/videowall-webui.service" > /etc/systemd/system/videowall-webui.service
# Remove the old static units this replaces, so they can't linger and fight
# the templated instances over the same ports/runtime dir.
for old in videowall-encode-4k.service videowall-encode-1080p.service; do
  if [ -f "/etc/systemd/system/$old" ]; then
    systemctl disable --now "$old" 2>/dev/null || true
    rm -f "/etc/systemd/system/$old"
    echo "    removed obsolete $old"
  fi
done
systemctl daemon-reload

cat <<'EOF'

==> Done. Next steps:

1. Fill in your camera URLs — either edit /etc/videowall/cameras-*.conf, or
   start the web UI (below) and use its Config page, which can also create,
   enable/disable and delete walls.

2. Start the relay, then the walls, then the web UI:
     systemctl enable --now mediamtx.service
     systemctl enable --now videowall-encode@4k.service
     systemctl enable --now videowall-encode@1080p.service
     systemctl enable --now videowall-webui.service

   Each wall is one instance of the templated unit, so a new wall named
   "lobby" is just: systemctl enable --now videowall-encode@lobby.service
   (the web UI does this for you when you create or enable a wall).

3. Firewall: clients need inbound UDP 8890 (the relay's SRT read port) and
   you need TCP 8080 for the web UI. Over Tailscale, scope both to the
   tailscale0 interface rather than opening them globally. The relay's RTSP
   publish port and its API are bound to loopback and need nothing.

4. Open http://<this-server>:8080/ and log in as admin.

Note: if a wall shows "config error", its camera count doesn't match
rows x columns — the encoder refuses to start on that and now exits cleanly
(code 78) instead of restart-looping. The dashboard says which it is.
EOF
