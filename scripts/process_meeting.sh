#!/bin/bash
# process_meeting.sh — 腾讯会议录制 → Obsidian 笔记（完整管道）
#
# 用法:
#   process_meeting.sh <meeting_mp4> [vault_path] [note_title] [--meta meta.json]
#
# 管道流程:
#   1. 从视频提取音频 (16kHz mono WAV)
#   2. MLX Whisper 转录（Apple Silicon GPU 加速）
#   3. 场景检测 + 感知哈希去重提取关键帧
#   4. 生成 kepano 风格 Obsidian 笔记
#   5. MCP 发布到 Obsidian Vault
#   6. 生成/更新会议索引 Base 文件

set -euo pipefail

# 载入本机配置（个人路径/词表不随 skill 分发）
CONFIG_FILE="${MEETING_SKILL_CONFIG:-$HOME/.zcode/config/meeting-to-obsidian/config.sh}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${OBSIDIAN_VAULT:=$HOME/Documents/Obsidian Vault}"
: "${CAPTURE_ROOT:=$HOME/Downloads/TencentMeeting}"
: "${MODELS_DIR:=$HOME/.zcode/models}"

MP4="${1:?用法: process_meeting.sh <meeting_mp4> [vault_path] [note_title] [--meta meta.json]}"
VAULT="${2:-$OBSIDIAN_VAULT}"
TITLE="${3:-}"
META_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --meta) META_FILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MLX_SCRIPT="$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py"
MCP_CLIENT="$SCRIPT_DIR/obsidian_mcp_client.py"
PYTHON="$HOME/.zcode/venvs/whisper/bin/python3"
LOG_DIR="$HOME/.zcode/logs"
mkdir -p "$LOG_DIR"

