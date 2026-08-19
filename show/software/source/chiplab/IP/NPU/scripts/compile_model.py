#!/usr/bin/env python3
"""Small NPU model compiler for the current FaceNet LBP target.

This is intentionally a thin orchestration layer around the already verified
quantization, microcode, descriptor, and checker scripts. The compiler surface
is target-based so future CNN backends can be added without changing the user
entry point.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


THIS_DIR = Path(__file__).resolve().parent
NPU_IP_ROOT = THIS_DIR.parent
DEFAULT_CONFIG = NPU_IP_ROOT / "configs" / "facenet_lbp_v1.json"
SUPPORTED_TARGETS = {
    "facenet_lbp_v1": "FPGALightFaceNet, 120x160 LBP input, bbox5 uint8 output",
    "mnist_lenet_v1": "PPQ_Mnist LeNet, 28x28 grayscale input, 10-class uint8 scores",
    "npu_vgg_s1_v1": "NPU TinyVGG-S1, 3x34x34 packed preload input, 10-class uint8 scores",
    "npu_vgg_s2b_v1": "NPU TinyVGG-S2b, 3x34x34 packed preload input, 10-class uint8 scores",
}


def _load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: top-level JSON must be an object")
    return data


def _resolve_config_path(value: str | Path) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    candidates = [Path.cwd() / path, NPU_IP_ROOT / path]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return candidates[0].resolve()


def _resolve_path(value: str | Path | None) -> Path | None:
    if value is None:
        return None
    path = Path(value)
    if path.is_absolute():
        return path
    return (NPU_IP_ROOT / path).resolve()


def _required(config: dict[str, Any], *keys: str) -> Any:
    cur: Any = config
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            dotted = ".".join(keys)
            raise SystemExit(f"missing required config field: {dotted}")
        cur = cur[key]
    return cur


def _set_nested(config: dict[str, Any], keys: tuple[str, ...], value: Any) -> None:
    if value is None:
        return
    cur = config
    for key in keys[:-1]:
        cur = cur.setdefault(key, {})
    cur[keys[-1]] = value


def _as_bool(value: Any, default: bool) -> bool:
    if value is None:
        return default
    return bool(value)


def _rel(path: Path | None) -> str | None:
    if path is None:
        return None
    try:
        return str(path.relative_to(NPU_IP_ROOT))
    except ValueError:
        return str(path)


def _format_cmd(argv: list[str]) -> str:
    return " ".join(shlex.quote(str(arg)) for arg in argv)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def apply_cli_overrides(config: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    cfg = copy.deepcopy(config)
    _set_nested(cfg, ("model", "weights"), args.weights)
    _set_nested(cfg, ("dataset", "root"), args.dataset_root)
    _set_nested(cfg, ("quant", "seed"), args.seed)
    _set_nested(cfg, ("quant", "calib_samples"), args.calib_samples)
    _set_nested(cfg, ("quant", "eval_samples"), args.eval_samples)
    _set_nested(cfg, ("quant", "batch_size"), args.batch_size)
    _set_nested(cfg, ("quant", "num_workers"), args.num_workers)
    _set_nested(cfg, ("quant", "activation_percentile"), args.activation_percentile)
    _set_nested(cfg, ("quant", "activation_margin"), args.activation_margin)
    _set_nested(cfg, ("quant", "device"), args.device)
    _set_nested(cfg, ("outputs", "package"), args.package_output)
    return cfg


def validate_target(config: dict[str, Any]) -> str:
    target = str(_required(config, "target"))
    if target not in SUPPORTED_TARGETS:
        supported = ", ".join(sorted(SUPPORTED_TARGETS))
        raise SystemExit(f"unsupported target {target!r}; supported targets: {supported}")
    return target


def resolve_compile_paths(config: dict[str, Any]) -> dict[str, Path | None]:
    outputs = _required(config, "outputs")
    integration = config.get("integration", {})
    return {
        "weights": _resolve_path(_required(config, "model", "weights")),
        "dataset_root": _resolve_path(_required(config, "dataset", "root")),
        "params_hex": _resolve_path(_required(outputs, "params_hex")),
        "quant_config": _resolve_path(_required(outputs, "quant_config")),
        "microcode_hex": _resolve_path(_required(outputs, "microcode_hex")),
        "desc_hex": _resolve_path(_required(outputs, "desc_hex")),
        "desc_header": _resolve_path(_required(outputs, "desc_header")),
        "demo_header": _resolve_path(outputs.get("demo_header")),
        "compile_manifest": _resolve_path(outputs.get("compile_manifest")),
        "package": _resolve_path(outputs.get("package")),
        "sync_bsp_desc_header": _resolve_path(integration.get("sync_bsp_desc_header")),
        "sync_sim_desc_hex": _resolve_path(integration.get("sync_sim_desc_hex")),
    }


def validate_inputs(paths: dict[str, Path | None], args: argparse.Namespace) -> None:
    checks: list[tuple[str, Path | None, bool]] = [
        # Existing quant_config/parameter images are sufficient for a
        # deterministic backend-only rebuild.  Checkpoints and datasets are
        # only inputs to the optional quantization stage.
        ("weights", paths["weights"], not args.skip_quant),
        ("dataset root", paths["dataset_root"], not args.skip_quant),
        ("params hex", paths["params_hex"], args.skip_quant),
        ("quant config", paths["quant_config"], args.skip_quant),
    ]
    for label, path, required in checks:
        if not required or path is None:
            continue
        if not path.exists():
            if args.dry_run:
                print(f"[warn] {label} does not exist yet: {path}")
            else:
                raise SystemExit(f"{label} does not exist: {path}")


def quant_cmd(target: str, paths: dict[str, Path | None], quant: dict[str, Any]) -> list[str]:
    if target == "mnist_lenet_v1":
        argv = [
            sys.executable,
            str(THIS_DIR / "quant_mnist_lenet.py"),
            "--weights",
            str(paths["weights"]),
            "--dataset-root",
            str(paths["dataset_root"]),
            "--output-hex",
            str(paths["params_hex"]),
            "--output-config",
            str(paths["quant_config"]),
            "--activation-percentile",
            str(quant.get("activation_percentile", 100.0)),
            "--activation-margin",
            str(quant.get("activation_margin", 1.10)),
            "--calib-samples",
            str(quant.get("calib_samples", 0)),
            "--demo-sample",
            str(quant.get("demo_sample", "img7")),
            "--device",
            str(quant.get("device", "cpu")),
        ]
        if paths.get("demo_header") is not None:
            argv.extend(["--output-demo-header", str(paths["demo_header"])])
        return argv

    if target.startswith("npu_vgg_"):
        argv = [
            sys.executable,
            str(THIS_DIR / "quant_tiny_vgg.py"),
            "--target",
            target,
            "--weights",
            str(paths["weights"]),
            "--dataset-root",
            str(paths["dataset_root"]),
            "--output-hex",
            str(paths["params_hex"]),
            "--output-config",
            str(paths["quant_config"]),
            "--seed",
            str(quant.get("seed", 42)),
            "--calib-samples",
            str(quant.get("calib_samples", 1024)),
            "--eval-samples",
            str(quant.get("eval_samples", 0)),
            "--batch-size",
            str(quant.get("batch_size", 128)),
            "--activation-percentile",
            str(quant.get("activation_percentile", 99.9)),
            "--activation-margin",
            str(quant.get("activation_margin", 1.10)),
            "--device",
            str(quant.get("device", "cpu")),
        ]
        if quant.get("variant"):
            argv.extend(["--variant", str(quant["variant"])])
        if quant.get("tiny_vgg_root"):
            argv.extend(["--tiny-vgg-root", str(_resolve_path(quant["tiny_vgg_root"]))])
        if quant.get("demo_input_bin"):
            argv.extend(["--demo-input-bin", str(_resolve_path(quant["demo_input_bin"]))])
        if paths.get("demo_header") is not None:
            argv.extend(["--output-demo-header", str(paths["demo_header"])])
        return argv

    return [
        sys.executable,
        str(THIS_DIR / "quant_calibrated.py"),
        "--weights",
        str(paths["weights"]),
        "--dataset-root",
        str(paths["dataset_root"]),
        "--output-hex",
        str(paths["params_hex"]),
        "--output-config",
        str(paths["quant_config"]),
        "--seed",
        str(quant.get("seed", 42)),
        "--calib-samples",
        str(quant.get("calib_samples", 2048)),
        "--eval-samples",
        str(quant.get("eval_samples", 2048)),
        "--batch-size",
        str(quant.get("batch_size", 128)),
        "--num-workers",
        str(quant.get("num_workers", 0)),
        "--activation-percentile",
        str(quant.get("activation_percentile", 100.0)),
        "--activation-margin",
        str(quant.get("activation_margin", 1.05)),
        "--device",
        str(quant.get("device", "cpu")),
    ]


def microcode_cmd(target: str, paths: dict[str, Path | None]) -> list[str]:
    return [
        sys.executable,
        str(THIS_DIR / "gen_microcode.py"),
        "--target",
        target,
        "--weights",
        str(paths["weights"]),
        "--quant-config",
        str(paths["quant_config"]),
        "--output-hex",
        str(paths["microcode_hex"]),
    ]


def descriptor_cmd(target: str, paths: dict[str, Path | None]) -> list[str]:
    return [
        sys.executable,
        str(THIS_DIR / "gen_descriptors.py"),
        "--target",
        target,
        "--microcode-hex",
        str(paths["microcode_hex"]),
        "--quant-config",
        str(paths["quant_config"]),
        "--output-hex",
        str(paths["desc_hex"]),
        "--output-header",
        str(paths["desc_header"]),
    ]


def verify_params_cmd(paths: dict[str, Path | None]) -> list[str]:
    return [
        sys.executable,
        str(THIS_DIR / "verify_npu_params_blocked.py"),
        "--params-hex",
        str(paths["params_hex"]),
    ]


def check_desc_cmd(paths: dict[str, Path | None]) -> list[str]:
    return [
        sys.executable,
        str(THIS_DIR / "check_desc_match.py"),
        "--desc-hex",
        str(paths["desc_hex"]),
        "--microcode-hex",
        str(paths["microcode_hex"]),
        "--quant-config",
        str(paths["quant_config"]),
    ]


def package_cmd(target: str, paths: dict[str, Path | None]) -> list[str]:
    return [
        sys.executable,
        str(THIS_DIR / "xnpu_pack.py"),
        "--catalog",
        str(NPU_IP_ROOT / "models" / "catalog.json"),
        "--target",
        target,
        "--output",
        str(paths["package"]),
        "--descriptor",
        str(paths["desc_hex"]),
        "--parameters",
        str(paths["params_hex"]),
    ]


def run_command(
    step: str,
    argv: list[str],
    records: list[dict[str, Any]],
    *,
    dry_run: bool,
    env_extra: dict[str, str] | None = None,
) -> None:
    record = {"step": step, "argv": [str(arg) for arg in argv], "dry_run": dry_run}
    records.append(record)
    print(f"\n[{step}]", flush=True)
    print("+ " + _format_cmd(record["argv"]), flush=True)
    if dry_run:
        return

    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    subprocess.run(record["argv"], cwd=NPU_IP_ROOT, env=env, check=True)
    record["returncode"] = 0


def copy_artifact(
    label: str,
    src: Path | None,
    dst: Path | None,
    records: list[dict[str, Any]],
    *,
    dry_run: bool,
) -> None:
    if src is None or dst is None:
        return
    record = {
        "step": f"sync_{label}",
        "src": str(src),
        "dst": str(dst),
        "dry_run": dry_run,
    }
    records.append(record)
    print(f"\n[sync {label}]", flush=True)
    print(f"+ cp {shlex.quote(str(src))} {shlex.quote(str(dst))}", flush=True)
    if dry_run:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    record["copied"] = True


def read_quant_summary(path: Path | None) -> dict[str, Any] | None:
    if path is None or not path.exists():
        return None
    try:
        qcfg = _load_json(path)
    except Exception as exc:  # noqa: BLE001
        return {"error": f"failed to read quant config: {exc}"}

    layers = []
    for layer in qcfg.get("layers", []):
        layers.append({
            "index": layer.get("index"),
            "name": layer.get("name"),
            "shift": layer.get("shift"),
            "weight_shape": layer.get("weight_shape"),
            "rom_weight_start": layer.get("rom_weight_start"),
            "rom_bias_start": layer.get("rom_bias_start"),
        })

    return {
        "format_version": qcfg.get("format_version"),
        "rom_words": qcfg.get("export", {}).get("rom_words"),
        "metrics": qcfg.get("metrics"),
        "layers": layers,
    }


def collect_artifacts(paths: dict[str, Path | None]) -> dict[str, dict[str, Any]]:
    names = [
        "params_hex",
        "quant_config",
        "microcode_hex",
        "desc_hex",
        "desc_header",
        "demo_header",
        "sync_bsp_desc_header",
        "sync_sim_desc_hex",
        "package",
    ]
    artifacts: dict[str, dict[str, Any]] = {}
    for name in names:
        path = paths.get(name)
        if path is None or not path.exists():
            continue
        artifacts[name] = {
            "path": _rel(path),
            "bytes": path.stat().st_size,
            "sha256": _sha256(path),
        }
    return artifacts


def write_manifest(
    config_path: Path,
    config: dict[str, Any],
    target: str,
    paths: dict[str, Path | None],
    records: list[dict[str, Any]],
) -> None:
    manifest_path = paths.get("compile_manifest")
    if manifest_path is None:
        return

    resolved_paths = {key: _rel(value) for key, value in paths.items()}
    manifest = {
        "format_version": "npu_compile_manifest_v1",
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "target": target,
        "target_description": SUPPORTED_TARGETS[target],
        "compiler": {
            "script": _rel(Path(__file__).resolve()),
            "version": 1,
        },
        "config_path": _rel(config_path),
        "config": config,
        "resolved_paths": resolved_paths,
        "steps": records,
        "artifacts": collect_artifacts(paths),
        "quant_summary": read_quant_summary(paths.get("quant_config")),
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"\n[manifest]\n+ wrote {manifest_path}", flush=True)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Compile a supported CNN model into NPU software/RTL artifacts.")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="Compile JSON config.")
    parser.add_argument("--dry-run", action="store_true", help="Print the planned commands without writing artifacts.")
    parser.add_argument("--skip-quant", action="store_true", help="Reuse existing params_hex/quant_config artifacts.")
    parser.add_argument("--skip-verify", action="store_true", help="Skip parameter and descriptor consistency checks.")
    parser.add_argument("--no-sync", action="store_true", help="Disable configured BSP/simulation copy steps.")

    parser.add_argument("--weights", help="Override model.weights.")
    parser.add_argument("--dataset-root", help="Override dataset.root.")
    parser.add_argument("--seed", type=int, help="Override quant.seed.")
    parser.add_argument("--calib-samples", type=int, help="Override quant.calib_samples.")
    parser.add_argument("--eval-samples", type=int, help="Override quant.eval_samples; 0 means all validation images.")
    parser.add_argument("--batch-size", type=int, help="Override quant.batch_size.")
    parser.add_argument("--num-workers", type=int, help="Override quant.num_workers.")
    parser.add_argument("--activation-percentile", type=float, help="Override quant.activation_percentile.")
    parser.add_argument("--activation-margin", type=float, help="Override quant.activation_margin.")
    parser.add_argument("--device", help="Override quant.device, for example cpu or cuda.")
    parser.add_argument("--package-output", help="Override outputs.package.")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    config_path = _resolve_config_path(args.config)
    raw_config = _load_json(config_path)
    config = apply_cli_overrides(raw_config, args)
    target = validate_target(config)
    paths = resolve_compile_paths(config)
    validate_inputs(paths, args)

    print("NPU model compiler v1", flush=True)
    print(f"  root:   {NPU_IP_ROOT}", flush=True)
    print(f"  config: {config_path}", flush=True)
    print(f"  target: {target} ({SUPPORTED_TARGETS[target]})", flush=True)

    records: list[dict[str, Any]] = []
    quant = config.get("quant", {})
    verify = config.get("verify", {})

    if not args.skip_quant:
        run_command("quantize_params", quant_cmd(target, paths, quant), records, dry_run=args.dry_run)
    else:
        print("\n[quantize_params]\n+ skipped", flush=True)

    run_command("generate_microcode", microcode_cmd(target, paths), records, dry_run=args.dry_run)
    run_command("generate_descriptors", descriptor_cmd(target, paths), records, dry_run=args.dry_run)

    if not args.no_sync:
        copy_artifact("bsp_desc_header", paths["desc_header"], paths["sync_bsp_desc_header"], records, dry_run=args.dry_run)
        copy_artifact("sim_desc_hex", paths["desc_hex"], paths["sync_sim_desc_hex"], records, dry_run=args.dry_run)

    if not args.skip_verify:
        verify_env = {
            "NPU_QUANT_CONFIG": str(paths["quant_config"]),
            "NPU_WEIGHTS_PTH": str(paths["weights"]),
        }
        if target == "facenet_lbp_v1" and _as_bool(verify.get("params"), True):
            run_command("verify_params", verify_params_cmd(paths), records, dry_run=args.dry_run, env_extra=verify_env)
        elif target != "facenet_lbp_v1" and _as_bool(verify.get("params"), False):
            print("\n[verify_params]\n+ skipped (FaceNet-specific verifier)", flush=True)
        if _as_bool(verify.get("descriptors"), True):
            run_command("check_descriptors", check_desc_cmd(paths), records, dry_run=args.dry_run)
    else:
        print("\n[verify]\n+ skipped", flush=True)

    if paths["package"] is not None:
        run_command("build_package", package_cmd(target, paths), records, dry_run=args.dry_run)
    else:
        print("\n[build_package]\n+ skipped (no outputs.package configured)", flush=True)

    if not args.dry_run:
        write_manifest(config_path, config, target, paths, records)

    print("\nCompile flow complete" if not args.dry_run else "\nDry run complete", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
