#!/usr/bin/env python3
"""Create a deliberately invalid VisionArm calibration template."""
from __future__ import annotations

import argparse
from pathlib import Path

from calibration_io import encode, new_config, save_config


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    cfg = new_config()
    cfg["meta"]["invalid_reason"] = "template values must be replaced by hardware measurements"
    cfg["camera"] = {
        "matrix": encode([0] * 9), "distortion": encode([0] * 5), "rms_px": "999",
    }
    cfg["workspace"] = {
        "homography": encode([0] * 9), "max_error_mm": "999",
    }
    cfg["arm"] = {
        "alignment_axes": "x,y", "jacobian": encode([0] * 4),
        "gripper_target_pixel": "-1,-1",
        "max_error_px": "999", "jacobian_condition": "999",
        "work_zero_x": "0", "work_zero_y": "0", "work_zero_z": "0",
        "invert_x": "0", "invert_y": "0", "invert_z": "0", "max_x_steps": "0",
        "max_y_steps": "0", "max_z_steps": "0",
    }
    save_config(cfg, args.output)
    print(f"wrote invalid template {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
