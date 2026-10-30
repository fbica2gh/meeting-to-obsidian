#!/bin/bash
# incremental_watch.sh — 会议中增量转录 + 散会后自动出笔记
#
# 用法:
#   incremental_watch.sh <捕获目录> [vault] [标题] [--meta meta.json]
#
# 机制:
#   1. 监听 audio.wav 增长；每满一段（默认 5 分钟）就切出该段，
#      用 MLX Whisper 转录并缓存到 <捕获目录>/.inc/（不重复转录）
#   2. 捕获结束后把所有分片合并成完整转录，再走
#      润色/总结/配图说明/笔记生成/MCP 发布（与 process_live 相同的管线）
#
# 收益: 会议结束约 2-3 分钟出笔记（批处理方式需 10+ 分钟）

set -euo pipefail

# 载入本机配置（个人路径/词表不随 skill 分发）
CONFIG_FILE="${MEETING_SKILL_CONFIG:-$HOME/.zcode/config/meeting-to-obsidian/config.sh}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${OBSIDIAN_VAULT:=$HOME/Documents/Obsidian Vault}"
: "${CAPTURE_ROOT:=$HOME/Downloads/TencentMeeting}"
: "${MODELS_DIR:=$HOME/.zcode/models}"

CAPTURE_DIR="${1:?用法: incremental_watch.sh <捕获目录> [vault] [标题] [--meta meta.json]}"
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
FFPROBE="/opt/homebrew/bin/ffprobe"
PYTHON="$HOME/.zcode/venvs/whisper/bin/python3"
MLX="$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py"
CHUNK_SECONDS="${CHUNK_SECONDS:-300}"   # 每片 5 分钟
AUDIO="$CAPTURE_DIR/audio.wav"
INC_DIR="$CAPTURE_DIR/.inc"
LOG="$HOME/.zcode/logs/incremental_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
dur() { $FFPROBE -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null || echo 0; }

mkdir -p "$INC_DIR" "$HOME/.zcode/logs"

[[ -z "$TITLE" ]] && TITLE=$(basename "$CAPTURE_DIR")
log "增量监听启动: ${CAPTURE_DIR}（标题: ${TITLE}）"

# ── 阶段 1: 捕获期间增量转录 ──
transcribe_chunk() {
    local idx="$1" start="$2" length="$3"
    local chunk="$INC_DIR/chunk_$(printf "%03d" "$idx").wav"
    local outd="$INC_DIR/chunk_$(printf "%03d" "$idx")"
    $FFMPEG -nostdin -ss "$start" -t "$length" -i "$AUDIO" -acodec pcm_s16le -ar 16000 -ac 1 "$chunk" -y -loglevel error
    if [[ ! -s "$chunk" ]]; then return 1; fi
    # 单 ASR：Qwen3-ASR（时间戳+正文一起出）；失败回退 whisper-turbo
    "$PYTHON" "$SCRIPT_DIR/qwen_asr_transcribe.py" "$chunk" "$outd" \
        "$MODELS_DIR/Qwen3-ASR-1.7B" >> "$LOG" 2>&1 || \
        { log "  WARN: 分片 $idx qwen 转录失败，改用 whisper-turbo";
          "$PYTHON" "$HOME/.zcode/skills/mlx-transcribe/scripts/mlx_transcribe.py" "$chunk" "$outd" \
            "$MODELS_DIR/whisper-large-v3-turbo" >> "$LOG" 2>&1 || log "  WARN: 分片 $idx 转录失败"; }
    rm -f "$chunk"
    log "  分片 $idx（${start}s 起 ${length}s）转录完成"
}

