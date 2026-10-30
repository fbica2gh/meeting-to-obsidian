#!/usr/bin/env python3
"""
polish_note.py — 会议转录后处理（多模态版）

能力:
  1) 逐帧视觉纠错：把每张关键帧（幻灯片）+ 该时段转录一起交给多模态模型，
     结合画面上的文字纠正同音字/术语错误，同时生成该图的配图说明
     （一次调用同时完成"用图片纠正语音"和"配图说明"）
  2) 分章节要点总结（map-reduce）
  3) 主题标签、会议主题一句话
  4) 并行执行（分片级线程池）；无时间戳/无图时回退纯文本两遍纠错

后端: OpenAI 兼容接口；自动选择 MLX server(8081) > ollama(/v1)

Usage:
    polish_note.py <raw_transcript> <polished_out> <summary_out>
                   [--segments audio.json] [--manifest manifest.txt]
                   [--frames-dir DIR] [--captions-out C] [--tags-out T] [--topic-out P]
"""
import argparse
import base64
import io
import json
import os
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# 后端选择：LLM_BASE_URL/LLM_MODEL 环境变量优先；未设置时自动探测
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "").rstrip("/")
LLM_MODEL = os.environ.get("LLM_MODEL", "")
DEFAULT_MODEL = "qwen2.5:7b"
MLX_SERVER_URL = "http://127.0.0.1:8081/v1"
MLX_MODEL_PATH = os.path.expanduser("~/.zcode/models/Qwen3.6-35B-A3B-4bit")
# 词表：用户配置目录优先（个人/业务术语不随 skill 分发），回退 skill 内示例
GLOSSARY_FILE = os.environ.get(
    "GLOSSARY_FILE",
    os.path.expanduser("~/.zcode/config/meeting-to-obsidian/glossary.txt"),
)
GLOSSARY_EXAMPLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "glossary.example.txt"
)
MAX_BYTES = 8 * 1024 * 1024
IMG_MAX_WIDTH = 1280     # 送入模型的图片最大宽度（省 prefill）
CHUNK_SIZE = 1000

_b = {"base": None, "model": None}


def select_backend(requested=None):
    """决定后端：环境变量 > MLX server(8081) > ollama。写入 _b。"""
    if LLM_BASE_URL and LLM_MODEL:
        _b["base"], _b["model"] = LLM_BASE_URL, LLM_MODEL
        return
    try:
        with urllib.request.urlopen(f"{MLX_SERVER_URL}/models", timeout=5) as r:
            json.load(r)
        _b["base"], _b["model"] = MLX_SERVER_URL, MLX_MODEL_PATH
        print("  后端: MLX server (Qwen3.6-35B-A3B-4bit)", flush=True)
        return
    except Exception:
        pass
    _b["base"], _b["model"] = "http://127.0.0.1:11434/v1", requested or DEFAULT_MODEL
    print(f"  后端: ollama ({_b['model']})", flush=True)


def load_glossary(path=None):
    """读取 错误写法=正确写法 词典，长词优先。"""
    path = path or GLOSSARY_FILE
    if not os.path.exists(path):
        path = GLOSSARY_EXAMPLE
    rules = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                wrong, right = line.split("=", 1)
                if wrong and right:
                    rules.append((wrong, right))
    except FileNotFoundError:
        pass
    rules.sort(key=lambda r: -len(r[0]))
    return rules


def apply_glossary(text, rules):
    for wrong, right in rules:
        text = text.replace(wrong, right)
    return text


def strip_fences(text):
    if not text:
        return text
    t = text.strip()
    if t.startswith("```"):
        lines = t.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        t = "\n".join(lines).strip()
    return t


def ollama_generate(prompt, model=None, retries=2, image_path=None):
    """调用 OpenAI 兼容接口；image_path 提供时发送多模态 content（图片自动降采样）"""
    use_model = model or _b["model"] or DEFAULT_MODEL
    if image_path:
        try:
            from PIL import Image
            img = Image.open(image_path).convert("RGB")
            if img.width > IMG_MAX_WIDTH:
                h = int(img.height * IMG_MAX_WIDTH / img.width)
                img = img.resize((IMG_MAX_WIDTH, h), Image.Resampling.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=85)
            img_url = "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()
            content = [{"type": "image_url", "image_url": {"url": img_url}},
                       {"type": "text", "text": prompt}]
        except Exception as e:
            print(f"  WARN: 图片处理失败（{e}），转纯文本", flush=True)
            content = prompt
    else:
        content = prompt
    payload = json.dumps({
        "model": use_model,
        "messages": [{"role": "user", "content": content}],
        "temperature": 0.1,
        "max_tokens": 4096,
    }).encode("utf-8")
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                f"{_b['base']}/chat/completions",
                data=payload,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=900) as resp:
                d = json.load(resp)
            return strip_fences((d["choices"][0]["message"]["content"] or "").strip())
        except Exception as e:
            last_err = e
            time.sleep(2)
    raise last_err


