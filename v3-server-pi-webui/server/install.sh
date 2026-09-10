#!/bin/bash
# Video wall server installer. Target: Debian 13 (trixie); Debian 12 also works.
#
# Run from inside a full clone of the repo:  sudo ./install.sh
# It needs the whole repo, not just server/, because it also deploys shared
# Python helpers from ../common/.
#
# Re-running is safe: existing config, credentials and the relay binary are
# left alone.
#
# -E so the ERR trap fires inside functions too. Every failure is reported
# with the step, line, command and exit code — this script must never just
# stop silently.
set -Eeuo pipefail

# ---------------------------------------------------------------- diagnostics

CURRENT_STEP="startup"
LOG_FILE=/var/log/videowall-install.log

step() { CURRENT_STEP="$1"; printf '\n==> %s\n' "$1"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_err() {
  local rc=$? line=${1:-?} cmd=${2:-?} extra=""
  # Decode signals: 141 = SIGPIPE, which is silent and was the cause of a
  # previous "the installer just stopped with no message" report.
  if [ "$rc" -gt 128 ]; then
    local sig=$((rc - 128))
    extra="  (killed by signal $sig$([ "$sig" -eq 13 ] && echo ' = SIGPIPE'))"
  fi
  printf '\n'
  printf '!!! INSTALL FAILED\n'
  printf '    step:    %s\n' "$CURRENT_STEP"
  printf '    line:    %s\n' "$line"
  printf '    command: %s\n' "$cmd"
  printf '    exit:    %s%s\n' "$rc" "$extra"
  printf '    log:     %s\n' "$LOG_FILE"
  printf '\n    Nothing is half-started: re-run after fixing, it is idempotent.\n'
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# --------------------------------------------------------------------- config

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$REPO_DIR/../common"
VW_USER="videowall"
VW_WEB_USER="videowall-web"
VW_GROUP="videowall"
DIST_DIR=/opt/videowall/dist

MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.9.3}"

# --------------------------------------------------------------- CLI options

CHECK_ONLY=0
usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh [--check]

  --check    Run only the environment preflight checks and exit without
             changing anything. Use this to verify a freshly-built minimal
             VM is ready before committing to an install.

Environment overrides:
  MEDIAMTX_VERSION=vX.Y.Z    relay version to install (default v1.9.3)
  MEDIAMTX_ARCH=...          override the auto-detected release asset
  MEDIAMTX_SHA256=...        checksum for the relay tarball (required to install it)
USAGE
}
for arg in "$@"; do
  case "$arg" in
    --check|--check-only|--preflight) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 1 ;;
  esac
done

# ------------------------------------------------------------------ preflight

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo ./install.sh)"

# Log everything from here on. Done after the root check so the log file is
# always creatable.
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/videowall-install.log
exec > >(tee -a "$LOG_FILE") 2>&1
printf '=== videowall server install%s: %s ===\n' \
  "$([ "$CHECK_ONLY" = 1 ] && echo ' (--check)')" "$(date -Is)"

CHECK_FAILURES=0
ok()    { printf '    [ ok ]  %s\n' "$*"; }
fixed() { printf '    [fixt]  %s\n' "$*"; }
note()  { printf '    [note]  %s\n' "$*"; }
bad()   { printf '    [FAIL]  %s\n' "$*" >&2; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }

# Predictable text handling regardless of the VM's locale setup.
export LC_ALL=C

step "Preflight: shell environment"
info "PATH=$PATH"
# On a minimal VM this is the big one. 'su' (without '-') keeps the calling
# user's PATH, which has no sbin directories, so useradd/groupadd/visudo all
# appear to be missing. Fix it for this run rather than failing, and say why.
SBIN_MISSING=()
for d in /usr/local/sbin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) SBIN_MISSING+=("$d") ;; esac
done
if [ "${#SBIN_MISSING[@]}" -gt 0 ]; then
  PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
  export PATH
  fixed "prepended ${SBIN_MISSING[*]} to PATH for this run"
  note "Your shell was missing the sbin directories. That normally means"
  note "'su' was used instead of 'su -' (su keeps the calling user's PATH)."
  note "useradd, groupadd and visudo live there. For interactive work prefer"
  note "'sudo -i' or 'su -' so your own shell has them too."
else
  ok "sbin directories present in PATH"
fi
[ -n "${BASH_VERSION:-}" ] && ok "running under bash ${BASH_VERSION%%(*}"

