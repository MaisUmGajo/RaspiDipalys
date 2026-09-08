#!/bin/bash
# Composite N RTSP streams into a ROWSxCOLS mosaic and display it fullscreen
# on the given X display.
#
# Usage: videowall-grid.sh <urls-file> <rows> <cols> <canvas-w> <canvas-h>
#
# DISPLAY must already be set by the caller (xinitrc sets it to :0.0 / :0.1).
set -euo pipefail

CONF_FILE="$1"
ROWS="$2"
COLS="$3"
OUT_W="$4"
OUT_H="$5"

ENV_FILE="/etc/videowall/videowall.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

FPS="${FPS:-12}"
HWDECODE="${HWDECODE:-1}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"

mapfile -t URLS < <(grep -vE '^[[:space:]]*(#|$)' "$CONF_FILE")

N=$((ROWS * COLS))
if [ "${#URLS[@]}" -ne "$N" ]; then
  echo "videowall-grid: expected $N URLs in $CONF_FILE (rows=$ROWS cols=$COLS), found ${#URLS[@]}" >&2
  exit 1
fi

# Cell size: even dimensions required for 4:2:0 chroma subsampling.
CELL_W=$((OUT_W / COLS))
CELL_H=$((OUT_H / ROWS))
CELL_W=$((CELL_W - (CELL_W % 2)))
CELL_H=$((CELL_H - (CELL_H % 2)))

FFMPEG_ARGS=(-hide_banner -loglevel warning -nostdin)

for url in "${URLS[@]}"; do
  if [ "$HWDECODE" = "1" ]; then
    FFMPEG_ARGS+=(-c:v h264_v4l2m2m)
  fi
  FFMPEG_ARGS+=(-rtsp_transport "$RTSP_TRANSPORT" -fflags nobuffer -flags low_delay -i "$url")
done

# Per-input: drop to target fps, scale to fit the cell preserving aspect
# ratio, letterbox-pad to the exact cell size (avoids stretched/distorted
# picture when a camera's stream isn't exactly cell-shaped).
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

FILTER+="${INPUT_LABELS}xstack=inputs=${N}:layout=${LAYOUT}:fill=black[out]"

FFMPEG_ARGS+=(-filter_complex "$FILTER" -map "[out]" -an -f nut -c:v rawvideo pipe:1)

ffmpeg "${FFMPEG_ARGS[@]}" \
  | mpv --no-config --fullscreen --no-audio --really-quiet --idle=no \
        --vo=gpu --demuxer=lavf --demuxer-lavf-format=nut -
