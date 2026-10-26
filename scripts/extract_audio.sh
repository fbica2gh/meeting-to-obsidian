#!/bin/bash
# extract_audio.sh — Extract audio from Tencent Meeting recording
# Usage: extract_audio.sh <input_mp4> <output_wav>
set -euo pipefail

INPUT="${1:?Usage: extract_audio.sh <input_mp4> <output_wav>}"
OUTPUT="${2:?Usage: extract_audio.sh <input_mp4> <output_wav>}"

FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="/opt/homebrew/bin/ffprobe"

# Get duration
DURATION=$($FFPROBE -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null || echo "0")
DURATION_FMT=$(printf "%d:%02d" "$(echo "$DURATION/60" | bc)" "$(echo "$DURATION%60/1" | bc)")

echo "Input: $INPUT"
echo "Duration: $DURATION_FMT"
echo "Extracting audio..."

$FFMPEG -nostdin -i "$INPUT" \
    -vn -acodec pcm_s16le -ar 16000 -ac 1 \
    "$OUTPUT" -y -loglevel warning

if [[ ! -s "$OUTPUT" ]]; then
    echo "FAIL: ffmpeg produced no output" >&2
    exit 1
fi

echo "Audio extracted: $OUTPUT"
echo "DURATION=$DURATION_FMT"
