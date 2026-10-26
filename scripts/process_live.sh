#!/bin/bash
# process_live.sh — 处理实时捕获的截图+音频，生成 Obsidian 笔记
#
# 用法:
#   process_live.sh <捕获目录> [vault_path] [note_title] [--meta meta.json]
#
# 捕获目录应包含:
#   frame_*.png  — 腾讯会议窗口截图（文件名为捕获时刻 HHMMSS）
#   audio.wav    — 系统音频录制
#
# 流程: 转录 audio.wav（不经视频合成）+ 裁剪/去重截图 → 笔记 → MCP 写入

set -euo pipefail

# 载入本机配置（个人路径/词表不随 skill 分发）
CONFIG_FILE="${MEETING_SKILL_CONFIG:-$HOME/.zcode/config/meeting-to-obsidian/config.sh}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${OBSIDIAN_VAULT:=$HOME/Documents/Obsidian Vault}"
: "${CAPTURE_ROOT:=$HOME/Downloads/TencentMeeting}"
: "${MODELS_DIR:=$HOME/.zcode/models}"

CAPTURE_DIR="${1:?用法: process_live.sh <捕获目录> [vault_path] [note_title] [--meta meta.json]}"
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
FFMPEG="/opt/homebrew/bin/ffmpeg"
PYTHON="$HOME/.zcode/venvs/whisper/bin/python3"
LOG_DIR="$HOME/.zcode/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/process_live_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$CAPTURE_DIR")
fi
SAFE_TITLE=$(echo "$TITLE" | perl -CSD -pe 's/[^\p{Han}\p{Latin}\p{Nd}]+/-/g; s/-{2,}/-/g; s/^-//; s/-$//')
MEETING_DATE=$(echo "$TITLE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || date +%Y-%m-%d)

# 验证输入
AUDIO="$CAPTURE_DIR/audio.wav"
if [[ ! -f "$AUDIO" ]]; then
    echo "ERROR: 音频文件不存在: $AUDIO"
    exit 1
fi

FRAMES=("$CAPTURE_DIR"/frame_*.png)
if [[ ! -f "${FRAMES[0]:-}" ]]; then
    echo "ERROR: 截图文件不存在: $CAPTURE_DIR/frame_*.png"
    exit 1
fi

WORK_DIR=$(mktemp -d)
log "============================================"
log " 实时捕获 → Obsidian 笔记"
log "============================================"
log "捕获目录: $CAPTURE_DIR"
log "笔记标题: $TITLE"
log "工作目录: $WORK_DIR"
log ""

# Step 1: ASR（单模型：Qwen3-ASR，时间戳+正文一起出，20x 实时）
#   如需旧双引擎模式：ASR_BACKEND=auto（qwen 正文 + whisper-turbo 时间戳）
log "[1/5] 语音转录（${#FRAMES[@]} 张截图）..."
TRANSCRIPT="$WORK_DIR/audio.txt"
TURBO_MODEL="$MODELS_DIR/whisper-large-v3-turbo"
QASR_MODEL="$MODELS_DIR/Qwen3-ASR-1.7B"
FRAMES_DIR="$WORK_DIR/frames"

case "${ASR_BACKEND:-qwen}" in
whisper)
    "$PYTHON" "$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py" "$AUDIO" "$WORK_DIR" "$TURBO_MODEL" >> "$LOG_FILE" 2>&1 || {
        log "ERROR: 转录失败"; exit 1
    }
    ;;
*)
    "$PYTHON" "$SCRIPT_DIR/qwen_asr_transcribe.py" "$AUDIO" "$WORK_DIR" "$QASR_MODEL" >> "$LOG_FILE" 2>&1 || {
        log "WARNING: Qwen3-ASR 失败，改用 whisper-turbo"
        "$PYTHON" "$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py" "$AUDIO" "$WORK_DIR" "$TURBO_MODEL" >> "$LOG_FILE" 2>&1 || {
            log "ERROR: 转录失败"; exit 1
        }
    }
    ;;
esac
TRANS_LEN=$(wc -c < "$TRANSCRIPT" | tr -d ' ')
log "  转录完成: ${TRANS_LEN} 字符"

# Step 2: 裁剪黑边/UI 条 + 感知哈希去重（在副本上操作，不动原始捕获）
log "[2/5] 截图裁剪与去重..."
mkdir -p "$FRAMES_DIR"
cp "$CAPTURE_DIR"/frame_*.png "$FRAMES_DIR/"
"$PYTHON" "$SCRIPT_DIR/crop_borders.py" "$FRAMES_DIR" >> "$LOG_FILE" 2>&1
"$PYTHON" "$SCRIPT_DIR/dedup_images.py" "$FRAMES_DIR" 12 >> "$LOG_FILE" 2>&1
KEYFRAMES=("$FRAMES_DIR"/frame_*.png)
log "  保留 ${#KEYFRAMES[@]} 张关键帧"

