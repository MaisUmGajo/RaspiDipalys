#!/bin/bash
# Composite one wall's RTSP camera streams into a mosaic, H.264-encode it, and
# publish it into the MediaMTX relay (which fans it out to any number of Pi
# clients over SRT).
#
# Usage: videowall-encode.sh <wall-slug>
#
# All tunables live in /etc/videowall/wall-<slug>.env (per-wall) and
# /etc/videowall/videowall-server.env (shared), so the web UI has small plain
# files to edit and neither this script nor the systemd unit needs touching.
#
# Exit code 78 (EX_CONFIG) is used for every "this wall is misconfigured or
# switched off" case. The systemd unit sets RestartPreventExitStatus=78, so
# such a wall stops cleanly instead of hot-looping every RestartSec forever.
set -euo pipefail

EX_CONFIG=78

die_config() { echo "videowall-encode: $*" >&2; exit "$EX_CONFIG"; }

[ "$#" -eq 1 ] || die_config "usage: videowall-encode.sh <wall-slug>"

WALL="$1"
WALL_ENV="/etc/videowall/wall-${WALL}.env"
GLOBAL_ENV="/etc/videowall/videowall-server.env"

[ -f "$WALL_ENV" ] || die_config "missing $WALL_ENV"
# shellcheck disable=SC1090
source "$WALL_ENV"
# shellcheck disable=SC1090
[ -f "$GLOBAL_ENV" ] && source "$GLOBAL_ENV"

# A wall can be configured but deliberately not running. The web UI stops and
# disables the unit when you switch a wall off; this check means a stray manual
# start can't contradict that.
ENABLED="${ENABLED:-true}"
if [ "$ENABLED" != "true" ]; then
  die_config "wall '$WALL' is disabled (ENABLED=$ENABLED in $WALL_ENV); not starting"
fi

for var in ROWS COLS CANVAS_W CANVAS_H BITRATE_KBPS CAMERAS_FILE; do
  [ -n "${!var:-}" ] || die_config "$var not set in $WALL_ENV"
done

FPS="${FPS:-15}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
MEDIAMTX_RTSP_HOST="${MEDIAMTX_RTSP_HOST:-127.0.0.1}"
MEDIAMTX_RTSP_PORT="${MEDIAMTX_RTSP_PORT:-8554}"
SNAPSHOT="${SNAPSHOT:-1}"
SNAPSHOT_WIDTH="${SNAPSHOT_WIDTH:-1280}"
SNAPSHOT_INTERVAL_S="${SNAPSHOT_INTERVAL_S:-5}"

# No SRT_LATENCY_MS here: clients now subscribe to the relay and request their
# own latency, so this script never builds an SRT URL.

# Which encoder to use: none (libx264), vaapi (Intel/AMD) or nvenc (NVIDIA).
# VAAPI=1 predates this setting and still means HWACCEL=vaapi, so existing
# /etc/videowall/videowall-server.env files keep working untouched.
VAAPI="${VAAPI:-0}"
HWACCEL="${HWACCEL:-}"
if [ -z "$HWACCEL" ]; then
  if [ "$VAAPI" = "1" ]; then HWACCEL=vaapi; else HWACCEL=none; fi
fi

case "$HWACCEL" in
  none|vaapi|nvenc) ;;
  *)
    echo "videowall-encode: HWACCEL must be one of: none, vaapi, nvenc (got '$HWACCEL')" >&2
    exit 1
    ;;
esac

# Check the encoder is actually present in this ffmpeg build. Without this the
# failure is a wall of ffmpeg output ending in "Unknown encoder", repeated
# every five seconds by systemd — this says plainly what is wrong instead.
# Capture the encoder list into a variable and match on it, rather than
# piping ffmpeg into `grep -q`. Under `set -o pipefail` that pipeline reports
# FAILURE on success: grep -q exits the moment it matches, ffmpeg is killed by
# SIGPIPE (141), and pipefail surfaces that as the pipeline's status — so the
# check concludes the encoder is missing precisely when it is present. Same
# trap as `tr ... | head -c` in install.sh.
FFMPEG_ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"

