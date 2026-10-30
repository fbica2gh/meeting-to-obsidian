#!/usr/bin/env python3
"""
generate_note.py — Generate Obsidian note from transcript + keyframes + meeting metadata
Follows kepano/obsidian-skills obsidian-markdown specification.

Usage:
    generate_note.py <transcript_file> <frames_manifest> <output_file>
                     [meta_json] [summary_file] [segments_json] [captions_json] [tags_file]

notes:
  - transcript_file: 润色后的全文（无时间戳）
  - frames_manifest: 每行 "m:ss|文件名"
  - segments_json:   [{"start":秒,"end":秒,"text":...}]，用于图文时间对齐
  - captions_json:   {"文件名": {"caption":..., "raw":...}}，每张图的配图说明
  - tags_file:       每行一个主题标签，写入 frontmatter 属性
"""

import json
import os
import sys
from datetime import datetime


def parse_manifest(manifest_path):
    """Parse frame manifest: timestamp|filename per line"""
    frames = []
    if not os.path.exists(manifest_path):
        return frames
    with open(manifest_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if "|" in line:
                ts, filename = line.split("|", 1)
                frames.append({"timestamp": ts, "file": filename})
    return frames


def parse_ts(ts):
    """'m:ss' or 'h:mm:ss' → seconds"""
    parts = [int(p) for p in ts.split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0


def format_ts(seconds):
    m, s = divmod(int(seconds), 60)
    return f"{m}:{s:02d}"


def generate_note(transcript, frames, title, meeting_date, output_path,
                  meta=None, summary=None, captions=None, tags=None, duration=None,
                  topic=None, audio_link=None):
    """Generate Obsidian note with kepano obsidian-markdown spec compliance"""

    # ── frontmatter 属性：基础 + 内容自动生成 ──
    note_lines = [
        "---",
        f'title: "{title}"',
        f'date: "{meeting_date}"',
        "tags:",
        "  - 会议笔记",
    ]
    for t in tags or []:
        note_lines.append(f"  - {t}")
    note_lines += [
        "source: 腾讯会议",
        "transcribed: true",
    ]
    authors = (meta or {}).get("authors") or ([meta["speaker"]] if (meta or {}).get("speaker") else [])
    if authors:
        note_lines.append("authors:")
        for a in authors:
            note_lines.append(f"  - {a}")
    if topic:
        note_lines.append(f'topic: "{topic}"')
    if duration:
        note_lines.append(f'duration: "{duration}"')
    if frames:
        note_lines.append(f"keyframes: {len(frames)}")
    note_lines += ["---", ""]

    note_lines += [
        f"# {title}",
        "",
        "> [!info] 会议信息",
        f"> **日期**: {meeting_date}",
    ]
    if duration:
        note_lines.append(f"> **时长**: {duration}")
    if frames:
        note_lines.append(f"> **关键帧**: {len(frames)} 张")
    if tags:
        pass  # 标签已在 frontmatter 属性中
    if topic:
        note_lines.append(f"> **主题**: {topic}")
    if authors:
        note_lines.append(f"> **主讲人**: {'、'.join(authors)}")
    if audio_link:
        note_lines.append(f"> **录音**: [[{audio_link}|▶ 会议录音]]")

    if meta:
        if meta.get("location"):
            note_lines.append(f"> **地点**: {meta['location']}")
        if meta.get("organizer"):
            note_lines.append(f"> **主办**: {meta['organizer']}")
        if meta.get("theme"):
            note_lines.append(f"> **主题**: {meta['theme']}")
        if meta.get("guests"):
            note_lines.append(f"> **嘉宾**: {len(meta['guests'])} 位")

    note_lines.append("")

    # Agenda section
    if meta and meta.get("agenda"):
        note_lines.append("## 会议议程")
        note_lines.append("")

        # Group by session
        sessions = {}
        for item in meta["agenda"]:
            session = item.get("session", "其他")
            if session not in sessions:
                sessions[session] = []
            sessions[session].append(item)

        for session, items in sessions.items():
            note_lines.append(f"### {session}")
            note_lines.append("")
            for item in items:
                note_lines.append(f"- **{item['time']}** | {item['topic']}")
                note_lines.append(f"  - 演讲嘉宾: {item['speaker']}")
            note_lines.append("")

        # Mermaid timeline
        note_lines.append("#### 议程时间线")
        note_lines.append("")
        note_lines.append("```mermaid")
        note_lines.append("timeline")
        note_lines.append(f"    title {meeting_date} 议程")
        for item in meta["agenda"]:
            time_short = item["time"].split("-")[0].replace(":", "")
            note_lines.append(f"    {time_short} : {item['topic'][:20]}")
        note_lines.append("```")
        note_lines.append("")

    # Guests section
    if meta and meta.get("guests"):
        note_lines.append("## 嘉宾阵容")
        note_lines.append("")
        for guest in meta["guests"]:
            note_lines.append(f"### {guest['name']}")
            note_lines.append(f"- **身份**: {guest['title']}")
            note_lines.append(f"- **领域**: {guest['field']}")
            note_lines.append("")

    # ── 图文对照：每张截图 + 配图说明 + 该时段原文 ──
    if frames:
        note_lines.append("## 图文记录")
        note_lines.append("")
        for i, frame in enumerate(frames):
            ts = frame["timestamp"]
            img_path = frame["file"]
            cap_info = (captions or {}).get(frame["file"], {})
            if isinstance(cap_info, str):
                cap_info = {"caption": cap_info, "raw": ""}
            caption = (cap_info.get("caption") or "").strip()
            raw_slice = (cap_info.get("raw") or "").strip()

            if caption:
                note_lines.append(f"### [{ts}] {caption}")
            else:
                note_lines.append(f"### [{ts}]")
            note_lines.append("")
            note_lines.append(f"![[{img_path}]]")
            note_lines.append("")
            audio_clip = (cap_info.get("audio") or "").strip()
            if raw_slice:
                note_lines.append("> [!quote]- 本时段讲解原文")
                for line in raw_slice.splitlines():
                    note_lines.append(f"> {line}")
                note_lines.append("")
            elif audio_clip:
                note_lines.append("> [!quote]- 本时段讲解原文")
                note_lines.append("> （本次翻页间无语音）")
                note_lines.append("")
            if audio_clip:
                note_lines.append(f"> [!audio]- 本页讲解录音 [[{audio_clip}|▶]]")
                note_lines.append("")
            note_lines.append("")

        note_lines.append("---")
        note_lines.append("")

    # 要点总结
    note_lines.append("## 要点总结")
    note_lines.append("")
    if summary:
        for line in summary.splitlines():
            line = line.strip()
            if line:
                note_lines.append(line)
    else:
        note_lines.append("<!-- 3-5 个核心观点 -->")
    note_lines.append("")

    # 语音转录（润色全文）
    note_lines.append("## 语音转录")
    note_lines.append("")
    if transcript:
        note_lines.append(transcript)
    else:
        note_lines.append("<!-- 转录内容待处理 -->")
    note_lines.append("")
    note_lines.append("---")
    note_lines.append("")

    note_lines.append("## 个人笔记")
    note_lines.append("")
    note_lines.append("<!-- 在此添加会后想法和行动项 -->")
    note_lines.append("")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(note_lines))

    print(f"Note saved: {output_path}")


def main():
    if len(sys.argv) < 4:
        print(__doc__ or "usage: generate_note.py <transcript> <manifest> <output> [meta] [summary] [segments] [captions] [tags]")
        sys.exit(1)

    transcript_file = sys.argv[1]
    manifest_file = sys.argv[2]
    output_file = sys.argv[3]

    # Read transcript
    with open(transcript_file, "r", encoding="utf-8") as f:
        transcript = f.read().strip()

    # Parse frames
    frames = parse_manifest(manifest_file)

    # Read metadata
    title = "会议笔记"
    meeting_date = datetime.now().strftime("%Y-%m-%d")
    meta = None
    if len(sys.argv) > 4 and os.path.exists(sys.argv[4]):
        with open(sys.argv[4], "r", encoding="utf-8") as f:
            meta = json.load(f)
        title = meta.get("title", title)
        meeting_date = meta.get("date", meeting_date)

    summary = None
    if len(sys.argv) > 5 and os.path.exists(sys.argv[5]):
        with open(sys.argv[5], "r", encoding="utf-8") as f:
            summary = f.read().strip() or None

    segments = None
    if len(sys.argv) > 6 and os.path.exists(sys.argv[6]):
        with open(sys.argv[6], "r", encoding="utf-8") as f:
            segments = json.load(f)

    captions = None
    if len(sys.argv) > 7 and os.path.exists(sys.argv[7]):
        with open(sys.argv[7], "r", encoding="utf-8") as f:
            captions = json.load(f)

    tags = None
    if len(sys.argv) > 8 and os.path.exists(sys.argv[8]):
        with open(sys.argv[8], "r", encoding="utf-8") as f:
            tags = [line.strip() for line in f if line.strip()] or None

    topic = None
    if len(sys.argv) > 9 and os.path.exists(sys.argv[9]):
        with open(sys.argv[9], "r", encoding="utf-8") as f:
            topic = f.read().strip() or None

    audio_link = None
    if len(sys.argv) > 10 and sys.argv[10]:
        audio_link = sys.argv[10]

    # 时长：取最后一个分段的结束时间
    duration = None
    if segments:
        last_end = max(s.get("end", 0) for s in segments)
        if last_end > 0:
            duration = format_ts(last_end)

    generate_note(transcript, frames, title, meeting_date, output_file,
                  meta=meta, summary=summary, captions=captions, tags=tags,
                  duration=duration, topic=topic, audio_link=audio_link)


if __name__ == "__main__":
    main()
