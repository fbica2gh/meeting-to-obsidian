#!/bin/bash
# extract_smart_keyframes.sh — Extract keyframes using scene detection with fallback
# Usage: extract_smart_keyframes.sh <input_mp4> <output_dir> [threshold]
set -euo pipefail

INPUT="${1:?Usage: extract_smart_keyframes.sh <input_mp4> <output_dir> [threshold]}"
OUTPUT_DIR="${2:?Usage: extract_smart_keyframes.sh <input_mp4> <output_dir> [threshold]}"
THRESHOLD="${3:-0.3}"

FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="/opt/homebrew/bin/ffprobe"

mkdir -p "$OUTPUT_DIR"

# Get video duration
DURATION=$($FFPROBE -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null || echo "0")

echo "Input: $INPUT"
echo "Duration: ${DURATION}s"

# Try scene detection first
echo "Trying scene detection (threshold=$THRESHOLD)..."
$FFMPEG -nostdin -i "$INPUT" \
    -vf "select='gt(scene,${THRESHOLD})',scale=1920:-1" \
    -fps_mode vfr \
    -q:v 2 \
    -pix_fmt yuvj420p \
    "$OUTPUT_DIR/frame_%04d.jpg" \
    -y -loglevel warning 2>/dev/null || true

FRAME_COUNT=$(ls -1 "$OUTPUT_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')

if [[ "$FRAME_COUNT" -eq 0 ]]; then
    echo "Scene detection found no frames, falling back to fixed interval extraction..."
    # Fallback: extract frames at fixed intervals (every 10 seconds)
    INTERVAL=10
    $FFMPEG -nostdin -i "$INPUT" \
        -vf "fps=1/${INTERVAL},scale=1920:-1" \
        -q:v 2 \
        -pix_fmt yuvj420p \
        "$OUTPUT_DIR/frame_%04d.jpg" \
        -y -loglevel warning
    FRAME_COUNT=$(ls -1 "$OUTPUT_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')
fi

echo "Extracted $FRAME_COUNT frames to $OUTPUT_DIR"

# Generate manifest with timestamps
MANIFEST="$OUTPUT_DIR/manifest.txt"
> "$MANIFEST"

# Try to extract timestamps from scene detection
TIMESTAMPS_FILE="$OUTPUT_DIR/timestamps.txt"
$FFMPEG -nostdin -i "$INPUT" \
    -vf "select='gt(scene,${THRESHOLD})',showinfo" \
    -fps_mode vfr \
    -f null - 2>&1 | grep "pts_time:" | while read -r line; do
    TIMESTAMP=$(echo "$line" | grep -o 'pts_time:[0-9.]*' | cut -d: -f2)
    if [[ -n "$TIMESTAMP" ]]; then
        MINS=$(echo "$TIMESTAMP/60" | bc)
        SECS=$(echo "$TIMESTAMP%60/1" | bc)
        echo "${MINS}:${SECS}"
    fi
done > "$TIMESTAMPS_FILE" 2>/dev/null || true

# Build manifest
if [[ -s "$TIMESTAMPS_FILE" ]] && [[ $(wc -l < "$TIMESTAMPS_FILE") -eq "$FRAME_COUNT" ]]; then
    paste -d'|' "$TIMESTAMPS_FILE" <(ls -1 "$OUTPUT_DIR"/frame_*.jpg | xargs -I{} basename {}) > "$MANIFEST"
else
    # Fallback: assign sequential timestamps based on frame index
    INTERVAL=10
    i=0
    for frame in "$OUTPUT_DIR"/frame_*.jpg; do
        TS=$(( i * INTERVAL ))
        MINS=$(( TS / 60 ))
        SECS=$(( TS % 60 ))
        BASENAME=$(basename "$frame")
        echo "${MINS}:${SECS}|${BASENAME}" >> "$MANIFEST"
        i=$((i + 1))
    done
fi

echo "Manifest saved: $MANIFEST"