case "$HWACCEL" in
  vaapi)
    case "$FFMPEG_ENCODERS" in
      *h264_vaapi*) ;;
      *)
        echo "videowall-encode: HWACCEL=vaapi but this ffmpeg build has no h264_vaapi encoder." >&2
        exit 1
        ;;
    esac
    ;;
  nvenc)
    case "$FFMPEG_ENCODERS" in
      *h264_nvenc*) ;;
      *)
        echo "videowall-encode: HWACCEL=nvenc but this ffmpeg build has no h264_nvenc encoder." >&2
        exit 1
        ;;
    esac
    # Debian's ffmpeg lists h264_nvenc even with no NVIDIA driver loaded, so
    # the check above passes on a machine that has no GPU at all and ffmpeg
    # then fails later with a much less obvious CUDA error. Check for the
    # device node too — this is the case you actually hit when a card has not
    # been passed through to the VM, or the driver did not load.
    if ! compgen -G "/dev/nvidia[0-9]*" >/dev/null; then
      echo "videowall-encode: HWACCEL=nvenc but no /dev/nvidia* device is present." >&2
      echo "                  The NVIDIA driver is not loaded, or the GPU is not visible" >&2
      echo "                  to this machine (on a VM, check PCI passthrough)." >&2
      echo "                  Verify with 'nvidia-smi'. Set HWACCEL=none to fall back" >&2
      echo "                  to software encoding." >&2
      exit 1
    fi
    ;;
esac

mapfile -t URLS < <(grep -vE '^[[:space:]]*(#|$)' "$CAMERAS_FILE")

N=$((ROWS * COLS))
if [ "${#URLS[@]}" -ne "$N" ]; then
  die_config "expected $N URLs in $CAMERAS_FILE (rows=$ROWS cols=$COLS), found ${#URLS[@]}"
fi

# Cell size: even dimensions required for 4:2:0 chroma subsampling.
CELL_W=$((CANVAS_W / COLS))
CELL_H=$((CANVAS_H / ROWS))
CELL_W=$((CELL_W - (CELL_W % 2)))
CELL_H=$((CELL_H - (CELL_H % 2)))

# Runtime dir for the progress file and the snapshot. Under systemd this is
# created by RuntimeDirectory=videowall (owned by this service user); /run is
# not writable by a normal user, so fall back for manual/debug runs, otherwise
# ffmpeg would abort trying to open its -progress file.
RUN_DIR="/run/videowall"
if ! mkdir -p "$RUN_DIR" 2>/dev/null || [ ! -w "$RUN_DIR" ]; then
  RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/videowall"
  mkdir -p "$RUN_DIR" 2>/dev/null
fi
PROGRESS_FILE="$RUN_DIR/progress-${WALL}.txt"
SNAPSHOT_FILE="$RUN_DIR/snapshot-${WALL}.jpg"

# Probe every source before launching ffmpeg, so one dead camera cannot take
# down the whole wall.
#
# ffmpeg opens ALL of its inputs before producing a single frame, and if any
# one of them fails the entire process exits ("Error opening input files").
# Under systemd that becomes an endless restart loop in which nine working
# cameras display nothing because a tenth is unplugged, on a wall whose whole
# purpose is to show the cameras that ARE up. So: check each source first and
# feed a black frame generator in place of any that will not open. That cell
# goes black and the rest of the wall runs.
#
# Probes run concurrently, but only PROBE_JOBS at a time, and anything that
# fails is retried once on its own afterwards.
#
# Both limits are there for the same reason: an NVR serving every camera on
# this wall is a single host, and hitting it with N simultaneous RTSP session
# setups makes it throttle or refuse them. Observed on a UniFi Protect NVR —
# nine parallel probes reported three cameras dead that each probed fine in
# 2-3s on their own, which blacked out three working cells. False negatives
# here are worse than the failure this whole mechanism exists to avoid, so a
# source is only declared dead after it has failed a probe it had to itself.
#
# Fully sequential probing would be safest but too slow: thirteen unreachable
# cameras at the timeout each would add minutes to every start.
PROBE_TIMEOUT_S="${PROBE_TIMEOUT_S:-8}"
PROBE_JOBS="${PROBE_JOBS:-3}"
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT

probe_one() {
  timeout "$PROBE_TIMEOUT_S" ffprobe -v error \
    -rtsp_transport "$RTSP_TRANSPORT" \
    -select_streams v:0 -show_entries stream=codec_name \
    -of csv=p=0 "$1" >/dev/null 2>&1
}

