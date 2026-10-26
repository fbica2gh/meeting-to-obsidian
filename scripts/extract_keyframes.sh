#!/bin/bash
# extract_keyframes.sh — 从视频提取关键帧（场景检测 + 感知哈希去重）
# 参考 Meetily 的场景检测 + Margins 的文件驱动模式
#
# 用法:
#   extract_keyframes.sh <input_mp4> <output_dir> [场景阈值] [最小间隔秒数]
#
# 默认:
#   场景阈值: 0.3（越高越只保留变化大的帧）
#   最小间隔: 15秒（同一 PPT 页只保留一帧）

set -euo pipefail

INPUT="${1:?用法: extract_keyframes.sh <input_mp4> <output_dir> [threshold] [min_interval]}"
OUTPUT_DIR="${2:?缺少输出目录}"
THRESHOLD="${3:-0.3}"
MIN_INTERVAL="${4:-15}"

FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="/opt/homebrew/bin/ffprobe"
PYTHON="$HOME/.zcode/venvs/whisper/bin/python3"

mkdir -p "$OUTPUT_DIR"

DURATION=$($FFPROBE -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null || echo "0")

echo "输入: $INPUT"
echo "时长: ${DURATION}s"
echo "场景阈值: $THRESHOLD | 最小间隔: ${MIN_INTERVAL}s"

# 第一步：场景检测提取
echo "[1/3] 场景检测..."
$FFMPEG -nostdin -i "$INPUT" \
    -vf "select='gt(scene,${THRESHOLD})',scale=1920:-1" \
    -fps_mode vfr \
    -q:v 2 \
    -pix_fmt yuvj420p \
    "$OUTPUT_DIR/raw_%04d.jpg" \
    -y -loglevel warning 2>/dev/null || true

RAW_COUNT=$(find "$OUTPUT_DIR" -name "raw_*.jpg" -type f 2>/dev/null | wc -l | tr -d ' ') || RAW_COUNT=0
echo "  场景检测: $RAW_COUNT 帧"

if [[ "$RAW_COUNT" -eq 0 ]]; then
    echo "  场景检测无结果，使用固定间隔回退..."
    $FFMPEG -nostdin -i "$INPUT" \
        -vf "fps=1/10,scale=1920:-1" \
        -q:v 2 \
        -pix_fmt yuvj420p \
        "$OUTPUT_DIR/raw_%04d.jpg" \
        -y -loglevel warning || true
    RAW_COUNT=$(find "$OUTPUT_DIR" -name "raw_*.jpg" -type f 2>/dev/null | wc -l | tr -d ' ') || RAW_COUNT=0
    echo "  固定间隔: $RAW_COUNT 帧"
fi

# 第二步：裁剪黑边和 UI 条
echo "[2/4] 裁剪黑边/UI 条..."
CROP_SCRIPT="$(cd "$(dirname "$0")" && pwd)/crop_borders.py"
if [[ -f "$CROP_SCRIPT" ]]; then
    "$PYTHON" "$CROP_SCRIPT" "$OUTPUT_DIR" 2>&1 | tail -2
else
    echo "  WARNING: crop_borders.py 未找到，跳过裁剪"
fi

# 第三步：感知哈希去重
echo "[3/4] 感知哈希去重..."
DEDUP_SCRIPT="$(cd "$(dirname "$0")" && pwd)/dedup_images.py"
if [[ -f "$DEDUP_SCRIPT" ]]; then
"$PYTHON" "$DEDUP_SCRIPT" "$OUTPUT_DIR" 12
else
    echo "  WARNING: dedup_images.py 未找到，跳过去重"
fi

# 第三步：按最小间隔过滤 + 重命名
echo "[3/3] 间隔过滤与重命名..."

# 提取时间戳
TIMESTAMPS_FILE="$OUTPUT_DIR/timestamps_raw.txt"
$FFMPEG -nostdin -i "$INPUT" \
    -vf "select='gt(scene,${THRESHOLD})',showinfo" \
    -fps_mode vfr \
    -f null - 2>&1 | grep "pts_time:" | while read -r line; do
    TIMESTAMP=$(echo "$line" | grep -o 'pts_time:[0-9.]*' | cut -d: -f2)
    if [[ -n "$TIMESTAMP" ]]; then
        echo "$TIMESTAMP"
    fi