step "Preflight: system"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ok "OS: ${PRETTY_NAME:-unknown}"
  case "${ID:-}" in
    debian|raspbian|ubuntu) ;;
    *) note "Not a Debian-family OS (ID=${ID:-?}); package names may differ." ;;
  esac
else
  note "No /etc/os-release; cannot identify the distribution."
fi

# Units are the whole delivery mechanism here, so no systemd is fatal.
if [ -d /run/systemd/system ]; then
  ok "systemd is the running init"
else
  bad "systemd is not running as init (no /run/systemd/system).
           This installs systemd units and cannot work without it —
           containers without systemd are not supported."
fi

# A wildly wrong clock makes HTTPS certificate validation fail with errors
# that look like network problems. Common on fresh VMs with no NTP yet.
CLOCK_YEAR="$(date -u +%Y)"
if [ "$CLOCK_YEAR" -ge 2024 ] && [ "$CLOCK_YEAR" -le 2100 ]; then
  ok "system clock plausible ($(date -uIs))"
else
  bad "system clock looks wrong ($(date -uIs)) — TLS verification will fail.
           Install/enable time sync (e.g. systemd-timesyncd) first."
fi

DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
case "$DEB_ARCH" in
  amd64) MEDIAMTX_ARCH_DEFAULT=linux_amd64 ;;
  arm64) MEDIAMTX_ARCH_DEFAULT=linux_arm64v8 ;;
  armhf) MEDIAMTX_ARCH_DEFAULT=linux_armv7 ;;
  *) MEDIAMTX_ARCH_DEFAULT="" ;;
esac
MEDIAMTX_ARCH="${MEDIAMTX_ARCH:-$MEDIAMTX_ARCH_DEFAULT}"
if [ -n "$MEDIAMTX_ARCH" ]; then
  ok "architecture $DEB_ARCH -> relay asset $MEDIAMTX_ARCH"
else
  bad "unsupported architecture '$DEB_ARCH' — no relay asset is mapped for it.
           Set MEDIAMTX_ARCH=... if you know the right release asset name."
fi

AVAIL_KB="$(df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
if [ "${AVAIL_KB:-0}" -ge 102400 ]; then
  ok "disk space on /opt: $((AVAIL_KB / 1024))MB free"
else
  note "Less than 100MB free on /opt (${AVAIL_KB}KB)."
fi

step "Preflight: required commands"
# Two tiers. The first must already exist — they are all from
# essential/required packages, so a minimal Debian has them, and if one is
# genuinely missing something is very wrong with the image. The second tier
# we can install ourselves, so a miss becomes a package to add rather than
# a failure. Everything is resolved to a full path so a PATH problem is
# obvious in the log.
declare -A PKG_FOR=(
  [useradd]=passwd [groupadd]=passwd [getent]=libc-bin
  [visudo]=sudo [sudo]=sudo [curl]=curl [tar]=tar
  [python3]=python3 [ffmpeg]=ffmpeg
  [systemctl]=systemd [systemd-analyze]=systemd
  [sha256sum]=coreutils [install]=coreutils [df]=coreutils
  [mktemp]=coreutils [chown]=coreutils [chmod]=coreutils [find]=findutils
  [apt-get]=apt [apt-cache]=apt [dpkg]=dpkg
  [sed]=sed [grep]=grep [awk]=mawk
)
NEED_PKGS=()
for cmd in apt-get apt-cache dpkg install sed grep awk find df mktemp chown chmod tar getent; do
  if p="$(command -v "$cmd" 2>/dev/null)"; then
    ok "$cmd -> $p"
  else
    bad "$cmd not found (from package '${PKG_FOR[$cmd]:-?}') — required before
           anything else can run. Check the PATH note above, or install it."
  fi
done
for cmd in useradd groupadd visudo curl sha256sum python3 systemctl systemd-analyze; do
  if p="$(command -v "$cmd" 2>/dev/null)"; then
    ok "$cmd -> $p"
  elif [ -n "${PKG_FOR[$cmd]:-}" ]; then
    NEED_PKGS+=("${PKG_FOR[$cmd]}")
    note "$cmd missing -> will install package '${PKG_FOR[$cmd]}'"
  else
    bad "$cmd not found and no package mapping is known for it."
  fi
done

