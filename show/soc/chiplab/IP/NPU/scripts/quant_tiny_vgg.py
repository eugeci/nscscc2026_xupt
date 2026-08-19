#!/usr/bin/env python3
"""Quantize and export NPU TinyVGG variants for the SoC NPU.

The trained model consumes CIFAR-style float input in [0, 1] and subtracts
``input_shift=0.5`` before the first convolution. The NPU sees unsigned bytes,
so layer 0 is lowered as:

  padded raw uint8 CHW input: 3x34x34, border=128
  first Conv2d: kernel=3, padding=0, bias folded by ``-0.5 * sum(weight)``

This preserves the model's zero-padding semantics closely enough for the
integer datapath while using the layer-0 packed preload path.
"""

from __future__ import annotations

import argparse
import json
import math
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
TINY_VGG_ROOT = PROJECTS_ROOT / "tiny_vgg_cnn"

if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))
if str(TINY_VGG_ROOT) not in sys.path:
    sys.path.insert(0, str(TINY_VGG_ROOT))

from quant_int8 import (  # noqa: E402
    _build_bias_block,
    _build_weight_block,
    _bytes_to_hex_lines,
    permute_fc_weights_for_npu,
)

from model import build_model  # noqa: E402
from synthetic_data import SyntheticCIFAR10  # noqa: E402


RAW_H = 32
RAW_W = 32
PADDED_H = 34
PADDED_W = 34
INPUT_CHANNELS = 3
INPUT_SCALE = 1.0 / 255.0
INPUT_SHIFT = 0.5
BORDER_U8 = 128
SHIFT_BITS = 4
MAX_SHIFT = (1 << SHIFT_BITS) - 1
ACT_RELU = "relu"


def _torch_load(path: Path) -> dict[str, Any]:
    try:
        return torch.load(str(path), map_location="cpu", weights_only=True)
    except TypeError:
        return torch.load(str(path), map_location="cpu")


def load_tiny_vgg(weights: Path, variant: str) -> tuple[nn.Module, dict[str, Any]]:
    model = build_model(variant)
    ckpt = _torch_load(weights)
    state = ckpt.get("model_state_dict", ckpt) if isinstance(ckpt, dict) else ckpt
    model.load_state_dict(state)
    model.eval()
    return model, ckpt if isinstance(ckpt, dict) else {}


def conv_output_dim(size: int, kernel: int, padding: int) -> int:
    return size + 2 * padding - kernel + 1


def build_lowered_layers(model: nn.Module) -> list[dict[str, Any]]:
    layers: list[dict[str, Any]] = []
    cur_h, cur_w = PADDED_H, PADDED_W
    pending_pool = False
    conv_index = 0

    def attach_pool() -> None:
        nonlocal cur_h, cur_w, pending_pool
        if not layers or pending_pool:
            raise ValueError("unexpected MaxPool placement in TinyVGG features")
        layers[-1]["pool"] = True
        layers[-1]["output_h"] //= 2
        layers[-1]["output_w"] //= 2
        cur_h, cur_w = int(layers[-1]["output_h"]), int(layers[-1]["output_w"])
        pending_pool = True

    for module in model.features:
        if isinstance(module, nn.Conv2d):
            weight = module.weight.detach().cpu().clone()
            if module.bias is None:
                bias = torch.zeros(module.out_channels)
            else:
                bias = module.bias.detach().cpu().clone()

            kernel = int(module.kernel_size[0])
            if kernel != 3 or int(module.stride[0]) != 1:
                raise ValueError(f"unsupported TinyVGG Conv2d: {module}")

            if conv_index == 0:
                padding = 0
                folded_bias = bias - INPUT_SHIFT * weight.sum(dim=(1, 2, 3))
            else:
                padding = int(module.padding[0])
                folded_bias = bias

            conv_h = conv_output_dim(cur_h, kernel, padding)
            conv_w = conv_output_dim(cur_w, kernel, padding)
            layers.append({
                "index": len(layers),
                "name": f"C{conv_index + 1}",
                "kind": "conv",
                "is_fc": False,
                "kernel": kernel,
                "padding": padding,
                "pool": False,
                "activation": ACT_RELU,
                "cin": int(weight.shape[1]),
                "cout": int(weight.shape[0]),
                "input_h": cur_h,
                "input_w": cur_w,
                "conv_out_h": conv_h,
                "conv_out_w": conv_w,
                "output_h": conv_h,
                "output_w": conv_w,
                "prev_per_oc": conv_h * conv_w,
                "weight": weight,
                "bias": folded_bias,
                "source_padding": int(module.padding[0]),
                "lowering": "input_shift_bias_fold_valid_padded_input" if conv_index == 0 else "direct",
            })
            cur_h, cur_w = conv_h, conv_w
            pending_pool = False
            conv_index += 1
        elif isinstance(module, nn.ReLU):
            continue
        elif isinstance(module, nn.MaxPool2d):
            attach_pool()
        else:
            raise ValueError(f"unsupported TinyVGG feature module: {module}")

    classifier = model.classifier
    if not isinstance(classifier, nn.Linear):
        raise ValueError(f"unsupported TinyVGG classifier: {classifier}")

    fc_in = int(classifier.weight.shape[1])
    flat = int(layers[-1]["cout"] * cur_h * cur_w)
    if flat != fc_in:
        raise ValueError(f"FC input mismatch: lowered shape {flat}, classifier expects {fc_in}")

    layers.append({
        "index": len(layers),
        "name": "FC1",
        "kind": "fc",
        "is_fc": True,
        "kernel": 1,
        "padding": 0,
        "pool": False,
        "activation": ACT_RELU,
        "cin": fc_in,
        "cout": int(classifier.weight.shape[0]),
        "input_h": 1,
        "input_w": 1,
        "conv_out_h": 1,
        "conv_out_w": 1,
        "output_h": 1,
        "output_w": 1,
        "prev_per_oc": cur_h * cur_w,
        "weight": classifier.weight.detach().cpu().clone(),
        "bias": classifier.bias.detach().cpu().clone()
        if classifier.bias is not None else torch.zeros(classifier.out_features),
        "lowering": "flattened_fc",
    })

    return layers


