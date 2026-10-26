#!/bin/bash
# setup.sh — 检查并安装所有依赖
set -euo pipefail

echo "============================================"
echo " 腾讯会议 → Obsidian 笔记 — 依赖检查"
echo "============================================"
echo ""

MISSING=0

# 检查 Python3
if command -v python3 &>/dev/null; then
    echo "✓ Python3: $(python3 --version)"
else
    echo "✗ Python3: 未安装"
    MISSING=1
fi

# 检查 ffmpeg
if command -v ffmpeg &>/dev/null; then
    echo "✓ ffmpeg: $(ffmpeg -version 2>&1 | head -1)"
else
    echo "✗ ffmpeg: 未安装 (brew install ffmpeg)"
    MISSING=1
fi

# 检查 ffprobe
if command -v ffprobe &>/dev/null; then
    echo "✓ ffprobe: 已安装"
else
    echo "✗ ffprobe: 未安装 (通常随 ffmpeg 一起安装)"
    MISSING=1
fi

# 检查 MLX Whisper（使用 whisper venv）
PYTHON="$HOME/.zcode/venvs/whisper/bin/python3"
if [[ -x "$PYTHON" ]] && "$PYTHON" -c "import mlx_whisper" 2>/dev/null; then
    echo "✓ MLX Whisper: 已安装 (venv)"
else
    echo "✗ MLX Whisper: 未安装"
    echo "  安装: pip install mlx-whisper"
    MISSING=1
fi

# 检查 MCP 依赖（使用 obsidian-mcp venv）
MCP_PYTHON="$HOME/.zcode/venvs/obsidian-mcp/bin/python3"
if [[ -x "$MCP_PYTHON" ]] && "$MCP_PYTHON" -c "import mcp" 2>/dev/null; then
    echo "✓ MCP SDK: 已安装 (venv)"
else
    echo "✗ MCP SDK: 未安装"
    echo "  安装: pip install mcp==1.11.0"
    MISSING=1
fi

# 检查 Pillow（图像去重依赖）
if "$PYTHON" -c "from PIL import Image" 2>/dev/null; then
    echo "✓ Pillow: 已安装"
else
    echo "✗ Pillow: 未安装"
    echo "  安装: pip install Pillow"
    MISSING=1
fi

# 检查 swiftc（编译 ScreenCaptureKit 辅助程序）
if command -v swiftc &>/dev/null; then
    echo "✓ swiftc: 已安装"
else
    echo "✗ swiftc: 未安装 (需要 Xcode Command Line Tools)"
    echo "  安装: xcode-select --install"
    MISSING=1
fi

# 检查 ScreenCaptureKit 辅助程序
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$SCRIPT_DIR/window_capture" && -x "$SCRIPT_DIR/system_audio_capture" ]]; then
    echo "✓ SCK 辅助程序: 已编译"
else
    echo "✗ SCK 辅助程序: 未编译"
    echo "  构建: bash $SCRIPT_DIR/build_swift.sh"
    MISSING=1
fi

# 检查 bc
if command -v bc &>/dev/null; then
    echo "✓ bc: 已安装"
else
    echo "✗ bc: 未安装"
    MISSING=1
fi

# 检查 perl
if command -v perl &>/dev/null; then
    echo "✓ perl: 已安装"
else
    echo "✗ perl: 未安装"
    MISSING=1
fi

# 检查 Obsidian MCP 配置
MCP_BIN="$HOME/.zcode/venvs/obsidian-mcp/bin/obsidian-mcp"
if [[ -x "$MCP_BIN" ]]; then
    echo "✓ MCP 服务器: $MCP_BIN"
else
    echo "✗ MCP 服务器: 未找到"
    echo "  请安装 obsidian-mcp-server"
    MISSING=1
fi

# 检查 Vault 路径
VAULT="$HOME/Documents/Obsidian Vault"
if [[ -d "$VAULT" ]]; then
    echo "✓ Obsidian Vault: $VAULT"
else
    echo "✗ Obsidian Vault: 未找到 ($VAULT)"
    MISSING=1
fi

# 检查录制目录
RECORDING_DIR="$HOME/Downloads/TencentMeeting"
if [[ -d "$RECORDING_DIR" ]]; then
    echo "✓ 录制目录: $RECORDING_DIR"
else
    echo "✗ 录制目录: 未找到 ($RECORDING_DIR)"
    MISSING=1
fi

echo ""
if [[ $MISSING -eq 0 ]]; then
    echo "============================================"
    echo " 所有依赖已就绪！"
    echo "============================================"
else
    echo "============================================"
    echo " 缺少部分依赖，请安装后重试"
    echo "============================================"
    exit 1
fi
