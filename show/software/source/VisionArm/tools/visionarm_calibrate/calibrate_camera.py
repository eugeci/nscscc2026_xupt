#!/usr/bin/env python3
"""Estimate OV5640 intrinsics and distortion from checkerboard images."""
from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path

import cv2
import numpy as np

from calibration_io import encode, invalidate, load_config, save_config


def collect_points(paths: list[str], columns: int, rows: int, square_mm: float):
    object_template = np.zeros((columns * rows, 3), np.float32)
    object_template[:, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_mm
    object_points, image_points, accepted = [], [], []
    image_size = None
    for path in paths:
        image = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        if image is None:
            continue
        if image_size and image_size != (image.shape[1], image.shape[0]):
            raise ValueError("all calibration images must have identical dimensions")
        image_size = (image.shape[1], image.shape[0])
        found, corners = cv2.findChessboardCornersSB(image, (columns, rows))
        if not found:
            continue
        object_points.append(object_template.copy())
        image_points.append(corners.astype(np.float32))
        accepted.append(path)
    if image_size is None or len(accepted) < 6:
        raise ValueError(f"need at least 6 valid checkerboard views, found {len(accepted)}")
    return object_points, image_points, accepted, image_size


def reprojection_errors(object_points, image_points, rvecs, tvecs, matrix, distortion):
    errors = []
    for obj, observed, rvec, tvec in zip(object_points, image_points, rvecs, tvecs):
        projected, _ = cv2.projectPoints(obj, rvec, tvec, matrix, distortion)
        errors.append(float(cv2.norm(observed, projected, cv2.NORM_L2) / len(projected)))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", required=True, help="glob such as captures/*.png")
    parser.add_argument("--columns", required=True, type=int, help="inner corner columns")
    parser.add_argument("--rows", required=True, type=int, help="inner corner rows")
    parser.add_argument("--square-mm", required=True, type=float)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", type=Path,
                        help="JSON report (default: OUTPUT.camera-report.json)")
    args = parser.parse_args()
    paths = sorted(glob.glob(args.images))
    objects, images, accepted, size = collect_points(paths, args.columns, args.rows, args.square_mm)
    rms, matrix, distortion, rvecs, tvecs = cv2.calibrateCamera(objects, images, size, None, None)
    errors = reprojection_errors(objects, images, rvecs, tvecs, matrix, distortion)
    cfg = load_config(args.output, create=True)
    cfg["meta"]["version"] = "1"
    cfg["meta"]["image_width"] = str(size[0])
    cfg["meta"]["image_height"] = str(size[1])
    cfg["camera"] = {
        "matrix": encode(matrix.reshape(-1)),
        "distortion": encode(distortion.reshape(-1)),
        "rms_px": f"{rms:.9g}",
        "mean_view_error_px": f"{np.mean(errors):.9g}",
        "max_view_error_px": f"{np.max(errors):.9g}",
        "views": str(len(accepted)),
        "checkerboard_inner_corners": f"{args.columns},{args.rows}",
        "square_mm": f"{args.square_mm:.9g}",
    }
    invalidate(cfg, "workspace and arm calibration must be completed and validated")
    save_config(cfg, args.output)
    report = args.report or args.output.with_suffix(".camera-report.json")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({
        "image_size": list(size), "checkerboard_inner_corners": [args.columns, args.rows],
        "square_mm": args.square_mm, "rms_px": rms,
        "accepted_images": [
            {"path": path, "reprojection_error_px": error}
            for path, error in zip(accepted, errors)
        ],
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"camera views={len(accepted)} rms={rms:.4f}px max_view={max(errors):.4f}px")
    print(f"wrote {args.output}")
    print(f"wrote {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
