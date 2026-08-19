#!/usr/bin/env python3
"""Quantize and export the PPQ_Mnist LeNet model for the current NPU.

This backend intentionally targets the RTL contract already implemented in the
SoC NPU:

  uint8 activation * int8 weight -> int32 accumulator + int32 bias
  -> ReLU -> arithmetic right shift -> clamp to uint8 -> optional 2x2 maxpool

The source PyTorch model in ../PPQ_Mnist uses Conv + BatchNorm + ReLU + Pool.
BatchNorm is folded into each Conv offline. The original second pool is
MaxPool2d(2, padding=1), which the current RTL does not implement directly.
The lowered NPU topology uses Conv2 padding=1 followed by unpadded 2x2 pool so
the FC input remains 16*2*2 = 64.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

THIS_DIR = Path(__file__).resolve().parent
NPU_IP_ROOT = THIS_DIR.parent
REPO_ROOT = NPU_IP_ROOT.parents[2]
PROJECTS_ROOT = REPO_ROOT.parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from quant_int8 import (  # noqa: E402
    _build_bias_block,
    _build_weight_block,
    _bytes_to_hex_lines,
    permute_fc_weights_for_npu,
)

IMG_H = 28
IMG_W = 28
FRAME_BYTES = 160 * 120
SHIFT_BITS = 4
MAX_SHIFT = (1 << SHIFT_BITS) - 1
INPUT_SCALE = 1.0
ACT_RELU = "relu"


class PPQLeNet(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(1, 4, 3, 1)
        self.bn1 = nn.BatchNorm2d(4)
        self.conv2 = nn.Conv2d(4, 8, 3, 1)
        self.bn2 = nn.BatchNorm2d(8)
        self.conv3 = nn.Conv2d(8, 16, 3, 1)
        self.bn3 = nn.BatchNorm2d(16)
        self.fc1 = nn.Linear(64, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.max_pool2d(F.relu(self.bn1(self.conv1(x))), 2)
        x = F.max_pool2d(F.relu(self.bn2(self.conv2(x))), 2, padding=1)
        x = F.max_pool2d(F.relu(self.bn3(self.conv3(x))), 2)
        return self.fc1(torch.flatten(x, 1))


def _torch_load_state(path: Path) -> dict[str, torch.Tensor]:
    try:
        return torch.load(str(path), map_location="cpu", weights_only=True)
    except TypeError:
        return torch.load(str(path), map_location="cpu")


def load_model(weights: Path) -> PPQLeNet:
    model = PPQLeNet()
    model.load_state_dict(_torch_load_state(weights))
    model.eval()
    return model


def fold_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> tuple[torch.Tensor, torch.Tensor]:
    weight = conv.weight.detach().cpu()
    if conv.bias is None:
        bias = torch.zeros(conv.out_channels)
    else:
        bias = conv.bias.detach().cpu()

    bn_weight = bn.weight.detach().cpu()
    bn_bias = bn.bias.detach().cpu()
    mean = bn.running_mean.detach().cpu()
    var = bn.running_var.detach().cpu()
    scale = bn_weight / torch.sqrt(var + bn.eps)
    folded_weight = weight * scale.reshape(-1, 1, 1, 1)
    folded_bias = (bias - mean) * scale + bn_bias
    return folded_weight, folded_bias


def parse_ppq_main_images(main_c: Path) -> dict[str, np.ndarray]:
    text = main_c.read_text(encoding="utf-8", errors="ignore")
    images: dict[str, np.ndarray] = {}
    pattern = re.compile(
        r"unsigned\s+char\s+(img\d+)\s*\[28\]\s*\[28\]\s*=\s*\{(.*?)\n\};",
        re.S,
    )
    for match in pattern.finditer(text):
        name = match.group(1)
        values = [int(v) for v in re.findall(r"\b\d+\b", match.group(2))]
        if len(values) != IMG_H * IMG_W:
            raise ValueError(f"{main_c}: {name} has {len(values)} values, expected 784")
        images[name] = np.asarray(values, dtype=np.uint8).reshape(IMG_H, IMG_W)
    if not images:
        raise ValueError(f"{main_c}: no img* arrays found")
    return images


def image_label_from_name(name: str) -> int | None:
    m = re.fullmatch(r"img(\d+)", name)
    if not m:
        return None
    label = int(m.group(1))
    return label if 0 <= label <= 9 else None


def choose_calib_names(images: dict[str, np.ndarray], demo_sample: str, limit: int) -> list[str]:
    names = sorted(images)
    if demo_sample in images:
        names.remove(demo_sample)
        names.insert(0, demo_sample)
    if limit > 0:
        names = names[:limit]
    return names


def conv_output_dim(size: int, kernel: int, padding: int) -> int:
    return size + 2 * padding - kernel + 1


def build_folded_layers(model: PPQLeNet) -> list[dict[str, Any]]:
    w1, b1 = fold_conv_bn(model.conv1, model.bn1)
    w2, b2 = fold_conv_bn(model.conv2, model.bn2)
    w3, b3 = fold_conv_bn(model.conv3, model.bn3)

    specs: list[dict[str, Any]] = [
        {
            "name": "C1",
            "kind": "conv",
            "kernel": 3,
            "padding": 0,
            "pool": True,
            "activation": ACT_RELU,
            "weight": w1,
            "bias": b1,
        },
        {
            "name": "C2",
            "kind": "conv",
            "kernel": 3,
            "padding": 1,
            "pool": True,
            "activation": ACT_RELU,
            "weight": w2,
            "bias": b2,
            "lowering_note": "original pool padding=1 lowered as conv padding=1 + pool padding=0",
        },
        {
            "name": "C3",
            "kind": "conv",
            "kernel": 3,
            "padding": 0,
            "pool": True,
            "activation": ACT_RELU,
            "weight": w3,
            "bias": b3,
        },
        {
            "name": "FC1",
            "kind": "fc",
            "kernel": 1,
            "padding": 0,
            "pool": False,
            "activation": ACT_RELU,
            "weight": model.fc1.weight.detach().cpu(),
            "bias": model.fc1.bias.detach().cpu(),
        },
    ]

    cur_h, cur_w = IMG_H, IMG_W
    for index, layer in enumerate(specs):
        layer["index"] = index
        if layer["kind"] == "conv":
            weight = layer["weight"]
            cout, cin = int(weight.shape[0]), int(weight.shape[1])
            kernel = int(layer["kernel"])
            padding = int(layer["padding"])
            conv_h = conv_output_dim(cur_h, kernel, padding)
            conv_w = conv_output_dim(cur_w, kernel, padding)
            out_h, out_w = conv_h, conv_w
            if layer["pool"]:
                out_h //= 2
                out_w //= 2
            layer.update({
                "is_fc": False,
                "cin": cin,
                "cout": cout,
                "input_h": cur_h,
                "input_w": cur_w,
                "conv_out_h": conv_h,
                "conv_out_w": conv_w,
                "output_h": out_h,
                "output_w": out_w,
                "prev_per_oc": conv_h * conv_w,
            })
            cur_h, cur_w = out_h, out_w
        else:
            weight = layer["weight"]
            cin = int(weight.shape[1])
            cout = int(weight.shape[0])
            flat = int(specs[index - 1]["cout"] * cur_h * cur_w)
            if flat != cin:
                raise ValueError(f"FC input mismatch: lowered shape {flat}, weight cin {cin}")
            layer.update({
                "is_fc": True,
                "cin": cin,
                "cout": cout,
                "input_h": 1,
                "input_w": 1,
                "conv_out_h": 1,
                "conv_out_w": 1,
                "output_h": 1,
                "output_w": 1,
                "prev_per_oc": cur_h * cur_w,
            })
            cur_h, cur_w = 1, 1

    return specs


def forward_float_layers(raw_u8: torch.Tensor, layers: list[dict[str, Any]]) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    x = raw_u8.float()
    activations: dict[str, torch.Tensor] = {}
    for layer in layers:
        weight = layer["weight"].to(x.device)
        bias = layer["bias"].to(x.device)
        if layer["kind"] == "conv":
            x = F.conv2d(x, weight, bias=bias, stride=1, padding=int(layer["padding"]))
        else:
            x = torch.flatten(x, 1)
            x = F.linear(x, weight, bias)

        x = F.relu(x)
        activations[layer["name"]] = x
        if layer["pool"]:
            x = F.max_pool2d(x, 2)
    return x, activations


def calibrate_activation_ranges(
    images: dict[str, np.ndarray],
    names: list[str],
    layers: list[dict[str, Any]],
    percentile: float,
    device: torch.device,
) -> dict[str, float]:
    batch = np.stack([images[name] for name in names], axis=0)
    raw = torch.from_numpy(batch).unsqueeze(1).to(device=device, dtype=torch.float32)
    ranges = {layer["name"]: 0.0 for layer in layers}
    with torch.no_grad():
        _out, acts = forward_float_layers(raw, layers)
        for layer in layers:
            value = acts[layer["name"]].detach()
            if percentile >= 100.0:
                stat = value.max()
            else:
                stat = torch.quantile(value.flatten(), percentile / 100.0)
            ranges[layer["name"]] = float(stat.cpu())
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

    output_scale = prev_scale * weight_scale * (2**shift)
    return weight_scale, shift, output_scale, forced


def quantize_layers(
    layers: list[dict[str, Any]],
    activation_ranges: dict[str, float],
    activation_margin: float,
) -> list[dict[str, Any]]:
    quant_layers: list[dict[str, Any]] = []
    prev_scale = INPUT_SCALE

    for layer in layers:
        weight = layer["weight"].detach().cpu()
        bias = layer["bias"].detach().cpu()
        max_abs_weight = float(weight.abs().max())
        min_weight_scale = max_abs_weight / 127.0 if max_abs_weight > 0.0 else 1.0 / 127.0
        target_output_scale = max(activation_ranges[layer["name"]] * activation_margin / 255.0, 1e-12)
        weight_scale, shift, output_scale, forced = choose_weight_scale_shift(
            prev_scale=prev_scale,
            min_weight_scale=min_weight_scale,
            target_output_scale=target_output_scale,
        )
        acc_scale = prev_scale * weight_scale
        q_weight = torch.round(weight / weight_scale).clamp(-128, 127).to(torch.int8).numpy()
        q_bias = torch.round(bias / acc_scale).to(torch.int64).numpy()
        if q_bias.min(initial=0) < -(2**31) or q_bias.max(initial=0) > 2**31 - 1:
            raise OverflowError(f"{layer['name']}: quantized bias does not fit int32")

        item = {k: v for k, v in layer.items() if k not in {"weight", "bias"}}
        item.update({
            "input_scale": prev_scale,
            "weight_scale": weight_scale,
            "min_weight_scale": min_weight_scale,
            "acc_scale": acc_scale,
            "target_output_scale": target_output_scale,
            "output_scale": output_scale,
            "shift": shift,
            "scale_forced_by_weight_range": forced,
            "activation_calib_amax": activation_ranges[layer["name"]],
            "activation_margin": activation_margin,
            "q_weight": q_weight,
            "q_bias": q_bias.astype(np.int32),
            "weight_shape": list(q_weight.shape),
            "q_weight_min": int(q_weight.min(initial=0)),
            "q_weight_max": int(q_weight.max(initial=0)),
            "q_bias_min": int(q_bias.min(initial=0)),
            "q_bias_max": int(q_bias.max(initial=0)),
        })
        quant_layers.append(item)
        prev_scale = output_scale

    return quant_layers


def _floor_div_pow2(x: torch.Tensor, shift: int) -> torch.Tensor:
    if shift == 0:
        return torch.floor(x)
    return torch.floor(x / float(2**shift))


def forward_quantized_runtime(raw_u8: torch.Tensor, layers: list[dict[str, Any]], device: torch.device) -> torch.Tensor:
    x = raw_u8.to(device=device, dtype=torch.float32)
    for layer in layers:
        q_weight = torch.from_numpy(layer["q_weight"].astype(np.float32)).to(device)
        q_bias = torch.from_numpy(layer["q_bias"].astype(np.float32)).to(device)
        if layer["kind"] == "conv":
            x = F.conv2d(x, q_weight, bias=q_bias, stride=1, padding=int(layer["padding"]))
        else:
            x = torch.flatten(x, 1)
            x = F.linear(x, q_weight, q_bias)

        acc = torch.round(x)
        act = torch.clamp(acc, min=0.0)
        q = _floor_div_pow2(act, int(layer["shift"]))
        q = torch.clamp(q, 0.0, 255.0)
        if layer["pool"]:
            q = F.max_pool2d(q, 2)
        x = q
    return x.reshape(x.shape[0], -1).to(torch.uint8)


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


def checksum_xor32(data: list[int] | np.ndarray, byte_count: int) -> int:
    values = [int(v) & 0xFF for v in list(data)[:byte_count]]
    checksum = 0
    for i in range(0, byte_count, 4):
        word = 0
        remain = byte_count - i
        word |= values[i]
        if remain > 1:
            word |= values[i + 1] << 8
        if remain > 2:
            word |= values[i + 2] << 16
        if remain > 3:
            word |= values[i + 3] << 24
        checksum ^= word
    return checksum & 0xFFFFFFFF


def write_demo_header(
    path: Path,
    sample_name: str,
    sample_label: int,
    frame: np.ndarray,
    scores: np.ndarray,
) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame_bytes = [0] * FRAME_BYTES
    flat = frame.reshape(-1).astype(np.uint8).tolist()
    frame_bytes[: len(flat)] = [int(v) for v in flat]
    score_bytes = [int(v) for v in scores.reshape(-1).astype(np.uint8).tolist()]
    result_bytes = 10
    checksum = checksum_xor32(score_bytes, result_bytes)
    pred = int(np.argmax(score_bytes[:result_bytes]))

    with path.open("w", encoding="ascii") as f:
        f.write("// Auto-generated by quant_mnist_lenet.py\n")
        f.write("// Do not hand-edit.\n\n")
        f.write("#ifndef MNIST_LENET_INPUT_H\n#define MNIST_LENET_INPUT_H\n\n")
        f.write('#include "npu.h"\n\n')
        f.write(f"#define MNIST_LENET_RESULT_BYTES {result_bytes}u\n")
        f.write(f"#define MNIST_LENET_EXPECTED_CLASS {sample_label}u\n")
        f.write(f"#define MNIST_LENET_PREDICTED_CLASS {pred}u\n")
        f.write(f"#define MNIST_LENET_EXPECTED_CHECKSUM 0x{checksum:08X}u\n\n")
        f.write(f'static const char mnist_lenet_fixture_name[] = "{sample_name}";\n\n')
        f.write("static const U8 mnist_lenet_expected_scores[MNIST_LENET_RESULT_BYTES] = {\n")
        for i in range(0, result_bytes, 10):
            chunk = score_bytes[i:i + 10]
            f.write("    " + ", ".join(f"{v}u" for v in chunk) + ",\n")
        f.write("};\n\n")
        f.write("static const U8 mnist_lenet_frame[NPU_FRAME_PIXELS] = {\n")
        for i in range(0, len(frame_bytes), 16):
            chunk = frame_bytes[i:i + 16]
            f.write("    " + ", ".join(f"{v}u" for v in chunk) + ",\n")
        f.write("};\n\n")
        f.write("#endif // MNIST_LENET_INPUT_H\n")

    return {
        "sample_name": sample_name,
        "expected_class": sample_label,
        "predicted_class": pred,
        "scores_u8": score_bytes[:result_bytes],
        "checksum_xor32": checksum,
        "header": str(path),
    }


def evaluate_samples(
    images: dict[str, np.ndarray],
    layers: list[dict[str, Any]],
    device: torch.device,
) -> dict[str, Any]:
    names = sorted(images)
    batch = np.stack([images[name] for name in names], axis=0)
    raw = torch.from_numpy(batch).unsqueeze(1)
    with torch.no_grad():
        scores = forward_quantized_runtime(raw, layers, device).cpu().numpy()
    correct = 0
    details = []
    for idx, name in enumerate(names):
        label = image_label_from_name(name)
        pred = int(np.argmax(scores[idx, :10]))
        if label is not None and pred == label:
            correct += 1
        details.append({
            "name": name,
            "label": label,
            "pred": pred,
            "scores_u8": [int(v) for v in scores[idx, :10]],
        })
    labeled = sum(1 for name in names if image_label_from_name(name) is not None)
    return {
        "samples": len(names),
        "labeled_samples": labeled,
        "quant_sample_accuracy": correct / labeled if labeled else 0.0,
        "details": details,
    }


def clean_layer_for_json(layer: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value for key, value in layer.items()
        if key not in {"q_weight", "q_bias"}
    }


def write_quant_config(
    args: argparse.Namespace,
    layers: list[dict[str, Any]],
    activation_ranges: dict[str, float],
    metrics: dict[str, Any],
    demo: dict[str, Any],
    total_words: int,
) -> None:
    config = {
        "format_version": "npu_mnist_lenet_pow2_uint8_v1",
        "target": "mnist_lenet_v1",
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "source": {
            "weights": str(args.weights),
            "ppq_dir": str(args.dataset_root),
            "ppq_main_c": str(args.dataset_root / "main.c"),
            "model": "PPQ_Mnist LeNet, Conv-BN-ReLU-Pool x3 + FC",
        },
        "lowering": {
            "input": "28x28 uint8 grayscale, first 784 bytes of the SoC frame buffer",
            "frame_load": "SoC wrapper still requires 160x120 frame fullness; demo header zero-pads after byte 784",
            "pool2_note": "original MaxPool2d(2,padding=1) is lowered as Conv2 padding=1 + unpadded MaxPool2d(2)",
            "final_activation": "ReLU, because current descriptor ACT_NONE maps to the ReLU datapath",
        },
        "rtl_contract": {
            "activation_dtype": "uint8",
            "weight_dtype": "int8",
            "bias_dtype": "int32 accumulator scale",
            "shift_bits": SHIFT_BITS,
            "input_scale": INPUT_SCALE,
        },
        "inputs": {
            "calib_samples": args.calib_samples,
            "activation_percentile": args.activation_percentile,
            "activation_margin": args.activation_margin,
            "demo_sample": args.demo_sample,
        },
        "activation_ranges": activation_ranges,
        "layers": [clean_layer_for_json(layer) for layer in layers],
        "metrics": metrics,
        "demo": demo,
        "export": {
            "hex_path": str(args.output_hex),
            "config_path": str(args.output_config),
            "demo_header": str(args.output_demo_header),
            "rom_words": total_words,
        },
    }
    args.output_config.parent.mkdir(parents=True, exist_ok=True)
    args.output_config.write_text(json.dumps(config, indent=2), encoding="utf-8")


def print_layer_table(layers: list[dict[str, Any]]) -> None:
    print()
    print("layer | kind | in -> out | weight | shift | qweight | qbias | rom(w,b,s)")
    print("-" * 104)
    for layer in layers:
        shape = f"{layer['input_w']}x{layer['input_h']}x{layer['cin']} -> {layer['output_w']}x{layer['output_h']}x{layer['cout']}"
        print(
            f"{layer['name']:>5} | {layer['kind']:<4} | {shape:<24} | "
            f"{str(layer['weight_shape']):<16} | {layer['shift']:>5} | "
            f"[{layer['q_weight_min']:>4},{layer['q_weight_max']:>4}] | "
            f"[{layer['q_bias_min']:>11},{layer['q_bias_max']:>11}] | "
            f"{layer.get('rom_weight_start', -1)},{layer.get('rom_bias_start', -1)},"
            f"{layer.get('rom_shift_start', -1)}"
        )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Quantize/export PPQ_Mnist LeNet for the NPU.")
    parser.add_argument("--weights", type=Path, default=PROJECTS_ROOT / "PPQ_Mnist" / "LeNet.pth")
    parser.add_argument("--dataset-root", type=Path, default=PROJECTS_ROOT / "PPQ_Mnist")
    parser.add_argument("--output-hex", type=Path, default=NPU_IP_ROOT / "params" / "mnist_lenet" / "npu_params.hex")
    parser.add_argument("--output-config", type=Path, default=NPU_IP_ROOT / "params" / "mnist_lenet" / "quant_config.json")
    parser.add_argument("--output-demo-header", type=Path, default=REPO_ROOT / "sdk" / "software" / "examples" / "npu_demo" / "models" / "mnist_lenet_input.h")
    parser.add_argument("--demo-sample", default="img7")
    parser.add_argument("--calib-samples", type=int, default=0,
                        help="Number of PPQ main.c img* samples to calibrate; 0 uses all.")
    parser.add_argument("--activation-percentile", type=float, default=100.0)
    parser.add_argument("--activation-margin", type=float, default=1.10)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    device = torch.device(args.device)
    model = load_model(args.weights)
    layers_float = build_folded_layers(model)

    images = parse_ppq_main_images(args.dataset_root / "main.c")
    if args.demo_sample not in images:
        available = ", ".join(sorted(images))
        raise SystemExit(f"demo sample {args.demo_sample!r} not found; available: {available}")

    calib_names = choose_calib_names(images, args.demo_sample, args.calib_samples)
    activation_ranges = calibrate_activation_ranges(
        images=images,
        names=calib_names,
        layers=layers_float,
        percentile=args.activation_percentile,
        device=device,
    )
    layers = quantize_layers(layers_float, activation_ranges, args.activation_margin)
    total_words = export_blocked_params(layers, args.output_hex)
    metrics = evaluate_samples(images, layers, device)

    demo_label = image_label_from_name(args.demo_sample)
    if demo_label is None:
        raise SystemExit(f"cannot infer label from demo sample {args.demo_sample!r}")
    demo_raw = torch.from_numpy(images[args.demo_sample][None, None, :, :])
    with torch.no_grad():
        demo_scores = forward_quantized_runtime(demo_raw, layers, device).cpu().numpy()[0, :10]
    demo = write_demo_header(
        path=args.output_demo_header,
        sample_name=args.demo_sample,
        sample_label=demo_label,
        frame=images[args.demo_sample],
        scores=demo_scores,
    )
    write_quant_config(args, layers, activation_ranges, metrics, demo, total_words)

    print(f"Loaded weights: {args.weights}")
    print(f"PPQ dir: {args.dataset_root}")
    print(f"Calibration samples: {len(calib_names)} ({', '.join(calib_names)})")
    print(f"Device: {device}")
    print_layer_table(layers)
    print()
    print(f"Exported HEX: {args.output_hex}")
    print(f"Exported config: {args.output_config}")
    print(f"Exported demo header: {args.output_demo_header}")
    print(f"ROM words: {total_words}")
    print(f"Demo: {demo['sample_name']} expected={demo['expected_class']} "
          f"pred={demo['predicted_class']} scores={demo['scores_u8']} "
          f"checksum=0x{demo['checksum_xor32']:08X}")
    print("Sample evaluation:")
    print(f"  quant_sample_accuracy: {metrics['quant_sample_accuracy']:.6f} "
          f"({metrics['labeled_samples']} labeled samples)")
    for item in metrics["details"]:
        print(f"  {item['name']}: label={item['label']} pred={item['pred']} scores={item['scores_u8']}")

    forced = [layer["name"] for layer in layers if layer["scale_forced_by_weight_range"]]
    if forced:
        print()
        print("Warning: target output scale was too small for these layers; weight range forced the scale:")
        print("  " + ", ".join(forced))

    if demo["predicted_class"] != demo["expected_class"]:
        print()
        print("Warning: demo prediction does not match the sample label; postprocess will flag this on board.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
