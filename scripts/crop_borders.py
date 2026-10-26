#!/usr/bin/env python3
"""crop_borders.py — 自动裁剪截图的黑边和会议 UI 图层

腾讯会议窗口截图包含：
  - 右侧/四周黑边（共享内容按比例显示时的留白）
  - 顶部会议标题栏（会议详情/布局/设置）
  - 顶部/底部黑边条（共享画面 letterbox）
  - 底部"正在共享"悬浮提示（位于黑色条上，随黑边一起裁掉）

算法：按行/列统计暗像素占比。
  - 暗行/暗列（暗像素占比 > 0.85）视为 letterbox；
  - 亮行块（暗像素占比 < 0.5 的连续行块）中最高的一个视为共享内容区；
  - 标题栏是顶部的另一个较小亮块，自动排除；
  - 内容区确定后，再按列裁掉左右黑边。

若亮块过小（内容异常）则回退为"非黑 bbox + 固定比例 UI 裁剪"。

用法:
    crop_borders.py <目录或图片> [--out-dir DIR] [--no-ui-trim]
"""
import os
import sys
import argparse
from pathlib import Path

BLACK_THRESHOLD = 25   # 像素亮度低于此值视为"黑"
DARK_ROW_FRAC = 0.85   # 行/列暗像素占比超过此值视为 letterbox
BRIGHT_ROW_FRAC = 0.5  # 行暗像素占比低于此值视为内容行
MIN_CONTENT_FRAC = 0.3  # 内容区小于原图 30% 视为异常，回退旧行为
LEGACY_UI_TRIM = 0.035  # 回退模式：顶部/底部各裁 3.5%


def _rowcol_profiles(gray):
    """返回 (行暗占比数组, 列暗占比数组)，输入为灰度 numpy 数组"""
    import numpy as np
    dark = (gray < BLACK_THRESHOLD).astype(np.float32)
    return dark.mean(axis=1), dark.mean(axis=0)


def find_content_bbox(img, trim_ui=True):
    """找到共享内容区域的边界框 (left, top, right, bottom)"""
    import numpy as np
    w, h = img.size
    gray = np.asarray(img.convert('L'), dtype=np.uint8)

    row_dark, _ = _rowcol_profiles(gray)

    # 亮行块：连续的暗占比 < BRIGHT_ROW_FRAC 的行
    is_bright = row_dark < BRIGHT_ROW_FRAC
    blocks = []
    start = None
    for y in range(h):
        if is_bright[y] and start is None:
            start = y
        elif not is_bright[y] and start is not None:
            blocks.append((start, y))
            start = None
    if start is not None:
        blocks.append((start, h))

    if blocks:
        top, bottom = max(blocks, key=lambda b: b[1] - b[0])
    else:
        top, bottom = 0, h

    # 内容区过小视为检测失败，回退：非黑 bbox + 固定比例 UI 裁剪
    if (bottom - top) < h * MIN_CONTENT_FRAC or not trim_ui:
        row_has_content = row_dark < 0.98
        top2 = next((y for y in range(h) if row_has_content[y]), 0)
        bottom2 = next((y for y in range(h - 1, -1, -1) if row_has_content[y]), h)
        if trim_ui:
            top2 = max(top2, int(h * LEGACY_UI_TRIM))
            bottom2 = min(bottom2, h - int(h * LEGACY_UI_TRIM))
        # 左右也按非黑 bbox
        col_dark_frac = None  # 惰性计算
        dark = (gray < BLACK_THRESHOLD)
        col_has = ~dark.all(axis=0)
        left = next((x for x in range(w) if col_has[x]), 0)
        right = next((x for x in range(w - 1, -1, -1) if col_has[x]), w - 1) + 1
        return (left, top2, right, bottom2)

    # 在内容行范围内裁左右黑边
    content = gray[top:bottom, :]
    col_dark = (content < BLACK_THRESHOLD).mean(axis=0)
    col_ok = col_dark < DARK_ROW_FRAC
    left = next((x for x in range(w) if col_ok[x]), 0)
    right = next((x for x in range(w - 1, -1, -1) if col_ok[x]), w - 1) + 1

    return (left, top, right, bottom)


def crop_image(img, trim_ui=True):
    """裁剪单张图片，返回裁剪后的图"""
    bbox = find_content_bbox(img, trim_ui)
    w, h = img.size
    cw, ch = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if cw < w * 0.3 or ch < h * 0.3:
        return img, None
    return img.crop(bbox), bbox


def process_path(src, out_dir=None, trim_ui=True):
    from PIL import Image
    src_path = Path(src)
    images = []
    if src_path.is_dir():
        images = (sorted(src_path.glob("frame_*.png"))
                  + sorted(src_path.glob("frame_*.jpg"))
                  + sorted(src_path.glob("raw_*.jpg")))
    elif src_path.is_file():
        images = [src_path]

    if not images:
        print("未找到图片")
        return

    total = 0
    cropped = 0
    for img_path in images:
        img = Image.open(img_path)
        new_img, bbox = crop_image(img, trim_ui)
        if out_dir:
            out_path = Path(out_dir) / img_path.name
            out_path.parent.mkdir(parents=True, exist_ok=True)
        else:
            out_path = img_path
        new_img.save(out_path, quality=95)
        total += 1
        if bbox:
            cropped += 1

    print(f"处理 {total} 张，裁剪 {cropped} 张")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("src", help="图片或目录")
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--no-ui-trim", action="store_true", help="不裁剪 UI 条")
    args = parser.parse_args()
    process_path(args.src, args.out_dir, trim_ui=not args.no_ui_trim)
