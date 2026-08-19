#!/usr/bin/env python3
"""Dependency-free regression tests for backend-only NPU compilation."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
NPU_ROOT = SCRIPT_DIR.parent
CONFIG_DIR = NPU_ROOT / "configs"
COMPILER = SCRIPT_DIR / "compile_model.py"
ARTIFACT_KEYS = ("microcode_hex", "desc_hex", "desc_header", "package")


def resolve_npu_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else NPU_ROOT / path


class BackendCompilerTest(unittest.TestCase):
    def test_checked_in_targets_are_reproducible_without_quantization(self) -> None:
        config_paths = sorted(CONFIG_DIR.glob("*.json"))
        self.assertEqual(4, len(config_paths))

        for config_path in config_paths:
            with self.subTest(config=config_path.name):
                config = json.loads(config_path.read_text(encoding="utf-8"))
                expected = {}
                for key in ARTIFACT_KEYS:
                    baseline = config["outputs"][key]
                    if key == "desc_hex":
                        baseline = config["integration"]["sync_sim_desc_hex"]
                    expected[key] = resolve_npu_path(baseline)
                for key, path in expected.items():
                    self.assertTrue(path.is_file(), f"missing {key} baseline: {path}")

                with tempfile.TemporaryDirectory() as temporary:
                    temp_root = Path(temporary)
                    generated = {
                        key: temp_root / Path(config["outputs"][key]).name
                        for key in ARTIFACT_KEYS
                    }
                    for key, path in generated.items():
                        config["outputs"][key] = str(path)
                    config["outputs"]["compile_manifest"] = str(
                        temp_root / "npu_compile_manifest.json"
                    )
                    config["integration"] = {}
                    temporary_config = temp_root / config_path.name
                    temporary_config.write_text(
                        json.dumps(config, indent=2), encoding="utf-8"
                    )

                    command = [
                        sys.executable,
                        str(COMPILER),
                        "--config",
                        str(temporary_config),
                        "--skip-quant",
                        "--skip-verify",
                        "--no-sync",
                    ]
                    result = subprocess.run(
                        command,
                        cwd=NPU_ROOT,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                    )
                    self.assertEqual(0, result.returncode, result.stdout)

                    for key in ARTIFACT_KEYS:
                        self.assertEqual(
                            expected[key].read_bytes(),
                            generated[key].read_bytes(),
                            f"{config['target']}: {key}",
                        )

    def test_unsupported_target_is_rejected(self) -> None:
        config_path = CONFIG_DIR / "mnist_lenet_v1.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["target"] = "unsupported_test_target"

        with tempfile.TemporaryDirectory() as temporary:
            temporary_config = Path(temporary) / "unsupported.json"
            temporary_config.write_text(
                json.dumps(config, indent=2), encoding="utf-8"
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(COMPILER),
                    "--config",
                    str(temporary_config),
                    "--skip-quant",
                    "--dry-run",
                ],
                cwd=NPU_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("unsupported target", result.stdout)

    def test_missing_backend_artifact_reports_exact_path(self) -> None:
        config_path = CONFIG_DIR / "mnist_lenet_v1.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))

        with tempfile.TemporaryDirectory() as temporary:
            temp_root = Path(temporary)
            missing_params = temp_root / "missing_params.hex"
            config["outputs"]["params_hex"] = str(missing_params)
            for key in ARTIFACT_KEYS:
                config["outputs"][key] = str(temp_root / f"generated_{key}")
            config["outputs"]["compile_manifest"] = str(temp_root / "manifest.json")
            config["integration"] = {}
            temporary_config = temp_root / "missing.json"
            temporary_config.write_text(
                json.dumps(config, indent=2), encoding="utf-8"
            )
            base_command = [
                sys.executable,
                str(COMPILER),
                "--config",
                str(temporary_config),
                "--skip-quant",
            ]
            dry_run = subprocess.run(
                base_command + ["--dry-run"],
                cwd=NPU_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.assertEqual(0, dry_run.returncode, dry_run.stdout)
            self.assertIn(
                f"[warn] params hex does not exist yet: {missing_params}",
                dry_run.stdout,
            )

            real_run = subprocess.run(
                base_command + ["--skip-verify", "--no-sync"],
                cwd=NPU_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.assertNotEqual(0, real_run.returncode)
            self.assertIn(
                f"params hex does not exist: {missing_params}", real_run.stdout
            )
            for key in ARTIFACT_KEYS:
                self.assertFalse((temp_root / f"generated_{key}").exists())


if __name__ == "__main__":
    unittest.main()
