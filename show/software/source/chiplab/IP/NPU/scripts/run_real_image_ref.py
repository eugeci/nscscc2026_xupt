#!/usr/bin/env python3
"""Run the quantized FaceNet reference on a real RGB image.

This is an offline reference runner.  It mirrors the intended full-chain
preprocess:

    RGB888 640x480 -> rgb2y Q14 -> fixed 4:1 bilinear resize -> LBP
    -> face_inference_ref.run_full_inference()
"""

from __future__ import annotations

import argparse
import contextlib
import sys
from pathlib import Path

import numpy as np


SRC_W = 640
SRC_H = 480
DST_W = 160
DST_H = 120

THIS_DIR = Path(__file__).resolve().parent
NPU_IP_ROOT = THIS_DIR.parent
SIM_DIR = NPU_IP_ROOT / "sim"

if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from face_inference_ref import load_quantized_model, run_full_inference  # noqa: E402


def load_rgb_image(path: Path) -> np.ndarray:
    """Load an image file as HWC RGB uint8."""
    try:
        from PIL import Image

        with Image.open(path) as img:
            return np.asarray(img.convert("RGB"), dtype=np.uint8)
    except ImportError:
        pass

    try:
        import cv2
    except ImportError as exc:
        raise SystemExit("Install Pillow or OpenCV to load image files") from exc

    bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if bgr is None:
        raise SystemExit(f"Could not read image: {path}")
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.uint8)


def resize_rgb(rgb: np.ndarray, mode: str) -> np.ndarray:
    if mode == "none":
        return rgb

    try:
        from PIL import Image

        resampling_enum = getattr(Image, "Resampling", Image)
        resampling = resampling_enum.NEAREST if mode == "nearest" else resampling_enum.BILINEAR
        img = Image.fromarray(rgb, mode="RGB")
        return np.asarray(img.resize((SRC_W, SRC_H), resample=resampling), dtype=np.uint8)
    except ImportError:
        pass

    try:
        import cv2
    except ImportError as exc:
        raise SystemExit("Install Pillow or OpenCV to resize image files") from exc

    interpolation = cv2.INTER_NEAREST if mode == "nearest" else cv2.INTER_LINEAR
    return cv2.resize(rgb, (SRC_W, SRC_H), interpolation=interpolation).astype(np.uint8)


def make_synthetic_image(seed: int) -> np.ndarray:
    """Make the same kind of synthetic 480p frame used by full-chain tests."""
    rng = np.random.default_rng(seed)
    img = np.zeros((SRC_H, SRC_W, 3), dtype=np.uint8)
    img[:, :, 0] = np.linspace(0, 255, SRC_W, dtype=np.uint8)[None, :]
    img[:, :, 1] = np.linspace(0, 255, SRC_H, dtype=np.uint8)[:, None]
    img[:, :, 2] = 80

    yy, xx = np.ogrid[:SRC_H, :SRC_W]
    for _ in range(5):
        cx = int(rng.integers(50, SRC_W - 50))
        cy = int(rng.integers(50, SRC_H - 50))
        radius = int(rng.integers(20, 80))
        color = rng.integers(0, 256, 3, dtype=np.uint8)
        mask = (xx - cx) * (xx - cx) + (yy - cy) * (yy - cy) <= radius * radius
        img[mask] = color

    noise = rng.integers(-20, 20, size=(SRC_H, SRC_W, 3), dtype=np.int16)
    return np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)


def rtl_equivalent_rgb2y(rgb: np.ndarray) -> np.ndarray:
    """Q14 BT.601, matching rtl/preproc/rgb2y.v."""
    red = rgb[:, :, 0].astype(np.int32)
    green = rgb[:, :, 1].astype(np.int32)
    blue = rgb[:, :, 2].astype(np.int32)
    y = (blue * 1868 + green * 9617 + red * 4899 + 8192) >> 14
    return np.clip(y, 0, 255).astype(np.uint8)


