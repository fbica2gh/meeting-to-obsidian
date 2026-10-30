#!/usr/bin/env python3
"""segment_topics.py — 按主题把会议页序列切分为多段（确定性算法 + LLM 命名）

切分算法（不依赖 LLM 猜边界）：
  1. 每页的配图说明/转录摘要 → nomic-embed-text 嵌入（ollama 本地）
  2. 相邻滑动窗口余弦相似度 → 主题边界 = 相似度深谷（且谷深显著）
  3. 每段标题由 LLM 命名（小调用）

只有"换人讲完全不同主题"才会出现深谷；同一主题内部小节不会产生显著谷——
这天然满足"按汇报主题切、不按阶段切"。

Usage:
    segment_topics.py <captions.json> <sections_out.json> [model]
"""
import json
import os
import re
import sys
import urllib.request

EMBED_URL = os.environ.get("OLLAMA_EMBED_URL", "http://127.0.0.1:11434/api/embeddings")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text:latest")
MIN_SECTION_FRAMES = 4   # 一段至少页数（防碎片）
VALLEY_DROP = 0.08       # 谷深阈值：相似度下降幅度超过它才算主题边界


def embed(text, retries=3):
    payload = json.dumps({"model": EMBED_MODEL, "prompt": text[:1200]}).encode("utf-8")
    for a in range(retries):
        try:
            req = urllib.request.Request(EMBED_URL, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.load(r)
            v = d.get("embedding")
            if v:
                return v
        except Exception:
            import time; time.sleep(1)
    return None


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5 or 1e-9
    nb = sum(x * x for x in b) ** 0.5 or 1e-9
    return dot / (na * nb)


def main():
    caps_path, out_path = sys.argv[1], sys.argv[2]
    caps = json.load(open(caps_path, encoding="utf-8"))
    keys = sorted(caps.keys(), key=lambda f: caps[f].get("ts_str", "0:00"))

    # 每页表征文本：配图说明优先，其次纠正文本
    texts = []
    for k in keys:
        info = caps[k]
        t = (info.get("caption") or info.get("fixed") or info.get("raw") or "").strip()
        texts.append(t or "（无内容）")

    vecs = []
    for i, t in enumerate(texts, 1):
        v = embed(t)
        vecs.append(v)
        if v is None:
            print(f"WARN: 页 {i} 嵌入失败", file=sys.stderr)
    ok = [i for i, v in enumerate(vecs) if v is not None]
    if len(ok) < 2 * MIN_SECTION_FRAMES:
        print("嵌入不可用/太少，回退单主题", file=sys.stderr)
        json.dump({"sections": [{"title": "", "start_index": 1, "frames": keys}],
                   "fallback": True}, open(out_path, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)
        return

    # 相邻滑窗相似度（窗口=前后各2页的均值向量，降噪）
    import math
    def mean_vec(idxs):
        vs = [vecs[i] for i in idxs if vecs[i]]
        if not vs:
            return None
        n = len(vs)
        return [sum(v[j] for v in vs) / n for j in range(len(vs[0]))]

    sims = []
    for i in range(len(keys) - 1):
        a = mean_vec(range(max(0, i - 1), i + 2))
        b = mean_vec(range(i, min(len(keys), i + 3)))
        if a and b:
            sims.append((i + 1, cosine(a, b)))  # 边界在页 i+1 之前

    # 找深谷：相似度低于局部邻域（前后 MIN_SECTION_FRAMES 页）均值减去 VALLEY_DROP
    bounds = []
    for pos, sim in sims:
        lo = max(0, pos - MIN_SECTION_FRAMES)
        hi = min(len(sims), pos + MIN_SECTION_FRAMES)
        window = [s for j, s in sims[lo:hi] if j != pos]
        if not window:
            continue
        avg = sum(window) / len(window)
        if avg - sim > VALLEY_DROP:
            bounds.append((pos, avg - sim))
    # 抑制相邻的连片谷，取每簇最深谷
    bounds.sort()
    merged = []
    for pos, depth in bounds:
        if merged and pos - merged[-1][0] < MIN_SECTION_FRAMES:
            if depth > merged[-1][1]:
                merged[-1] = (pos, depth)
        else:
            merged.append((pos, depth))
    bounds = [p for p, _ in merged]

    starts = sorted({1} | {p + 1 for p in bounds if p + 1 <= len(keys)})
    if len(starts) < 2:
        starts = [1]

    sections = []
    for si, start in enumerate(starts, 1):
        end = starts[si] - 1 if si < len(starts) else len(keys)
        sections.append({
            "title": "",
            "start_index": start,
            "end_index": end,
            "ts_start": caps[keys[start - 1]].get("ts_str", "0:00"),
            "ts_end": caps[keys[end - 1]].get("ts_str", "0:00"),
            "frames": [keys[i] for i in range(start - 1, end)],
        })

    # 每段由 LLM 命名（确定性边界之上，仅命名）
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from polish_note import select_backend, ollama_generate
        select_backend(None)
        for sec in sections:
            outline = "\n".join(
                f"- {(caps[f].get('caption') or caps[f].get('fixed') or '')[:50]}"
                for f in sec["frames"][:12])
            try:
                t = ollama_generate(
                    "根据会议某主题段的页面要点，给这段起一个主题名（≤20字，直接输出名称，不要解释）：\n"
                    + outline, _b_model_or_none())
                sec["title"] = (t or "").strip().splitlines()[0].strip().strip('"。. ')[:40]
            except Exception as e:
                print(f"WARN: 段命名失败（{e}）", file=sys.stderr)
    except Exception as e:
        print(f"WARN: 命名后端不可用（{e}）", file=sys.stderr)

    json.dump({"sections": sections, "fallback": False, "method": "embedding-valley"},
              open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"分段完成: {len(sections)} 段", file=sys.stderr)
    for i, sec in enumerate(sections, 1):
        print(f"  段{i}: [{sec['ts_start']}] {sec['title'] or '(未命名)'}  {len(sec['frames'])} 页",
              file=sys.stderr)


def _b_model_or_none():
    try:
        from polish_note import _b
        return _b.get("model")
    except Exception:
        return None


if __name__ == "__main__":
    main()