for ((i = 0; i < N; i++)); do
  while [ "$(jobs -rp | wc -l)" -ge "$PROBE_JOBS" ]; do wait -n; done
  (
    if probe_one "${URLS[$i]}"; then
      echo ok > "$PROBE_DIR/$i"
    fi
  ) &
done
wait

# Second chance, one at a time, for anything the concurrent pass rejected.
for ((i = 0; i < N; i++)); do
  if [ ! -s "$PROBE_DIR/$i" ] && probe_one "${URLS[$i]}"; then
    echo ok > "$PROBE_DIR/$i"
    echo "videowall-encode: source $((i + 1)) failed the concurrent probe but succeeded on retry" >&2
  fi
done

DEAD_CELLS=()
LIVE_COUNT=0
declare -a SOURCE_OK
for ((i = 0; i < N; i++)); do
  if [ -s "$PROBE_DIR/$i" ]; then
    SOURCE_OK[i]=1
    LIVE_COUNT=$((LIVE_COUNT + 1))
  else
    SOURCE_OK[i]=0
    # Report positions 1-based, matching the row-major order documented in
    # the cameras-*.conf files.
    DEAD_CELLS+=("$((i + 1))")
  fi
done
rm -rf "$PROBE_DIR"
trap - EXIT

# Only refuse to start when there is genuinely nothing to show. A wall of
# entirely black cells would look identical to a broken encoder while still
# burning CPU encoding nothing, so fail loudly instead and let systemd retry.
#
# Deliberately exit 1 rather than die_config's EX_CONFIG (78): the unit sets
# RestartPreventExitStatus=78, which is right for "this wall is misconfigured
# or switched off" but wrong here. Every camera being unreachable is usually
# transient — the NVR is rebooting, the tunnel is down — and must be retried,
# not latched off until someone notices.
if [ "$LIVE_COUNT" -eq 0 ]; then
  echo "videowall-encode: none of the $N sources in $CAMERAS_FILE are usable — not starting the '$WALL' wall" >&2
  exit 1
fi

if [ "${#DEAD_CELLS[@]}" -gt 0 ]; then
  echo "videowall-encode: '$WALL' starting with $LIVE_COUNT/$N sources live; showing black in cell(s): ${DEAD_CELLS[*]}" >&2
fi

FFMPEG_ARGS=(-hide_banner -loglevel warning -nostdin)
if [ "$HWACCEL" = "vaapi" ]; then
  FFMPEG_ARGS+=(-vaapi_device "${VAAPI_DEVICE:-/dev/dri/renderD128}")
fi

for ((i = 0; i < N; i++)); do
  if [ "${SOURCE_OK[i]}" -eq 1 ]; then
    # NVDEC decodes the camera streams on the GPU as well as encoding there.
    # Frames still come back to system memory for the xstack mosaic, because
    # that filter runs on the CPU — so this offloads decoding, not the whole
    # pipeline. Off by default: it is the encode that dominates at 4K, and a
    # driver too old for a given camera's stream fails the input outright.
    if [ "$HWACCEL" = "nvenc" ] && [ "${NVDEC:-0}" = "1" ]; then
      FFMPEG_ARGS+=(-hwaccel cuda)
    fi
    FFMPEG_ARGS+=(-rtsp_transport "$RTSP_TRANSPORT" -fflags nobuffer -i "${URLS[$i]}")
  else
    # -re paces this synthetic source at wall-clock speed. Without it lavfi
    # generates frames as fast as the CPU allows while the real cameras arrive
    # in real time, and the filter graph buffers the difference without bound.
    FFMPEG_ARGS+=(-re -f lavfi -i "color=c=black:s=${CELL_W}x${CELL_H}:r=${FPS}")
  fi
done

# Per-input: drop to target fps, scale to fit the cell preserving aspect
# ratio, letterbox-pad to the exact cell size.
FILTER=""
for ((i = 0; i < N; i++)); do
  FILTER+="[$i:v]fps=${FPS},scale=${CELL_W}:${CELL_H}:force_original_aspect_ratio=decrease,pad=${CELL_W}:${CELL_H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[v$i];"
done

LAYOUT_PARTS=()
for ((r = 0; r < ROWS; r++)); do
  for ((c = 0; c < COLS; c++)); do
    LAYOUT_PARTS+=("$((c * CELL_W))_$((r * CELL_H))")
  done
done
LAYOUT=$(IFS='|'; echo "${LAYOUT_PARTS[*]}")