def compute_lbp_from_gray_ds(gray_ds: np.ndarray, mode: str) -> np.ndarray:
    """Compute 8-bit LBP from a 160x120 downsampled gray image.

    mode="intended":
        bit7=top-left, bit6=top, ..., bit0=left.  This is the order used by
        the Python full-chain golden and the documented training data path.

    mode="legacy-rtl":
        bit0=top-left, bit1=top, ..., bit7=left.  This matches the old
        lbp_extractor.v assignment before the software-preprocess alignment.
    """
    padded = np.pad(gray_ds, ((1, 1), (1, 1)), mode="constant")
    center = gray_ds

    top_l = (padded[0:-2, 0:-2] >= center).astype(np.uint8)
    top_c = (padded[0:-2, 1:-1] >= center).astype(np.uint8)
    top_r = (padded[0:-2, 2:  ] >= center).astype(np.uint8)
    mid_r = (padded[1:-1, 2:  ] >= center).astype(np.uint8)
    bot_r = (padded[2:,   2:  ] >= center).astype(np.uint8)
    bot_c = (padded[2:,   1:-1] >= center).astype(np.uint8)
    bot_l = (padded[2:,   0:-2] >= center).astype(np.uint8)
    mid_l = (padded[1:-1, 0:-2] >= center).astype(np.uint8)

    out = np.zeros_like(gray_ds, dtype=np.uint8)
    if mode == "intended":
        out |= top_l << 7
        out |= top_c << 6
        out |= top_r << 5
        out |= mid_r << 4
        out |= bot_r << 3
        out |= bot_c << 2
        out |= bot_l << 1
        out |= mid_l << 0
    elif mode == "legacy-rtl":
        out |= top_l << 0
        out |= top_c << 1
        out |= top_r << 2
        out |= mid_r << 3
        out |= bot_r << 4
        out |= bot_c << 5
        out |= bot_l << 6
        out |= mid_l << 7
    else:
        raise ValueError(f"unknown LBP mode: {mode}")

    return out


def resize_gray_4x_bilinear_fixed(gray: np.ndarray) -> np.ndarray:
    """Fixed 640x480 -> 160x120 bilinear center-sample approximation used by RTL."""
    gray_ds = (
        gray[1::4, 1::4].astype(np.uint16) +
        gray[1::4, 2::4].astype(np.uint16) +
        gray[2::4, 1::4].astype(np.uint16) +
        gray[2::4, 2::4].astype(np.uint16) +
        2
    ) >> 2
    return gray_ds.astype(np.uint8)


def preprocess_rgb_to_lbp(rgb: np.ndarray, lbp_mode: str, preproc: str = "rtl-bilinear") -> np.ndarray:
    """Return uint8 LBP image with shape (1, 120, 160)."""
    if rgb.shape[:2] != (SRC_H, SRC_W):
        raise ValueError(f"expected RGB shape {SRC_H}x{SRC_W}, got {rgb.shape[:2]}")

    gray = rtl_equivalent_rgb2y(rgb)
    if preproc == "rtl-bilinear":
        gray_ds = resize_gray_4x_bilinear_fixed(gray)
    elif preproc == "point-sample":
        gray_ds = gray[0::4, 0::4].copy()
    else:
        raise ValueError(f"unknown preproc: {preproc}")
    if gray_ds.shape != (DST_H, DST_W):
        raise ValueError(f"downsampled shape mismatch: {gray_ds.shape}")

    lbp = compute_lbp_from_gray_ds(gray_ds, lbp_mode)
    return lbp[None, :, :]