def chunk_text(text, size=CHUNK_SIZE):
    for i in range(0, len(text), size):
        yield text[i:i + size]


def parse_ts(ts):
    parts = [int(p) for p in ts.split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0


def load_manifest(path):
    frames = []
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "|" in line:
                    ts, filename = line.split("|", 1)
                    frames.append({"ts": parse_ts(ts), "ts_str": ts, "file": filename})
    return frames


# ── 多模态主路径：逐帧 视觉纠错 + 配图说明 ──────────────────────────

VISION_PROMPT = (
    "你是会议记录整理助手。给你一张演示文稿截图，以及放映该页时演讲的语音转录片段。\n"
    "转录是语音识别结果，存在同音字/错别字（例如读音相同或相近但写错的词）。\n"
    "请：1) 逐句输出纠正后的转录全文（保真为第一优先）：只纠正同音字/错别字、添加标点、"
    "删除纯语气词（呃/啊/嗯/哈），严禁概括、缩写或跳过任何句子，长度应与原文相当；"
    "可参照截图上的文字修正术语写法。\n"
    "2) 另写一句该截图的配图说明：直接陈述句总结该页核心内容与结论，"
    "句首禁止「该页/本页/此页/幻灯片/演讲/讲解」等指代前缀与转述语气。\n"
    "只输出 JSON：<JSON_OBJECT> 格式为 {\"fixed\": \"纠正后的本段转录全文\", \"caption\": \"配图说明\"}\n"
    "已知术语替换（必须执行）：@HINT@\n\n本段转录：\n@CHUNK@"
)


def vision_frame_pass(frames, segments, frames_dir, rules, out_captions):
    """逐帧：视觉纠错 + 配图说明。返回 (polished_full_text, captions dict)"""
    hint = "；".join(f"{w}→{r}" for w, r in rules[:25]) or "（无）"
    captions = {}

    tasks = []
    for i, fr in enumerate(frames):
        t0 = fr["ts"] - 1.0
        t1 = frames[i + 1]["ts"] if i + 1 < len(frames) else float("inf")
        slice_text = apply_glossary(
            " ".join(s["text"] for s in segments if t0 <= s["start"] < t1).strip(), rules)
        img = os.path.join(frames_dir, fr["file"]) if frames_dir else None
        if img and not os.path.exists(img):
            img = None
        tasks.append((i, fr, slice_text, img))

    def run_frame(task):
        i, fr, slice_text, img = task
        if not slice_text:
            captions[fr["file"]] = {"ts_str": fr["ts_str"], "caption": "", "raw": ""}
            return fr["file"], None
        prompt = (VISION_PROMPT
                  .replace("@HINT@", hint)
                  .replace("@CHUNK@", slice_text[:2500])
                  .replace("<JSON_OBJECT>", ""))
        out = None
        try:
            out = ollama_generate(prompt, image_path=img)
        except Exception as e:
            print(f"  WARN: 帧 {fr['file']} 视觉处理失败（{e}）", flush=True)
        fixed, caption = slice_text, ""
        if out:
            try:
                m = re.search(r"\{[\s\S]*\}", out)
                if m:
                    j = json.loads(m.group(0))
                    fixed = (j.get("fixed") or "").strip()
                    caption = (j.get("caption") or "").strip()
            except Exception:
                pass
        # 保真校验：模型输出明显短于原文（被概括/截断）时回退为原文切片，只保留 caption
        if fixed and len(fixed) < len(slice_text) * 0.8:
            fixed = slice_text
        captions[fr["file"]] = {"ts_str": fr["ts_str"], "caption": caption,
                                 "raw": slice_text, "fixed": fixed}
        print(f"  帧 {i + 1}/{len(frames)} 完成: {fr['file']}", flush=True)
        return fr["file"], fixed

    workers = min(4, max(1, len(tasks)))
    fixed_map = {}
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(run_frame, t) for t in tasks]
        for f in as_completed(futs):
            try:
                fname, fixed = f.result()
                if fixed is not None:
                    fixed_map[fname] = fixed
            except Exception as e:
                print(f"  WARN: {e}", flush=True)

    fixed_parts = [fixed_map[fr["file"]] for _, fr, _, _ in tasks if fr["file"] in fixed_map]

    # 关键：按放映顺序重建 captions（并行完成序≠时间序），下游分段/对齐依赖时间序
    captions = {fr["file"]: captions[fr["file"]]
                for _, fr, _, _ in tasks if fr["file"] in captions}

    if out_captions:
        os.makedirs(os.path.dirname(out_captions) or ".", exist_ok=True)
        with open(out_captions, "w", encoding="utf-8") as f:
            json.dump(captions, f, ensure_ascii=False, indent=1)
    return "\n".join(fixed_parts), captions


