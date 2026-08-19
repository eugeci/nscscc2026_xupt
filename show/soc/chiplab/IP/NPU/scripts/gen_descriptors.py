#!/usr/bin/env python3
"""
gen_descriptors.py — 从现有 FaceNet microcode + param ROM 生成 descriptor 文件

用法:
    python3 gen_descriptors.py

输出:
    npu_desc.hex — 供 RTL $readmemh 初始化 desc_ram (32 层 × 8 word = 256 行)
    npu_desc.h   — 供 BSP 直接 #include 的 descriptor 常量数组
"""

import argparse
import json
import os
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
NPU_IP_ROOT = os.path.dirname(THIS_DIR)
MICROCODE_HEX = os.path.join(NPU_IP_ROOT, "sim", "microcode_face.hex")

# ---------------------------------------------------------------------------
# FaceNet 10-layer microcode (from microcode_face.hex)
# 格式: 64-bit hex, 字段定义见 npu_sequencer.v:
#   [63]    = is_fc_mode
#   [62:61] = activation_type (0=ReLU, 1=HardSigmoid)
#   [60]    = pool_en
#   [59:58] = kernel_size (0=1×1, 1=2×2, 2=3×3)
#   [57:48] = cin_total
#   [47:38] = cout_total
#   [37:28] = img_width
#   [27:18] = img_height
#   [17:14] = shift_bits
#   [13]    = padding_en
# ---------------------------------------------------------------------------
MICROCODE = [
    0x1801020A01E22000,  # L0: C1  conv 3×3, cin=1,  cout=8,  160×120, pool, ReLU
    0x1808040500F22000,  # L1: C2  conv 3×3, cin=8,  cout=16, 80×60,  pool, ReLU
    0x00100402807A0000,  # L2: C3  conv 1×1, cin=16, cout=16, 80×60,  no-pool, ReLU
    0x18100602807A6000,  # L3: C4  conv 3×3, cin=16, cout=24, 80×60,  pool, ReLU
    0x18180801403E2000,  # L4: C5  conv 3×3, cin=24, cout=32, 40×30,  pool, ReLU
    0x00200800A01E0000,  # L5: C6  conv 1×1, cin=32, cout=32, 40×30,  no-pool, ReLU
    0x18200800A01E2000,  # L6: C7  conv 3×3, cin=32, cout=32, 40×30,  pool, ReLU
    0x04200800500E2000,  # L7: C8  conv 2×2, cin=32, cout=32, 20×15,  pool, ReLU
    0x830010001005C000,  # L8: FC1 FC,     cin=768,cout=64, 1×1,    no-pool, ReLU
    0xA040014010064000,  # L9: FC2 FC,     cin=64, cout=5,  1×1,    no-pool, HardSigmoid
]


def load_microcode_words(path=MICROCODE_HEX, min_active_words=10):
    """Prefer generated sim/microcode_face.hex over the legacy embedded table."""
    if not os.path.exists(path):
        print(f"[gen_descriptors] (warn) {path} not found; using embedded legacy table")
        return MICROCODE

    words = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            text = line.strip()
            if not text or text.startswith("@") or text.startswith("//"):
                continue
            value = int(text, 16)
            if value != 0:
                words.append(value)

    if len(words) < min_active_words:
        print(f"[gen_descriptors] (warn) {path} has only {len(words)} active words; "
              "using embedded legacy table")
        return MICROCODE

    return words

# From npu_param_rom.v (word offsets in blocked parameter image)
WEIGHT_OFFSETS = [0, 593, 1186, 1267, 2452, 4789, 5078, 7415, 8472, 20825]
BIAS_OFFSETS   = [576, 1169, 1250, 2419, 4756, 5045, 7382, 8439, 20760, 21081]

# ---------------------------------------------------------------------------
# Descriptor 位域常量 (与 npu_descriptor_defs.vh / npu_descriptor.h 同步)
# ---------------------------------------------------------------------------
OP_CONV     = 0
OP_FC        = 1
ACT_NONE     = 0
ACT_RELU      = 1
ACT_RELU6     = 2
ACT_LEAKY     = 3
ACT_HARDSIGMOID = 4
POOL_NONE    = 0
POOL_MAX      = 1
PAD_VALID     = 0
PAD_SAME      = 1

HEADER_NAMES = {
    "facenet_lbp_v1": ("FACENET_NUM_LAYERS", "facenet_descriptors"),
    "mnist_lenet_v1": ("MNIST_LENET_NUM_LAYERS", "mnist_lenet_descriptors"),
    "npu_vgg_s1_v1": ("NPU_VGG_S1_NUM_LAYERS", "npu_vgg_s1_descriptors"),
    "npu_vgg_s2b_v1": ("NPU_VGG_S2B_NUM_LAYERS", "npu_vgg_s2b_descriptors"),
}

