#!/bin/bash
# Run with sudo on a fresh Raspberry Pi OS Lite (64-bit, Bookworm) install,
# from inside this directory: sudo ./install.sh
# -E so the ERR trap fires inside functions too. Every failure is reported
# with the step, line, command and exit code — this script must never just
# stop silently (a SIGPIPE once did exactly that; see the note by the
# credential generation below).
set -Eeuo pipefail

CURRENT_STEP="startup"
LOG_FILE=/var/log/videowall-pi-install.log

step() { CURRENT_STEP="$1"; printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_err() {
  local rc=$? line=${1:-?} cmd=${2:-?} extra=""
  if [ "$rc" -gt 128 ]; then
    local sig=$((rc - 128))
    extra="  (killed by signal $sig$([ "$sig" -eq 13 ] && echo ' = SIGPIPE'))"
  fi
  printf '\n!!! INSTALL FAILED\n'
  printf '    step:    %s\n' "$CURRENT_STEP"
  printf '    line:    %s\n' "$line"
  printf '    command: %s\n' "$cmd"
  printf '    exit:    %s%s\n' "$rc" "$extra"
  printf '    log:     %s\n' "$LOG_FILE"
  printf '\n    Re-run after fixing; this script is idempotent.\n'
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo ./install.sh)"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/videowall-pi-install.log
exec > >(tee -a "$LOG_FILE") 2>&1
printf '=== videowall Pi install: %s ===\n' "$(date -Is)"

export LC_ALL=C

step "Preflight: shell environment"
info "PATH=$PATH"
# 'su' (without '-') keeps the calling user's PATH, which has no sbin
# directories, so useradd/groupadd/visudo look like they don't exist. Repair
# it for this run rather than failing halfway through, and explain why.
SBIN_MISSING=()
for d in /usr/local/sbin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) SBIN_MISSING+=("$d") ;; esac
done
if [ "${#SBIN_MISSING[@]}" -gt 0 ]; then
  PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
  export PATH
  info "FIXED: prepended ${SBIN_MISSING[*]} to PATH for this run"
  info "(use 'sudo -i' or 'su -' so your own shell has them too)"
fi

step "Preflight: required commands"
PREFLIGHT_FAILED=0
for cmd in apt-get dpkg install sed grep awk find tar getent \
           useradd groupadd visudo systemctl; do
  if p="$(command -v "$cmd" 2>/dev/null)"; then
    info "ok   $cmd -> $p"
  else
    warn "missing: $cmd"
    PREFLIGHT_FAILED=1
  fi
done
[ "$PREFLIGHT_FAILED" -eq 0 ] || die "Required commands are missing (see above).
    On a minimal image, useradd/groupadd come from 'passwd' and visudo from
    'sudo'. Install those, or check the PATH note above, then re-run."

# The web UI's privileged action relies on a drop-in in /etc/sudoers.d; with
# no includedir line it would be silently ignored.
if [ -f /etc/sudoers ] && \
   ! grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
  warn "/etc/sudoers has no '#includedir /etc/sudoers.d' line, so the web UI's
    sudoers drop-in will be ignored and its restart button won't work."
fi

if [ ! -d /run/systemd/system ]; then
  die "systemd is not running as init — this installs systemd units."
fi
info "systemd is the running init"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$REPO_DIR/../common"
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
  ffmpeg python3-flask python3-psutil gunicorn sudo

# vcgencmd — for `measure_temp` / `get_throttled` while hand-tuning — ships in
# libraspberrypi-bin on Bookworm, which Trixie replaced with raspi-utils-core.
# Nothing here needs it at runtime (the web UI reads the temperature straight
# from /sys/class/thermal), so install whichever the running release offers and
# carry on if neither is available, rather than failing the whole install over
# an optional diagnostic.
# `apt-cache show` is not the test to use here: on Trixie it still succeeds for
# libraspberrypi-bin (other packages reference it), while `apt-get install` then
# fails with "has no installation candidate". Check for a real candidate version.
VCGENCMD_PKG=""
for pkg in libraspberrypi-bin raspi-utils-core; do
  if [ "$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')" != "" ] &&
     [ "$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')" != "(none)" ]; then
    VCGENCMD_PKG="$pkg"
    break
  fi
done
if [ -n "$VCGENCMD_PKG" ]; then
  apt-get install -y "$VCGENCMD_PKG"
  echo "    installed $VCGENCMD_PKG (provides vcgencmd)"
else
  echo "    note: no vcgencmd package available on this release — thermal/throttling"
  echo "          diagnostics won't be available, but nothing here needs them."
fi

GUNICORN_BIN="$(command -v gunicorn3 || command -v gunicorn || true)"
if [ -z "$GUNICORN_BIN" ]; then
  echo "Could not find a 'gunicorn' or 'gunicorn3' binary after install — aborting." >&2
  exit 1
fi