DONE_IDX=0
while true; do
    sleep 30
    # 捕获进程还活着吗（capture.pid / screenshot.pid / audio.pid 任一存活即视为运行中）
    ALIVE=0
    for pf in "$CAPTURE_DIR"/capture.pid "$CAPTURE_DIR"/screenshot.pid "$CAPTURE_DIR"/audio.pid; do
        if [[ -f "$pf" ]]; then
            P=$(cat "$pf" 2>/dev/null)
            [[ -n "$P" ]] && kill -0 "$P" 2>/dev/null && ALIVE=1
        fi
    done
    D=$(dur "$AUDIO")
    D="${D%.*}"
    TOTAL_CHUNKS=$(( D / CHUNK_SECONDS ))
    # 转录所有未处理完成的完整分片
    while [[ $DONE_IDX -lt $TOTAL_CHUNKS ]]; do
        transcribe_chunk "$DONE_IDX" "$((DONE_IDX * CHUNK_SECONDS))" "$CHUNK_SECONDS" || log "  WARN: 分片 $DONE_IDX 转录失败"
        DONE_IDX=$((DONE_IDX + 1))
    done
    if [[ $ALIVE -eq 0 ]]; then
        log "捕获已停止，音频总长 ${D}s"
        break
    fi
done

# ── 阶段 2: 结束后出笔记 ──
# 最后不足一片的尾部也转录掉
TAIL_START=$((DONE_IDX * CHUNK_SECONDS))
TAIL_LEN=$(echo "$D - $TAIL_START" | bc)
if (( $(echo "$TAIL_LEN > 10" | bc -l) )); then
    transcribe_chunk "$DONE_IDX" "$TAIL_START" "$TAIL_LEN" || log "  WARN: 尾部转录失败"
    DONE_IDX=$((DONE_IDX + 1))
fi

if [[ $DONE_IDX -eq 0 ]]; then
    log "ERROR: 没有任何转录内容"
    exit 1
fi

WORK_DIR=$(mktemp -d)
# 合并全文 + 分段（时间戳按片偏移累加）
"$PYTHON" - "$INC_DIR" "$DONE_IDX" "$WORK_DIR" <<'PYEOF'
import json, os, sys
inc_dir, n, work = sys.argv[1], int(sys.argv[2]), sys.argv[3]
texts, segs = [], []
offset = 0.0
for i in range(n):
    d = f"{inc_dir}/chunk_{i:03d}"
    t = os.path.join(d, "audio.txt")
    j = os.path.join(d, "audio.json")
    if os.path.exists(t):
        texts.append(open(t, encoding="utf-8").read().strip())
    if os.path.exists(j):
        for s in json.load(open(j, encoding="utf-8")):
            segs.append({"start": round(s["start"] + offset, 2), "end": round(s["end"] + offset, 2), "text": s["text"]})
    # 该片时长 = 全片最大 end（分片是整段切出来的）
    if segs and os.path.exists(j):
        offset = max(offset, max((s["end"] for s in segs), default=offset))
open(os.path.join(work, "audio.txt"), "w", encoding="utf-8").write("\n".join(texts))
json.dump(segs, open(os.path.join(work, "audio.json"), "w", encoding="utf-8"), ensure_ascii=False)
print(f"merged: {len(texts)} chunks, {len(segs)} segments", file=sys.stderr)
PYEOF
log "转录合并完成: $(wc -c < "$WORK_DIR/audio.txt" | tr -d ' ') 字符"