def pad_chw_u8(raw_chw: np.ndarray) -> np.ndarray:
    raw = np.asarray(raw_chw, dtype=np.uint8)
    if raw.shape != (INPUT_CHANNELS, RAW_H, RAW_W):
        raise ValueError(f"expected raw input shape {(INPUT_CHANNELS, RAW_H, RAW_W)}, got {raw.shape}")
    padded = np.full((INPUT_CHANNELS, PADDED_H, PADDED_W), BORDER_U8, dtype=np.uint8)
    padded[:, 1:-1, 1:-1] = raw
    return padded


def choose_calib_images(tiny_vgg_root: Path, count: int, seed: int) -> tuple[torch.Tensor, str]:
    count = max(1, int(count))
    try:
        import torchvision

        ds = torchvision.datasets.CIFAR10(root=str(tiny_vgg_root / "data"), train=True, download=False)
        rng = np.random.RandomState(seed)
        indices = rng.choice(len(ds), size=min(count, len(ds)), replace=False)
        imgs = []
        for idx in indices:
            img, _ = ds[int(idx)]
            imgs.append(np.asarray(img, dtype=np.float32).transpose(2, 0, 1) / 255.0)
        return torch.from_numpy(np.stack(imgs, axis=0)), "cifar10_train"
    except Exception:
        samples_per_class = max(1, math.ceil(count / 10))
        ds = SyntheticCIFAR10(train=True, transform=None,
                              samples_per_class=samples_per_class, seed=seed)
        imgs = []
        for idx in range(min(count, len(ds))):
            img, _ = ds[idx]
            imgs.append(img)
        return torch.stack(imgs, dim=0), "synthetic_train"


def choose_eval_images(tiny_vgg_root: Path, count: int, seed: int) -> tuple[torch.Tensor, np.ndarray, str]:
    count = max(0, int(count))
    if count == 0:
        return torch.empty(0, INPUT_CHANNELS, RAW_H, RAW_W), np.empty(0, dtype=np.int64), "none"
    try:
        import torchvision

        ds = torchvision.datasets.CIFAR10(root=str(tiny_vgg_root / "data"), train=False, download=False)
        rng = np.random.RandomState(seed + 1000)
        indices = rng.choice(len(ds), size=min(count, len(ds)), replace=False)
        imgs = []
        labels = []
        for idx in indices:
            img, label = ds[int(idx)]
            imgs.append(np.asarray(img, dtype=np.float32).transpose(2, 0, 1) / 255.0)
            labels.append(int(label))
        return torch.from_numpy(np.stack(imgs, axis=0)), np.asarray(labels, dtype=np.int64), "cifar10_test"
    except Exception:
        samples_per_class = max(1, math.ceil(count / 10))
        ds = SyntheticCIFAR10(train=False, transform=None,
                              samples_per_class=samples_per_class, seed=seed)
        imgs = []
        labels = []
        for idx in range(min(count, len(ds))):
            img, label = ds[idx]
            imgs.append(img)
            labels.append(label)
        return torch.stack(imgs, dim=0), np.asarray(labels, dtype=np.int64), "synthetic_test"