done > "$TIMESTAMPS_FILE" 2>/dev/null || true

# 按最小间隔过滤并重命名
FRAME_IDX=0
LAST_TS=-999
MANIFEST="$OUTPUT_DIR/manifest.txt"
> "$MANIFEST"

for img in "$OUTPUT_DIR"/raw_*.jpg; do
    [[ -f "$img" ]] || continue
    
    # 获取时间戳
    TS=$(sed -n "$((FRAME_IDX + 1))p" "$TIMESTAMPS_FILE" 2>/dev/null || echo "")
    if [[ -z "$TS" ]]; then
        TS=$((FRAME_IDX * 10))
    fi
    
    # 最小间隔过滤
    DIFF=$(echo "$TS - $LAST_TS" | bc)
    if (( $(echo "$DIFF < $MIN_INTERVAL" | bc -l) )); then
        FRAME_IDX=$((FRAME_IDX + 1))
        continue
    fi
    
    # 重命名为最终格式
    MINS=$(echo "$TS/60" | bc)
    SECS=$(echo "$TS%60/1" | bc)
    FRAME_FILE=$(printf "frame_%04d.jpg" $((FRAME_IDX + 1)))
    mv "$img" "$OUTPUT_DIR/$FRAME_FILE"
    
    # 写入 manifest
    echo "$(printf "%d:%02d" $MINS $SECS)|${FRAME_FILE}" >> "$MANIFEST"
    
    LAST_TS=$TS
    FRAME_IDX=$((FRAME_IDX + 1))
done

# 清理未使用的文件
rm -f "$OUTPUT_DIR"/raw_*.jpg
rm -f "$TIMESTAMPS_FILE"

FINAL_COUNT=$(find "$OUTPUT_DIR" -name "frame_*.jpg" -type f 2>/dev/null | wc -l | tr -d ' ') || FINAL_COUNT=0

# 最小保留帧数限制（防止过度去重）
MIN_FRAMES=10
if [[ "$FINAL_COUNT" -lt "$MIN_FRAMES" ]] && [[ "$RAW_COUNT" -gt "$FINAL_COUNT" ]]; then
    echo "  Over-dedup ($FINAL_COUNT < $MIN_FRAMES), restoring from duplicates..."
    DUP_DIR="$OUTPUT_DIR/.duplicates"
    if [[ -d "$DUP_DIR" ]]; then
        DUP_COUNT=$(find "$DUP_DIR" -name "raw_*.jpg" -type f 2>/dev/null | wc -l | tr -d ' ') || DUP_COUNT=0
        NEEDED=$((MIN_FRAMES - FINAL_COUNT))
        RESTORE=$((NEEDED < DUP_COUNT ? NEEDED : DUP_COUNT))
        i=1
        while [[ $i -le $RESTORE ]]; do
            DUP_FILE=$(find "$DUP_DIR" -name "raw_*.jpg" -type f 2>/dev/null | sort | head -$i | tail -1)
            if [[ -f "$DUP_FILE" ]]; then
                FRAME_FILE=$(printf "frame_%04d.jpg" $((FINAL_COUNT + i)))
                cp "$DUP_FILE" "$OUTPUT_DIR/$FRAME_FILE"
                TS=$(( (FINAL_COUNT + i - 1) * 15 ))
                MINS=$(( TS / 60 ))
                SECS=$(( TS % 60 ))
                echo "$(printf "%d:%02d" $MINS $SECS)|${FRAME_FILE}" >> "$MANIFEST"
            fi
            i=$((i + 1))
        done
        FINAL_COUNT=$((FINAL_COUNT + RESTORE))
    fi
fi

echo ""
echo "最终: $FINAL_COUNT 帧（原始 $RAW_COUNT 帧）"
echo "Manifest: $MANIFEST"
