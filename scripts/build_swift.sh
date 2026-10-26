#!/bin/bash
# build_swift.sh — 编译并签名两个 ScreenCaptureKit 辅助程序
#
#   window_capture        — 捕获指定窗口画面（支持后台窗口）
#   system_audio_capture  — 捕获系统音频（腾讯会议等应用音频输出）
#
# system_audio_capture 内嵌 Info.plist（含 NSAudioCaptureUsageDescription），
# 否则 macOS 会静默拒绝系统音频捕获（返回全零 buffer）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> 编译 window_capture ..."
swiftc -O window_capture.swift -o window_capture
codesign -s - -f window_capture
echo "    OK"

echo "==> 编译 system_audio_capture（内嵌 Info.plist）..."
if [[ ! -f Info.plist ]]; then
    echo "ERROR: 缺少 Info.plist（需含 NSAudioCaptureUsageDescription）"
    exit 1
fi
swiftc -O system_audio_capture.swift -o system_audio_capture \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - -f system_audio_capture
echo "    OK"

echo "==> 验证嵌入的 Info.plist ..."
otool -s __TEXT __info_plist system_audio_capture > /dev/null 2>&1 && echo "    OK" || echo "    WARNING: 未检测到 __info_plist section"

echo ""
echo "构建完成："
echo "  $SCRIPT_DIR/window_capture"
echo "  $SCRIPT_DIR/system_audio_capture"
echo ""
echo "注意：首次运行需授予'屏幕录制/系统音频录制'权限。"
