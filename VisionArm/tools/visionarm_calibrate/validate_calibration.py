#!/usr/bin/env python3
"""Validate a completed calibration and optionally mark it control-ready."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from calibration_io import decode, load_config, save_config


def validate(cfg, max_camera_rms: float, max_workspace_mm: float,
             max_arm_px: float, max_condition: float) -> list[str]:
    errors: list[str] = []
    try:
        if cfg.getint("meta", "version") != 1: errors.append("unsupported version")
        if cfg.getint("meta", "image_width") != 640 or cfg.getint("meta", "image_height") != 480:
            errors.append("runtime requires 640x480 calibration")
        matrix = np.asarray(decode(cfg["camera"]["matrix"], 9)).reshape(3, 3)
        if abs(np.linalg.det(matrix)) < 1e-9: errors.append("camera matrix is singular")
        decode(cfg["camera"]["distortion"], 5)
        if cfg.getfloat("camera", "rms_px") > max_camera_rms: errors.append("camera RMS too high")
        homography = np.asarray(decode(cfg["workspace"]["homography"], 9)).reshape(3, 3)
        if abs(np.linalg.det(homography)) < 1e-12: errors.append("homography is singular")
        if cfg.getfloat("workspace", "max_error_mm") > max_workspace_mm:
            errors.append("workspace error too high")
        jacobian = np.asarray(decode(cfg["arm"]["jacobian"], 4)).reshape(2, 2)
        if abs(np.linalg.det(jacobian)) < 1e-12: errors.append("arm Jacobian is singular")
        axes = [item.strip() for item in cfg.get("arm", "alignment_axes").split(",")]
        if len(axes) != 2 or axes[0] == axes[1] or not set(axes) <= {"x", "y", "z"}:
            errors.append("alignment_axes must be two distinct axes from x,y,z")
        target = decode(cfg["arm"]["gripper_target_pixel"], 2)
        if not 0 <= target[0] < 640 or not 0 <= target[1] < 480:
            errors.append("gripper_target_pixel is outside 640x480")
        if cfg.getfloat("arm", "max_error_px") > max_arm_px: errors.append("arm fit error too high")
        if cfg.getfloat("arm", "jacobian_condition") > max_condition:
            errors.append("arm fit condition number too high")
        for axis in "xyz":
            if cfg.getint("arm", f"work_zero_{axis}") < 0:
                errors.append(f"work_zero_{axis} must be non-negative")
            if cfg.getint("arm", f"invert_{axis}") not in (0, 1):
                errors.append(f"invert_{axis} must be 0 or 1")
            if cfg.getint("arm", f"max_{axis}_steps") <= 0:
                errors.append(f"max_{axis}_steps is not measured")
        if cfg.getint("grasp", "align_deadband_px") <= 0:
            errors.append("align_deadband_px must be positive")
        if cfg.getint("grasp", "stable_frames") < 2: errors.append("stable_frames must be >= 2")
        if cfg.getint("grasp", "max_align_moves") <= 0: errors.append("max_align_moves must be positive")
    except Exception as exc:
        # ConfigParser lookup errors have several concrete types across Python versions.
        errors.append(f"missing or invalid field: {exc}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--max-camera-rms", type=float, default=1.0)
    parser.add_argument("--max-workspace-mm", type=float, default=3.0)
    parser.add_argument("--max-arm-px", type=float, default=5.0)
    parser.add_argument("--max-condition", type=float, default=20.0)
    parser.add_argument("--mark-valid", action="store_true")
    args = parser.parse_args()
    cfg = load_config(args.config)
    errors = validate(cfg, args.max_camera_rms, args.max_workspace_mm,
                      args.max_arm_px, args.max_condition)
    if errors:
        cfg["meta"]["validated"] = "0"
        cfg["meta"]["invalid_reason"] = "; ".join(errors)
        save_config(cfg, args.config)
        for error in errors: print(f"FAIL: {error}")
        return 1
    print("CALIBRATION_VALIDATION_PASS")
    if args.mark_valid:
        cfg["meta"]["validated"] = "1"
        cfg["meta"].pop("invalid_reason", None)
        save_config(cfg, args.config)
        print(f"marked control-ready: {args.config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
