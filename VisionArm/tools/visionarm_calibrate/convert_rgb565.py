#!/usr/bin/env python3
"""Convert VisionArm little-endian RGB565 frames to PNG."""
from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np


def decode_rgb565(data: bytes, width: int, height: int, stride: int) -> np.ndarray:
    expected = stride * height
    if len(data) != expected:
        raise ValueError(f"expected {expected} bytes, got {len(data)}")
    words = np.frombuffer(data, dtype="<u2").reshape(height, stride // 2)[:, :width]
    red5 = (words >> 11) & 0x1F
    green6 = (words >> 5) & 0x3F
    blue5 = words & 0x1F
    red = ((red5 << 3) | (red5 >> 2)).astype(np.uint8)
    green = ((green6 << 2) | (green6 >> 4)).astype(np.uint8)
    blue = ((blue5 << 3) | (blue5 >> 2)).astype(np.uint8)
    return np.dstack((blue, green, red))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--stride", type=int, default=1280)
    args = parser.parse_args()
    image = decode_rgb565(args.input.read_bytes(), args.width, args.height, args.stride)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(args.output), image):
        raise SystemExit(f"failed to write {args.output}")
    print(f"converted {args.input} -> {args.output} ({args.width}x{args.height})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