def load_demo_input(path: Path) -> np.ndarray:
    data = np.fromfile(path, dtype=np.uint8)
    if data.size != INPUT_CHANNELS * RAW_H * RAW_W:
        raise ValueError(f"{path}: expected {INPUT_CHANNELS * RAW_H * RAW_W} bytes, got {data.size}")
    return data.reshape(INPUT_CHANNELS, RAW_H, RAW_W)


def forward_float_layers(padded_u8: torch.Tensor, layers: list[dict[str, Any]]) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    x = padded_u8.float() * INPUT_SCALE
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
    raw_float_chw: torch.Tensor,
    layers: list[dict[str, Any]],
    percentile: float,
    device: torch.device,
    batch_size: int,
) -> dict[str, float]:
    ranges = {layer["name"]: 0.0 for layer in layers}
    with torch.no_grad():
        for start in range(0, len(raw_float_chw), batch_size):
            raw = raw_float_chw[start:start + batch_size]
            raw_u8 = torch.round(raw * 255.0).clamp(0, 255).to(torch.uint8).cpu().numpy()
            padded = np.stack([pad_chw_u8(item) for item in raw_u8], axis=0)
            padded_t = torch.from_numpy(padded).to(device)
            _out, acts = forward_float_layers(padded_t, layers)
            for layer in layers:
                value = acts[layer["name"]].detach()
                if percentile >= 100.0:
                    stat = value.max()
                else:
                    stat = torch.quantile(value.flatten(), percentile / 100.0)
                ranges[layer["name"]] = max(ranges[layer["name"]], float(stat.cpu()))
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


def forward_quantized_runtime(padded_u8: torch.Tensor, layers: list[dict[str, Any]], device: torch.device) -> torch.Tensor:
    x = padded_u8.to(device=device, dtype=torch.float32)
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


def c_symbol_prefix(target: str) -> str:
    if target == "npu_vgg_s0_v1":
        return "npu_vgg_s0"
    if target == "npu_vgg_s1_v1":
        return "npu_vgg_s1"
    if target == "npu_vgg_s2b_v1":
        return "npu_vgg_s2b"
    return target.replace("_v1", "").replace("-", "_")


def write_demo_header(
    path: Path,
    target: str,
    raw_sample_path: Path,
    padded_input: np.ndarray,
    scores: np.ndarray,
) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    prefix = c_symbol_prefix(target)
    macro = prefix.upper()
    input_bytes = int(padded_input.size)
    score_bytes = [int(v) for v in scores.reshape(-1).astype(np.uint8).tolist()]
    result_bytes = 10
    checksum = checksum_xor32(score_bytes, result_bytes)
    pred = int(np.argmax(score_bytes[:result_bytes]))
    input_flat = [int(v) for v in padded_input.reshape(-1).tolist()]

    with path.open("w", encoding="ascii") as f:
        f.write("// Auto-generated by quant_tiny_vgg.py\n")
        f.write("// Do not hand-edit.\n\n")
        f.write(f"#ifndef {macro}_INPUT_H\n#define {macro}_INPUT_H\n\n")
        f.write('#include "npu.h"\n\n')
        f.write(f"#define {macro}_INPUT_BYTES {input_bytes}u\n")
        f.write(f"#define {macro}_RESULT_BYTES {result_bytes}u\n")
        f.write(f"#define {macro}_PREDICTED_CLASS {pred}u\n")
        f.write(f"#define {macro}_EXPECTED_CLASS {pred}u\n")
        f.write(f"#define {macro}_EXPECTED_CHECKSUM 0x{checksum:08X}u\n\n")
        f.write(f'static const char {prefix}_fixture_name[] = "{raw_sample_path.name}:3x34x34_border128";\n\n')
        f.write(f"static const U8 {prefix}_expected_scores[{macro}_RESULT_BYTES] = {{\n")
        for i in range(0, result_bytes, 10):
            chunk = score_bytes[i:i + 10]
            f.write("    " + ", ".join(f"{v}u" for v in chunk) + ",\n")
        f.write("};\n\n")
        f.write(f"static const U8 {prefix}_input[{macro}_INPUT_BYTES] = {{\n")
        for i in range(0, len(input_flat), 16):
            chunk = input_flat[i:i + 16]
            f.write("    " + ", ".join(f"{v}u" for v in chunk) + ",\n")
        f.write("};\n\n")
        f.write(f"#endif // {macro}_INPUT_H\n")

    return {
        "sample_path": str(raw_sample_path),
        "input_bytes": input_bytes,
        "expected_class": pred,
        "predicted_class": pred,
        "scores_u8": score_bytes[:result_bytes],
        "checksum_xor32": checksum,
        "header": str(path),
    }


