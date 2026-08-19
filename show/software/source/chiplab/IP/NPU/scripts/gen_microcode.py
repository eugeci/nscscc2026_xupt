"""
gen_microcode.py
================

为 FPGALightFaceNet (10 层) 生成 NPU 64-bit 微码 hex 文件, 输出至
``../sim/microcode_face.hex``。

微码字段布局 (与 NPU/spec_v0.1.md §6 / npu_sequencer.v 对齐)::

    [63]    is_fc_mode
    [62:61] activation_type    (00=ReLU, 01=HardSigmoid)
    [60]    pool_en
    [59:58] kernel_size        (00=1x1, 01=2x2, 10=3x3)
    [57:48] cin_total          (10b)
    [47:38] cout_total         (10b)
    [37:28] img_width          (10b, layer 输入宽)
    [27:18] img_height         (10b, layer 输入高)
    [17:14] shift_bits         ( 4b, 量化反缩放右移)
    [13]    padding_en         ( 1b, 显式 padding 开关; npu_core_top 与 kernel==3x3 OR 派生组合)
    [12:0]  reserved (=0)

输入分辨率 (LBP): 160 x 120, 单通道。

如果 ``../params/fpga_face_net.pth`` 存在, 脚本会加载权重并按 ``quant_int8.py``
的对称绝对最大值法计算每层 ``shift_n = ceil(log2(1/w_scale))``, 截到 4 位;
否则使用 ``DEFAULT_SHIFT`` 占位 (需在真实推理前由校准脚本覆盖)。

硬件约束 (Step 14.1b 后的现状, 脚本会在终端打印警告):
- ``LBP 输入 (Layer-0)``: 使用 lbp_input_buffer (20K 深) 单独路由,
  支持任意 ≤ 20480 像素的帧，当前 160x120=19200 合法。
- ``其他 layer 激活存储``: fm_bank_array (16 banks x 8K 深)，单 bank
  最大为 4800 (C2 80x60), 安全余量 70%。
- ``Cout > 16``: 由 sequencer Cout 分组处理 (已支持)。
- ``Cin > 16``: 由 sequencer Cin 分组处理 (已支持, Step 14.1b)。
  转换原则：[oc_g][cin_g][16 cout × 16 cin × k²] (oc-major)。
  PSUM 在同一 oc_group 的多个 cin_group 之间持久存于 channel_accumulator。
- ``Cin > 256`` 或 ``Cout > 256``: 实现限制 (sequencer cin_group_idx/oc_group_idx 均 4-bit)。
"""

import argparse
import json
import math
import os
from pathlib import Path

NPU_IP_ROOT = Path(__file__).resolve().parent.parent
HEX_PATH = NPU_IP_ROOT / "sim" / "microcode_face.hex"
PTH_PATH = NPU_IP_ROOT / "params" / "fpga_face_net.pth"
QUANT_CONFIG_PATH = NPU_IP_ROOT / "params" / "quant_config.json"
ROM_DEPTH = 32          # 必须与 npu_sequencer.v 中 microcode_rom 容量一致
DEFAULT_SHIFT = 8       # 没有 .pth 时的占位 shift_bits
MAX_SHIFT = 15

ACT_RELU = 0b00
ACT_HARDSIG = 0b01

KERNEL_ENC = {1: 0b00, 2: 0b01, 3: 0b10}
SUPPORTED_TARGETS = {
    "facenet_lbp_v1",
    "mnist_lenet_v1",
    "npu_vgg_s1_v1",
    "npu_vgg_s2b_v1",
}