# ── 纯文本回退路径（无时间戳或无图） ──────────────────────────────

def text_polish(raw, model, rules):
    raw = apply_glossary(raw, rules)
    hint = "；".join(f"{w}→{r}" for w, r in rules[:20]) or "（无）"
    chunks = list(chunk_text(raw))

    def fix_chunk(args):
        idx, chunk = args
        prompt = (
            "以下是会议语音转录的一个片段，存在同音字错误。已知的术语替换（必须执行）：" + hint + "\n"
            "请根据上下文语义纠正同音字/错别字、添加标点，删除无意义的语气词（呃、啊、嗯、哦等），"
            "但保持原有内容和句子结构，不要添加原文没有的信息，不要跳过任何句子。"
            "直接输出纠正后的文本，不要解释：\n\n" + chunk
        )
        try:
            out = ollama_generate(prompt, model)
        except Exception as e:
            print(f"  WARN: 段 {idx} 纠错失败（{e}），保留原文", flush=True)
            out = chunk
        if not out:
            out = chunk
        try:
            review_prompt = (
                "仔细检查下面这段会议转录文字，找出仍存在的同音字/错别字，"
                "只输出修正后的完整文本；若已无明显错误则原样输出。不要解释：\n\n" + out
            )
            out2 = ollama_generate(review_prompt, model)
            if out2 and len(out2) >= len(out) * 0.5:
                out = out2
        except Exception:
            pass
        print(f"  纠错段 {idx}/{len(chunks)} 完成", flush=True)
        return idx, out

    with ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(fix_chunk, enumerate(chunks, 1)))
    return "\n".join(out for _, out in sorted(results))


# ── 总结 / 标签 / 主题 ────────────────────────────────────────────

def summarize(text, model):
    chunks = list(chunk_text(text, 4000))
    partials = []
    for i, c in enumerate(chunks, 1):
        prompt = (
            "以下是会议转录的第 " + str(i) + "/" + str(len(chunks)) + " 部分。"
            "请总结这部分讲了什么：按讨论主题分点，每个主题 2-3 句话，"
            "必须保留具体术语、方法名、数字和结论。输出 markdown 无序列表：\n\n" + c
        )
        try:
            partials.append(ollama_generate(prompt, model))
        except Exception as e:
            print(f"  WARN: 分段总结 {i} 失败（{e}）", flush=True)
    if not partials:
        return ""
    if len(partials) == 1:
        merged = partials[0]
    else:
        prompt = (
            "以下是对同一场会议各部分的分段总结。请合并为一份结构化的会议总结：\n"
            "- 去除重复内容，按主题组织\n"
            "- 每个主题用 **粗体小标题** 开头，后接 2-3 句展开（保留术语、数字、结论）\n"
            "- 最后加一行「## 待办/开放问题」（如有）\n"
            "直接输出 markdown，不要解释：\n\n" + "\n\n".join(partials)
        )
        try:
            merged = ollama_generate(prompt, model)
        except Exception as e:
            print(f"  WARN: 总结合并失败（{e}）", flush=True)
            merged = "\n".join(partials)
    return merged


def generate_tags(text, model):
    prompt = (
        "根据下面的会议转录文本，提取 3-6 个主题标签（中文或英文术语，不含#号，"
        "每行一个，按相关性排序）。直接输出标签，不要解释：\n\n" + text[:4000]
    )
    out = ollama_generate(prompt, model)
    tags = []
    for line in out.splitlines():
        t = line.strip().strip('-*·.。、# ')
        t = re.sub(r'^\d+[.、]\s*', '', t)
        if t and len(t) <= 20 and t not in tags:
            tags.append(t)
    return tags[:6]


def generate_topic(text, model):
    prompt = (
        "根据下面的会议转录文本，用一句话（不超过 25 字）概括这场会议的主题，"
        "格式如「XX大学机器人技术进展报告」「XX产品需求评审」。"
        "直接输出这一句话，不要解释、不要句号：\n\n" + text[:4000]
    )
    out = ollama_generate(prompt, model)
    topic = out.strip().splitlines()[0].strip().strip('"。. ') if out else ""
    return topic[:40]


