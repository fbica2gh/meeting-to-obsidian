#!/bin/bash
# capture_sck.sh — 实时捕获腾讯会议窗口 + 系统音频（ScreenCaptureKit）
#
# 用法:
#   capture_sck.sh <window_id> [输出目录] [截图间隔秒数]
#
# 特性:
#   - 窗口画面：ScreenCaptureKit 捕获（支持后台窗口）
#   - 系统音频：ScreenCaptureKit 捕获腾讯会议等应用的音频输出
#   - 不占用音频输出设备，用户仍可正常听到会议声音
#
# 依赖:
#   window_capture        — 编译自 window_capture.swift
#   system_audio_capture  — 编译自 system_audio_capture.swift
#   两者均已代码签名，需"屏幕录制/系统音频录制"权限

set -euo pipefail

WINDOW_ID="${1:?用法: capture_sck.sh <window_id> [输出目录] [截图间隔秒数]}"
OUTPUT_DIR="${2:-$HOME/Downloads/TencentMeeting/$(date +%Y-%m-%d_%H%M%S)}"
INTERVAL="${3:-15}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINDOW_CAPTURE="$SCRIPT_DIR/window_capture"
AUDIO_CAPTURE="$SCRIPT_DIR/system_audio_capture"
LOG_DIR="$HOME/.zcode/logs"
mkdir -p "$LOG_DIR" "$OUTPUT_DIR"

LOG_FILE="$LOG_DIR/capture_sck_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="$OUTPUT_DIR/capture.pid"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# 检查依赖
for bin in "$WINDOW_CAPTURE" "$AUDIO_CAPTURE"; do
    if [[ ! -x "$bin" ]]; then
        log "ERROR: 缺少可执行文件: $bin"
        log "请运行: bash $SCRIPT_DIR/build_swift.sh"
        exit 1
    fi
done

# 清理函数
cleanup() {
    rm -f "$PID_FILE" "$OUTPUT_DIR/screenshot.pid" "$OUTPUT_DIR/audio.pid"
}
trap 'log "收到停止信号，正在清理..."; cleanup; exit 0' INT TERM
trap 'cleanup' EXIT

echo $$ > "$PID_FILE"

log "============================================"
log " ScreenCaptureKit 实时捕获（画面 + 系统音频）"
log "============================================"
log "窗口 ID: $WINDOW_ID"
log "输出目录: $OUTPUT_DIR"
log "截图间隔: ${INTERVAL}s"
log "日志: $LOG_FILE"
log ""

# ── 截图进程 ─────────────────────────────────────────────────────────
log "[1/2] 启动窗口截图进程..."
(
    COUNT=0
    FAILS=0
    while true; do
        COUNT=$((COUNT + 1))
        TS=$(date +%H%M%S)
        OUT="$OUTPUT_DIR/frame_${TS}.png"
        if "$WINDOW_CAPTURE" "$WINDOW_ID" "$OUT" >> "$LOG_FILE" 2>&1; then
            log "截图 #$COUNT: $(basename "$OUT")"
            FAILS=0
        else
            FAILS=$((FAILS + 1))
            log "WARNING: 截图失败 (#$FAILS)"
            if [[ $FAILS -ge 3 ]]; then
                # 窗口可能已关闭或最小化，尝试重新定位
                NEW_WID=$(swift "$SCRIPT_DIR/find_tencent_window.swift" 2>/dev/null || echo "")
                if [[ -n "$NEW_WID" ]]; then
                    WINDOW_ID="$NEW_WID"
                    log "窗口 ID 更新为 $WINDOW_ID"
                fi
                FAILS=0
            fi
        fi
        sleep "$INTERVAL"
    done
) >> "$LOG_FILE" 2>&1 &
SCREENSHOT_PID=$!
echo $SCREENSHOT_PID > "$OUTPUT_DIR/screenshot.pid"
log "截图进程 PID: $SCREENSHOT_PID"

# ── 音频进程（ScreenCaptureKit 系统音频）───────────────────────────
log "[2/2] 启动系统音频捕获进程..."
"$AUDIO_CAPTURE" "$OUTPUT_DIR/audio.wav" >> "$LOG_FILE" 2>&1 &
AUDIO_PID=$!
echo $AUDIO_PID > "$OUTPUT_DIR/audio.pid"
log "音频进程 PID: $AUDIO_PID"

log ""
log "捕获进行中（用户可正常听到会议声音）"
log "停止命令: kill \$(cat $PID_FILE)"

wait $SCREENSHOT_PID $AUDIO_PID 2>/dev/null || true
cleanup
log "捕获结束"
