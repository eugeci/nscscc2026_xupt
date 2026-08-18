#!/usr/bin/env python3
"""Fit a local two-axis arm-step to image-pixel Jacobian from motion samples."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np

from calibration_io import encode, invalidate, load_config, save_config


VALID_AXES = {"x", "y", "z"}


def read_samples(path: Path, axes: tuple[str, str]) -> tuple[np.ndarray, np.ndarray]:
    motions, pixels = [], []
    with path.open("r", encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream):
            motions.append((float(row[f"d{axes[0]}_steps"]), float(row[f"d{axes[1]}_steps"])))
            pixels.append((float(row["u1"]) - float(row["u0"]),
                           float(row["v1"]) - float(row["v0"])))
    if len(motions) < 4:
        raise ValueError("arm CSV needs at least four motion samples")
    return np.asarray(motions, np.float64), np.asarray(pixels, np.float64)


def fit_jacobian(motions: np.ndarray, pixels: np.ndarray):
    coefficients, _, rank, singular = np.linalg.lstsq(motions, pixels, rcond=None)
    if rank < 2:
        raise ValueError("motion samples do not independently excite both axes")
    predicted = motions @ coefficients
    errors = np.linalg.norm(predicted - pixels, axis=1)
    jacobian = coefficients.T
    condition = float(singular[0] / singular[-1])
    return jacobian, errors, condition


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", required=True, type=Path,
                        help="CSV: d<axis>_steps,d<axis>_steps,u0,v0,u1,v1")
    parser.add_argument("--axes", default="x,y", help="two controlled axes, e.g. x,z")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--work-zero", required=True, help="X,Y,Z steps from machine zero")
    parser.add_argument("--max-steps", required=True, help="measured safe X,Y,Z travel")
    parser.add_argument("--target-pixel", required=True,
                        help="measured gripper reference u,v at the work pose")
    args = parser.parse_args()
    axes = tuple(item.strip().lower() for item in args.axes.split(","))
    if len(axes) != 2 or axes[0] == axes[1] or not set(axes) <= VALID_AXES:
        raise SystemExit("--axes must contain two distinct axes from x,y,z")
    work_zero = [int(item.strip()) for item in args.work_zero.split(",")]
    if len(work_zero) != 3 or any(value < 0 for value in work_zero):
        raise SystemExit("--work-zero must be three non-negative step counts")
    max_steps = [int(item.strip()) for item in args.max_steps.split(",")]
    if len(max_steps) != 3 or any(value <= 0 for value in max_steps):
        raise SystemExit("--max-steps must be three measured positive step counts")
    target_pixel = [float(item.strip()) for item in args.target_pixel.split(",")]
    if (len(target_pixel) != 2 or not 0 <= target_pixel[0] < 640 or
            not 0 <= target_pixel[1] < 480):
        raise SystemExit("--target-pixel must be u,v inside the 640x480 image")
    motions, pixels = read_samples(args.samples, axes)
    jacobian, errors, condition = fit_jacobian(motions, pixels)
    cfg = load_config(args.config)
    cfg["arm"] = {
        "alignment_axes": ",".join(axes),
        "jacobian": encode(jacobian.reshape(-1)),
        "gripper_target_pixel": encode(target_pixel),
        "jacobian_condition": f"{condition:.9g}",
        "rms_px": f"{np.sqrt(np.mean(errors ** 2)):.9g}",
        "max_error_px": f"{np.max(errors):.9g}",
        "samples": str(len(motions)),
        "sample_source": args.samples.name,
        "work_zero_x": str(work_zero[0]),
        "work_zero_y": str(work_zero[1]),
        "work_zero_z": str(work_zero[2]),
        "invert_x": "0",
        "invert_y": "0",
        "invert_z": "0",
        "max_x_steps": str(max_steps[0]),
        "max_y_steps": str(max_steps[1]),
        "max_z_steps": str(max_steps[2]),
    }
    invalidate(cfg, "set measured software travel limits and run validation")
    save_config(cfg, args.config)
    print(f"arm axes={axes[0]},{axes[1]} rms={np.sqrt(np.mean(errors ** 2)):.4f}px "
          f"max={np.max(errors):.4f}px condition={condition:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
