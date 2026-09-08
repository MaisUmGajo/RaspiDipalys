#!/bin/bash
# Composite N RTSP camera streams into one ROWSxCOLS mosaic, H.264-encode it,
# and publish it over SRT for a single downstream consumer (the Pi) to pull.
#
# Usage: videowall-encode.sh <urls-file> <rows> <cols> <canvas-w> <canvas-h> <srt-port> <bitrate-kbps>
set -euo pipefail

CONF_FILE="$1"
ROWS="$2"
COLS="$3"
OUT_W="$4"
OUT_H="$5"
PORT="$6"
BITRATE_KBPS="$7"

ENV_FILE="/etc/videowall/videowall-server.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

FPS="${FPS:-15}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
SRT_LATENCY_MS="${SRT_LATENCY_MS:-200}"
VAAPI="${VAAPI:-0}"

mapfile -t URLS < <(grep -vE '^[[:space:]]*(#|$)' "$CONF_FILE")

N=$((ROWS * COLS))
if [ "${#URLS[@]}" -ne "$N" ]; then
  echo "videowall-encode: expected $N URLs in $CONF_FILE (rows=$ROWS cols=$COLS), found ${#URLS[@]}" >&2
  exit 1
fi

# Cell size: even dimensions required for 4:2:0 chroma subsampling.
CELL_W=$((OUT_W / COLS))
CELL_H=$((OUT_H / ROWS))
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

if [ "$VAAPI" = "1" ]; then
  MIX_LABEL="mix"
else
  MIX_LABEL="out"
fi
FILTER+="${INPUT_LABELS}xstack=inputs=${N}:layout=${LAYOUT}:fill=black[${MIX_LABEL}]"

GOP=$((FPS * 2))

if [ "$VAAPI" = "1" ]; then
  FILTER+=",format=nv12,hwupload[out]"
  ENCODE_ARGS=(-c:v h264_vaapi -g "$GOP")
else
  ENCODE_ARGS=(-c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p -g "$GOP" -bf 0)
fi

exec ffmpeg "${FFMPEG_ARGS[@]}" \
  -filter_complex "$FILTER" -map "[out]" -an \
  "${ENCODE_ARGS[@]}" \
  -b:v "${BITRATE_KBPS}k" -maxrate "${BITRATE_KBPS}k" -bufsize "$((BITRATE_KBPS * 2))k" \
  -f mpegts "srt://0.0.0.0:${PORT}?mode=listener&latency=${SRT_LATENCY_MS}"
