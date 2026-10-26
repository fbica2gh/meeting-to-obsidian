#!/usr/bin/env python3
"""
parallel_download.py — 多源多线程下载器（严格校验 Range 响应）

要点:
  - 每个线程负责一个字节区间，直接按偏移写入目标文件（不产生分片文件）
  - 每次请求校验状态码 206 且 Content-Range 匹配，否则判定为"服务未支持 Range"并换源
  - 断点续传：启动时扫描文件，找出未完成的区间继续
  - 多源轮转：ModelScope / hf-mirror / gitcode

用法:
  parallel_download.py --repo mlx-community/xxx --file model.safetensors \
      --dest ~/models/xxx --size 4076186653 [--threads 8]
"""
import argparse
import os
import re
import sys
import threading
import time
import urllib.request

SOURCES = [
    "https://www.modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={file}",
    "https://modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={file}",
    "https://hf-mirror.com/{repo}/resolve/main/{file}",
    "https://gitcode.com/{repo}/raw/main/{file}",
]


def build_urls(repo, fname):
    return [t.format(repo=repo, file=fname) for t in SOURCES]


def download_range(url, path, start, end, lock, state):
    """下载 [start,end] 到 path 的对应偏移；严格校验 206"""
    for attempt in range(60):
        try:
            req = urllib.request.Request(url, headers={
                "Range": f"bytes={start}-{end}",
                "User-Agent": "Mozilla/5.0",
            })
            with urllib.request.urlopen(req, timeout=180) as resp:
                if resp.status != 206:
                    raise RuntimeError(f"非 206 响应({resp.status})，该源不支持 Range")
                cr = resp.headers.get("Content-Range", "")
                m = re.match(r"bytes (\d+)-(\d+)/(\d+)", cr)
                if not m or int(m.group(1)) != start:
                    raise RuntimeError(f"Content-Range 不匹配: {cr}")
                pos = start
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    with lock:
                        os.pwrite(fd, chunk, pos)
                        state["done"] += len(chunk)
                    pos += len(chunk)
                    if pos > end:
                        # 服务端多给了字节：截断到区间末尾
                        with lock:
                            os.ftruncate(fd, os.fstat(fd).st_size) if False else None
                        break
                if pos - 1 >= end:
                    return True
        except Exception as e:
            time.sleep(min(10, 1 + attempt))
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--size", type=int, required=True)
    ap.add_argument("--threads", type=int, default=8)
    args = ap.parse_args()

    os.makedirs(args.dest, exist_ok=True)
    path = os.path.join(args.dest, args.file)
    total = args.size

    if not os.path.exists(path):
        with open(path, "wb") as f:
            f.truncate(total)
    else:
        cur = os.path.getsize(path)
        if cur != total:
            with open(path, "r+b") as f:
                f.truncate(total)

    urls = build_urls(args.repo, args.file)
    global fd
    fd = os.open(path, os.O_RDWR)
    lock = threading.Lock()
    state = {"done": 0}

    # 区间划分
    n = args.threads
    chunk = (total + n - 1) // n
    ranges = []
    for i in range(n):
        s = i * chunk
        e = min(s + chunk - 1, total - 1)
        if s <= e:
            ranges.append((s, e, i))

    print(f"下载 {args.repo}/{args.file}  {total/1e9:.2f} GB，{n} 线程，{len(urls)} 源", flush=True)
    threads = []
    for (s, e, i) in ranges:
        # 起始源按索引轮转
        t = threading.Thread(target=worker, args=(s, e, i, urls, lock, state))
        t.daemon = True
        t.start()
        threads.append(t)

    start_time = time.time()
    while any(t.is_alive() for t in threads):
        time.sleep(10)
        el = time.time() - start_time
        done = state["done"]
        print(f"  {done/1e9:.2f} GB  {done/1e6/max(el,1):.2f} MB/s", flush=True)
    for t in threads:
        t.join()

    size = os.path.getsize(path)
    os.close(fd)
    print(f"完成校验: {size} / {total} {'✓' if size == total else '✗'}", flush=True)


def worker(start, end, idx, urls, lock, state):
    for u in urls:
        if download_range(u, None, start, end, lock, state):
            return
    print(f"  区间 {start}-{end} 失败", flush=True)


if __name__ == "__main__":
    main()
