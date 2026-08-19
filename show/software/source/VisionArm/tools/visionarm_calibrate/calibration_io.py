#!/usr/bin/env python3
"""Shared calibration INI helpers."""
from __future__ import annotations

import configparser
from pathlib import Path
from typing import Iterable


def new_config(width: int = 640, height: int = 480) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg["meta"] = {
        "version": "1",
        "validated": "0",
        "image_width": str(width),
        "image_height": str(height),
    }
    cfg["grasp"] = {
        "align_deadband_px": "30",
        "stable_frames": "3",
        "max_align_moves": "30",
    }
    return cfg


def load_config(path: str | Path, create: bool = False) -> configparser.ConfigParser:
    target = Path(path)
    if create and not target.exists():
        return new_config()
    cfg = configparser.ConfigParser(interpolation=None)
    with target.open("r", encoding="utf-8") as stream:
        cfg.read_file(stream)
    return cfg


def save_config(cfg: configparser.ConfigParser, path: str | Path) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        cfg.write(stream)
    temporary.replace(target)


def encode(values: Iterable[float]) -> str:
    return ",".join(f"{float(value):.12g}" for value in values)


def decode(text: str, count: int | None = None) -> list[float]:
    values = [float(item.strip()) for item in text.split(",") if item.strip()]
    if count is not None and len(values) != count:
        raise ValueError(f"expected {count} values, got {len(values)}")
    return values


def invalidate(cfg: configparser.ConfigParser, reason: str) -> None:
    if "meta" not in cfg:
        cfg["meta"] = {}
    cfg["meta"]["validated"] = "0"
    cfg["meta"]["invalid_reason"] = reason