step "Preflight: sudo configuration"
# The web UI's privileged actions rely on a drop-in in /etc/sudoers.d. If
# sudoers has no includedir line, that drop-in is silently ignored and the
# UI's start/stop/restart buttons quietly do nothing.
if [ -f /etc/sudoers ]; then
  if grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
    ok "/etc/sudoers includes /etc/sudoers.d"
  else
    bad "/etc/sudoers has no '#includedir /etc/sudoers.d' line, so the web UI's
           sudoers drop-in would be ignored. Add that line (with visudo)."
  fi
else
  note "/etc/sudoers absent — the 'sudo' package will provide it."
fi

step "Preflight: target directories"
for d in /etc /opt /usr/local/bin /usr/local/sbin /etc/systemd/system; do
  if [ -d "$d" ]; then
    if [ -w "$d" ]; then ok "writable: $d"; else bad "not writable: $d"; fi
  elif [ "$CHECK_ONLY" = 1 ]; then
    note "missing (would be created): $d"
  else
    mkdir -p "$d" && fixed "created $d"
  fi
done

step "Preflight: repository completeness"
# The most common mistake is copying only server/ instead of cloning the
# repo, so check for the actual files rather than just the directory.
if [ -d "$COMMON_DIR" ]; then
  shopt -s nullglob
  COMMON_FILES=("$COMMON_DIR"/*.py)
  shopt -u nullglob
  if [ "${#COMMON_FILES[@]}" -gt 0 ]; then
    ok "shared helpers: ${#COMMON_FILES[@]} file(s) in common/"
  else
    bad "no .py files in $COMMON_DIR — the clone looks incomplete."
  fi
else
  bad "missing $COMMON_DIR — clone the whole repository, not just server/."
  COMMON_FILES=()
fi
REPO_MISSING=()
for f in bin/videowall-encode.sh bin/videowall-ctl webui/app.py \
         webui/templates/index.html webui/templates/config.html \
         systemd/videowall-encode@.service systemd/mediamtx.service \
         systemd/videowall-webui.service sudoers/videowall-webui \
         config/mediamtx.yml.example config/videowall-server.env.example; do
  [ -e "$REPO_DIR/$f" ] || REPO_MISSING+=("$f")
done
if [ "${#REPO_MISSING[@]}" -eq 0 ]; then
  ok "all expected repository files present"
else
  bad "missing from the clone: ${REPO_MISSING[*]}"
fi

step "Preflight: network"
if getent hosts deb.debian.org >/dev/null 2>&1; then
  ok "DNS resolves deb.debian.org"
else
  bad "cannot resolve deb.debian.org — apt will fail. Check DNS/resolv.conf."
fi
if [ ! -x /usr/local/bin/mediamtx ]; then
  if getent hosts github.com >/dev/null 2>&1; then
    ok "DNS resolves github.com (needed for the relay download)"
  else
    note "cannot resolve github.com — pre-stage the relay tarball in $DIST_DIR
           if this machine has no direct internet access."
  fi
fi

step "Preflight: result"
if [ "$CHECK_FAILURES" -gt 0 ]; then
  die "$CHECK_FAILURES preflight check(s) failed (see [FAIL] lines above).
    Nothing has been installed or changed. Fix those and re-run."
fi
ok "all preflight checks passed"
if [ "$CHECK_ONLY" = 1 ]; then
  printf '\n    --check requested, so stopping here without installing.\n'
  printf '    Re-run without --check to proceed.\n'
  printf '    Log: %s\n' "$LOG_FILE"
  exit 0
fi

# --------------------------------------------------------------------- apt

step "Installing packages"
apt-get update

# Resolve names that have moved between Debian releases rather than assuming.
pkg_exists() { apt-cache show "$1" >/dev/null 2>&1; }
PKGS=(ffmpeg python3 python3-flask python3-psutil sudo curl ca-certificates)
# Anything the preflight found missing from a tier-2 command.
[ "${#NEED_PKGS[@]}" -gt 0 ] && PKGS+=("${NEED_PKGS[@]}")
GUNICORN_PKG=""
for cand in gunicorn python3-gunicorn; do
  if pkg_exists "$cand"; then GUNICORN_PKG="$cand"; break; fi
done
[ -n "$GUNICORN_PKG" ] || die "Neither 'gunicorn' nor 'python3-gunicorn' is available in apt."
PKGS+=("$GUNICORN_PKG")

# De-duplicate, then confirm every name really exists before touching apt, so
# a typo or a renamed package fails with a clear list instead of mid-install.
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | sort -u)
info "packages: ${PKGS[*]}"
MISSING=()
for p in "${PKGS[@]}"; do pkg_exists "$p" || MISSING+=("$p"); done
[ "${#MISSING[@]}" -eq 0 ] || die "These packages are not available in apt: ${MISSING[*]}
    Check that your sources.list has the main component enabled."

DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"

# Re-verify the tier-2 commands now exist; a package installing without
# providing the expected binary is exactly the kind of surprise this catches.
for cmd in useradd groupadd visudo curl python3 systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is still not on PATH after installing packages."
done

GUNICORN_BIN="$(command -v gunicorn3 2>/dev/null || command -v gunicorn 2>/dev/null || true)"
[ -n "$GUNICORN_BIN" ] || die "The '$GUNICORN_PKG' package installed but no gunicorn binary is on PATH."
info "gunicorn: $GUNICORN_BIN"

step "Verifying Python dependencies are importable"
# Fail here, with a clear message, rather than when the service silently
# refuses to start later.
python3 - <<'PY' || die "Python imports failed — see the message above."
import importlib.util, sys
missing = [m for m in ("flask", "werkzeug", "psutil") if importlib.util.find_spec(m) is None]
if missing:
    sys.exit("missing Python modules: " + ", ".join(missing))
PY
info "flask, werkzeug and psutil all import"

step "Checking ffmpeg capabilities"
# NOTE: deliberately not `ffmpeg ... | grep -q`. Under `set -o pipefail`,
# grep -q exits early, ffmpeg dies of SIGPIPE, and the pipeline reports 141 —
# which made this check report "missing" even when the feature was present.
IMAGE2_HELP="$(ffmpeg -hide_banner -h muxer=image2 2>/dev/null || true)"
case "$IMAGE2_HELP" in
  *atomic_writing*) info "image2 muxer supports -atomic_writing (snapshot writes are safe)" ;;
  *) warn "This ffmpeg's image2 muxer has no -atomic_writing option.
    The mosaic snapshot uses it so the web UI can never read a half-written
    JPEG. If the encoders fail to start, set SNAPSHOT=0 in
    /etc/videowall/videowall-server.env." ;;
esac

# ------------------------------------------------------------- users & config

step "Creating users and group"
getent group "$VW_GROUP" >/dev/null || groupadd -r "$VW_GROUP"
id -u "$VW_USER" >/dev/null 2>&1 || \
  useradd -r -M -g "$VW_GROUP" -G video,render -s /usr/sbin/nologin "$VW_USER"
id -u "$VW_WEB_USER" >/dev/null 2>&1 || \
  useradd -r -M -g "$VW_GROUP" -s /usr/sbin/nologin "$VW_WEB_USER"
info "users: $VW_USER, $VW_WEB_USER (group $VW_GROUP)"

step "Installing scripts and configuration"
install -d -m 775 -o root -g "$VW_GROUP" /etc/videowall
install -d -m 755 /opt/videowall/bin /opt/videowall/webui

install -m 755 "$REPO_DIR/bin/videowall-encode.sh" /opt/videowall/bin/videowall-encode.sh
# Root-owned and outside /opt, so it is clearly separate from anything the
# web UI account can write to. This is the sudoers gate; if videowall-web
# could modify it, it would not be a gate.
install -m 755 -o root -g root "$REPO_DIR/bin/videowall-ctl" /usr/local/sbin/videowall-ctl

if [ ! -f /etc/videowall/mediamtx.yml ]; then
  install -m 644 "$REPO_DIR/config/mediamtx.yml.example" /etc/videowall/mediamtx.yml
  info "wrote /etc/videowall/mediamtx.yml"
else
  info "/etc/videowall/mediamtx.yml exists, left alone"
fi

for f in cameras-4k.conf cameras-1080p.conf wall-4k.env wall-1080p.env videowall-server.env; do
  if [ ! -f "/etc/videowall/$f" ]; then
    install -m 664 -o root -g "$VW_GROUP" "$REPO_DIR/config/$f.example" "/etc/videowall/$f"
    info "wrote /etc/videowall/$f"
  else
    info "/etc/videowall/$f exists, left alone"
  fi
done

# ---------------------------------------------------------------- relay binary

step "Installing the MediaMTX relay ($MEDIAMTX_VERSION)"
# The relay is what lets more than one client watch the same wall. It is not
# packaged in Debian, so it comes from the project's own release, and this
# script will not install it unverified.
if [ -x /usr/local/bin/mediamtx ]; then
  info "/usr/local/bin/mediamtx already present, left alone"
  info "(delete it and re-run to upgrade)"
else
  TARBALL="mediamtx_${MEDIAMTX_VERSION}_${MEDIAMTX_ARCH}.tar.gz"
  URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/${TARBALL}"
  install -d -m 755 "$DIST_DIR"
  TARBALL_PATH="$DIST_DIR/$TARBALL"

  if [ -f "$TARBALL_PATH" ]; then
    info "using pre-staged $TARBALL_PATH"
  else
    info "downloading $URL"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
         --connect-timeout 15 -o "$TARBALL_PATH.part" "$URL" \
      || die "Download failed. Check connectivity, or pre-stage the tarball at
    $TARBALL_PATH and re-run. Available releases:
    https://github.com/bluenviron/mediamtx/releases"
    mv "$TARBALL_PATH.part" "$TARBALL_PATH"
  fi

  ACTUAL_SHA="$(sha256sum "$TARBALL_PATH" | awk '{print $1}')"
  if [ -n "${MEDIAMTX_SHA256:-}" ]; then
    [ "$ACTUAL_SHA" = "$MEDIAMTX_SHA256" ] || die "SHA256 mismatch for $TARBALL_PATH
    expected: $MEDIAMTX_SHA256
    actual:   $ACTUAL_SHA
    Refusing to install. Delete the file and investigate."
    info "checksum verified"
  else
    printf '\n'
    printf '    STOPPING: the relay binary is not verified yet.\n\n'
    printf '      file:   %s\n' "$TARBALL_PATH"
    printf '      sha256: %s\n\n' "$ACTUAL_SHA"
    printf '    Compare that with the checksum published for %s at\n' "$MEDIAMTX_VERSION"
    printf '      https://github.com/bluenviron/mediamtx/releases/tag/%s\n' "$MEDIAMTX_VERSION"
    printf '    then re-run:\n'
    printf '      sudo MEDIAMTX_SHA256=%s ./install.sh\n\n' "$ACTUAL_SHA"
    printf '    (This installer will not vouch for a hash it cannot check, and\n'
    printf '     will not install an unverified binary on your behalf. Everything\n'
    printf '     up to this point is already done, so the re-run is quick.)\n'
    exit 2
  fi

  tar -xzf "$TARBALL_PATH" -C "$DIST_DIR" mediamtx \
    || die "Could not extract 'mediamtx' from $TARBALL_PATH — wrong architecture asset?"
  install -m 755 "$DIST_DIR/mediamtx" /usr/local/bin/mediamtx
  # Keep upstream's own config for diffing: MediaMTX's schema has changed
  # across releases and it refuses to start on unknown keys.
  tar -xzf "$TARBALL_PATH" -C "$DIST_DIR" mediamtx.yml 2>/dev/null \
    && install -m 644 "$DIST_DIR/mediamtx.yml" /etc/videowall/mediamtx.reference.yml \
    || warn "Release contains no mediamtx.yml to keep as a reference."
  info "installed $(/usr/local/bin/mediamtx --version 2>/dev/null || echo 'mediamtx (version unknown)')"
fi

[ -x /usr/local/bin/mediamtx ] || die "mediamtx is still not installed at /usr/local/bin/mediamtx."

# -------------------------------------------------------------------- web UI

step "Deploying web UI"
# Glob-free: copies dotfiles too and cannot fail on an unexpanded wildcard.
cp -r "$REPO_DIR/webui/." /opt/videowall/webui/
install -m 644 "${COMMON_FILES[@]}" /opt/videowall/webui/
chown -R "$VW_WEB_USER:$VW_GROUP" /opt/videowall/webui
# Postconditions: catch a partial deploy here rather than via a 500 later.
for f in app.py probe.py vwcommon.py templates/index.html templates/config.html; do
  [ -f "/opt/videowall/webui/$f" ] || die "Deploy incomplete: /opt/videowall/webui/$f is missing."
done
info "deployed $(find /opt/videowall/webui -type f | wc -l) files"

step "Generating credentials"
if [ ! -f /etc/videowall/webui.env ]; then
  # Generated inside Python with the `secrets` module. The previous version
  # used `tr -dc ... < /dev/urandom | head -c 20`, where head exits first,
  # tr dies of SIGPIPE, and `set -o pipefail` turned that into a silent
  # abort of the whole installer at exactly this step.
  mapfile -t CREDS < <(python3 - <<'PY'
import secrets, string
from werkzeug.security import generate_password_hash
alphabet = string.ascii_letters + string.digits
password = "".join(secrets.choice(alphabet) for _ in range(20))
token = "".join(secrets.choice(alphabet) for _ in range(32))
print(password)
print(token)
print(generate_password_hash(password))
print(generate_password_hash(token))
PY
  )
  [ "${#CREDS[@]}" -eq 4 ] || die "Credential generation produced ${#CREDS[@]} lines, expected 4."
  WEBUI_PASSWORD="${CREDS[0]}"
  READ_TOKEN="${CREDS[1]}"
  umask 027
  {
    echo "WEBUI_USER=admin"
    echo "WEBUI_PASSWORD_HASH=${CREDS[2]}"
    echo "WEBUI_READ_TOKEN_HASH=${CREDS[3]}"
  } > /etc/videowall/webui.env
  chmod 640 /etc/videowall/webui.env
  chown root:"$VW_GROUP" /etc/videowall/webui.env
  CREDS_BANNER=1
else
  info "/etc/videowall/webui.env exists, left alone"
  CREDS_BANNER=0
fi

step "Installing the sudoers rule"
TMP_SUDOERS="$(mktemp)"
install -m 440 -o root -g root "$REPO_DIR/sudoers/videowall-webui" "$TMP_SUDOERS"
if visudo -cf "$TMP_SUDOERS" >/dev/null; then
  install -m 440 -o root -g root "$TMP_SUDOERS" /etc/sudoers.d/videowall-webui
  info "installed /etc/sudoers.d/videowall-webui"
else
  warn "sudoers file failed validation and was NOT installed — the web UI's
    start/stop/restart controls will not work until this is fixed."
fi
rm -f "$TMP_SUDOERS"

step "Installing systemd units"
install -m 644 "$REPO_DIR/systemd/videowall-encode@.service" /etc/systemd/system/videowall-encode@.service
install -m 644 "$REPO_DIR/systemd/mediamtx.service" /etc/systemd/system/mediamtx.service
sed "s#GUNICORN_BIN#$GUNICORN_BIN#" "$REPO_DIR/systemd/videowall-webui.service" \
  > /etc/systemd/system/videowall-webui.service
grep -q '^ExecStart=/' /etc/systemd/system/videowall-webui.service \
  || die "GUNICORN_BIN substitution failed in videowall-webui.service."

# Remove the static units this replaces, so they cannot linger and fight the
# templated instances over the same runtime directory.
for old in videowall-encode-4k.service videowall-encode-1080p.service; do
  if [ -f "/etc/systemd/system/$old" ]; then
    systemctl disable --now "$old" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$old"
    info "removed obsolete $old"
  fi
done
systemctl daemon-reload
systemd-analyze verify videowall-encode@4k.service 2>&1 | grep -v '^$' || true

step "Done"
if [ "$CREDS_BANNER" = "1" ]; then
  cat <<EOF

    CREDENTIALS — save these now. They are stored only as hashes and will
    not be shown again.

      web UI user:       admin
      web UI password:   $WEBUI_PASSWORD

      client read token: $READ_TOKEN
        Paste this into each Pi's SERVER_API_TOKEN so it can list walls
        without ever holding the admin password.

EOF
fi

cat <<'EOF'
    Next steps:

    1. Camera URLs: edit /etc/videowall/cameras-*.conf, or start the web UI
       (below) and use its Config page, which can also create, enable,
       disable and delete walls.

    2. Start the relay, the walls, then the web UI:
         systemctl enable --now mediamtx.service
         systemctl enable --now videowall-encode@4k.service
         systemctl enable --now videowall-encode@1080p.service
         systemctl enable --now videowall-webui.service

       Each wall is one instance of the templated unit, so a wall named
       "lobby" is just videowall-encode@lobby.service. The web UI does this
       for you when you create or enable a wall.

    3. Firewall: clients need inbound UDP 8890 (the relay's SRT read port),
       and you need TCP 8080 for the web UI. Over Tailscale, scope both to
       the tailscale0 interface rather than opening them globally. The
       relay's RTSP publish port and its API are bound to loopback.

    4. Open http://<this-server>:8080/ and log in as admin.

    If anything failed, the full transcript is in /var/log/videowall-install.log
EOF
