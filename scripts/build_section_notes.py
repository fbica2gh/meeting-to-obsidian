#!/usr/bin/env python3
"""build_section_notes.py — 从逐帧润色结果生成笔记（支持多主题自动拆分）

输入: captions.json（逐帧 ts_str/caption/raw/fixed）、原始录音、vault、元数据
流程:
  1. segment_topics.py 逻辑：LLM 依据逐页摘要判定主题边界（单主题→单笔记）
  2. 对每段：
     - 截取该时段录音片段（按帧词序 5s 帧的时间窗，精确到帧，m4a 附件）
     - 复制该段关键帧，组装该段转录（视觉纠错后的逐帧文本）
     - 生成该段的 note（属性/录音链接/图文对照/录音片段 callout）并经 MCP 写入 vault
  3. 单主题时回退为整场一份笔记（与旧流程一致）

Usage:
    build_section_notes.py --captions captions.json --audio session/audio.wav
        --audio-link "attachments/xx/audio.m4a" --vault <vault> --frames-dir <dir>
        --base-title <标题> --date <YYYY-MM-DD> [--meta meta.json] [--tags tags.txt]
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
CLIP_BITRATE = "32k"


def sh_list(args, timeout=900):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r


def sanitize(title, fallback):
    t = re.sub(r"[\\/:<>|*?\"~\[\]]+", " ", title or "").strip()
    t = re.sub(r"\s+", " ", t)[:40].strip()
    return re.sub(r"\s+", "-", t) or fallback


def ts_to_sec(ts):
    parts = [int(x) for x in ts.split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0


def fmt_dur(sec):
    m, s = divmod(int(sec), 60)
    return f"{m}:{s:02d}"


def frame_stamp(fname):
    """frame_HHMMSS.png → HHMMSS"""
    m = re.search(r"frame_(\d{6})", fname)
    return m.group(1) if m else None


def mcp_write(vault, note_rel_path, note_path):
    r = sh_list([sys.executable, os.path.join(SCRIPT_DIR, "obsidian_mcp_client.py"),
                 "configure", vault])
    log(r)
    r = sh_list([sys.executable, os.path.join(SCRIPT_DIR, "obsidian_mcp_client.py"),
                 "write", note_rel_path, note_path])
    log(r)


def log(s):
    print(s, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--captions", required=True)
    ap.add_argument("--audio", required=True)
    ap.add_argument("--audio-link", default=None, help="整场完整录音的 vault 相对路径（挂到第一份/唯一笔记）")
    ap.add_argument("--vault", required=True)
    ap.add_argument("--frames-dir", required=True)
    ap.add_argument("--base-title", required=True)
    ap.add_argument("--date", default=None)
    ap.add_argument("--meta", default=None)
    ap.add_argument("--tags", default=None)
    ap.add_argument("--model", default=None)
    args = ap.parse_args()

    caps = json.load(open(args.captions, encoding="utf-8"))
    # 时间序兜底排序（防御任何上游乱序）
    keys = sorted(caps.keys(), key=lambda f: ts_to_sec(caps[f].get("ts_str", "0:00")))
    if not keys:
        print("ERROR: captions 为空"); sys.exit(1)

    meta = {}
    if args.meta and os.path.exists(args.meta):
        meta = json.load(open(args.meta, encoding="utf-8"))
    date = args.date or meta.get("date") or datetime.date.today().isoformat()
    authors = meta.get("authors") or []
    tags = None
    if args.tags and os.path.exists(args.tags):
        tags = [l.strip() for l in open(args.tags, encoding="utf-8") if l.strip()] or None

    # ── 1. 主题切分（LLM；失败/单主题回退单笔记） ──
    try:
        import segment_topics as st
        outline_raw = st.segment(caps, args.model)
        starts = st.parse_sections(outline_raw, len(keys), None)
        titles_by_start = {}
        if starts:
            try:
                d = json.loads(re.search(r"\{[\s\S]*\}|\[[\s\S]*\]", outline_raw).group(0))
                if isinstance(d, dict):
                    for sec in d["sections"]:
                        idx = int(sec.get("start_index", 1))
                        titles_by_start[idx] = (sec.get("title") or "").strip()
            except Exception:
                pass
    except Exception as e:
        log(f"WARN: 主题切分失败（{e}），退化为单笔记")
        starts = None
    sections = []
    if starts and len(starts) > 1:
        starts = sorted(set(starts))
        for i, s_i in enumerate(starts):
            e_i = starts[i + 1] - 1 if i + 1 < len(starts) else len(keys)
            sections.append({"title": titles_by_start.get(s_i, ""),
                             "frames": [keys[j] for j in range(s_i - 1, e_i)],
                             "ts_start": caps[keys[s_i - 1]].get("ts_str", "0:00"),
                             "ts_end": caps[keys[e_i - 1]].get("ts_str", "0:00")})
    else:
        sections = [{"title": (meta.get("title") or args.base_title),
                     "frames": keys,
                     "ts_start": caps[keys[0]].get("ts_str", "0:00"),
                     "ts_end": caps[keys[-1]].get("ts_str", "0:00")}]
    log(f"主题分段: {len(sections)} 段")

    # 音频总时长（最后一片的截止用）
    r = sh_list([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=nw=1:nk=1", args.audio])
    try:
        audio_dur = float(r.stdout.strip())
    except Exception:
        audio_dur = 0.0

    import generate_note as gn
    multi = len(sections) > 1

    # ── 2. 逐段生成 ──
    for si, sec in enumerate(sections, 1):
        sec_title = sanitize(sec["title"],
                             f"{args.base_title}" if not multi else f"{args.base_title}第{si}部分")
        # 主标题去敏（多段时每个都加唯一性；标题空则用兜底）
        if multi and not sec["title"]:
            sec_title = re.sub(r"\s+", "-", sanitize(args.base_title, args.base_title)) + f"-第{si}部分"
        attach = os.path.join(args.vault, "attachments", sec_title, "clips")
        os.makedirs(attach, exist_ok=True)
        os.makedirs(os.path.join(args.vault, "attachments", sec_title), exist_ok=True)

        frames = sec["frames"]
        ts_secs = [ts_to_sec(caps[f].get("ts_str", "0:00")) for f in frames]

        # ── 逐段切片录音（并行） ──
        clip_jobs = []
        for fi, fname in enumerate(frames):
            info = caps[fname]
            t0 = ts_secs[fi]
            t1 = ts_secs[fi + 1] if fi + 1 < len(frames) else (int(audio_dur) if audio_dur else t0 + 5)
            text = (info.get("fixed") or info.get("raw") or "").strip()
            if t1 <= t0 or (not text and not info.get("caption")):
                continue
            stamp = frame_stamp(fname) or f"{t0:06d}"
            clip_rel = f"attachments/{sec_title}/clips/seg_{stamp}.m4a"
            clip_jobs.append((t0, min(t1, int(audio_dur) - 1 if audio_dur else t1 + 5),
                              os.path.join(args.vault, clip_rel), fname, clip_rel))

        def gen_clip(job):
            t0, t1, out, fname, rel = job
            r = sh_list([FFMPEG, "-nostdin", "-ss", str(t0), "-to", str(t1), "-i", args.audio,
                         "-c:a", "aac", "-b:a", CLIP_BITRATE, "-ac", "1", out, "-y",
                         "-loglevel", "error"], timeout=300)
            return (fname, rel if (r.returncode == 0 and os.path.getsize(out) > 1000) else None)

        with ThreadPoolExecutor(max_workers=4) as ex:
            for fname, rel in ex.map(gen_clip, clip_jobs):
                if rel:
                    caps[fname]["audio"] = rel
        n_clips = sum(1 for f in clip_jobs if caps[f[3]].get("audio"))
        log(f"  段{si} 录音片段 {n_clips}/{len(clip_jobs)}")

        # ── 该段转录（逐帧纠正文本拼接） ──
        transcript = "\n".join(
            (caps[f].get("fixed") or caps[f].get("raw") or "").strip()
            for f in frames if (caps[f].get("fixed") or caps[f].get("raw"))
        ).strip()
        # ── 该段 captions 子集 ──
        sub_caps = {f: caps[f] for f in frames if f in caps}

        # ── manifest 子集 ──
        manifest_lines = [f"{caps[f].get('ts_str','0:00')}|{f}" for f in frames]
        man_path = os.path.join(os.path.dirname(args.captions),
                                f"manifest_{si}.txt")
        open(man_path, "w", encoding="utf-8").write("\n".join(manifest_lines))

        # ── 元数据 ──
        meta_sec = dict(meta)
        meta_sec.pop("title", None)
        dur_sec = ts_secs[-1] - ts_secs[0] if len(ts_secs) > 1 else int(audio_dur)
        meta_sec["date"] = date

        note_out = os.path.join(os.path.dirname(args.captions), f"note_{si}.md")
        audio_link = None
        if si == 1 and args.audio_link:
            audio_link = args.audio_link
        gn.generate_note(transcript, gn.parse_manifest(man_path), sec_title, date,
                         note_out, meta=meta_sec, captions=sub_caps, tags=tags,
                         duration=fmt_dur(dur_sec), topic=None, audio_link=audio_link)
        # 纠正内嵌图片引用
        txt = open(note_out, encoding="utf-8").read()
        txt = txt.replace("![[frame_", f"![[attachments/{sec_title}/frame_")
        open(note_out, "w", encoding="utf-8").write(txt)

        # 复制关键帧
        frames_dst = os.path.join(args.vault, "attachments", sec_title)
        for f in frames:
            src = os.path.join(args.frames_dir, f)
            if os.path.exists(src):
                dst = os.path.join(frames_dst, f)
                if not os.path.exists(dst):
                    try:
                        os.link(src, dst)
                    except OSError:
                        open(dst, "wb").write(open(src, "rb").read())

        # MCP 发布
        mcp_write(args.vault, f"会议笔记/{sec_title}.md", note_out)
        log(f"  段{si} 笔记: 会议笔记/{sec_title}.md（{len(frames)} 帧，{fmt_dur(dur_sec)}）")

    log(f"完成: 共 {len(sections)} 份笔记")


if __name__ == "__main__":
    main()