# ── 以下与 process_live 相同：裁剪/去重/润色/笔记/发布 ──
SAFE_TITLE=$(echo "$TITLE" | perl -CSD -pe 's/[^\p{Han}\p{Latin}\p{Nd}]+/-/g; s/-{2,}/-/g; s/^-//; s/-$//')
MEETING_DATE=$(echo "$TITLE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || date +%Y-%m-%d)

log "截图裁剪与去重..."
FRAMES_DIR="$WORK_DIR/frames"
mkdir -p "$FRAMES_DIR"
cp "$CAPTURE_DIR"/frame_*.png "$FRAMES_DIR/" 2>/dev/null || true
"$PYTHON" "$SCRIPT_DIR/crop_borders.py" "$FRAMES_DIR" >> "$LOG" 2>&1 || true
"$PYTHON" "$SCRIPT_DIR/dedup_images.py" "$FRAMES_DIR" 12 >> "$LOG" 2>&1 || true
KEYFRAMES=("$FRAMES_DIR"/frame_*.png)
log "  保留 ${#KEYFRAMES[@]} 张关键帧"

MANIFEST="$WORK_DIR/manifest.txt"
FIRST_TS=""
for frame in "${KEYFRAMES[@]}"; do
    fname=$(basename "$frame")
    hh=${fname:6:2}; mm=${fname:8:2}; ss=${fname:10:2}
    cur=$((10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
    [[ -z "$FIRST_TS" ]] && FIRST_TS=$cur
    rel=$((cur - FIRST_TS))
    echo "$(printf "%d:%02d" $((rel / 60)) $((rel % 60)))|${fname}" >> "$MANIFEST"
done

log "转录润色与要点归纳..."
bash "$SCRIPT_DIR/mlx_server.sh" "" "" start >> "$LOG" 2>&1 || true
TRANSCRIPT="$WORK_DIR/audio.txt"
POLISHED="$WORK_DIR/audio_polished.txt"
SUMMARY="$WORK_DIR/summary.md"
CAPTIONS="$WORK_DIR/captions.json"
TAGS="$WORK_DIR/tags.txt"
TOPIC="$WORK_DIR/topic.txt"
"$PYTHON" "$SCRIPT_DIR/polish_note.py" "$TRANSCRIPT" "$POLISHED" "$SUMMARY" \
    --segments "$WORK_DIR/audio.json" --manifest "$MANIFEST" --frames-dir "$FRAMES_DIR" \
    --captions-out "$CAPTIONS" --tags-out "$TAGS" --topic-out "$TOPIC" >> "$LOG" 2>&1 || \
    log "WARNING: 润色失败，使用原始转录"
[[ -s "$POLISHED" ]] && TRANSCRIPT="$POLISHED"

# 笔记标题按内容修订：模型提炼的主题优先
if [[ -s "$TOPIC" ]]; then
    T=$(head -1 "$TOPIC" | tr -d '\n\r' | sed 's/[\/:<>|*?"~-]/ /g; s/  */ /g; s/^ //; s/ $//' | cut -c1-40)
    if [[ -n "$T" ]]; then
        log "  笔记命名: ${T}（按内容）"
        TITLE="$T"
        SAFE_TITLE=$(echo "$TITLE" | perl -CSD -pe 's/[^\p{Han}\p{Latin}\p{Nd}]+/-/g; s/-{2,}/-/g; s/^-//; s/-$//')
    fi
fi

[[ -n "$META_FILE" && -f "$META_FILE" ]] && cp "$META_FILE" "$WORK_DIR/meta.json" || \
    printf '{"title": "%s", "date": "%s"}\n' "$TITLE" "$MEETING_DATE" > "$WORK_DIR/meta.json"

NOTE_CONTENT="$WORK_DIR/note.md"
# ── 发布：整场录音压缩 + 主题切分 + 逐页录音切片 + 按主题出笔记 ──
REC_DIR="$VAULT/attachments/__完整录音"
mkdir -p "$REC_DIR"
AUDIO_LINK=""
if "$FFMPEG" -nostdin -i "$AUDIO" -c:a aac -b:a 64k -ac 1 "$REC_DIR/${SAFE_TITLE}.m4a" -y -loglevel error 2>>"$LOG" && [ -s "$REC_DIR/${SAFE_TITLE}.m4a" ]; then
    AUDIO_LINK="attachments/__完整录音/${SAFE_TITLE}.m4a"
    log "  整场录音: ${AUDIO_LINK}"
fi

"$PYTHON" "$SCRIPT_DIR/build_section_notes.py" \
    --captions "$WORK_DIR/captions.json" --audio "$AUDIO" --audio-link "$AUDIO_LINK" \
    --vault "$VAULT" --frames-dir "$FRAMES_DIR" \
    --base-title "$SAFE_TITLE" --date "$MEETING_DATE" \
    --meta "$WORK_DIR/meta.json" >> "$LOG" 2>&1 || { log "ERROR: 笔记生成失败"; exit 1; }

log "完成！笔记已按主题写入: $VAULT/会议笔记/"

"$SCRIPT_DIR/cleanup_tmp.py" 1024 >> "$LOG" 2>&1 || true

if [[ "${KEEP_MLX_SERVER:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/mlx_server.sh" "" "" stop >> "$LOG" 2>&1 || true
    ollama stop qwen2.5:7b >/dev/null 2>&1 || true
    log "  已卸载 MLX server 与回退模型，释放内存/GPU"
fi