# ============================================================================
# 字段编码
# ============================================================================
def encode_layer(is_fc, act, pool, kernel, cin, cout, w, h, shift, padding=False):
    """按 spec 字段布局打包 64-bit 整数。"""
    if kernel not in KERNEL_ENC:
        raise ValueError(f"Unsupported kernel size: {kernel}")
    if cin >> 10 or cout >> 10 or w >> 10 or h >> 10:
        raise ValueError(
            f"cin/cout/w/h must fit in 10 bits "
            f"(cin={cin}, cout={cout}, w={w}, h={h})"
        )
    if shift >> 4:
        raise ValueError(f"shift_bits must fit in 4 bits (got {shift})")

    word = 0
    word |= (1 if is_fc else 0) << 63
    word |= (act & 0b11) << 61
    word |= (1 if pool else 0) << 60
    word |= (KERNEL_ENC[kernel] & 0b11) << 58
    word |= (cin & 0x3FF) << 48
    word |= (cout & 0x3FF) << 38
    word |= (w & 0x3FF) << 28
    word |= (h & 0x3FF) << 18
    word |= (shift & 0xF) << 14
    word |= (1 if padding else 0) << 13
    return word


# ============================================================================
# 模型 -> 层规格
# ============================================================================
def derive_layer_specs():
    """为 FPGALightFaceNet 列出 10 层规格 (输入空间维度逐层推导)。"""
    layers = []
    cur_w, cur_h = 160, 120

    def add(name, **cfg):
        layers.append({"name": name, **cfg})

    # ---- 卷积主干 (8 层) ----
    # padding 字段映射 PyTorch nn.Conv2d 的 padding=1 (3x3) 与 padding=1 (2x2)
    add("C1", is_fc=False, act=ACT_RELU, pool=True,  kernel=3, padding=True,
        cin=1,  cout=8,  w=cur_w, h=cur_h)
    cur_w, cur_h = cur_w // 2, cur_h // 2          # 80 x 60

    add("C2", is_fc=False, act=ACT_RELU, pool=True,  kernel=3, padding=True,
        cin=8,  cout=16, w=cur_w, h=cur_h)
    cur_w, cur_h = cur_w // 2, cur_h // 2          # 40 x 30

    add("C3", is_fc=False, act=ACT_RELU, pool=False, kernel=1, padding=False,
        cin=16, cout=16, w=cur_w, h=cur_h)         # 40 x 30 (no pool)

    add("C4", is_fc=False, act=ACT_RELU, pool=True,  kernel=3, padding=True,
        cin=16, cout=24, w=cur_w, h=cur_h)
    cur_w, cur_h = cur_w // 2, cur_h // 2          # 20 x 15

    add("C5", is_fc=False, act=ACT_RELU, pool=True,  kernel=3, padding=True,
        cin=24, cout=32, w=cur_w, h=cur_h)
    cur_w, cur_h = cur_w // 2, cur_h // 2          # 10 x 7  (15//2 截断)

    add("C6", is_fc=False, act=ACT_RELU, pool=False, kernel=1, padding=False,
        cin=32, cout=32, w=cur_w, h=cur_h)         # 10 x 7

    add("C7", is_fc=False, act=ACT_RELU, pool=True,  kernel=3, padding=True,
        cin=32, cout=32, w=cur_w, h=cur_h)
    cur_w, cur_h = cur_w // 2, cur_h // 2          # 5 x 3   (7//2 截断)

    # C8: kernel=2, padding=1 -> 输出 (cur+1) x (cur+1) = 6 x 4
    add("C8", is_fc=False, act=ACT_RELU, pool=False, kernel=2, padding=True,
        cin=32, cout=32, w=cur_w, h=cur_h)

    # ---- 全连接 (2 层) ----
    # FC 借用 1x1 conv 通道, NPU 内部把空间维度欺骗为 1x1, 通过 BCU 真实遍历 cin
    add("FC1", is_fc=True, act=ACT_RELU,    pool=False, kernel=1, padding=False,
        cin=768, cout=64, w=1, h=1)                # 32 * 4 * 6 = 768

    add("FC2", is_fc=True, act=ACT_HARDSIG, pool=False, kernel=1, padding=False,
        cin=64,  cout=5,  w=1, h=1)                # HardSigmoid 检测头

    return layers