def evaluate_samples(
    eval_float: torch.Tensor,
    labels: np.ndarray,
    layers: list[dict[str, Any]],
    device: torch.device,
    batch_size: int,
) -> dict[str, Any]:
    if len(eval_float) == 0:
        return {"samples": 0, "quant_sample_accuracy": None, "details": []}
    correct = 0
    details = []
    with torch.no_grad():
        for start in range(0, len(eval_float), batch_size):
            raw = eval_float[start:start + batch_size]
            raw_u8 = torch.round(raw * 255.0).clamp(0, 255).to(torch.uint8).cpu().numpy()
            padded = np.stack([pad_chw_u8(item) for item in raw_u8], axis=0)
            scores = forward_quantized_runtime(torch.from_numpy(padded), layers, device).cpu().numpy()
            for local, score in enumerate(scores):
                idx = start + local
                label = int(labels[idx]) if idx < len(labels) else None
                pred = int(np.argmax(score[:10]))
                if label is not None and pred == label:
                    correct += 1
                if len(details) < 32:
                    details.append({
                        "index": idx,
                        "label": label,
                        "pred": pred,
                        "scores_u8": [int(v) for v in score[:10]],
                    })
    return {
        "samples": int(len(eval_float)),
        "quant_sample_accuracy": correct / len(eval_float),
        "details": details,
    }


def clean_layer_for_json(layer: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value for key, value in layer.items()
        if key not in {"q_weight", "q_bias"}
    }


