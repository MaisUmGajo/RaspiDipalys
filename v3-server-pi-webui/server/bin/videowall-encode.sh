#!/bin/bash
# Composite a wall's RTSP camera streams into a mosaic, H.264-encode it, and
# publish it over SRT for a single downstream consumer (the Pi) to pull.
#
# Usage: videowall-encode.sh <wall-name>   (e.g. "4k" or "1080p")
#
# All tunables live in /etc/videowall/wall-<wall-name>.env (per-wall) and
# /etc/videowall/videowall-server.env (shared) so the web UI has exactly
# two small files to edit per wall instead of touching this script or the
# systemd units.
set -euo pipefail

WALL="$1"
WALL_ENV="/etc/videowall/wall-${WALL}.env"
GLOBAL_ENV="/etc/videowall/videowall-server.env"

[ -f "$WALL_ENV" ] || { echo "videowall-encode: missing $WALL_ENV" >&2; exit 1; }
# shellcheck disable=SC1090
source "$WALL_ENV"
# shellcheck disable=SC1090
[ -f "$GLOBAL_ENV" ] && source "$GLOBAL_ENV"

: "${ROWS:?ROWS not set in $WALL_ENV}"
: "${COLS:?COLS not set in $WALL_ENV}"
: "${CANVAS_W:?CANVAS_W not set in $WALL_ENV}"
: "${CANVAS_H:?CANVAS_H not set in $WALL_ENV}"
: "${PORT:?PORT not set in $WALL_ENV}"
: "${BITRATE_KBPS:?BITRATE_KBPS not set in $WALL_ENV}"
: "${CAMERAS_FILE:?CAMERAS_FILE not set in $WALL_ENV}"

FPS="${FPS:-15}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
SRT_LATENCY_MS="${SRT_LATENCY_MS:-400}"
VAAPI="${VAAPI:-0}"

mapfile -t URLS < <(grep -vE '^[[:space:]]*(#|$)' "$CAMERAS_FILE")

N=$((ROWS * COLS))
if [ "${#URLS[@]}" -ne "$N" ]; then
  echo "videowall-encode: expected $N URLs in $CAMERAS_FILE (rows=$ROWS cols=$COLS), found ${#URLS[@]}" >&2
  exit 1
fi

# Cell size: even dimensions required for 4:2:0 chroma subsampling.
CELL_W=$((CANVAS_W / COLS))
CELL_H=$((CANVAS_H / ROWS))
CELL_W=$((CELL_W - (CELL_W % 2)))
CELL_H=$((CELL_H - (CELL_H % 2)))

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

GOP=$((FPS * 2))

if [ "$VAAPI" = "1" ]; then
  MIX_LABEL="mix"
else
  MIX_LABEL="out"
fi
FILTER+="${INPUT_LABELS}xstack=inputs=${N}:layout=${LAYOUT}:fill=black[${MIX_LABEL}]"

if [ "$VAAPI" = "1" ]; then
  FILTER+=",format=nv12,hwupload[out]"
  ENCODE_ARGS=(-c:v h264_vaapi -g "$GOP")
else
  ENCODE_ARGS=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p -g "$GOP" -bf 0)
fi

# Periodic machine-readable progress (frame/fps/bitrate/speed) for the web
# UI to read. Under systemd, /run/videowall is created by RuntimeDirectory=
# (owned by this service user). But /run is NOT writable by a normal user, so
# if the dir is missing/unwritable — e.g. when running this script by hand for
# debugging, outside systemd — fall back to a user-writable location. Without
# this, ffmpeg's -progress would fail to open its file and the whole encode
# would abort, not just lose the stats.
RUN_DIR="/run/videowall"
if ! mkdir -p "$RUN_DIR" 2>/dev/null || [ ! -w "$RUN_DIR" ]; then
  RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/videowall"
  mkdir -p "$RUN_DIR" 2>/dev/null
fi
PROGRESS_FILE="$RUN_DIR/progress-${WALL}.txt"

exec ffmpeg "${FFMPEG_ARGS[@]}" \
  -filter_complex "$FILTER" -map "[out]" -an \
  "${ENCODE_ARGS[@]}" \
  -b:v "${BITRATE_KBPS}k" -maxrate "${BITRATE_KBPS}k" -bufsize "$((BITRATE_KBPS * 2))k" \
  -progress "$PROGRESS_FILE" \
  -f mpegts "srt://0.0.0.0:${PORT}?mode=listener&latency=${SRT_LATENCY_MS}"
