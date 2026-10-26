#!/bin/bash
# mlx_server.sh — 启动 MLX server（OpenAI 兼容接口），供 polish_note.py 使用
#
# 用法:
#   mlx_server.sh [模型目录] [端口] [start|stop|status]
#
# 例:
#   mlx_server.sh ~/.zcode/models/Qwen3.6-35B-A3B-4bit 8081 start
#   export LLM_BASE_URL=http://127.0.0.1:8081/v1
#   export LLM_MODEL=Qwen3.6-35B-A3B-4bit
set -uo pipefail

CONFIG_FILE="${MEETING_SKILL_CONFIG:-$HOME/.zcode/config/meeting-to-obsidian/config.sh}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${MODELS_DIR:=$HOME/.zcode/models}"
MODEL="${1:-$MODELS_DIR/Qwen3.6-35B-A3B-4bit}"
PORT="${2:-8081}"
ACTION="${3:-start}"
PY="$HOME/.zcode/venvs/whisper/bin/python3"
PID_FILE="$HOME/.zcode/logs/mlx_server.pid"
LOG_FILE="$HOME/.zcode/logs/mlx_server.log"

case "$ACTION" in
  stop)
    pkill -f "mlx_vlm.server --model" 2>/dev/null
    pkill -f "mlx_lm.server --model" 2>/dev/null
    rm -f "$PID_FILE"
    sleep 1
    if pgrep -f "mlx_vlm.server|mlx_lm.server" >/dev/null 2>&1; then
        echo "WARN: 仍有 MLX server 进程残留"
    else
        echo "已停止 MLX server（GPU/内存已释放）"
    fi
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "运行中 (PID $(cat "$PID_FILE")) 端口 $PORT"
    else
        echo "未运行"
    fi
    ;;
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "已在运行 (PID $(cat "$PID_FILE"))"; exit 0
    fi
    if [ ! -d "$MODEL" ]; then echo "ERROR: 模型目录不存在: $MODEL"; exit 1; fi
    # 按模型类型选运行时：多模态架构(qwen3_5 等)用 mlx_vlm，纯文本用 mlx_lm
    local runtime="mlx_lm.server"
    if grep -qE '"(architectures|model_type)"' "$MODEL/config.json" 2>/dev/null && \
       grep -qE 'qwen3_5|qwen3_5_moe|ForConditionalGeneration' "$MODEL/config.json" 2>/dev/null; then
        runtime="mlx_vlm.server"
    fi
    echo "启动 MLX server: $MODEL (端口 $PORT, $runtime)"
    nohup "$PY" -m "$runtime" --model "$MODEL" --host 127.0.0.1 --port "$PORT" \
        > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    for i in $(seq 1 300); do
        if curl -s --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
            echo "就绪: http://127.0.0.1:$PORT/v1 （用时 ${i}s）"
            exit 0
        fi
        sleep 1
    done
    echo "WARN: 300 秒内未就绪，查看日志: $LOG_FILE"; exit 1
    ;;
esac
