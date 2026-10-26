#!/bin/bash
# stop_capture.sh — 停止实时捕获
#
# 用法:
#   stop_capture.sh [捕获目录]
# 若未指定目录，自动查找最近一次捕获。

set -euo pipefail

if [[ $# -ge 1 ]]; then
    OUTPUT_DIR="$1"
else
    PID_FILE=$(find "$HOME/Downloads/TencentMeeting" -name "capture.pid" -type f 2>/dev/null | sort -r | head -1)
    if [[ -z "$PID_FILE" ]]; then
        echo "未找到正在运行的捕获进程"
        exit 1
    fi
    OUTPUT_DIR=$(dirname "$PID_FILE")
fi

echo "停止捕获: $OUTPUT_DIR"

# 停止主进程
if [[ -f "$OUTPUT_DIR/capture.pid" ]]; then
    CAPTURE_PID=$(cat "$OUTPUT_DIR/capture.pid")
    kill "$CAPTURE_PID" 2>/dev/null || true
fi

# 停止子进程
for pid_file in "$OUTPUT_DIR"/screenshot.pid "$OUTPUT_DIR"/audio.pid; do
    if [[ -f "$pid_file" ]]; then
        PID=$(cat "$pid_file")
        kill "$PID" 2>/dev/null || true
        rm -f "$pid_file"
    fi
done

# 兜底清理
pkill -f "system_audio_capture $OUTPUT_DIR" 2>/dev/null || true
pkill -f "window_capture" 2>/dev/null || true

sleep 2
rm -f "$OUTPUT_DIR/capture.pid"

echo ""
echo "捕获已停止"
if [[ -f "$OUTPUT_DIR/audio.wav" ]]; then
    echo "音频: $(ls -lh "$OUTPUT_DIR/audio.wav" | awk '{print $5}')"
    FRAMES=$(find "$OUTPUT_DIR" -name "frame_*.png" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "截图: $FRAMES 张"
    echo ""
    echo "处理命令:"
    echo "  bash ~/.zcode/skills/meeting-to-obsidian/scripts/process_live.sh '$OUTPUT_DIR'"
fi