def derive_layer_specs_from_quant_config(quant_config_path, target):
    """Build generic layer specs from a compiler quant_config.json."""
    quant_config_path = Path(quant_config_path)
    if not quant_config_path.exists():
        raise FileNotFoundError(f"quant config not found: {quant_config_path}")

    with quant_config_path.open("r", encoding="utf-8") as f:
        config = json.load(f)

    cfg_target = config.get("target")
    if cfg_target is not None and cfg_target != target:
        raise ValueError(
            f"{quant_config_path}: target mismatch, config has {cfg_target!r}, "
            f"requested {target!r}"
        )

    layers = []
    for qlayer in config.get("layers", []):
        kind = qlayer.get("kind")
        activation = qlayer.get("activation", "relu")
        if activation == "hardsigmoid":
            act = ACT_HARDSIG
        else:
            act = ACT_RELU

        kernel = int(qlayer.get("kernel", 1))
        if kernel not in KERNEL_ENC:
            raise ValueError(f"{qlayer.get('name')}: unsupported kernel {kernel}")

        shift = int(qlayer["shift"])
        if shift < 0 or shift > MAX_SHIFT:
            raise ValueError(f"{qlayer.get('name')}: shift {shift} does not fit 4 bits")

        layers.append({
            "name": qlayer["name"],
            "is_fc": kind == "fc",
            "act": act,
            "pool": bool(qlayer.get("pool", False)),
            "kernel": kernel,
            "padding": int(qlayer.get("padding", 0)) != 0,
            "cin": int(qlayer["cin"]),
            "cout": int(qlayer["cout"]),
            "w": int(qlayer.get("input_w", 1)),
            "h": int(qlayer.get("input_h", 1)),
            "shift": shift,
        })

    if not layers:
        raise ValueError(f"{quant_config_path}: no layers found")
    return layers


# ============================================================================
# 量化 shift_bits 推导 (优先读取校准配置; 回退到旧 pth 推导)
# ============================================================================
def compute_shifts_from_quant_config(layers, quant_config_path=QUANT_CONFIG_PATH):
    """Load calibrated shift_bits from params/quant_config.json if present."""
    quant_config_path = Path(quant_config_path)
    if not quant_config_path.exists():
        return None

    try:
        with quant_config_path.open("r", encoding="utf-8") as f:
            config = json.load(f)
    except Exception as exc:  # noqa: BLE001
        print(f"[gen_microcode] (warn) failed to load {quant_config_path.name}: {exc}; "
              "falling back to legacy pth-derived shifts.")
        return None

    if config.get("format_version") != "npu_face_calibrated_pow2_uint8_v1":
        print(f"[gen_microcode] (warn) unsupported {quant_config_path.name} format; "
              "falling back to legacy pth-derived shifts.")
        return None

    cfg_layers = config.get("layers", [])
    if len(cfg_layers) != len(layers):
        print(f"[gen_microcode] (warn) {quant_config_path.name} layer count "
              f"{len(cfg_layers)} != {len(layers)}; falling back.")
        return None

    shifts = []
    for spec, qcfg in zip(layers, cfg_layers):
        if qcfg.get("name") != spec["name"]:
            print(f"[gen_microcode] (warn) layer mismatch in {quant_config_path.name}: "
                  f"{qcfg.get('name')} != {spec['name']}; falling back.")
            return None
        shift = int(qcfg["shift"])
        if shift < 0 or shift > 15:
            raise ValueError(f"{spec['name']} shift_bits must fit in 4 bits (got {shift})")
        shifts.append(shift)

    print(f"[gen_microcode] using calibrated shifts from {quant_config_path}")
    return shifts


