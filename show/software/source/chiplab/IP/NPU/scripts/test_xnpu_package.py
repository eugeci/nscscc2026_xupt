#!/usr/bin/env python3
"""Dependency-free tests for the XNPU packer and reference parser."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from xnpu_format import (
    FormatError,
    SECTION_PARAMETERS,
    load_package,
    parse_package,
)

SCRIPT_DIR = Path(__file__).resolve().parent
NPU_ROOT = SCRIPT_DIR.parent
CATALOG = NPU_ROOT / "models" / "catalog.json"
PACKAGES = NPU_ROOT / "models" / "packages"
FIXTURES = NPU_ROOT / "models" / "fixtures" / "bin"


class XnpuPackageTest(unittest.TestCase):
    def test_catalog_packages(self) -> None:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        for model in catalog["models"]:
            with self.subTest(model=model["target"]):
                package = load_package(PACKAGES / f"{model['target']}.xnpu")
                self.assertEqual(package.header["model_id"], model["model_id"])
                self.assertEqual(package.header["hardware_abi"], catalog["hardware_abi"])
                self.assertEqual(package.header["layer_count"], model["layers"])
                self.assertEqual(
                    len(package.section(SECTION_PARAMETERS)),
                    model["parameter_image"]["bytes"],
                )

    def test_repack_is_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "packages"
            fixtures = root / "fixtures"
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "xnpu_pack.py"),
                    "--catalog",
                    str(CATALOG),
                    "--output-dir",
                    str(output),
                    "--fixture-dir",
                    str(fixtures),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            for expected in PACKAGES.iterdir():
                if expected.is_file():
                    self.assertEqual(
                        (output / expected.name).read_bytes(),
                        expected.read_bytes(),
                        expected.name,
                    )
            for expected in FIXTURES.iterdir():
                if expected.is_file():
                    self.assertEqual(
                        (fixtures / expected.name).read_bytes(),
                        expected.read_bytes(),
                        expected.name,
                    )

    def test_corruption_is_rejected(self) -> None:
        valid = bytearray((PACKAGES / "facenet_lbp_v1.xnpu").read_bytes())
        cases = {}
        corrupt = bytearray(valid)
        corrupt[0] ^= 1
        cases["magic"] = corrupt
        corrupt = bytearray(valid)
        corrupt[112] ^= 1
        cases["sha256"] = corrupt
        package = parse_package(valid)
        corrupt = bytearray(valid)
        corrupt[package.sections[SECTION_PARAMETERS].offset] ^= 1
        cases["section_crc32"] = corrupt
        cases["truncated"] = valid[:-1]
        for name, data in cases.items():
            with self.subTest(case=name), self.assertRaises(FormatError):
                parse_package(data)

    def test_inspector_json(self) -> None:
        output = subprocess.check_output(
            [
                sys.executable,
                str(SCRIPT_DIR / "xnpu_inspect.py"),
                "--json",
                str(PACKAGES / "facenet_lbp_v1.xnpu"),
            ],
            text=True,
        )
        info = json.loads(output)
        self.assertEqual(info["name"], "facenet_bbox")
        self.assertEqual(info["task"], "bbox")
        self.assertEqual(info["input"]["bytes"], 19200)
        self.assertEqual(info["output"]["bytes"], 16)


if __name__ == "__main__":
    unittest.main()