# 生成标题
if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$(dirname "$MP4")" | sed 's/^[0-9]*-[0-9]*-[0-9]* //; s/\.[^.]*$//')
fi
SAFE_TITLE=$(echo "$TITLE" | perl -CSD -pe 's/[^\p{Han}\p{Latin}\p{Nd}]+/-/g; s/-{2,}/-/g; s/^-//; s/-$//')
MEETING_DATE=$(echo "$TITLE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || date +%Y-%m-%d)

WORK_DIR=$(mktemp -d)
FRAMES_DIR="$WORK_DIR/frames"
mkdir -p "$FRAMES_DIR"

LOG_FILE="$LOG_DIR/process_${SAFE_TITLE}_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fail() { log "FAIL: $*"; rm -rf "$WORK_DIR"; exit 1; }

log "============================================"
log " 腾讯会议 → Obsidian 笔记"
log "============================================"
log "录制文件: $MP4"
log "笔记标题: $TITLE"
log "Vault: $VAULT"
log "工作目录: $WORK_DIR"
log "日志: $LOG_FILE"
log ""

# ── Step 1: 提取音频 ─────────────────────────────────────────────
log "[1/6] 提取音频..."
AUDIO="$WORK_DIR/audio.wav"
bash "$SCRIPT_DIR/extract_audio.sh" "$MP4" "$AUDIO" >> "$LOG_FILE" 2>&1 \
    || fail "音频提取失败"
log "  完成: $AUDIO"

# ── Step 2: MLX Whisper 转录 ───────────────────────────────────────
log "[2/6] MLX Whisper 转录..."
"$PYTHON" "$MLX_SCRIPT" "$AUDIO" "$WORK_DIR" >> "$LOG_FILE" 2>&1 \
    || { cat "$WORK_DIR/mlx_transcribe.log" 2>/dev/null | tee -a "$LOG_FILE" >&2; fail "转录失败"; }
TRANSCRIPT="$WORK_DIR/audio.txt"
[[ -s "$TRANSCRIPT" ]] || fail "转录文件为空"
TRANSCRIPT_CHARS=$(wc -m < "$TRANSCRIPT" | tr -d ' ')
log "  完成: $TRANSCRIPT_CHARS 字符"

# ── Step 3: 提取关键帧 ─────────────────────────────────────────────
log "[3/6] 提取关键帧..."
bash "$SCRIPT_DIR/extract_keyframes.sh" "$MP4" "$FRAMES_DIR" 0.3 15 >> "$LOG_FILE" 2>&1 \
    || fail "关键帧提取失败"
FRAME_COUNT=$(find "$FRAMES_DIR" -name "frame_*.jpg" -type f 2>/dev/null | wc -l | tr -d ' ') || FRAME_COUNT=0
log "  完成: $FRAME_COUNT 帧"

# ── Step 3.5: 本地模型润色（同音字纠错 + 标点 + 要点归纳 + 配图说明 + 标签） ────────
log "[3.5/6] 转录润色与要点归纳..."
POLISHED="$WORK_DIR/audio_polished.txt"
SUMMARY="$WORK_DIR/summary.md"
CAPTIONS="$WORK_DIR/captions.json"
TAGS="$WORK_DIR/tags.txt"
TOPIC="$WORK_DIR/topic.txt"
"$PYTHON" "$SCRIPT_DIR/polish_note.py" "$TRANSCRIPT" "$POLISHED" "$SUMMARY" \
    --segments "$WORK_DIR/audio.json" --manifest "$FRAMES_DIR/manifest.txt" \
    --captions-out "$CAPTIONS" --tags-out "$TAGS" --topic-out "$TOPIC" >> "$LOG_FILE" 2>&1 \
    || log "WARNING: 润色失败，使用原始转录"
if [[ -s "$POLISHED" ]]; then
    TRANSCRIPT="$POLISHED"
    log "  润色完成: $(wc -m < "$POLISHED" | tr -d ' ') 字符"
fi

# ── Step 4: 生成笔记内容 ───────────────────────────────────────────
log "[4/6] 生成笔记内容..."

# 元数据
if [[ -n "$META_FILE" && -f "$META_FILE" ]]; then
    cp "$META_FILE" "$WORK_DIR/meta.json"
else
    cat > "$WORK_DIR/meta.json" << EOF
{
    "title": "$TITLE",
    "date": "$MEETING_DATE"
}
EOF
fi

NOTE_CONTENT="$WORK_DIR/note.md"
NOTE_ARGS=("$TRANSCRIPT" "$FRAMES_DIR/manifest.txt" "$NOTE_CONTENT" "$WORK_DIR/meta.json")
[[ -s "$SUMMARY" ]] && NOTE_ARGS+=("$SUMMARY")
[[ -s "$WORK_DIR/audio.json" ]] && NOTE_ARGS+=("$WORK_DIR/audio.json")
[[ -s "$CAPTIONS" ]] && NOTE_ARGS+=("$CAPTIONS")
[[ -s "$TAGS" ]] && NOTE_ARGS+=("$TAGS")
[[ -s "$TOPIC" ]] && NOTE_ARGS+=("$TOPIC")
"$PYTHON" "$SCRIPT_DIR/generate_note.py" \
    "${NOTE_ARGS[@]}" >> "$LOG_FILE" 2>&1 \
    || fail "笔记生成失败"

# 修复图片路径
perl -i -pe "s|!\\[\\[frame_|!\\[\\[attachments/${SAFE_TITLE}/frame_|g" "$NOTE_CONTENT"
log "  完成: $NOTE_CONTENT"

# ── Step 5: MCP 发布 ───────────────────────────────────────────────
log "[5/6] MCP 发布到 Obsidian..."

ATTACH_DIR="$VAULT/attachments/$SAFE_TITLE"
mkdir -p "$ATTACH_DIR"
if ls "$FRAMES_DIR"/frame_*.jpg &>/dev/null; then
    cp "$FRAMES_DIR"/frame_*.jpg "$ATTACH_DIR/"
    log "  图片: $ATTACH_DIR"
fi

NOTE_PATH="会议笔记/${SAFE_TITLE}.md"
"$PYTHON" "$MCP_CLIENT" configure "$VAULT" >> "$LOG_FILE" 2>&1 \
    || fail "MCP configure 失败"
"$PYTHON" "$MCP_CLIENT" write "$NOTE_PATH" "$NOTE_CONTENT" >> "$LOG_FILE" 2>&1 \
    || fail "MCP write 失败"
log "  笔记: $NOTE_PATH"

# ── Step 6: 会议索引 Base ──────────────────────────────────────────
log "[6/6] 生成会议索引 Base..."
"$PYTHON" "$SCRIPT_DIR/generate_meeting_base.py" "$VAULT" "会议索引" >> "$LOG_FILE" 2>&1 \
    || log "  WARNING: Base 生成失败（非致命）"

log ""
log "============================================"
log " 完成！"
log " 笔记: $VAULT/$NOTE_PATH"
log " 图片: $ATTACH_DIR"
log " 索引: $VAULT/会议笔记/会议索引.base"
log " 日志: $LOG_FILE"
log "============================================"

# 保留工作目录供调试（可选：改为 rm -rf "$WORK_DIR" 清理）
log "工作目录保留: $WORK_DIR"