def compute_shifts_from_pth(layers, pth_path=PTH_PATH):
    """加载 fpga_face_net.pth, 为每个 Conv/Linear 计算 ``shift_n``。
    返回 list[int] 长度与 layers 相同; 如果加载失败, 返回 None。
    """
    pth_path = Path(pth_path)
    if not pth_path.exists():
        print(f"[gen_microcode] (info) {pth_path.name} not found, "
              f"using DEFAULT_SHIFT={DEFAULT_SHIFT} for all layers.")
        return None

    try:
        import torch
        import torch.nn as nn
        from quant_int8 import FPGALightFaceNet, quantize_tensor
    except ModuleNotFoundError as exc:
        dependency = exc.name or "PyTorch/NumPy"
        raise SystemExit(
            f"gen_microcode: cannot use the legacy FaceNet .pth shift fallback "
            f"because optional dependency {dependency!r} is unavailable; "
            "provide a valid --quant-config or install the quantization dependencies"
        ) from exc

    try:
        model = FPGALightFaceNet()
        state = torch.load(str(pth_path), map_location="cpu")
        model.load_state_dict(state)
        model.eval()
    except Exception as exc:  # noqa: BLE001
        print(f"[gen_microcode] (warn) failed to load {pth_path.name}: {exc}; "
              f"falling back to DEFAULT_SHIFT={DEFAULT_SHIFT}.")
        return None

    shifts = []
    layer_iter = (m for _, m in model.named_modules()
                  if isinstance(m, (nn.Conv2d, nn.Linear)))
    for spec, module in zip(layers, layer_iter):
        weight = module.weight.data
        _, w_scale = quantize_tensor(weight, 8)
        if w_scale > 0:
            raw_shift = int(math.ceil(math.log2(1.0 / w_scale)))
        else:
            raw_shift = 0
        clipped = max(0, min(15, raw_shift))
        shifts.append(clipped)
        if clipped != raw_shift:
            print(f"[gen_microcode] (warn) {spec['name']} shift={raw_shift} "
                  f"clipped to {clipped} (4-bit field)")
    return shifts


def compute_shifts(layers, quant_config_path=QUANT_CONFIG_PATH, pth_path=PTH_PATH):
    shifts = compute_shifts_from_quant_config(layers, quant_config_path)
    if shifts is not None:
        return shifts
    return compute_shifts_from_pth(layers, pth_path)


