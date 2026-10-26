#!/usr/bin/env python3
"""qwen_asr_transcribe.py — Qwen3-ASR (MLX) 转录，单模型方案：
输出与管线约定的 audio.txt（全文）+ audio.json（带 start/end 时间戳的分段）。
长音频自动切块；调用 CLI --format json 以启用分段并行转录。
热词偏置：glossary.txt 右列词自动作为 context。

用法:
    python3 qwen_asr_transcribe.py <音频文件> <输出目录> [模型目录]
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

DEFAULT_MODEL = os.path.expanduser("~/.zcode/models/Qwen3-ASR-1.7B")
GLOSSARY = os.environ.get(
    "GLOSSARY_FILE",
    os.path.expanduser("~/.zcode/config/meeting-to-obsidian/glossary.txt"),
)
GLOSSARY_EXAMPLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "glossary.example.txt"
)
FFPROBE = "/opt/homebrew/bin/ffprobe"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
MAX_CHUNK_SEC = 280
PY = sys.executable


def glossary_context():
    words = []
    path = GLOSSARY if os.path.exists(GLOSSARY) else GLOSSARY_EXAMPLE
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                right = line.split("=", 1)[1].strip()
                for w in re.split(r"[、，,]", right):
                    w = w.strip()
                    if w and w not in words:
                        words.append(w)
    except FileNotFoundError:
        pass
    return "；".join(words[:30])


def audio_duration(path):
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=60)
        return float(out.stdout.strip() or 0)
    except Exception:
        return 0.0


def transcribe(model, audio, ctx, outdir):
    out = subprocess.run(
        [PY, "-m", "mlx_audio.stt.generate", "--model", model, "--audio", audio,
         "--output-path", os.path.join(outdir, "res"), "--format", "json",
         "--max-parallel-segments", "4", "--context", ctx],
        capture_output=True, text=True, timeout=1800)
    j = os.path.join(outdir, "res.json")
    if not os.path.exists(j):
        raise RuntimeError(f"转录无输出: {out.stdout[-200:]} {out.stderr[-200:]}")
    d = json.load(open(j, encoding="utf-8"))
    segs = d.get("segments") or []
    if not segs and d.get("text"):
        segs = [{"start": 0.0, "end": 0.0, "text": d["text"]}]
    return segs


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    audio, out_dir = sys.argv[1], sys.argv[2]
    model_path = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_MODEL

    ctx = os.environ.get("ASR_CONTEXT", glossary_context())
    t0 = time.time()

    os.makedirs(out_dir, exist_ok=True)
    dur = audio_duration(audio)
    all_segs = []
    if dur > MAX_CHUNK_SEC + 20:
        with tempfile.TemporaryDirectory() as td:
            subprocess.run(
                [FFMPEG, "-nostdin", "-i", audio, "-acodec", "pcm_s16le",
                 "-ar", "16000", "-ac", "1", "-f", "segment",
                 "-segment_time", str(MAX_CHUNK_SEC),
                 os.path.join(td, "c%03d.wav"), "-y", "-loglevel", "error"],
                check=True)
            parts = sorted(os.listdir(td))
            offset = 0.0
            for i, part in enumerate(parts, 1):
                print(f"  长音频分段 {i}/{len(parts)}", file=sys.stderr, flush=True)
                segs = transcribe(model_path, os.path.join(td, part), ctx, td)
                for s in segs:
                    all_segs.append({"start": round(s["start"] + offset, 2),
                                     "end": round(s["end"] + offset, 2),
                                     "text": s["text"].strip()})
                if segs:
                    offset += max(s["end"] for s in segs)
    else:
        all_segs = transcribe(model_path, audio, ctx, out_dir)
        all_segs = [{"start": round(s["start"], 2), "end": round(s["end"], 2),
                     "text": s["text"].strip()} for s in all_segs]

    text = "\n".join(s["text"] for s in all_segs).strip()
    if not text:
        print("EMPTY transcript", file=sys.stderr)
        sys.exit(1)

    with open(os.path.join(out_dir, "audio.txt"), "w") as f:
        f.write(text)
    with open(os.path.join(out_dir, "audio.json"), "w") as f:
        json.dump(all_segs, f, ensure_ascii=False, indent=1)
    took = round(time.time() - t0, 1)
    print(f"OK {took}s -> {os.path.join(out_dir, 'audio.txt')} "
          f"(+audio.json, {len(all_segs)} 段, {dur:.0f}s 音频)", file=sys.stderr)


if __name__ == "__main__":
    main()
