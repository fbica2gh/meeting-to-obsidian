#!/bin/bash
# install.sh — meeting-to-obsidian 一键安装（macOS / Apple Silicon）
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.zcode/config/meeting-to-obsidian"
VENV="$HOME/.zcode/venvs/whisper"

echo "==> 1/5 检查系统依赖"
for cmd in swiftc ffmpeg python3 git; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "缺少 $cmd（brew install $cmd 或 xcode-select --install）"; exit 1; }
done
echo "  OK: swiftc / ffmpeg / python3 / git"

echo "==> 2/5 生成配置"
mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG_DIR/config.sh" ] || cp "$SKILL_DIR/config.example.sh" "$CONFIG_DIR/config.sh"
[ -f "$CONFIG_DIR/glossary.txt" ] || cp "$SKILL_DIR/glossary.example.txt" "$CONFIG_DIR/glossary.txt"
echo "  配置: $CONFIG_DIR/config.sh （请编辑 vault 路径等）"
echo "  词表: $CONFIG_DIR/glossary.txt （按你的领域补充 错误写法=正确写法）"

echo "==> 3/5 编译 ScreenCaptureKit 辅助程序"
CONFIG_FILE="$CONFIG_DIR/config.sh" bash "$SKILL_DIR/scripts/build_swift.sh" | tail -1

echo "==> 4/5 Python venv + MLX 依赖"
if [ ! -x "$VENV/bin/python3" ]; then
    python3 -m venv "$VENV"
fi
PIP="$VENV/bin/pip"
"$PIP" install -q --upgrade pip
# 国内网络可追加: -i https://mirrors.aliyun.com/pypi/simple/
"$PIP" install -q mlx mlx-audio mlx-vlm mlx-whisper pillow || {
    echo "  pip 安装失败，尝试国内镜像..."
    "$PIP" install -q -i https://mirrors.aliyun.com/pypi/simple/ mlx mlx-audio mlx-vlm mlx-whisper pillow
}
"$VENV/bin/python3" -c "import mlx, mlx_audio, mlx_vlm, mlx_whisper" && echo "  MLX 依赖 OK"

echo "==> 5/5 模型权重下载（可选，约 2.6 GB）"
CONFIG_FILE="$CONFIG_DIR/config.sh"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${MODELS_DIR:=$HOME/.zcode/models}"
read -rp "现在下载模型权重？[y/N] " yn
if [[ "${yn:-n}" =~ ^[Yy] ]]; then
    mkdir -p "$MODELS_DIR"
    "$VENV/bin/python3" "$SKILL_DIR/scripts/parallel_download.py" \
        --repo mlx-community/Qwen3-ASR-1.7B-bf16 --file model.safetensors \
        --dest "$MODELS_DIR/Qwen3-ASR-1.7B" --size 4076186653 --threads 8
    echo "  ASR 模型完成。多模态润色模型（Qwen3.6-35B-A3B-4bit，20.4GB）请按 README.md 下载，"
    echo "  或运行: $VENV/bin/python3 $SKILL_DIR/scripts/ms_download_repo.sh mlx-community/Qwen3.6-35B-A3B-4bit $MODELS_DIR/Qwen3.6-35B-A3B-4bit 8"
fi

cat <<DONE

安装完成。下一步：
  1) 编辑 $CONFIG_DIR/config.sh（vault 路径）
  2) 按需补充 $CONFIG_DIR/glossary.txt（领域术语 错误写法=正确写法）
  3) 确认 Obsidian 的 MCP 端点可用（scripts/obsidian_mcp_client.py configure "$OBSIDIAN_VAULT"）
  4) 开始录制（命令见 README.md「快速开始」）
DONE