def ollama_available(model, retries=3):
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(f"{_b['base']}/models", timeout=15) as resp:
                d = json.load(resp)
            ids = [m.get("id", "") for m in (d.get("data") or [])]
            if not ids:
                return False
            base = model.split("/")[-1].split(":")[0]
            return any(i == model or (base and base in i) for i in ids)
        except Exception:
            if attempt < retries - 1:
                time.sleep(2)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("polished_out")
    ap.add_argument("summary_out")
    ap.add_argument("--model", default=LLM_MODEL or None)
    ap.add_argument("--segments", default=None)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--frames-dir", default=None, help="关键帧目录（视觉纠错用）")
    ap.add_argument("--captions-out", default=None)
    ap.add_argument("--tags-out", default=None)
    ap.add_argument("--topic-out", default=None)
    args = ap.parse_args()

    with open(args.raw, "r", encoding="utf-8") as f:
        raw = f.read().strip()
    if len(raw.encode("utf-8")) > MAX_BYTES:
        os.makedirs(os.path.dirname(args.polished_out), exist_ok=True)
        with open(args.polished_out, "w", encoding="utf-8") as f:
            f.write(raw)
        open(args.summary_out, "w").close()
        print("SKIP: 转录超长，未润色")
        return
    if not raw:
        os.makedirs(os.path.dirname(args.polished_out), exist_ok=True)
        open(args.polished_out, "w").close()
        open(args.summary_out, "w").close()
        return

    select_backend(args.model)
    if not ollama_available(_b["model"]):
        print(f"SKIP: LLM 后端或模型 {_b['model']} 不可用（{_b['base']}），保留原始转录")
        os.makedirs(os.path.dirname(args.polished_out), exist_ok=True)
        with open(args.polished_out, "w", encoding="utf-8") as f:
            f.write(raw)
        os.makedirs(os.path.dirname(args.summary_out), exist_ok=True)
        open(args.summary_out, "w").close()
        return

    rules = load_glossary()

    segments = []
    if args.segments and os.path.exists(args.segments):
        try:
            segments = json.load(open(args.segments, encoding="utf-8"))
        except Exception:
            segments = []

    frames = load_manifest(args.manifest)
    has_vision = bool(frames and segments and args.frames_dir
                      and os.path.isdir(args.frames_dir))

    t0 = time.time()
    if has_vision:
        print("  多模态模式：逐帧视觉纠错 + 配图说明", flush=True)
        polished, _ = vision_frame_pass(frames, segments, args.frames_dir, rules,
                                        args.captions_out or os.path.join(
                                            os.path.dirname(args.polished_out), "captions.json"))
        polished = apply_glossary(polished, rules)  # 视觉改写可能回退术语，终检兜底
        if not polished:
            polished = raw
    else:
        polished = text_polish(raw, _b["model"], rules)
        if args.captions_out:
            try:
                os.makedirs(os.path.dirname(args.captions_out) or ".", exist_ok=True)
                json.dump({}, open(args.captions_out, "w", encoding="utf-8"))
            except Exception:
                pass
    print(f"  润色完成: {len(polished)} 字符（{time.time() - t0:.0f}s）", flush=True)

    os.makedirs(os.path.dirname(args.polished_out), exist_ok=True)
    with open(args.polished_out, "w", encoding="utf-8") as f:
        f.write(polished)

    try:
        summary = summarize(polished, _b["model"])
    except Exception as e:
        print(f"  WARN: 总结失败（{e}）", flush=True)
        summary = ""
    os.makedirs(os.path.dirname(args.summary_out), exist_ok=True)
    with open(args.summary_out, "w", encoding="utf-8") as f:
        f.write(summary)
    if summary:
        print("  总结完成", flush=True)

    if args.tags_out:
        try:
            tags = generate_tags(polished, _b["model"])
            os.makedirs(os.path.dirname(args.tags_out) or ".", exist_ok=True)
            with open(args.tags_out, "w", encoding="utf-8") as f:
                f.write("\n".join(tags))
            print(f"  标签完成: {', '.join(tags)}", flush=True)
        except Exception as e:
            print(f"  WARN: 标签生成失败（{e}）", flush=True)

    if args.topic_out:
        try:
            topic = generate_topic(polished, _b["model"])
            os.makedirs(os.path.dirname(args.topic_out) or ".", exist_ok=True)
            with open(args.topic_out, "w", encoding="utf-8") as f:
                f.write(topic)
            print(f"  主题: {topic}", flush=True)
        except Exception as e:
            print(f"  WARN: 主题生成失败（{e}）", flush=True)
    return


if __name__ == "__main__":
    main()