INPUT_LABELS=""
for ((i = 0; i < N; i++)); do INPUT_LABELS+="[v$i]"; done

FILTER+="${INPUT_LABELS}xstack=inputs=${N}:layout=${LAYOUT}:fill=black[mix]"

# Fan the mosaic out INSIDE the graph. A filter label is consumed by the first
# -map that claims it, so two "-map [mix]" would fail at startup; split is
# refcount-based and effectively free. The split must happen BEFORE any
# hwupload so the snapshot branch stays in system memory (no readback).
if [ "$SNAPSHOT" = "1" ]; then
  FILTER+=";[mix]split=2[enc][snapraw]"
  # Rate-limit before scaling, inside the graph: -r on the output would filter
  # at the mux stage, i.e. scale every frame and then throw most away.
  FILTER+=";[snapraw]fps=1/${SNAPSHOT_INTERVAL_S},scale=${SNAPSHOT_WIDTH}:-2[snap]"
else
  FILTER+=";[mix]null[enc]"
fi

GOP=$((FPS * 2))

# Close the graph from the [enc] branch produced above (the mosaic is split so
# the snapshot can tee off it), so every encoder path ends at [out].
#
# Only VAAPI needs real work here: its frames have to be uploaded to the GPU.
# NVENC takes ordinary system-memory frames and uploads them itself, so it
# ends the chain exactly as libx264 does.
case "$HWACCEL" in
  vaapi)
    FILTER+=";[enc]format=nv12,hwupload[out]"
    ENCODE_ARGS=(-c:v h264_vaapi -g "$GOP")
    ;;
  nvenc)
    # p4 is NVENC's middle preset: comfortably realtime for a 4K mosaic on
    # any NVENC generation while noticeably better quality than p1. tune=ll
    # (low latency) is the counterpart of libx264's zerolatency, and -bf 0
    # keeps it consistent with the other two paths — B-frames would add
    # reordering delay for no benefit on a live wall.
    #
    # CBR because this feeds a fixed-bitrate relay stream; the
    # -b:v/-maxrate/-bufsize trio below applies to all three encoders alike.
    FILTER+=";[enc]null[out]"
    ENCODE_ARGS=(
      -c:v h264_nvenc
      -preset "${NVENC_PRESET:-p4}"
      -tune "${NVENC_TUNE:-ll}"
      -profile:v high
      -rc cbr
      -pix_fmt yuv420p
      -g "$GOP"
      -bf 0
    )
    # Which GPU, when the box has more than one.
    [ -n "${NVENC_DEVICE:-}" ] && ENCODE_ARGS+=(-gpu "$NVENC_DEVICE")
    ;;
  none)
    FILTER+=";[enc]null[out]"
    ENCODE_ARGS=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p -g "$GOP" -bf 0)
    ;;
esac

# The snapshot output MUST come after the publish output: ffmpeg derives the
# frame=/fps= fields that -progress reports from the FIRST video output, so
# leading with the snapshot would silently make the dashboard report the JPEG
# writer's 0.2fps as the encoder's rate. -atomic_writing makes image2 write to
# a temp name and rename(), so the web UI can never read a half-written JPEG.
SNAP_OUT=()
if [ "$SNAPSHOT" = "1" ]; then
  SNAP_OUT=(-map "[snap]" -an
            -c:v mjpeg -q:v 6 -pix_fmt yuvj420p
            -f image2 -update 1 -atomic_writing 1 "$SNAPSHOT_FILE")
fi

# Publish into MediaMTX over loopback RTSP (lossless, and it remuxes rather
# than re-encodes). Clients then read from MediaMTX over SRT. Unlike an SRT
# listener, this does not block waiting for a client, so frames — and
# therefore snapshots — flow as soon as the encoder starts.
exec ffmpeg "${FFMPEG_ARGS[@]}" \
  -filter_complex "$FILTER" -map "[out]" -an \
  "${ENCODE_ARGS[@]}" \
  -b:v "${BITRATE_KBPS}k" -maxrate "${BITRATE_KBPS}k" -bufsize "$((BITRATE_KBPS * 2))k" \
  -progress "$PROGRESS_FILE" \
  -f rtsp -rtsp_transport tcp "rtsp://${MEDIAMTX_RTSP_HOST}:${MEDIAMTX_RTSP_PORT}/${WALL}" \
  "${SNAP_OUT[@]}"
