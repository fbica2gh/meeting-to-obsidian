#!/usr/bin/env python3
"""cleanup_tmp.py — 本管线临时工作目录滚动清理（默认上限 1GB）

识别含 audio.txt / frames / manifest.txt 的 tmp.* 工作目录，
按 mtime 从旧到新删除直到总占用 ≤ 上限。
"""
import os
import glob
import shutil
import sys
import tempfile


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def main():
    limit = int(sys.argv[1]) * 1024 * 1024 if len(sys.argv) > 1 else 1024 * 1024 * 1024
    base = os.path.dirname(tempfile.mkdtemp())
    ours = []
    for d in glob.glob(os.path.join(base, "tmp.*")):
        if not os.path.isdir(d):
            continue
        if (os.path.exists(os.path.join(d, "audio.txt"))
                or os.path.isdir(os.path.join(d, "frames"))
                or os.path.exists(os.path.join(d, "manifest.txt"))):
            ours.append((os.path.getmtime(d), d, dir_size(d)))

    if not ours:
        print("cleanup: 无临时目录")
        return
    total = sum(s for _, _, s in ours)
    print(f"cleanup: 工作目录 {len(ours)} 个，共 {total // 1024 // 1024} MB（上限 {limit // 1024 // 1024} MB）")

    ours.sort()  # 旧 → 新
    for mtime, d, size in ours:
        if total <= limit:
            break
        shutil.rmtree(d, ignore_errors=True)
        total -= size
        print(f"  已清理: {os.path.basename(d)}（{size // 1024 // 1024} MB）")
    print(f"cleanup 完成，剩余 {total // 1024 // 1024} MB")


if __name__ == "__main__":
    main()