# Step 3: 生成 manifest（用文件名中的捕获时刻 HHMMSS 计算真实时间偏移）
log "[3/5] 生成帧时间清单..."
MANIFEST="$WORK_DIR/manifest.txt"
FIRST_TS=""
for frame in "${KEYFRAMES[@]}"; do
    fname=$(basename "$frame")
    hh=${fname:6:2}; mm=${fname:8:2}; ss=${fname:10:2}
    cur=$((10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
    if [[ -z "$FIRST_TS" ]]; then FIRST_TS=$cur; fi
    rel=$((cur - FIRST_TS))
    echo "$(printf "%d:%02d" $((rel / 60)) $((rel % 60)))|${fname}" >> "$MANIFEST"
done
log "  $(wc -l < "$MANIFEST" | tr -d ' ') 帧"

# Step 3.5: 润色（多模态：逐帧视觉纠错+配图说明；总结/标签/主题）
bash "$SCRIPT_DIR/mlx_server.sh" "" "" start >> "$LOG_FILE" 2>&1 || true
log "[3.5/5] 转录润色与要点归纳（本地模型）..."
POLISHED="$WORK_DIR/audio_polished.txt"
SUMMARY="$WORK_DIR/summary.md"
CAPTIONS="$WORK_DIR/captions.json"
TAGS="$WORK_DIR/tags.txt"
TOPIC="$WORK_DIR/topic.txt"
"$PYTHON" "$SCRIPT_DIR/polish_note.py" "$TRANSCRIPT" "$POLISHED" "$SUMMARY" \
    --segments "$WORK_DIR/audio.json" --manifest "$MANIFEST" \
    --frames-dir "$FRAMES_DIR" \
    --captions-out "$CAPTIONS" --tags-out "$TAGS" --topic-out "$TOPIC" >> "$LOG_FILE" 2>&1 || {
    log "WARNING: 润色失败，使用原始转录"
}
if [[ -s "$POLISHED" ]]; then
    TRANSCRIPT="$POLISHED"
    log "  润色完成: $(wc -c < "$POLISHED" | tr -d ' ') 字符"
fi

# 笔记标题按内容修订：模型提炼的主题优先于传入的默认标题
if [[ -s "$TOPIC" ]]; then
    T=$(head -1 "$TOPIC" | tr -d '\n\r' | sed 's/[\/:<>|*?"~-]/ /g; s/  */ /g; s/^ //; s/ $//' | cut -c1-40)
    if [[ -n "$T" ]]; then
        log "  笔记命名: ${T}（按内容）"
        TITLE="$T"
        SAFE_TITLE=$(echo "$TITLE" | perl -CSD -pe 's/[^\p{Han}\p{Latin}\p{Nd}]+/-/g; s/-{2,}/-/g; s/^-//; s/-$//')
    fi
fi

# Step 4: 生成笔记并发布到 Obsidian
log "[4/5] 生成笔记并写入 Obsidian..."
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
NOTE_ARGS=("$TRANSCRIPT" "$MANIFEST" "$NOTE_CONTENT" "$WORK_DIR/meta.json")
if [[ -s "$SUMMARY" ]]; then
    NOTE_ARGS+=("$SUMMARY")
fi
if [[ -s "$WORK_DIR/audio.json" ]]; then
    NOTE_ARGS+=("$WORK_DIR/audio.json")
fi
if [[ -s "$CAPTIONS" ]]; then
    NOTE_ARGS+=("$CAPTIONS")
fi
if [[ -s "$TAGS" ]]; then
    NOTE_ARGS+=("$TAGS")
fi
if [[ -s "$TOPIC" ]]; then
    NOTE_ARGS+=("$TOPIC")
fi

# 录音压缩后挂入笔记附件（wav → m4a 64k，约 1/6 体积）；在生成笔记前完成以便写入链接
ATTACH_DIR="$VAULT/attachments/$SAFE_TITLE"
mkdir -p "$ATTACH_DIR"
AUDIO_LINK=""
if "$FFMPEG" -nostdin -i "$AUDIO" -c:a aac -b:a 64k -ac 1 "$ATTACH_DIR/audio.m4a" -y -loglevel error 2>>"$LOG_FILE" && [ -s "$ATTACH_DIR/audio.m4a" ]; then
    AUDIO_LINK="attachments/${SAFE_TITLE}/audio.m4a"
    log "  录音附件: ${AUDIO_LINK}（$(du -h "$ATTACH_DIR/audio.m4a" | awk '{print $1}')）"
else
    rm -f "$ATTACH_DIR/audio.m4a"
    log "WARNING: 录音压缩失败，跳过录音附件"
fi

"$PYTHON" "$SCRIPT_DIR/generate_note.py" "${NOTE_ARGS[@]}" "$AUDIO_LINK" >> "$LOG_FILE" 2>&1 || {
    log "ERROR: 笔记生成失败"
    exit 1
}

# 修复图片引用路径
perl -i -pe "s|!\\[\\[frame_|!\\[\\[attachments/${SAFE_TITLE}/frame_|g" "$NOTE_CONTENT"

# 只清旧帧文件（保留 audio.m4a），再拷入新关键帧
rm -f "$ATTACH_DIR"/frame_*.png 2>/dev/null
cp "$FRAMES_DIR"/frame_*.png "$ATTACH_DIR/"

MCP_CLIENT="$SCRIPT_DIR/obsidian_mcp_client.py"
NOTE_PATH="会议笔记/${SAFE_TITLE}.md"
"$PYTHON" "$MCP_CLIENT" configure "$VAULT" >> "$LOG_FILE" 2>&1
"$PYTHON" "$MCP_CLIENT" write "$NOTE_PATH" "$NOTE_CONTENT" >> "$LOG_FILE" 2>&1

log ""
log "完成！"
log "笔记: $VAULT/$NOTE_PATH"
log "图片: $ATTACH_DIR"
log "日志: $LOG_FILE"

# 临时目录滚动清理（上限 1GB）
bash "$SCRIPT_DIR/cleanup_tmp.py" 1024 >> "$LOG_FILE" 2>&1 || true

# 从 GPU/内存卸载模型，释放资源（设置 KEEP_MLX_SERVER=1 可保留下次直接复用）
if [[ "${KEEP_MLX_SERVER:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/mlx_server.sh" "" "" stop >> "$LOG_FILE" 2>&1 || true
    ollama stop qwen2.5:7b >/dev/null 2>&1 || true
    log "  已卸载：MLX server(Qwen3.6) / ollama 回退模型；ffmpeg 为一次性进程，无残留"
fi
