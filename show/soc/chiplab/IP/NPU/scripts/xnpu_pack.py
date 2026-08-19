#!/usr/bin/env python3
"""Build deterministic XNPU packages and standalone regression fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from xnpu_format import (
    SECTION_DESCRIPTORS,
    SECTION_JSON,
    SECTION_LABELS,
    SECTION_METADATA,
    SECTION_NAME,
    SECTION_PARAMETERS,
    SECTION_REQUIRED,
    SECTION_UTF8,
    TASK_BBOX,
    TASK_CLASSIFICATION,
    build_package,
)

CAP_AXI_DMA = 1 << 0
CAP_PACKED_PRELOAD = 1 << 1
CAP_RESULT_WRITEBACK = 1 << 2
CAP_DESCRIPTOR_RAM = 1 << 3

MODE = {"frame": 0, "packed_preload": 1}
LAYOUT = {"linear": 0, "nhwc": 1, "nchw": 2, "chw": 2}
DTYPE = {"u8": 0, "s8": 1, "u16": 2, "s16": 3, "u32": 4, "s32": 5}
TASK = {"bbox": TASK_BBOX, "classification": TASK_CLASSIFICATION}
CIFAR10_LABELS = (
    "airplane", "automobile", "bird", "cat", "deer",
    "dog", "frog", "horse", "ship", "truck",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve(catalog_path: Path, relative: str) -> Path:
    return (catalog_path.parent / relative).resolve()


def decode_hex_words(path: Path) -> bytes:
    output = bytearray()
    for number, raw_line in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("@"):
            continue
        if not re.fullmatch(r"[0-9a-fA-F]{8}", line):
            raise ValueError(f"{path}:{number}: expected one 32-bit HEX word")
        output.extend(struct.pack("<I", int(line, 16)))
    return bytes(output)


def read_c_u8_array(path: Path, symbol: str) -> bytes:
    text = path.read_text(encoding="utf-8")
    match = re.search(
        rf"\b{re.escape(symbol)}\s*\[[^\]]+\]\s*=\s*\{{(.*?)\}}\s*;",
        text,
        re.DOTALL,
    )
    if not match:
        raise ValueError(f"{path}: array {symbol} not found")
    tokens = re.findall(r"\b(?:0x[0-9a-fA-F]{1,2}|[0-9]{1,3})[uU]?\b", match.group(1))
    if not tokens:
        raise ValueError(f"{path}: array {symbol} has no byte literals")
    clean = [token.rstrip("uU") for token in tokens]
    values = [int(token, 16 if token.lower().startswith("0x") else 10) for token in clean]
    if any(value > 255 for value in values):
        raise ValueError(f"{path}: array {symbol} contains a value wider than u8")
    return bytes(values)


def labels_for(model: Dict) -> Iterable[str]:
    if model["task"] == "bbox":
        return ("confidence", "center_x", "center_y", "width", "height")
    if model["target"] == "mnist_lenet_v1":
        return tuple(str(value) for value in range(10))
    return CIFAR10_LABELS


def canonical_json(value: Dict) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def build_model(
    catalog_path: Path,
    catalog: Dict,
    model: Dict,
    descriptor_path: Optional[Path] = None,
    parameter_path: Optional[Path] = None,
) -> bytes:
    descriptor_path = descriptor_path or resolve(catalog_path, model["descriptor"]["path"])
    parameter_path = parameter_path or resolve(catalog_path, model["parameter_image"]["path"])
    config_path = catalog_path.parent.parent / "configs" / f"{model['target']}.json"
    if sha256(descriptor_path) != model["descriptor"]["sha256"]:
        raise ValueError(f"{descriptor_path}: catalog SHA-256 mismatch")
    if sha256(parameter_path) != model["parameter_image"]["sha256"]:
        raise ValueError(f"{parameter_path}: catalog SHA-256 mismatch")

    descriptor_image = decode_hex_words(descriptor_path)
    descriptor_bytes = model["layers"] * 32
    if len(descriptor_image) < descriptor_bytes or any(descriptor_image[descriptor_bytes:]):
        raise ValueError(
            f"{descriptor_path}: active descriptors or zero padding do not match catalog"
        )
    descriptors = descriptor_image[:descriptor_bytes]
    parameters = decode_hex_words(parameter_path)
    if len(parameters) != model["parameter_image"]["bytes"]:
        raise ValueError(f"{parameter_path}: parameter byte count does not match catalog")

    config = json.loads(config_path.read_text(encoding="utf-8"))
    input_contract = model["input"]
    output_contract = model["output"]
    input_shape = input_contract["shape"]
    output_shape = output_contract["shape"]
    required_caps = CAP_AXI_DMA | CAP_RESULT_WRITEBACK | CAP_DESCRIPTOR_RAM
    if input_contract["mode"] == "packed_preload":
        required_caps |= CAP_PACKED_PRELOAD
    metadata = {
        "format": "xupt_npu_metadata_v1",
        "target": model["target"],
        "task": model["task"],
        "input_contract": config["model"]["input_contract"],
        "output_contract": config["model"]["output_contract"],
        "source": catalog["source"],
    }
    labels = ("\n".join(labels_for(model)) + "\n").encode("utf-8")
    header = {
        "flags": 0,
        "hardware_abi": catalog["hardware_abi"],
        "model_id": model["model_id"],
        "task": TASK[model["task"]],
        "layer_count": model["layers"],
        "input_mode": MODE[input_contract["mode"]],
        "input_width": input_shape[0],
        "input_height": input_shape[1],
        "input_channels": input_shape[2],
        "input_layout": LAYOUT[input_contract["layout"]],
        "input_dtype": DTYPE[input_contract["dtype"]],
        "input_bytes": input_contract["bytes"],
        "output_width": output_shape[0],
        "output_height": output_shape[1],
        "output_channels": output_shape[2],
        "output_layout": LAYOUT[output_contract["layout"]],
        "output_dtype": DTYPE[output_contract["dtype"]],
        "output_bytes": output_contract["bytes"],
        "parameter_bytes": len(parameters),
        "scratch_bytes": catalog["shared_limits"]["scratch_bytes"],
        "required_caps": required_caps,
    }
    return build_package(
        header,
        (
            (SECTION_DESCRIPTORS, SECTION_REQUIRED, descriptors),
            (SECTION_PARAMETERS, SECTION_REQUIRED, parameters),
            (SECTION_NAME, SECTION_REQUIRED | SECTION_UTF8, model["name"].encode()),
            (SECTION_LABELS, SECTION_UTF8, labels),
            (SECTION_METADATA, SECTION_UTF8 | SECTION_JSON, canonical_json(metadata)),
        ),
    )


def emit_fixtures(catalog_path: Path, catalog: Dict, fixture_dir: Path) -> List[str]:
    fixture_dir.mkdir(parents=True, exist_ok=True)
    manifest = [
        "# XNPU regression manifest v1",
        "# package\\tinput\\tchecksum\\tkind\\texpected",
    ]
    for model in catalog["models"]:
        for fixture in model["fixtures"]:
            source = resolve(catalog_path, fixture["path"])
            if sha256(source) != fixture["sha256"]:
                raise ValueError(f"{source}: catalog SHA-256 mismatch")
            input_data = read_c_u8_array(source, fixture["input_symbol"])
            expected = read_c_u8_array(source, fixture["expected_symbol"])
            if len(input_data) != model["input"]["bytes"]:
                raise ValueError(f"{source}: input length does not match model contract")
            if len(expected) > model["output"]["bytes"]:
                raise ValueError(f"{source}: expected result is too large")
            (fixture_dir / f"{fixture['id']}.bin").write_bytes(input_data)
            (fixture_dir / f"{fixture['id']}.expected.bin").write_bytes(expected)
            if model["task"] == "bbox":
                kind = "bbox"
                expected_text = ",".join(str(value) for value in fixture["bbox"])
            else:
                kind = "top1"
                expected_text = str(fixture["top1"])
            manifest.append(
                "\t".join(
                    (
                        f"/models/{model['target']}.xnpu",
                        f"/fixtures/{fixture['id']}.bin",
                        fixture["result_checksum"],
                        kind,
                        expected_text,
                    )
                )
            )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "models" / "catalog.json",
    )
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--fixture-dir", type=Path)
    parser.add_argument("--target", help="Build exactly one catalog target.")
    parser.add_argument("--output", type=Path, help="Single-target package output path.")
    parser.add_argument("--descriptor", type=Path, help="Single-target descriptor HEX override.")
    parser.add_argument("--parameters", type=Path, help="Single-target parameter HEX override.")
    args = parser.parse_args()
    catalog_path = args.catalog.resolve()
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))

    single_options = (args.output, args.descriptor, args.parameters)
    if args.target is None and any(value is not None for value in single_options):
        parser.error("--output/--descriptor/--parameters require --target")
    if args.target is not None:
        if args.output is None:
            parser.error("--target requires --output")
        matches = [model for model in catalog["models"] if model["target"] == args.target]
        if not matches:
            supported = ", ".join(model["target"] for model in catalog["models"])
            parser.error(f"unknown target {args.target!r}; supported targets: {supported}")
        descriptor_path = args.descriptor.resolve() if args.descriptor else None
        parameter_path = args.parameters.resolve() if args.parameters else None
        package = build_model(
            catalog_path,
            catalog,
            matches[0],
            descriptor_path=descriptor_path,
            parameter_path=parameter_path,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(package)
        print(
            f"{args.output}: {len(package)} bytes "
            f"sha256={hashlib.sha256(package).hexdigest()}"
        )
        return 0

    output_dir = args.output_dir or catalog_path.parent / "packages"
    fixture_dir = args.fixture_dir or catalog_path.parent / "fixtures" / "bin"
    output_dir.mkdir(parents=True, exist_ok=True)
    for model in catalog["models"]:
        package = build_model(catalog_path, catalog, model)
        path = output_dir / f"{model['target']}.xnpu"
        path.write_bytes(package)
        print(f"{path}: {len(package)} bytes sha256={hashlib.sha256(package).hexdigest()}")
    manifest = emit_fixtures(catalog_path, catalog, fixture_dir)
    manifest_bytes = ("\n".join(manifest) + "\n").encode("utf-8")
    (output_dir / "regression.tsv").write_bytes(manifest_bytes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
