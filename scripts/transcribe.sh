#!/bin/bash
# transcribe.sh — Transcribe audio file using MLX Whisper
# Usage: transcribe.sh <input_wav> <output_dir> [model_dir]
set -euo pipefail

INPUT="${1:?Usage: transcribe.sh <input_wav> <output_dir> [model_dir]}"
OUTPUT_DIR="${2:?Usage: transcribe.sh <input_wav> <output_dir> [model_dir]}"
MODEL_DIR="${3:-}"

if [[ ! -f "$INPUT" ]]; then
    echo "FAIL: Input file not found: $INPUT" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

MLX_SCRIPT="$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py"

echo "Transcribing with MLX Whisper..."
if [[ -n "$MODEL_DIR" ]]; then
    python3 "$MLX_SCRIPT" "$INPUT" "$OUTPUT_DIR" "$MODEL_DIR" \
        2>"$OUTPUT_DIR/mlx_transcribe.log"
else
    python3 "$MLX_SCRIPT" "$INPUT" "$OUTPUT_DIR" \
        2>"$OUTPUT_DIR/mlx_transcribe.log"
fi

TRANSCRIPT_FILE="$OUTPUT_DIR/$(basename "$INPUT" .wav).txt"

if [[ ! -s "$TRANSCRIPT_FILE" ]]; then
    echo "FAIL: mlx_transcribe produced no transcript" >&2
    cat "$OUTPUT_DIR/mlx_transcribe.log" >&2
    exit 1
fi

echo "Transcript saved: $TRANSCRIPT_FILE"
cat "$TRANSCRIPT_FILE"