def write_quant_config(
    args: argparse.Namespace,
    target: str,
    variant: str,
    ckpt: dict[str, Any],
    layers: list[dict[str, Any]],
    activation_ranges: dict[str, float],
    metrics: dict[str, Any],
    demo: dict[str, Any],
    total_words: int,
    calib_source: str,
    eval_source: str,
) -> None:
    config = {
        "format_version": "npu_tiny_vgg_pow2_uint8_v1",
        "target": target,
        "variant": variant,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "source": {
            "weights": str(args.weights),
            "tiny_vgg_root": str(args.tiny_vgg_root),
            "checkpoint_epoch": ckpt.get("epoch"),
            "checkpoint_test_acc": ckpt.get("test_acc"),
            "model": "NPUTinyVGG, Conv-ReLU-Pool blocks + Linear classifier",
        },
        "lowering": {
            "input": "3x32x32 raw uint8 CHW fixture is padded to 3x34x34 with border value 128",
            "preload": "packed layer-0 preload; BCU reads linear CHW bytes via cross-bank addressing",
            "layer0": "original Conv2d padding=1 becomes software-padded input + Conv2d VALID",
            "input_shift": "model subtracts 0.5; first-layer bias is folded by -0.5 * sum(weight)",
            "final_activation": "ReLU, because current descriptor ACT_NONE maps to the ReLU datapath",
        },
        "rtl_contract": {
            "activation_dtype": "uint8",
            "weight_dtype": "int8",
            "bias_dtype": "int32 accumulator scale",
            "shift_bits": SHIFT_BITS,
            "input_scale": INPUT_SCALE,
            "packed_input_shape_chw": [INPUT_CHANNELS, PADDED_H, PADDED_W],
            "packed_input_bytes": INPUT_CHANNELS * PADDED_H * PADDED_W,
        },
        "inputs": {
            "calib_samples": args.calib_samples,
            "calib_source": calib_source,
            "eval_samples": args.eval_samples,
            "eval_source": eval_source,
            "activation_percentile": args.activation_percentile,
            "activation_margin": args.activation_margin,
            "demo_input_bin": str(args.demo_input_bin),
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
            f"{str(layer['weight_shape']):<18} | {layer['shift']:>5} | "
            f"[{layer['q_weight_min']:>4},{layer['q_weight_max']:>4}] | "
            f"[{layer['q_bias_min']:>11},{layer['q_bias_max']:>11}] | "
            f"{layer.get('rom_weight_start', -1)},{layer.get('rom_bias_start', -1)},"
            f"{layer.get('rom_shift_start', -1)}"
        )


def target_to_variant(target: str, requested: str | None) -> str:
    if requested:
        return requested
    if target == "npu_vgg_s1_v1":
        return "npu_s1"
    if target == "npu_vgg_s2b_v1":
        return "npu_s2b"
    raise ValueError(f"cannot infer TinyVGG variant from target {target!r}")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Quantize/export NPU TinyVGG for the SoC NPU.")
    parser.add_argument("--target", default="npu_vgg_s1_v1",
                        choices=["npu_vgg_s1_v1", "npu_vgg_s2b_v1"])
    parser.add_argument("--variant", choices=["npu_s1", "npu_s2b"])
    parser.add_argument("--tiny-vgg-root", type=Path, default=TINY_VGG_ROOT)
    parser.add_argument("--weights", type=Path, default=TINY_VGG_ROOT / "checkpoints" / "npu_s1_raw" / "tiny_vgg_best.pth")
    parser.add_argument("--dataset-root", type=Path, default=TINY_VGG_ROOT / "data")
    parser.add_argument("--demo-input-bin", type=Path, default=TINY_VGG_ROOT / "artifacts" / "npu_vgg_s1" / "input_chw_u8.bin")
    parser.add_argument("--output-hex", type=Path, default=NPU_IP_ROOT / "params" / "npu_vgg_s1" / "npu_params.hex")
    parser.add_argument("--output-config", type=Path, default=NPU_IP_ROOT / "params" / "npu_vgg_s1" / "quant_config.json")
    parser.add_argument("--output-demo-header", type=Path, default=REPO_ROOT / "sdk" / "software" / "examples" / "npu_demo" / "models" / "npu_vgg_s1_input.h")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--calib-samples", type=int, default=1024)
    parser.add_argument("--eval-samples", type=int, default=0)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--activation-percentile", type=float, default=99.9)
    parser.add_argument("--activation-margin", type=float, default=1.10)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    variant = target_to_variant(args.target, args.variant)
    device = torch.device(args.device)

    model, ckpt = load_tiny_vgg(args.weights, variant)
    layers_float = build_lowered_layers(model)
    calib, calib_source = choose_calib_images(args.tiny_vgg_root, args.calib_samples, args.seed)
    activation_ranges = calibrate_activation_ranges(
        raw_float_chw=calib,
        layers=layers_float,
        percentile=args.activation_percentile,
        device=device,
        batch_size=args.batch_size,
    )
    layers = quantize_layers(layers_float, activation_ranges, args.activation_margin)
    total_words = export_blocked_params(layers, args.output_hex)

    eval_float, eval_labels, eval_source = choose_eval_images(args.tiny_vgg_root, args.eval_samples, args.seed)
    metrics = evaluate_samples(eval_float, eval_labels, layers, device, args.batch_size)

    raw_demo = load_demo_input(args.demo_input_bin)
    padded_demo = pad_chw_u8(raw_demo)
    with torch.no_grad():
        demo_scores = forward_quantized_runtime(
            torch.from_numpy(padded_demo[None, :, :, :]),
            layers,
            device,
        ).cpu().numpy()[0, :10]
    demo = write_demo_header(
        path=args.output_demo_header,
        target=args.target,
        raw_sample_path=args.demo_input_bin,
        padded_input=padded_demo,
        scores=demo_scores,
    )
    write_quant_config(
        args=args,
        target=args.target,
        variant=variant,
        ckpt=ckpt,
        layers=layers,
        activation_ranges=activation_ranges,
        metrics=metrics,
        demo=demo,
        total_words=total_words,
        calib_source=calib_source,
        eval_source=eval_source,
    )

    print(f"Loaded weights: {args.weights}")
    print(f"Variant: {variant} target={args.target}")
    print(f"Calibration: {len(calib)} samples from {calib_source}")
    print(f"Device: {device}")
    print_layer_table(layers)
    print()
    print(f"Exported HEX: {args.output_hex}")
    print(f"Exported config: {args.output_config}")
    print(f"Exported demo header: {args.output_demo_header}")
    print(f"ROM words: {total_words}")
    print(f"Demo: pred={demo['predicted_class']} scores={demo['scores_u8']} "
          f"checksum=0x{demo['checksum_xor32']:08X} input_bytes={demo['input_bytes']}")
    if metrics["samples"]:
        print(f"Eval: {metrics['quant_sample_accuracy']:.6f} on {metrics['samples']} samples from {eval_source}")

    forced = [layer["name"] for layer in layers if layer["scale_forced_by_weight_range"]]
    if forced:
        print()
        print("Warning: target output scale was too small for these layers; weight range forced the scale:")
        print("  " + ", ".join(forced))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
