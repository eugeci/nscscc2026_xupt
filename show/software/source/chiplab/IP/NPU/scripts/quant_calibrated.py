#!/usr/bin/env python3
"""Calibrated quantization flow for the FaceNet NPU model.

This script follows the training contract in face/train.py:
  - input image is an already-computed 120x160 LBP uint8 image
  - float model input is LBP / 255.0
  - output is [conf, cx, cy, w, h] in normalized 0..1 coordinates

The exported fixed-point contract is constrained by the current RTL datapath:
  UINT8 activation * INT8 weight -> INT32 accumulator + INT32 bias
  -> ReLU or RTL HardSigmoid approximation -> arithmetic right shift
  -> clamp to UINT8.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

THIS_DIR = Path(__file__).resolve().parent
NPU_IP_ROOT = THIS_DIR.parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from quant_int8 import (  # noqa: E402
    FPGALightFaceNet,
    _build_bias_block,
    _build_weight_block,
    _bytes_to_hex_lines,
    permute_fc_weights_for_npu,
)

IMG_H = 120
IMG_W = 160
INPUT_SCALE = 1.0 / 255.0
SHIFT_BITS = 4
MAX_SHIFT = (1 << SHIFT_BITS) - 1
HARDSIGMOID_RTL_GAIN = 43.0 / 256.0
HARDSIGMOID_EXACT_GAIN = 1.0 / 6.0
FINAL_BYTE_SCALE = 1.0 / 255.0
FINAL_HW_TARGET_SCALE = FINAL_BYTE_SCALE * (HARDSIGMOID_RTL_GAIN / HARDSIGMOID_EXACT_GAIN)


LAYER_SPECS = [
    # name, kind, kernel, padding, pool, activation
    ("C1", "conv", 3, 1, True, "relu"),
    ("C2", "conv", 3, 1, True, "relu"),
    ("C3", "conv", 1, 0, False, "relu"),
    ("C4", "conv", 3, 1, True, "relu"),
    ("C5", "conv", 3, 1, True, "relu"),
    ("C6", "conv", 1, 0, False, "relu"),
    ("C7", "conv", 3, 1, True, "relu"),
    ("C8", "conv", 2, 1, False, "relu"),
    ("FC1", "fc", 1, 0, False, "relu"),
    ("FC2", "fc", 1, 0, False, "hardsigmoid"),
]


def _torch_load_state(path: Path) -> dict[str, torch.Tensor]:
    try:
        return torch.load(str(path), map_location="cpu", weights_only=True)
    except TypeError:
        return torch.load(str(path), map_location="cpu")


def _read_gray(path: Path) -> np.ndarray:
    try:
        import cv2

        img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            raise ValueError(f"OpenCV could not read {path}")
        return img.astype(np.uint8)
    except ImportError:
        from PIL import Image

        with Image.open(path) as im:
            return np.asarray(im.convert("L"), dtype=np.uint8)


class LBPContractDataset(Dataset):
    def __init__(self, dataset_root: Path, image_names: list[str]):
        self.dataset_root = dataset_root
        self.image_dir = dataset_root / "images"
        self.label_dir = dataset_root / "labels"
        self.image_names = image_names

    def __len__(self) -> int:
        return len(self.image_names)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
        name = self.image_names[idx]
        img = _read_gray(self.image_dir / name)
        if img.shape != (IMG_H, IMG_W):
            raise ValueError(f"{name}: expected {IMG_H}x{IMG_W} LBP image, got {img.shape}")

        target = np.zeros(5, dtype=np.float32)
        label_path = self.label_dir / (Path(name).stem + ".txt")
        if label_path.exists():
            content = label_path.read_text(encoding="utf-8").strip()
            if content:
                parts = content.split()
                if len(parts) < 6:
                    raise ValueError(f"{label_path}: expected '<class> conf cx cy w h'")
                target[:] = [float(v) for v in parts[1:6]]

        raw = torch.from_numpy(img.copy()).float().unsqueeze(0)
        return raw, torch.from_numpy(target)


def make_contract_split(dataset_root: Path, seed: int) -> tuple[list[str], list[str], list[str]]:
    image_dir = dataset_root / "images"
    names = sorted(p.name for p in image_dir.iterdir() if p.suffix.lower() in {".jpg", ".png"})
    rng = random.Random(seed)
    rng.shuffle(names)
    train_size = int(0.8 * len(names))
    return names, names[:train_size], names[train_size:]


def get_compute_modules(model: nn.Module) -> list[nn.Module]:
    modules = [m for m in model.modules() if isinstance(m, (nn.Conv2d, nn.Linear))]
    if len(modules) != len(LAYER_SPECS):
        raise RuntimeError(f"expected {len(LAYER_SPECS)} compute layers, got {len(modules)}")
    return modules


def forward_float_layers(
    modules: list[nn.Module],
    raw_lbp: torch.Tensor,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    x = raw_lbp / 255.0
    activations: dict[str, torch.Tensor] = {}

    for spec, module in zip(LAYER_SPECS, modules):
        name, kind, _kernel, _padding, pool, activation = spec
        if kind == "fc":
            x = torch.flatten(x, 1)

        x = module(x)
        if activation == "relu":
            x = F.relu(x)
            activations[name] = x
            if pool:
                x = F.max_pool2d(x, 2)
        elif activation == "hardsigmoid":
            x = F.hardsigmoid(x)
            activations[name] = x
        else:
            raise ValueError(f"unknown activation: {activation}")

    return x, activations


def calibrate_activation_ranges(
    model: nn.Module,
    loader: DataLoader,
    device: torch.device,
    percentile: float,
) -> dict[str, float]:
    modules = get_compute_modules(model)
    ranges = {name: 0.0 for name, *_ in LAYER_SPECS}
    model.eval()

    with torch.no_grad():
        for raw, _target in loader:
            raw = raw.to(device)
            _out, acts = forward_float_layers(modules, raw)
            for name, *_ in LAYER_SPECS:
                value = acts[name].detach()
                if percentile >= 100.0:
                    stat = value.max()
                else:
                    stat = torch.quantile(value.flatten(), percentile / 100.0)
                ranges[name] = max(ranges[name], float(stat.cpu()))

    return ranges


def choose_weight_scale_shift(
    prev_scale: float,
    min_weight_scale: float,
    target_output_scale: float,
) -> tuple[float, int, float, bool]:
    if min_weight_scale <= 0.0:
        min_weight_scale = 1.0 / 127.0
    if target_output_scale <= 0.0:
        target_output_scale = prev_scale * min_weight_scale

    ratio = target_output_scale / (prev_scale * min_weight_scale)
    if ratio >= 1.0:
        shift = min(MAX_SHIFT, int(math.floor(math.log2(ratio))))
        weight_scale = target_output_scale / (prev_scale * (2**shift))
        forced = False
    else:
        shift = 0
        weight_scale = min_weight_scale
        forced = True

    actual_output_scale = prev_scale * weight_scale * (2**shift)
    return weight_scale, shift, actual_output_scale, forced


def quantize_weight(weight: torch.Tensor, scale: float) -> np.ndarray:
    q = torch.round(weight.detach().cpu() / scale).clamp(-128, 127).to(torch.int8)
    return q.numpy()


def compute_layer_spatial_metadata(modules: list[nn.Module]) -> list[dict[str, int]]:
    cur_h, cur_w = IMG_H, IMG_W
    metadata: list[dict[str, int]] = []

    for spec, module in zip(LAYER_SPECS, modules):
        name, kind, _kernel, _padding, pool, _activation = spec
        if kind == "conv":
            assert isinstance(module, nn.Conv2d)
            kh, kw = module.kernel_size
            ph, pw = module.padding
            sh, sw = module.stride
            out_h = (cur_h + 2 * ph - kh) // sh + 1
            out_w = (cur_w + 2 * pw - kw) // sw + 1
            metadata.append({
                "conv_out_h": out_h,
                "conv_out_w": out_w,
                "prev_per_oc": out_h * out_w,
            })
            cur_h, cur_w = out_h, out_w
            if pool:
                cur_h //= 2
                cur_w //= 2
        else:
            prev_per_oc = cur_h * cur_w
            metadata.append({
                "conv_out_h": 1,
                "conv_out_w": 1,
                "prev_per_oc": prev_per_oc,
            })
            cur_h, cur_w = 1, 1

        if name == "C8" and cur_h * cur_w * 32 != 768:
            raise RuntimeError(f"C8 flatten shape mismatch: {cur_h}x{cur_w}x32")

    return metadata


def build_quantized_layers(
    model: nn.Module,
    activation_ranges: dict[str, float],
    activation_margin: float,
) -> list[dict[str, Any]]:
    modules = get_compute_modules(model)
    spatial = compute_layer_spatial_metadata(modules)
    layers: list[dict[str, Any]] = []
    prev_scale = INPUT_SCALE

    for index, (spec, module, meta) in enumerate(zip(LAYER_SPECS, modules, spatial)):
        name, kind, kernel, padding, pool, activation = spec
        weight = module.weight.detach().cpu()
        bias = module.bias.detach().cpu() if module.bias is not None else torch.zeros(weight.shape[0])
        max_abs_weight = float(weight.abs().max())
        min_weight_scale = max_abs_weight / 127.0 if max_abs_weight > 0.0 else 1.0 / 127.0

        if activation == "hardsigmoid":
            target_output_scale = FINAL_HW_TARGET_SCALE
        else:
            target_output_scale = max(activation_ranges[name] * activation_margin / 255.0, 1e-12)

        weight_scale, shift, output_scale, forced = choose_weight_scale_shift(
            prev_scale=prev_scale,
            min_weight_scale=min_weight_scale,
            target_output_scale=target_output_scale,
        )
        acc_scale = prev_scale * weight_scale
        q_weight = quantize_weight(weight, weight_scale)

        q_bias = torch.round(bias / acc_scale).to(torch.int64).numpy()
        hardsigmoid_bias_offset = 0
        if activation == "hardsigmoid":
            hardsigmoid_bias_offset = int(round(3.0 / acc_scale)) - 3
            q_bias = q_bias + hardsigmoid_bias_offset

        if q_bias.min(initial=0) < -(2**31) or q_bias.max(initial=0) > 2**31 - 1:
            raise OverflowError(f"{name}: quantized bias does not fit int32")

        layer = {
            "index": index,
            "name": name,
            "kind": kind,
            "kernel": kernel,
            "padding": padding,
            "pool": pool,
            "activation": activation,
            "input_scale": prev_scale,
            "weight_scale": weight_scale,
            "min_weight_scale": min_weight_scale,
            "acc_scale": acc_scale,
            "target_output_scale": target_output_scale,
            "output_scale": output_scale,
            "shift": shift,
            "scale_forced_by_weight_range": forced,
            "activation_calib_amax": activation_ranges[name],
            "activation_margin": activation_margin,
            "hardsigmoid_bias_offset": hardsigmoid_bias_offset,
            "q_weight": q_weight,
            "q_bias": q_bias.astype(np.int32),
            "weight_shape": list(q_weight.shape),
            "q_weight_min": int(q_weight.min(initial=0)),
            "q_weight_max": int(q_weight.max(initial=0)),
            "q_bias_min": int(q_bias.min(initial=0)),
            "q_bias_max": int(q_bias.max(initial=0)),
            "prev_per_oc": meta["prev_per_oc"],
        }
        layers.append(layer)
        prev_scale = output_scale

    return layers


def _floor_div_pow2(x: torch.Tensor, shift: int) -> torch.Tensor:
    if shift == 0:
        return torch.floor(x)
    return torch.floor(x / float(2**shift))


def prepare_runtime_layers(layers: list[dict[str, Any]], device: torch.device) -> list[dict[str, Any]]:
    runtime = []
    for layer in layers:
        item = dict(layer)
        item["q_weight_t"] = torch.from_numpy(layer["q_weight"].astype(np.float32)).to(device)
        item["q_bias_t"] = torch.from_numpy(layer["q_bias"].astype(np.float32)).to(device)
        runtime.append(item)
    return runtime


def forward_quantized_runtime(raw_lbp: torch.Tensor, runtime_layers: list[dict[str, Any]]) -> torch.Tensor:
    x = raw_lbp
    for layer in runtime_layers:
        if layer["kind"] == "conv":
            bias = layer["q_bias_t"]
            x = F.conv2d(x, layer["q_weight_t"], bias=bias, stride=1, padding=layer["padding"])
        else:
            x = torch.flatten(x, 1)
            x = F.linear(x, layer["q_weight_t"], layer["q_bias_t"])

        acc = torch.round(x)
        if layer["activation"] == "relu":
            act = torch.clamp(acc, min=0.0)
        else:
            act = torch.floor((acc + 3.0) * 43.0 / 256.0)

        q = _floor_div_pow2(act, int(layer["shift"]))
        q = torch.clamp(q, 0.0, 255.0)
        if layer["pool"]:
            q = F.max_pool2d(q, 2)
        x = q

    return x.reshape(x.shape[0], -1)


def xywh_iou(pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    pred_x1 = pred[:, 0] - pred[:, 2] / 2.0
    pred_y1 = pred[:, 1] - pred[:, 3] / 2.0
    pred_x2 = pred[:, 0] + pred[:, 2] / 2.0
    pred_y2 = pred[:, 1] + pred[:, 3] / 2.0

    tgt_x1 = target[:, 0] - target[:, 2] / 2.0
    tgt_y1 = target[:, 1] - target[:, 3] / 2.0
    tgt_x2 = target[:, 0] + target[:, 2] / 2.0
    tgt_y2 = target[:, 1] + target[:, 3] / 2.0

    inter_x1 = torch.maximum(pred_x1, tgt_x1)
    inter_y1 = torch.maximum(pred_y1, tgt_y1)
    inter_x2 = torch.minimum(pred_x2, tgt_x2)
    inter_y2 = torch.minimum(pred_y2, tgt_y2)
    inter_w = torch.clamp(inter_x2 - inter_x1, min=0.0)
    inter_h = torch.clamp(inter_y2 - inter_y1, min=0.0)
    inter = inter_w * inter_h

    area_p = torch.clamp(pred[:, 2], min=0.0) * torch.clamp(pred[:, 3], min=0.0)
    area_t = torch.clamp(target[:, 2], min=0.0) * torch.clamp(target[:, 3], min=0.0)
    union = area_p + area_t - inter
    return torch.where(union > 0.0, inter / (union + 1e-6), torch.zeros_like(union))


def evaluate_models(
    model: nn.Module,
    layers: list[dict[str, Any]],
    loader: DataLoader,
    device: torch.device,
) -> dict[str, Any]:
    modules = get_compute_modules(model)
    runtime_layers = prepare_runtime_layers(layers, device)
    model.eval()

    total = 0
    float_correct = 0
    quant_correct = 0
    float_ious: list[torch.Tensor] = []
    quant_ious: list[torch.Tensor] = []
    float_bbox_mae: list[torch.Tensor] = []
    quant_bbox_mae: list[torch.Tensor] = []
    output_abs_err: list[torch.Tensor] = []
    conf_abs_err: list[torch.Tensor] = []

    with torch.no_grad():
        for raw, target in loader:
            raw = raw.to(device)
            target = target.to(device)

            float_out, _acts = forward_float_layers(modules, raw)
            quant_bytes = forward_quantized_runtime(raw, runtime_layers)
            quant_out = quant_bytes / 255.0

            target_conf = target[:, 0] > 0.5
            float_pred_conf = float_out[:, 0] > 0.5
            quant_pred_conf = quant_out[:, 0] > 0.5
            total += int(target.shape[0])
            float_correct += int((float_pred_conf == target_conf).sum().cpu())
            quant_correct += int((quant_pred_conf == target_conf).sum().cpu())

            output_abs_err.append(torch.abs(quant_out - float_out).detach().cpu())
            conf_abs_err.append(torch.abs(quant_out[:, 0] - float_out[:, 0]).detach().cpu())

            pos = target_conf
            if bool(pos.any()):
                f_iou = xywh_iou(float_out[pos, 1:], target[pos, 1:])
                q_iou = xywh_iou(quant_out[pos, 1:], target[pos, 1:])
                float_ious.append(f_iou.detach().cpu())
                quant_ious.append(q_iou.detach().cpu())
                float_bbox_mae.append(torch.abs(float_out[pos, 1:] - target[pos, 1:]).detach().cpu())
                quant_bbox_mae.append(torch.abs(quant_out[pos, 1:] - target[pos, 1:]).detach().cpu())

    def cat_or_empty(values: list[torch.Tensor]) -> torch.Tensor:
        if not values:
            return torch.empty(0)
        return torch.cat([v.reshape(-1) for v in values], dim=0)

    f_ious = cat_or_empty(float_ious)
    q_ious = cat_or_empty(quant_ious)
    out_err = cat_or_empty(output_abs_err)
    conf_err = cat_or_empty(conf_abs_err)
    f_bbox_err = cat_or_empty(float_bbox_mae)
    q_bbox_err = cat_or_empty(quant_bbox_mae)

    return {
        "samples": total,
        "float_conf_accuracy": float_correct / total if total else 0.0,
        "quant_conf_accuracy": quant_correct / total if total else 0.0,
        "float_pos_avg_iou": float(f_ious.mean()) if f_ious.numel() else 0.0,
        "quant_pos_avg_iou": float(q_ious.mean()) if q_ious.numel() else 0.0,
        "float_pos_iou_gt_0p5": float((f_ious > 0.5).float().mean()) if f_ious.numel() else 0.0,
        "quant_pos_iou_gt_0p5": float((q_ious > 0.5).float().mean()) if q_ious.numel() else 0.0,
        "float_bbox_mae_pos": float(f_bbox_err.mean()) if f_bbox_err.numel() else 0.0,
        "quant_bbox_mae_pos": float(q_bbox_err.mean()) if q_bbox_err.numel() else 0.0,
        "quant_vs_float_output_mae": float(out_err.mean()) if out_err.numel() else 0.0,
        "quant_vs_float_conf_mae": float(conf_err.mean()) if conf_err.numel() else 0.0,
    }


def export_blocked_params(layers: list[dict[str, Any]], export_path: Path) -> int:
    export_path.parent.mkdir(parents=True, exist_ok=True)
    cur_word = 0
    with export_path.open("w", encoding="ascii") as f:
        f.write("@00000000\n")
        for layer in layers:
            q_weight = layer["q_weight"]
            if layer["kind"] == "fc":
                q_weight = permute_fc_weights_for_npu(q_weight, int(layer["prev_per_oc"]))

            kernel = int(layer["kernel"])
            cout = int(q_weight.shape[0])
            cin = int(q_weight.shape[1])
            oc_groups = (cout + 15) // 16
            cin_groups = (cin + 15) // 16
            block_words = (16 * 16 * kernel * kernel) // 4

            w_start = cur_word
            for oc_g in range(oc_groups):
                for cin_g in range(cin_groups):
                    block = _build_weight_block(q_weight, kernel, oc_g, cin_g)
                    for line in _bytes_to_hex_lines(block):
                        f.write(line + "\n")
                    cur_word += block_words

            b_start = cur_word
            for oc_g in range(oc_groups):
                block = _build_bias_block(layer["q_bias"], oc_g)
                for line in _bytes_to_hex_lines(block):
                    f.write(line + "\n")
                cur_word += 16

            s_start = cur_word
            f.write(f"{int(layer['shift']) & 0xFFFFFFFF:08X}\n")
            cur_word += 1

            layer["rom_weight_start"] = w_start
            layer["rom_bias_start"] = b_start
            layer["rom_shift_start"] = s_start

    return cur_word


def serializable_config(
    args: argparse.Namespace,
    dataset_root: Path,
    all_names: list[str],
    calib_names: list[str],
    eval_names: list[str],
    activation_ranges: dict[str, float],
    layers: list[dict[str, Any]],
    metrics: dict[str, Any],
    total_words: int,
) -> dict[str, Any]:
    clean_layers = []
    for layer in layers:
        clean_layers.append({
            key: value for key, value in layer.items()
            if key not in {"q_weight", "q_bias"}
        })

    return {
        "format_version": "npu_face_calibrated_pow2_uint8_v1",
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "training_contract": {
            "source": "face/train.py",
            "input": "120x160 grayscale LBP uint8, model input = image / 255.0",
            "target": "[conf, cx, cy, w, h], normalized 0..1",
            "output_activation": "torch.nn.Hardsigmoid over all 5 outputs",
            "inference_threshold": 0.5,
        },
        "rtl_contract": {
            "activation_dtype": "uint8",
            "weight_dtype": "int8",
            "bias_dtype": "int32 accumulator scale",
            "shift_bits": SHIFT_BITS,
            "hardsigmoid": "((x + 3) * 43) >>> 8",
            "final_byte_scale": FINAL_BYTE_SCALE,
            "final_hw_target_scale": FINAL_HW_TARGET_SCALE,
        },
        "inputs": {
            "weights": str(args.weights),
            "dataset_root": str(dataset_root),
            "split_seed": args.seed,
            "total_images": len(all_names),
            "calib_images": len(calib_names),
            "eval_images": len(eval_names),
            "activation_percentile": args.activation_percentile,
            "activation_margin": args.activation_margin,
        },
        "activation_ranges": activation_ranges,
        "layers": clean_layers,
        "metrics": metrics,
        "export": {
            "hex_path": str(args.output_hex),
            "config_path": str(args.output_config),
            "rom_words": total_words,
        },
    }


def print_layer_table(layers: list[dict[str, Any]]) -> None:
    print()
    print("layer | input_scale | weight_scale | out_scale | shift | qweight | qbias")
    print("-" * 92)
    for layer in layers:
        print(
            f"{layer['name']:>5} | "
            f"{layer['input_scale']:.6e} | "
            f"{layer['weight_scale']:.6e} | "
            f"{layer['output_scale']:.6e} | "
            f"{layer['shift']:>5} | "
            f"[{layer['q_weight_min']:>4},{layer['q_weight_max']:>4}] | "
            f"[{layer['q_bias_min']:>11},{layer['q_bias_max']:>11}]"
        )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Calibrate and export FaceNet NPU INT8 parameters.")
    parser.add_argument("--weights", type=Path, default=NPU_IP_ROOT / "params" / "fpga_face_net.pth")
    parser.add_argument("--dataset-root", type=Path, default=NPU_IP_ROOT / "face" / "LBP_Dataset")
    parser.add_argument("--output-hex", type=Path, default=NPU_IP_ROOT / "params" / "npu_params.hex")
    parser.add_argument("--output-config", type=Path, default=NPU_IP_ROOT / "params" / "quant_config.json")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--calib-samples", type=int, default=2048)
    parser.add_argument("--eval-samples", type=int, default=2048)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--activation-percentile", type=float, default=100.0)
    parser.add_argument("--activation-margin", type=float, default=1.05)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    device = torch.device(args.device)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    model = FPGALightFaceNet().to(device)
    state = _torch_load_state(args.weights)
    model.load_state_dict(state)
    model.eval()

    all_names, train_names, val_names = make_contract_split(args.dataset_root, args.seed)
    calib_names = train_names[: args.calib_samples] if args.calib_samples > 0 else train_names
    eval_names = val_names[: args.eval_samples] if args.eval_samples > 0 else val_names
    if not calib_names:
        raise SystemExit("no calibration images selected")
    if not eval_names:
        raise SystemExit("no evaluation images selected")

    calib_loader = DataLoader(
        LBPContractDataset(args.dataset_root, calib_names),
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
    )
    eval_loader = DataLoader(
        LBPContractDataset(args.dataset_root, eval_names),
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
    )

    print(f"Loaded weights: {args.weights}")
    print(f"Dataset: {args.dataset_root} ({len(all_names)} images)")
    print(f"Calibration images: {len(calib_names)}, evaluation images: {len(eval_names)}")
    print(f"Device: {device}")

    activation_ranges = calibrate_activation_ranges(
        model=model,
        loader=calib_loader,
        device=device,
        percentile=args.activation_percentile,
    )
    layers = build_quantized_layers(model, activation_ranges, args.activation_margin)
    print_layer_table(layers)

    total_words = export_blocked_params(layers, args.output_hex)
    metrics = evaluate_models(model, layers, eval_loader, device)

    config = serializable_config(
        args=args,
        dataset_root=args.dataset_root,
        all_names=all_names,
        calib_names=calib_names,
        eval_names=eval_names,
        activation_ranges=activation_ranges,
        layers=layers,
        metrics=metrics,
        total_words=total_words,
    )
    args.output_config.parent.mkdir(parents=True, exist_ok=True)
    args.output_config.write_text(json.dumps(config, indent=2), encoding="utf-8")

    print()
    print(f"Exported HEX: {args.output_hex}")
    print(f"Exported config: {args.output_config}")
    print(f"ROM words: {total_words}")
    print()
    print("Evaluation")
    for key, value in metrics.items():
        if isinstance(value, float):
            print(f"  {key}: {value:.6f}")
        else:
            print(f"  {key}: {value}")

    forced = [layer["name"] for layer in layers if layer["scale_forced_by_weight_range"]]
    if forced:
        print()
        print("Warning: target output scale was too small for these layers; weight range forced the scale:")
        print("  " + ", ".join(forced))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