step "Checking for SRT support in mpv's ffmpeg/libav"
# NOTE: deliberately not `ffmpeg ... | grep -q`. Under `set -o pipefail`,
# grep -q exits as soon as it matches, ffmpeg then dies of SIGPIPE, and the
# pipeline reports 141 — which made this check warn "SRT missing" even when
# SRT was fully supported.
PROTOCOLS="$(ffmpeg -hide_banner -protocols 2>/dev/null || true)"
case "$PROTOCOLS" in
  *srt*) info "ffmpeg/libav lists the srt protocol" ;;
  *) warn "ffmpeg on this system does not list \"srt\" among its protocols.
    mpv uses the same libav libraries, so it likely cannot open srt:// URLs
    either, and the display would never connect. Either install a build with
    libsrt support, or reconfigure the relay and this Pi onto a transport
    both ends support. Continuing anyway." ;;
esac

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

step "Deploying web UI"
# The most common install mistake is copying only pi/ instead of cloning the
# repo, so check for the actual files rather than just the directory.
[ -d "$COMMON_DIR" ] || die "Missing $COMMON_DIR — clone the whole repository, not just pi/."
shopt -s nullglob
COMMON_FILES=("$COMMON_DIR"/*.py)
shopt -u nullglob
[ "${#COMMON_FILES[@]}" -gt 0 ] || die "No .py files in $COMMON_DIR — the clone looks incomplete."

install -d -m 755 /opt/videowall/webui /opt/videowall/bin
# Glob-free: copies dotfiles too and cannot fail on an unexpanded wildcard.
cp -r "$REPO_DIR/webui/." /opt/videowall/webui/
# Shared helpers (source prober, env parsing, auth), kept in one place so a
# fix reaches both the server and the Pi.
install -m 644 "${COMMON_FILES[@]}" /opt/videowall/webui/
chown -R "$VW_WEB_USER:$VW_GROUP" /opt/videowall/webui
for f in app.py probe.py vwcommon.py mpvipc.py templates/index.html templates/config.html; do
  [ -f "/opt/videowall/webui/$f" ] || die "Deploy incomplete: /opt/videowall/webui/$f is missing."
done
info "deployed $(find /opt/videowall/webui -type f | wc -l) files"

step "Installing the stream watchdog"
# Reconnects streams that froze, degraded, or went corrupt — none of which
# make mpv exit, so the display loops alone would never notice them. Runs
# inside the display session (see .xinitrc), so it needs no service of its own
# and no privileges.
install -m 755 -o root -g root "$REPO_DIR/bin/videowall-watchdog.py" \
  /opt/videowall/bin/videowall-watchdog.py
# Shared runtime dir for the mpv IPC sockets and the health file the web UI
# reads. /run is not writable by either account, so systemd-tmpfiles creates
# it on each boot with the display user as owner.
install -m 644 "$REPO_DIR/config/tmpfiles-videowall.conf" /etc/tmpfiles.d/videowall.conf
systemd-tmpfiles --create /etc/tmpfiles.d/videowall.conf \
  || warn "systemd-tmpfiles could not create /run/videowall now; it will be
    created on the next boot. The watchdog falls back to XDG_RUNTIME_DIR."
info "watchdog installed; tune it via WATCHDOG_* settings in /etc/videowall/pi.env"

step "Generating credentials"
if [ ! -f /etc/videowall/webui.env ]; then
  # Generated inside Python with the `secrets` module. The previous version
  # used `tr -dc ... < /dev/urandom | head -c 20`, where head exits first, tr
  # dies of SIGPIPE, and `set -o pipefail` turned that into a completely
  # silent abort of the installer at exactly this step.
  mapfile -t CREDS < <(python3 - <<'PY'
import secrets, string
from werkzeug.security import generate_password_hash
alphabet = string.ascii_letters + string.digits
password = "".join(secrets.choice(alphabet) for _ in range(20))
print(password)
print(generate_password_hash(password))
PY
  )
  [ "${#CREDS[@]}" -eq 2 ] || die "Credential generation produced ${#CREDS[@]} lines, expected 2."
  WEBUI_PASSWORD="${CREDS[0]}"
  {
    echo "WEBUI_USER=admin"
    echo "WEBUI_PASSWORD_HASH=${CREDS[1]}"
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

1. Configure the outputs — either edit /etc/videowall/pi.env directly, or
   (easier) open the web UI at http://<this-pi>:8080/ and use the Config &
   test page: set SERVER_HOST, paste the read-only API token that the
   SERVER's installer printed, then pick which wall each HDMI output shows
   from the dropdown (it lists the walls the server actually offers). Click
   "Test this source" on each to confirm the stream is arriving, then
   "Save & apply".

   Walls are selected by NAME, not by port: every wall arrives on the one
   relay SRT port (8890 by default), so there are no per-wall ports to keep
   in sync. Several Pis can watch the same wall at once.

   Log in with the admin credentials printed above (stored only as a hash in
   /etc/videowall/webui.env — if lost, delete that file and re-run this
   script for a new one). Expose port 8080 over Tailscale only, never the
   open internet (plain HTTP + Basic Auth).

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
