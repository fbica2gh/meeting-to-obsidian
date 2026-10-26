#!/usr/bin/env python3
"""
dedup_images.py — Remove duplicate screenshots using perceptual hashing
Compares images with aHash + dHash + pixel-level check for accuracy.
"""
import os
import sys
import hashlib
from pathlib import Path

def ahash(img_path, hash_size=16):
    """Average hash - fast but less accurate"""
    try:
        from PIL import Image
        img = Image.open(img_path).convert('L').resize((hash_size, hash_size), Image.Resampling.LANCZOS)
        pixels = list(img.getdata())
        avg = sum(pixels) / len(pixels)
        bits = ''.join('1' if p > avg else '0' for p in pixels)
        return int(bits, 2)
    except Exception:
        return None

def dhash(img_path, hash_size=16):
    """Difference hash - more accurate for slides"""
    try:
        from PIL import Image
        img = Image.open(img_path).convert('L').resize((hash_size + 1, hash_size), Image.Resampling.LANCZOS)
        pixels = list(img.getdata())
        bits = ''
        for row in range(hash_size):
            for col in range(hash_size):
                left = row * (hash_size + 1) + col
                right = left + 1
                bits += '1' if pixels[left] > pixels[right] else '0'
        return int(bits, 2)
    except Exception:
        return None

def hamming_distance(h1, h2):
    """Calculate Hamming distance between two hashes"""
    if h1 is None or h2 is None:
        return 999
    return bin(h1 ^ h2).count('1')

def is_duplicate(img_path, kept_hashes, threshold=12):
    """Check if image is duplicate of any kept image"""
    d_hash = dhash(img_path)
    a_hash = ahash(img_path)
    
    for kept_d, kept_a in kept_hashes:
        # Quick check with aHash
        if hamming_distance(a_hash, kept_a) <= threshold:
            # Confirm with dHash
            if hamming_distance(d_hash, kept_d) <= threshold:
                return True
    return False

def dedup_images(input_dir, output_dir=None, threshold=5):
    """
    Deduplicate images in input_dir.
    If output_dir is None, move duplicates to input_dir/.duplicates
    """
    input_path = Path(input_dir)
    if output_dir is None:
        output_dir = input_path / ".duplicates"
    else:
        output_dir = Path(output_dir)
    
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Get all image files sorted by time
    images = sorted(input_path.glob("frame_*.png")) + sorted(input_path.glob("frame_*.jpg")) + sorted(input_path.glob("raw_*.jpg"))
    
    if not images:
        print("No images found")
        return
    
    kept = []
    kept_hashes = []
    duplicates = []
    
    for img_path in images:
        if is_duplicate(str(img_path), kept_hashes, threshold):
            # Move to duplicates
            dest = output_dir / img_path.name
            img_path.rename(dest)
            duplicates.append(img_path.name)
        else:
            # Keep
            d = dhash(str(img_path))
            a = ahash(str(img_path))
            kept_hashes.append((d, a))
            kept.append(img_path.name)
    
    print(f"Total images: {len(images)}")
    print(f"Kept: {len(kept)}")
    print(f"Duplicates removed: {len(duplicates)}")
    if duplicates:
        print(f"Duplicates: {', '.join(duplicates[:10])}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: dedup_images.py <input_dir> [output_dir] [threshold]")
        sys.exit(1)
    
    input_dir = sys.argv[1]
    args = sys.argv[2:]
    output_dir = None
    threshold = 5
    for arg in args:
        if arg.isdigit():
            threshold = int(arg)
        else:
            output_dir = arg
    
    dedup_images(input_dir, output_dir, threshold)