def parse_xywh(text: str) -> list[int]:
    parts = [part.strip() for part in text.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("expected x,y,w,h")
    try:
        return [int(part, 0) for part in parts]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("bbox values must be integers") from exc


def xywh_iou(a: list[int], b: list[int]) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ax2, ay2 = ax + max(0, aw), ay + max(0, ah)
    bx2, by2 = bx + max(0, bw), by + max(0, bh)
    ix1, iy1 = max(ax, bx), max(ay, by)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    inter = max(0, ix2 - ix1) * max(0, iy2 - iy1)
    area_a = max(0, aw) * max(0, ah)
    area_b = max(0, bw) * max(0, bh)
    union = area_a + area_b - inter
    return 0.0 if union <= 0 else inter / union


def cxcywh_to_xywh(cx: int, cy: int, w: int, h: int) -> list[int]:
    return [int(round(cx - w / 2)), int(round(cy - h / 2)), w, h]


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the quantized NPU Python reference on a 640x480 RGB image."
    )
    parser.add_argument("image", nargs="?", type=Path, help="input image path")
    parser.add_argument(
        "--synthetic-seed",
        type=int,
        help="use a generated synthetic 640x480 frame instead of an image file",
    )
    parser.add_argument(
        "--resize",
        choices=("none", "nearest", "bilinear"),
        default="none",
        help="host-side resize to 640x480 when the file is not already camera-sized",
    )
    parser.add_argument(
        "--lbp-mode",
        choices=("intended", "legacy-rtl"),
        default="intended",
        help="LBP bit order to use before quantized inference",
    )
    parser.add_argument(
        "--preproc",
        choices=("rtl-bilinear", "point-sample"),
        default="rtl-bilinear",
        help="RGB-to-160x120 gray preprocessing before LBP",
    )
    parser.add_argument(
        "--gt-npu",
        type=parse_xywh,
        metavar="X,Y,W,H",
        help="optional ground-truth bbox in 160x120 NPU coordinates",
    )
    parser.add_argument(
        "--gt-display",
        type=parse_xywh,
        metavar="X,Y,W,H",
        help="optional ground-truth bbox in 640x480 display coordinates",
    )
    parser.add_argument(
        "--quiet-layers",
        action="store_true",
        help="suppress per-layer logs from face_inference_ref",
    )
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()

    if args.image is None and args.synthetic_seed is None:
        raise SystemExit("provide an image path or --synthetic-seed")
    if args.image is not None and args.synthetic_seed is not None:
        raise SystemExit("provide either an image path or --synthetic-seed, not both")

    if args.synthetic_seed is not None:
        rgb = make_synthetic_image(args.synthetic_seed)
        source = f"synthetic seed {args.synthetic_seed}"
    else:
        rgb = load_rgb_image(args.image)
        source = str(args.image)

    original_shape = rgb.shape[:2]
    if original_shape != (SRC_H, SRC_W):
        if args.resize == "none":
            raise SystemExit(
                f"input is {original_shape[1]}x{original_shape[0]}, but the hardware "
                f"camera path is {SRC_W}x{SRC_H}. Use --resize nearest or --resize "
                f"bilinear for a host-side approximation."
            )
        rgb = resize_rgb(rgb, args.resize)

    lbp = preprocess_rgb_to_lbp(rgb, args.lbp_mode, args.preproc)

    layers = load_quantized_model()
    if args.quiet_layers:
        with open("/dev/null", "w", encoding="ascii") as devnull:
            with contextlib.redirect_stdout(devnull):
                activations = run_full_inference(lbp, layers)
    else:
        activations = run_full_inference(lbp, layers)

    pred = [int(v) & 0xFF for v in activations[-1].flatten()[:5]]
    conf, cx, cy, w, h = pred
    bbox_npu_cxcywh = [cx, cy, w, h]
    bbox_npu_xywh = cxcywh_to_xywh(cx, cy, w, h)
    bbox_display_cxcywh = [cx * 4, cy * 4, w * 4, h * 4]
    bbox_display_xywh = cxcywh_to_xywh(*bbox_display_cxcywh)

    print()
    print(f"source: {source}")
    print(f"input_shape_before_resize: {original_shape[1]}x{original_shape[0]}")
    print(f"resize: {args.resize}")
    print(f"preproc: {args.preproc}")
    print(f"lbp_mode: {args.lbp_mode}")
    print(f"bbox_bytes_conf_cx_cy_w_h: {pred}")
    print(f"confidence_u8: {conf} ({conf / 255.0:.4f})")
    print(f"bbox_npu_cxcywh_160x120: {bbox_npu_cxcywh}")
    print(f"bbox_npu_xywh_160x120: {bbox_npu_xywh}")
    print(f"bbox_display_cxcywh_640x480: {bbox_display_cxcywh}")
    print(f"bbox_display_xywh_640x480: {bbox_display_xywh}")

    if args.gt_npu is not None:
        print(f"iou_gt_npu: {xywh_iou(bbox_npu_xywh, args.gt_npu):.6f}")
    if args.gt_display is not None:
        print(f"iou_gt_display: {xywh_iou(bbox_display_xywh, args.gt_display):.6f}")

    if args.preproc == "point-sample" or args.lbp_mode == "legacy-rtl":
        print("note: this is a legacy/diagnostic preprocessing mode, not the aligned RTL path.")
    else:
        print("note: rtl-bilinear + intended follows the aligned RTL/software preprocessing path.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
