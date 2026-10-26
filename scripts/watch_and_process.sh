#!/bin/bash
# watch_and_process.sh — 监听腾讯会议录制目录，自动处理新录制文件
# 参考 Margins 的文件监听模式
#
# 用法:
#   watch_and_process.sh [录制目录] [Vault路径] [轮询间隔秒数]
#
# 默认:
#   录制目录: ~/Downloads/TencentMeeting
#   Vault: ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Yuque-Learning-Projects
#   轮询间隔: 30秒

set -euo pipefail

# 载入本机配置（个人路径/词表不随 skill 分发）
CONFIG_FILE="${MEETING_SKILL_CONFIG:-$HOME/.zcode/config/meeting-to-obsidian/config.sh}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${OBSIDIAN_VAULT:=$HOME/Documents/Obsidian Vault}"
: "${CAPTURE_ROOT:=$HOME/Downloads/TencentMeeting}"
: "${MODELS_DIR:=$HOME/.zcode/models}"

RECORDING_DIR="${1:-$HOME/Downloads/TencentMeeting}"
VAULT_PATH="${2:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Yuque-Learning-Projects}"
POLL_INTERVAL="${3:-30}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$HOME/.zcode/logs/meeting-watch.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "============================================"
log " 腾讯会议录制监听器"
log "============================================"
log "录制目录: $RECORDING_DIR"
log "Vault: $VAULT_PATH"
log "轮询间隔: ${POLL_INTERVAL}s"
log "日志: $LOG_FILE"
log ""

# 已处理的文件列表
PROCESSED_FILE="$HOME/.zcode/logs/processed_meetings.txt"
touch "$PROCESSED_FILE"

# 等待文件写入完成（文件大小稳定）
wait_for_stable() {
    local file="$1"
    local stable_count=0
    local last_size=0
    local max_wait=300  # 最多等待5分钟
    
    while [[ $stable_count -lt 3 ]]; do
        if [[ ! -f "$file" ]]; then
            return 1
        fi
        local current_size=$(stat -f%z "$file" 2>/dev/null || echo 0)
        if [[ "$current_size" -eq "$last_size" ]] && [[ "$current_size" -gt 1000 ]]; then
            stable_count=$((stable_count + 1))
        else
            stable_count=0
        fi
        last_size=$current_size
        sleep 5
        max_wait=$((max_wait - 5))
        if [[ $max_wait -le 0 ]]; then
            log "WARNING: 等待超时，继续处理: $file"
            return 0
        fi
    done
    return 0
}

# 处理单个录制文件
process_recording() {
    local mp4_file="$1"
    local dir_name=$(basename "$(dirname "$mp4_file")")
    
    # 检查是否已处理
    if grep -qF "$mp4_file" "$PROCESSED_FILE" 2>/dev/null; then
        return 0
    fi
    
    log "发现新录制: $mp4_file"
    log "等待文件写入完成..."
    
    if ! wait_for_stable "$mp4_file"; then
        log "ERROR: 文件不存在或无法读取: $mp4_file"
        return 1
    fi
    
    local file_size=$(stat -f%z "$mp4_file" 2>/dev/null || echo 0)
    log "文件大小: $file_size bytes"
    
    if [[ "$file_size" -lt 10000 ]]; then
        log "WARNING: 文件过小，可能录制失败: $mp4_file"
        echo "$mp4_file" >> "$PROCESSED_FILE"
        return 1
    fi
    
    # 检查是否有对应的音频文件
    local audio_file=""
    local dir=$(dirname "$mp4_file")
    if [[ -f "$dir/audio.m4a" ]]; then
        audio_file="$dir/audio.m4a"
        log "发现音频文件: $audio_file"
    fi
    
    # 处理录制
    log "开始处理: $dir_name"
    if bash "$SCRIPT_DIR/process_meeting.sh" "$mp4_file" "$VAULT_PATH" "$dir_name"; then
        log "处理完成: $dir_name"
        echo "$mp4_file" >> "$PROCESSED_FILE"
        
        # 可选：移动已处理文件到归档目录
        # mv "$(dirname "$mp4_file")" "$RECORDING_DIR/processed/"
    else
        log "ERROR: 处理失败: $dir_name"
        return 1
    fi
}

# 主循环
log "开始监听..."
while true; do
    # 查找所有 .mp4 文件
    while IFS= read -r -d '' mp4_file; do
        process_recording "$mp4_file" || true
    done < <(find "$RECORDING_DIR" -name "*.mp4" -type f -print0 2>/dev/null)
    
    sleep "$POLL_INTERVAL"
done
