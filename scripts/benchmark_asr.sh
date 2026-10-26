#!/bin/bash
# benchmark_asr.sh — ASR 三方实测：whisper-small / whisper-large-v3-turbo / Qwen3-ASR
#
# 用法: benchmark_asr.sh <音频文件> [输出目录]
set -uo pipefail

AUDIO="${1:?用法: benchmark_asr.sh <音频文件> [输出目录]}"
OUT="${2:-/tmp/asr_bench}"
CONFIG_FILE="${MEETING_SKILL_CONFIG:-$HOME/.zcode/config/meeting-to-obsidian/config.sh}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${MODELS_DIR:=$HOME/.zcode/models}"
PY="$HOME/.zcode/venvs/whisper/bin/python3"
MLX_SCRIPT="$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py"
SMALL="$MODELS_DIR/whisper-small-mlx"
TURBO="$MODELS_DIR/whisper-large-v3-turbo"
QASR="$MODELS_DIR/Qwen3-ASR-1.7B"

mkdir -p "$OUT"
DUR=$(/opt/homebrew/bin/ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$AUDIO")
echo "音频: $AUDIO （${DUR}s）"
echo "============================================"

run_whisper() {
    local name="$1" model="$2"
    [[ -d "$model" ]] || { echo "[$name] 跳过（模型未就绪）"; return; }
    local d="$OUT/$name"; mkdir -p "$d"
    local t0=$(date +%s)
    "$PY" "$MLX_SCRIPT" "$AUDIO" "$d" "$model" > "$d/run.log" 2>&1
    local t1=$(date +%s)
    local el=$((t1 - t0))
    local chars=$(wc -m < "$d/audio.txt" 2>/dev/null | tr -d ' ')
    local rt=$(echo "$DUR / $el" | bc -l 2>/dev/null | cut -c1-5)
    echo "[$name] 用时 ${el}s | 倍速 ${rt}x | 输出 ${chars} 字"
}

run_whisper "whisper-small" "$SMALL"
run_whisper "whisper-turbo" "$TURBO"

if [[ -f "$QASR/model.safetensors" ]]; then
    d="$OUT/qwen3-asr"; mkdir -p "$d"
    t0=$(date +%s)
    "$PY" -m mlx_audio.stt.generate --model "$QASR" --audio "$AUDIO" \
        --output-dir "$d" > "$d/run.log" 2>&1
    t1=$(date +%s)
    el=$((t1 - t0))
    echo "[qwen3-asr] 用时 ${el}s"
    find "$d" -name "*.txt" -o -name "*.json" | head -3
else
    echo "[qwen3-asr] 跳过（模型未就绪）"
fi

echo "============================================"
echo "输出目录: $OUT"
for f in "$OUT"/*/audio.txt; do
    [ -f "$f" ] || continue
    echo ""
    echo "---- $(dirname "$f" | xargs basename) ----"
    head -c 600 "$f"
    echo ""
done