def field(val, high, low):
    """Extract bit field val[high:low]."""
    mask = (1 << (high - low + 1)) - 1
    return (val >> low) & mask

def decode_microcode(mc):
    """Decode a 64-bit microcode word into a dict of fields.

    Field map (from npu_sequencer.v):
      [63]    = is_fc_mode
      [62:61] = activation_type
      [60]    = pool_en
      [59:58] = kernel_size
      [57:48] = cin_total
      [47:38] = cout_total
      [37:28] = img_width
      [27:18] = img_height
      [17:14] = shift_bits
      [13]    = padding_en
    """
    return {
        'is_fc':       field(mc, 63, 63),
        'activation':  field(mc, 62, 61),
        'pool_en':     field(mc, 60, 60),
        'kernel_size': field(mc, 59, 58),
        'cin_total':   field(mc, 57, 48),
        'cout_total':  field(mc, 47, 38),
        'img_width':   field(mc, 37, 28),
        'img_height':  field(mc, 27, 18),
        'shift_bits':  field(mc, 17, 14),
        'padding_en':  field(mc, 13, 13),
    }

def calc_output_dims(mc_decoded):
    """Calculate output spatial dimensions from microcode fields."""
    w = mc_decoded['img_width']
    h = mc_decoded['img_height']
    if mc_decoded['is_fc']:
        return 1, 1

    ks = mc_decoded['kernel_size']
    pool = mc_decoded['pool_en']
    k = {0: 1, 1: 2, 2: 3}[ks]

    if k == 1:
        ow, oh = w, h
    elif k == 2:
        if mc_decoded['padding_en']:
            ow, oh = w + 1, h + 1
        else:
            ow, oh = w - 1, h - 1
    else:
        if mc_decoded['padding_en']:
            ow, oh = w, h
        else:
            ow, oh = w - 2, h - 2

    if pool:
        ow //= 2
        oh //= 2

    return ow, oh


