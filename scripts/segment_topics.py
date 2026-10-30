#!/usr/bin/env python3
"""segment_topics.py — 按内容把连续多主题汇报自动切分为多个主题段

输入 captions.json（逐帧：ts_str/caption/fixed/raw），输出 sections.json
（段列表：title / start_frame / ts_start / ts_end / frame 数切片清单）。

切分依据：结合页序列的配图说明、换页节奏与综述语义，由多模态/文本 LLM 判定主题边界；
单主题会议返回 1 段（即维持单笔记模式）。
"""
import json
import os
import sys


def load_captions(path):
    return json.load(open(path, encoding="utf-8"))


def build_outline(caps):
    """把逐帧信息压成 LLM 可读的大纲（每行: 序号|时间|配图说明摘要）"""
    lines = []
    for i, (fname, info) in enumerate(caps.items(), 1):
        cap = (info.get("caption") or "").strip()
        txt = (info.get("fixed") or info.get("raw") or "").strip()
        gist = (cap or txt)[:60]
        if gist:
            lines.append(f"{i}|{info.get('ts_str','')}|{gist}")
    return "\n".join(lines)


def parse_sections(out, caps_len, ts_by_index):
    """从 LLM 输出解析分界（返回段起点的帧序号列表）"""
    import re
    out = out.strip()
    m = re.search(r"\{[\s\S]*\}|\[[\s\S]*\]", out)
    if not m:
        return None
    txt = m.group(0)
    try:
        d = json.loads(txt)
    except Exception:
        try:
            d = json.loads(txt.replace("'", '"'))
        except Exception:
            return None
    starts = []
    if isinstance(d, dict) and "sections" in d:
        for sec in d["sections"]:
            idx = sec.get("start_index") or sec.get("index") or sec.get("start")
            if idx is None:
                continue
            try:
                starts.append(int(idx))
            except Exception:
                pass
    elif isinstance(d, list):
        for it in d:
            idx = (it.get("start_index") if isinstance(it, dict) else it)
            try:
                starts.append(int(idx))
            except Exception:
                pass
    if not starts:
        return None
    # 规范化：>1 起点、递增、范围合法
    starts = sorted({s for s in starts if 1 <= s <= caps_len}) if len(starts) > 1 else []
    return [1] + starts or [1]


def segment(caps, model=None):
    from polish_note import select_backend, ollama_generate  # 复用后端选择与调用
    outline = build_outline(caps)
    prompt = (
        "以下是会议中逐页幻灯片的时间与内容摘要（按放映顺序）。会议里可能连续分别汇报了几个独立主题。\n"
        "请按内容把页序列切分为若干主题段（不要拆得太碎；一页内容的多个自然段不是分段理由；"
        "明显换人/换产品/完全不同领域才是切分点）。每段给出标题、起始页序号（1 开始，含该段首页）。\n"
        "只输出 JSON：{\"sections\":[{\"title\":\"主题名(≤20字)\",\"start_index\":页序号}]}，"
        "若整场只有一个主题则输出一个起始为 1 的段。\n\n页序号|时间|内容摘要：\n" + outline[:8000]
    )
    select_backend(model)
    out = ollama_generate(prompt)
    return out


def main():
    caps_path, out_path = sys.argv[1], sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else None
    caps = load_captions(caps_path)
    keys = list(caps.keys())
    raw = segment(caps, model)
    starts = None
    try:
        starts = parse_sections(raw, len(keys), None)
    except Exception as e:
        print(f"WARN: 分段解析失败（{e}）", file=sys.stderr)
    sections = []
    if not starts:
        starts = [1]
        fallback = True
    else:
        fallback = False
    starts = sorted(set(starts)) or [1]
    for si, start in enumerate(starts):
        end = starts[si + 1] - 1 if si + 1 < len(starts) else len(keys)
        frames_idx = range(start - 1, end)
        if not frames_idx:
            continue
        ts_start = caps[keys[start - 1]].get("ts_str", "0:00")
        ts_end = caps[keys[end - 1]].get("ts_str", ts_start)
        # 标题：优先 LLM 给出的该段标题
        title = ""
        try:
            d = json.loads(re.search(r"\{[\s\S]*\}|\[[\s\S]*\]", raw).group(0))
            if isinstance(d, dict):
                sec = d["sections"][si]
                title = (sec.get("title") or "").strip() if isinstance(sec, dict) else ""
        except Exception:
            pass
        sections.append({
            "title": title,
            "start_index": start,
            "end_index": end,
            "ts_start": ts_start,
            "ts_end": ts_end,
            "frames": [keys[i] for i in frames_idx],
        })
    json.dump({"sections": sections, "fallback": fallback},
              open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"分段完成: {len(sections)} 段"
          + ("" if fallback else "（LLM 判定）") + (" （回退单主题）" if fallback else ""),
          file=sys.stderr)
    for i, sec in enumerate(sections, 1):
        print(f"  段{i}: [{sec['ts_start']}] {sec['title'] or '(未命名)'}"
              f"  {len(sec['frames'])} 页", file=sys.stderr)


if __name__ == "__main__":
    main()