# ============================================================================
# 硬件约束告警
# ============================================================================
def warn_constraints(layers):
    print("=" * 60)
    print("Hardware constraint check (post Step 14.1b):")
    print("=" * 60)

    # LBP 输入尺寸 (lbp_input_buffer 深 20480)
    layer0 = layers[0] if layers else None
    if layer0 is not None:
        in_pixels = layer0['w'] * layer0['h']
        if in_pixels > 20480:
            print(f"  [!] Layer-0 输入像素数 {in_pixels} > lbp_input_buffer 深度 20480")
            print(f"      => 需扩大 lbp_input_buffer 深度\n")
        else:
            print(f"  [ok] Layer-0 LBP 输入 {layer0['w']}x{layer0['h']}={in_pixels} 适配 lbp_input_buffer (20480)")

    # 非 Layer-0 激活存储 (fm_bank_array 单 bank 深 8192)
    # 每 bank 平均素点 = w * h * (Cout 分组顶点), 这里以上限估计
    fm_overflow = []
    for l in layers[1:]:
        out_w = l['w'] if l.get('padding') else (l['w'] - 2 if l['kernel'] == 3 else l['w'])
        out_h = l['h'] if l.get('padding') else (l['h'] - 2 if l['kernel'] == 3 else l['h'])
        if l['pool']:
            out_w //= 2; out_h //= 2
        # Cout 分组后，同一 bank 最多容纳 ceil(cout/16) 个连续块
        groups = (l['cout'] + 15) // 16
        per_bank = out_w * out_h * groups
        if per_bank > 8192:
            fm_overflow.append((l['name'], per_bank))
    if fm_overflow:
        print(f"  [!] fm_bank_array 单 bank 深度 8192 不足:")
        for name, depth in fm_overflow:
            print(f"      - {name} 需 {depth} entries")

    # Cin > 16: 仅 提示会走多组 DMA (信息性，不阻塞)
    cin_grouped = [(l['name'], (l['cin'] + 15) // 16) for l in layers if l['cin'] > 16]
    if cin_grouped:
        print(f"  [info] Cin > 16 走 Cin 分组 (Step 14.1b): "
              f"{', '.join(f'{n}({g}组)' for n, g in cin_grouped)}")

    # Cin > 1024 超过 sequencer cin_group_idx 6-bit 能力
    cin_overflow = [l['name'] for l in layers if l['cin'] > 1024]
    if cin_overflow:
        print(f"  [!] Cin > 1024 (sequencer cin_group_idx 6-bit 上限): "
              f"{', '.join(cin_overflow)}")

    # Cout > 256
    cout_overflow = [l['name'] for l in layers if l['cout'] > 256]
    if cout_overflow:
        print(f"  [!] Cout > 256 (sequencer oc_group_idx 4-bit 上限): "
              f"{', '.join(cout_overflow)}")

    print("=" * 60)


# ============================================================================
# 主入口
# ============================================================================
def build_arg_parser():
    parser = argparse.ArgumentParser(description="Generate NPU microcode.")
    parser.add_argument("--target", default="facenet_lbp_v1",
                        choices=sorted(SUPPORTED_TARGETS),
                        help="Compiler target/topology to encode.")
    parser.add_argument("--weights", type=Path, default=PTH_PATH,
                        help="PyTorch .pth weights used only as a legacy shift fallback.")
    parser.add_argument("--quant-config", type=Path, default=QUANT_CONFIG_PATH,
                        help="Calibrated quantization config containing shift_bits.")
    parser.add_argument("--output-hex", type=Path, default=HEX_PATH,
                        help="Output 64-bit microcode hex file.")
    return parser


def main():
    args = build_arg_parser().parse_args()
    if args.target == "facenet_lbp_v1":
        layers = derive_layer_specs()
        shifts = compute_shifts(layers, args.quant_config, args.weights)
    else:
        layers = derive_layer_specs_from_quant_config(args.quant_config, args.target)
        shifts = [int(layer["shift"]) for layer in layers]

    print(f"\nDerived {len(layers)} layers for {args.target}:")
    print(f"  {'name':<5} {'k':<3} {'cin':<5} {'cout':<5} {'w':<5} {'h':<5} "
          f"{'pad':<4} {'pool':<5} {'act':<8} {'shift':<5}")
    print("  " + "-" * 60)

    encoded = []
    for idx, layer in enumerate(layers):
        shift = shifts[idx] if shifts is not None else int(layer.get("shift", DEFAULT_SHIFT))
        word = encode_layer(
            is_fc=layer['is_fc'], act=layer['act'], pool=layer['pool'],
            kernel=layer['kernel'], cin=layer['cin'], cout=layer['cout'],
            w=layer['w'], h=layer['h'], shift=shift,
            padding=layer.get('padding', False),
        )
        encoded.append(word)
        act_name = {ACT_RELU: "ReLU", ACT_HARDSIG: "HardSig"}[layer['act']]
        print(f"  {layer['name']:<5} {layer['kernel']:<3} {layer['cin']:<5} "
              f"{layer['cout']:<5} {layer['w']:<5} {layer['h']:<5} "
              f"{int(layer.get('padding', False)):<4} "
              f"{int(layer['pool']):<5} {act_name:<8} {shift:<5}")

    warn_constraints(layers)

    # 写出 hex (大写 16 位 hex, 末尾换行; ROM 容量 32, 不足填零)
    args.output_hex.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output_hex, "w", encoding="utf-8", newline="\n") as f:
        for i in range(ROM_DEPTH):
            value = encoded[i] if i < len(encoded) else 0
            f.write(f"{value:016X}\n")

    try:
        rel = os.path.relpath(args.output_hex, Path.cwd())
    except ValueError:
        rel = str(args.output_hex)
    print(f"\nMicrocode written: {rel}  "
          f"({len(encoded)} active + {ROM_DEPTH - len(encoded)} padding lines)")


if __name__ == "__main__":
    main()
