#!/usr/bin/env python3
"""Inspect and validate an XNPU deployment package."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from xnpu_format import (
    SECTION_LABELS,
    SECTION_METADATA,
    SECTION_NAME,
    load_package,
)

TASKS = {1: "bbox", 2: "classification"}
MODES = {0: "frame", 1: "packed_preload"}
LAYOUTS = {0: "linear", 1: "nhwc", 2: "nchw"}
DTYPES = {0: "u8", 1: "s8", 2: "u16", 3: "s16", 4: "u32", 5: "s32"}


def describe(path: Path) -> dict:
    package = load_package(path)
    header = package.header
    result = {
        "path": str(path),
        "file_sha256": hashlib.sha256(package.data).hexdigest(),
        "package_sha256": package.sha256.hex(),
        "model_id": header["model_id"],
        "name": package.section(SECTION_NAME).decode(),
        "hardware_abi": header["hardware_abi"],
        "task": TASKS.get(header["task"], f"unknown:{header['task']}"),
        "layers": header["layer_count"],
        "input": {
            "mode": MODES.get(header["input_mode"], f"unknown:{header['input_mode']}"),
            "shape": [
                header["input_width"],
                header["input_height"],
                header["input_channels"],
            ],
            "layout": LAYOUTS.get(header["input_layout"], "unknown"),
            "dtype": DTYPES.get(header["input_dtype"], "unknown"),
            "bytes": header["input_bytes"],
        },
        "output": {
            "shape": [
                header["output_width"],
                header["output_height"],
                header["output_channels"],
            ],
            "layout": LAYOUTS.get(header["output_layout"], "unknown"),
            "dtype": DTYPES.get(header["output_dtype"], "unknown"),
            "bytes": header["output_bytes"],
        },
        "parameter_bytes": header["parameter_bytes"],
        "scratch_bytes": header["scratch_bytes"],
        "required_caps": f"0x{header['required_caps']:08x}",
        "sections": [
            {
                "type": section.type,
                "flags": section.flags,
                "offset": section.offset,
                "bytes": len(section.data),
                "crc32": f"0x{section.crc32:08x}",
            }
            for section in package.sections.values()
        ],
    }
    if SECTION_LABELS in package.sections:
        result["labels"] = package.section(SECTION_LABELS).decode().splitlines()
    if SECTION_METADATA in package.sections:
        result["metadata"] = json.loads(package.section(SECTION_METADATA))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit canonical JSON")
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    info = describe(args.package)
    if args.json:
        print(json.dumps(info, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    else:
        print(f"name: {info['name']} (id={info['model_id']})")
        print(f"hardware ABI: {info['hardware_abi']}  task: {info['task']}")
        print(f"layers: {info['layers']}  required caps: {info['required_caps']}")
        print(f"input: {info['input']}")
        print(f"output: {info['output']}")
        print(
            f"parameters: {info['parameter_bytes']}  scratch: {info['scratch_bytes']}"
        )
        print(f"package SHA-256: {info['package_sha256']}")
        print(f"file SHA-256: {info['file_sha256']}")
        for section in info["sections"]:
            print(
                "section "
                f"{section['type']}: offset={section['offset']} "
                f"bytes={section['bytes']} crc32={section['crc32']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
