# 第三方组件与许可声明（THIRD-PARTY NOTICES）

本 skill 的自有代码（`scripts/` 下的 Shell / Python / Swift）以 MIT 许可发布（见 LICENSE）。
运行时依赖以下第三方组件，均以独立进程或库方式使用，未修改其源码、未再分发其权重：

## 运行框架与库

| 组件 | 许可 | 说明 |
|------|------|------|
| [MLX](https://github.com/ml-explore/mlx) / mlx-audio / mlx-vlm / mlx-whisper | MIT | Apple MLX 生态，推理框架 |
| [ffmpeg](https://ffmpeg.org) | LGPL/GPL（独立进程调用，不链接） | 音频转码；用户自装（如 Homebrew） |
| [Pillow](https://python-pillow.org) | MIT-CMU | 图像处理 |
| [ollama](https://ollama.com) | MIT | 可选回退后端 |
| Apple ScreenCaptureKit / AVFoundation | Apple 系统框架 | 仅调用系统 API，未再分发 |

## 模型权重（脚本按需下载，本仓库不包含、不再分发）

| 模型 | 许可 | 来源 |
|------|------|------|
| Qwen3-ASR-1.7B | Apache-2.0 | ModelScope / Hugging Face |
| Qwen3.6-35B-A3B（4bit MLX 转换版） | Apache-2.0 | ModelScope / Hugging Face |
| whisper-large-v3-turbo（可选回退） | MIT | Hugging Face |
| qwen2.5:7b（可选回退，经 ollama） | Apache-2.0 | ollama registry |

各模型按其原始许可使用，使用时请遵循对应模型卡片的使用条款。

## 使用注意事项

1. **会议录音合规**：录制会议可能涉及他人语音与屏幕内容，请确保获得参会方同意，
   并遵守所在地区关于个人信息保护与录音的法律法规；发布或分享会议内容前请再次确认授权范围。
2. **会议软件条款**：部分会议软件的服务条款对录制有约定，使用本工具前请自行确认。
3. **商标**：Tencent Meeting（腾讯会议）、Obsidian、Apple 等名称仅为互操作说明之用，
   本项目与上述权利人无关联。
4. **Apple 示例代码**：`scripts/` 下 Swift 代码为原创实现，非 Apple 官方示例的拷贝。
