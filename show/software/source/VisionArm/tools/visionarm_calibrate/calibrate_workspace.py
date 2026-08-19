#!/usr/bin/env python3
"""Fit the undistorted image-to-table homography from a point CSV."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import cv2
import numpy as np

from calibration_io import decode, encode, invalidate, load_config, save_config


def read_points(path: Path) -> tuple[np.ndarray, np.ndarray]:
    image, table = [], []
    with path.open("r", encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream):
            image.append((float(row["u"]), float(row["v"])))
            table.append((float(row["x_mm"]), float(row["y_mm"])))
    if len(image) < 4:
        raise ValueError("workspace CSV needs at least four points")
    return np.asarray(image, np.float64), np.asarray(table, np.float64)


def fit_homography(image: np.ndarray, table: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    matrix, mask = cv2.findHomography(image, table, method=0)
    if matrix is None or mask is None:
        raise ValueError("homography solve failed")
    projected = cv2.perspectiveTransform(image.reshape(-1, 1, 2), matrix).reshape(-1, 2)
    errors = np.linalg.norm(projected - table, axis=1)
    return matrix, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--points", required=True, type=Path,
                        help="CSV columns: u,v,x_mm,y_mm")
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    cfg = load_config(args.config)
    image, table = read_points(args.points)
    if "camera" in cfg:
        camera = np.asarray(decode(cfg["camera"]["matrix"], 9)).reshape(3, 3)
        distortion = np.asarray(decode(cfg["camera"]["distortion"]))
        image = cv2.undistortPoints(image.reshape(-1, 1, 2), camera, distortion,
                                    P=camera).reshape(-1, 2)
    matrix, errors = fit_homography(image, table)
    cfg["workspace"] = {
        "homography": encode(matrix.reshape(-1)),
        "points": str(len(image)),
        "rms_mm": f"{np.sqrt(np.mean(errors ** 2)):.9g}",
        "max_error_mm": f"{np.max(errors):.9g}",
        "point_source": args.points.name,
    }
    invalidate(cfg, "arm calibration must be completed and validation must pass")
    save_config(cfg, args.config)
    print(f"workspace points={len(image)} rms={np.sqrt(np.mean(errors ** 2)):.4f}mm "
          f"max={np.max(errors):.4f}mm")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