def load_param_offsets_from_quant_config(path):
    if path is None:
        return None
    if not os.path.exists(path):
        raise FileNotFoundError(f"quant config not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        config = json.load(f)
    layers = config.get("layers", [])
    if not layers:
        raise ValueError(f"{path}: no layers found")
    weight_offsets = []
    bias_offsets = []
    for layer in layers:
        weight_offsets.append(int(layer["rom_weight_start"]))
        bias_offsets.append(int(layer["rom_bias_start"]))
    return weight_offsets, bias_offsets


def pack_descriptor(op_type, activation, kernel_h, kernel_w,
                    stride_h, stride_w,
                    pool_type, pool_k, pool_stride,
                    pad_mode, pad_top, pad_bottom,
                    cin, cout,
                    input_w, input_h, output_w, output_h,
                    weight_offset, bias_offset, shift_bits):
    """Pack a single layer descriptor into 8 × 32-bit words."""
    w = [0] * 8

    # word0: version=0, op_type, activation, flags=0, kernel, stride
    w[0] = ((op_type    & 0xF) << 24) | \
           ((activation & 0xF) << 20) | \
           ((kernel_h   & 0xF) << 12) | \
           ((kernel_w   & 0xF) << 8)  | \
           ((stride_h   & 0xF) << 4)  | \
           ((stride_w   & 0xF) << 0)

    # word1: pool, padding
    w[1] = ((pool_type   & 0xF) << 20) | \
           ((pool_k      & 0xF) << 16) | \
           ((pool_stride & 0xF) << 12) | \
           ((pad_top     & 0xF) << 8)  | \
           ((pad_bottom  & 0xF) << 4)  | \
           ((pad_mode    & 0xF) << 0)

    # word2: cin, cout
    w[2] = ((cin  & 0xFFFF) << 0)  | \
           ((cout & 0xFFFF) << 16)

    # word3: input width, height
    w[3] = ((input_w  & 0xFFFF) << 0)  | \
           ((input_h  & 0xFFFF) << 16)

    # word4: output width, height
    w[4] = ((output_w & 0xFFFF) << 0)  | \
           ((output_h & 0xFFFF) << 16)

    # word5: weight offset (32-bit word address)
    w[5] = weight_offset & 0xFFFFFFFF

    # word6: bias offset (32-bit word address)
    w[6] = bias_offset & 0xFFFFFFFF

    # word7: shift_bits, quant
    w[7] = shift_bits & 0xF

    return w


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Generate NPU descriptor hex/header files.")
    parser.add_argument("--target", default="facenet_lbp_v1",
                        choices=sorted(HEADER_NAMES),
                        help="Compiler target name used for C symbols.")
    parser.add_argument("--microcode-hex", default=MICROCODE_HEX,
                        help="Input 64-bit microcode hex file.")
    parser.add_argument("--quant-config",
                        help="Optional quant_config.json containing ROM offsets.")
    parser.add_argument("--output-hex", default=os.path.join(THIS_DIR, "npu_desc.hex"),
                        help="Output descriptor RAM hex file.")
    parser.add_argument("--output-header", default=os.path.join(THIS_DIR, "npu_desc.h"),
                        help="Output BSP C descriptor header.")
    return parser


def main():
    args = build_arg_parser().parse_args()
    layers = []
    min_active = 10 if args.target == "facenet_lbp_v1" and not args.quant_config else 1
    microcode = load_microcode_words(args.microcode_hex, min_active)
    if args.quant_config:
        weight_offsets, bias_offsets = load_param_offsets_from_quant_config(args.quant_config)
    else:
        weight_offsets, bias_offsets = WEIGHT_OFFSETS, BIAS_OFFSETS

    active_layers = min(len(microcode), len(weight_offsets), len(bias_offsets))
    if active_layers == 0:
        raise SystemExit("no active descriptor layers")
    if len(microcode) != active_layers:
        print(f"[gen_descriptors] (warn) microcode has {len(microcode)} active words, "
              f"offset table has {len(weight_offsets)} layers; using first {active_layers}")

    for i, mc in enumerate(microcode[:active_layers]):
        d = decode_microcode(mc)
        ow, oh = calc_output_dims(d)

        # Determine op_type
        if d['is_fc']:
            op_type = OP_FC
            kh, kw = 1, 1
            sh, sw = 1, 1
            pool_type = POOL_NONE
            pool_k, pool_stride = 0, 0
            pad_mode = PAD_VALID
            pad_top, pad_bottom = 0, 0
        else:
            op_type = OP_CONV
            ks = d['kernel_size']
            k = {0: 1, 1: 2, 2: 3}[ks]
            kh, kw = k, k
            sh, sw = 1, 1
            pool_type = POOL_MAX if d['pool_en'] else POOL_NONE
            pool_k = 2 if d['pool_en'] else 0
            pool_stride = 2 if d['pool_en'] else 0
            pad_mode = PAD_SAME if d['padding_en'] else PAD_VALID
            pad_top, pad_bottom = 0, 0  # SAME padding handled by HW

        # Map legacy microcode activation to descriptor encoding
        # Legacy: 0=ReLU, 1=HardSigmoid
        # Descriptor: 1=RELU, 4=HARDSIGMOID
        if d['activation'] == 0:
            act = ACT_RELU
        elif d['activation'] == 1:
            act = ACT_HARDSIGMOID
        else:
            act = d['activation']

        desc = pack_descriptor(
            op_type, act,
            kh, kw, sh, sw,
            pool_type, pool_k, pool_stride,
            pad_mode, pad_top, pad_bottom,
            d['cin_total'], d['cout_total'],
            d['img_width'], d['img_height'],
            ow, oh,
            weight_offsets[i], bias_offsets[i],
            d['shift_bits']
        )
        layers.append(desc)

        op_name = "FC" if d['is_fc'] else f"CONV{k}x{k}"
        print(f"L{i}: {op_name} "
              f"cin={d['cin_total']} cout={d['cout_total']} "
              f"in={d['img_width']}×{d['img_height']} out={ow}×{oh} "
              f"pool={'MAX' if d['pool_en'] else 'none'} "
              f"act={'ReLU' if act==ACT_RELU else f'type{act}'} "
              f"shift={d['shift_bits']} "
              f"wt_off={weight_offsets[i]} bias_off={bias_offsets[i]}")

    # Write npu_desc.hex — 32 layers × 8 words = 256 lines
    hex_path = args.output_hex
    os.makedirs(os.path.dirname(os.path.abspath(hex_path)), exist_ok=True)
    with open(hex_path, 'w', encoding='utf-8', newline='\n') as f:
        for layer in range(32):
            for word in range(8):
                if layer < len(layers):
                    val = layers[layer][word]
                else:
                    val = 0
                f.write(f"{val:08X}\n")
    print(f"\nGenerated {hex_path} (256 lines)")

    # Write npu_desc.h — BSP descriptor array
    h_path = args.output_header
    guard = os.path.basename(h_path).upper().replace(".", "_")
    macro_name, array_name = HEADER_NAMES[args.target]
    os.makedirs(os.path.dirname(os.path.abspath(h_path)), exist_ok=True)
    with open(h_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(f"// Auto-generated by gen_descriptors.py - {args.target} descriptors\n")
        f.write("// Do not hand-edit.\n\n")
        f.write(f"#ifndef {guard}\n#define {guard}\n\n")
        f.write('#include "npu_descriptor.h"\n\n')
        f.write(f"#define {macro_name} {len(layers)}u\n\n")
        f.write(f"static const npu_layer_desc_t {array_name}[] = {{\n")
        for i, desc in enumerate(layers):
            f.write(f"    /* L{i} */ {{ {{")
            f.write(", ".join(f"0x{w:08X}u" for w in desc))
            f.write("} },\n")
        f.write("};\n\n")
        f.write(f"#endif // {guard}\n")
    print(f"Generated {h_path}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
