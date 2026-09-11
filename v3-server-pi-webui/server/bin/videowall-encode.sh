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
VAAPI="${VAAPI:-0}"
MEDIAMTX_RTSP_HOST="${MEDIAMTX_RTSP_HOST:-127.0.0.1}"
MEDIAMTX_RTSP_PORT="${MEDIAMTX_RTSP_PORT:-8554}"
SNAPSHOT="${SNAPSHOT:-1}"
SNAPSHOT_WIDTH="${SNAPSHOT_WIDTH:-1280}"
SNAPSHOT_INTERVAL_S="${SNAPSHOT_INTERVAL_S:-5}"

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

FFMPEG_ARGS=(-hide_banner -loglevel warning -nostdin)
if [ "$VAAPI" = "1" ]; then
  FFMPEG_ARGS+=(-vaapi_device /dev/dri/renderD128)
fi

for url in "${URLS[@]}"; do
  FFMPEG_ARGS+=(-rtsp_transport "$RTSP_TRANSPORT" -fflags nobuffer -i "$url")
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

if [ "$VAAPI" = "1" ]; then
  FILTER+=";[enc]format=nv12,hwupload[out]"
  ENCODE_ARGS=(-c:v h264_vaapi -g "$GOP")
else
  FILTER+=";[enc]null[out]"
  ENCODE_ARGS=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p -g "$GOP" -bf 0)
fi

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
