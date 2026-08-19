"""
build_dma_rom.py
================

P2 离线工具: 把训练好的 fpga_face_net.pth 量化, 按 NPU 期望的 DMA 流格式预打包,
dump 出片上 ROM 数据文件并打印基址表。

输出 (相对本脚本目录):
- ../sim/dma_weight_rom.hex       每行 1 个 144-bit 权重字 (36 hex chars)
- ../sim/dma_bias_rom.hex         每行 1 个 32-bit 偏置字 (8 hex chars)
- 控制台: 每个 (layer, oc_g, cin_g) DMA 组的 word 偏移 / 长度
- 控制台: 与 NPU sequencer `o_dma_base_addr` 字节算术的逐项对账

策略 (路线 A 探查): 复用 sim/face_inference_ref.py 中的 repack 逻辑
(Step 14.2a 的 FC 列重排 + repack_*_for_npu), 保证与 cocotb test_npu_face_inference
的 bit-true 路径完全一致。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np

# 复用仿真侧已经验证 bit-true 的 repack/permute 工具
_SCRIPTS_DIR = Path(__file__).resolve().parent
_NPU_IP_ROOT = _SCRIPTS_DIR.parent
_NPU_SIM_DIR = _NPU_IP_ROOT / "sim"
sys.path.insert(0, str(_NPU_SIM_DIR))
sys.path.insert(0, str(_SCRIPTS_DIR))

from face_inference_ref import (  # noqa: E402
    LAYER_SPECS,
    load_quantized_model,
    repack_conv_weights_for_npu,
    repack_fc_weights_for_npu,
    get_bias_for_group,
)

# Step 14.2a: FC 权重列重排, 与 cocotb 单一来源对齐
sys.path.insert(0, str(_SCRIPTS_DIR))
from quant_int8 import permute_fc_weights_for_npu  # noqa: E402


# -----------------------------------------------------------------
# 出力目录
# -----------------------------------------------------------------
WEIGHT_HEX = _NPU_SIM_DIR / "dma_weight_rom.hex"
BIAS_HEX   = _NPU_SIM_DIR / "dma_bias_rom.hex"


def _compute_out_dims(spec):
    """与 test_npu_face_inference._compute_out_dims 等价 (用于 FC permutation)。"""
    name, is_fc, _act, pool, kernel, cin, cout, w, h, padding = spec
    if is_fc:
        return 1, 1, 1
    if padding:
        out_w, out_h = w, h
    else:
        out_w, out_h = w - kernel + 1, h - kernel + 1
    if pool:
        out_w //= 2
        out_h //= 2
    per_oc = out_w * out_h
    return out_w, out_h, per_oc


def build_dma_rom():
    layers = load_quantized_model()
    assert len(layers) == len(LAYER_SPECS)

    weight_words: list[int] = []   # 每条 = 144-bit
    bias_words:   list[int] = []   # 每条 = 32-bit

    # 表: list of dict, 每条对应一次 DMA req
    dma_table: list[dict] = []

    print("=" * 90)
    print(f" {'L':>2}  {'name':<5}  {'oc_g':>4} {'cin_g':>5} {'cin_blk':>7} {'oc_blk':>6}  "
          f"{'w_off':>6} {'w_len':>5}   {'b_off':>5}   {'k':>1}  {'is_fc':>5}")
    print("=" * 90)

    for layer_idx, layer in enumerate(layers):
        spec = LAYER_SPECS[layer_idx]
        name, is_fc, _act, _pool, kernel, cin, cout, _w, _h, _pad = spec
        q_weight = layer["q_weight"]
        q_bias   = layer["q_bias"]

        oc_groups  = (cout + 15) // 16
        cin_groups = (cin  + 15) // 16

        # FC 权重列重排 (Step 14.2a) — 一次性完成, 不在每个 group 重复
        if is_fc:
            prev_spec = LAYER_SPECS[layer_idx - 1]
            _pw, _ph, prev_per_oc = _compute_out_dims(prev_spec)
            q_weight = permute_fc_weights_for_npu(q_weight, prev_per_oc)

        for oc_g in range(oc_groups):
            oc_block = min(16, cout - oc_g * 16)

            # 每个 oc_group 的 bias (16 路 INT32, oc_g 范围内多 cin_g 共享)
            bias_offset = len(bias_words)
            biases = get_bias_for_group(q_bias, oc_g)
            for v in biases:
                # 转 unsigned 32-bit (二补码)
                if v < 0:
                    v = (v + (1 << 32)) & 0xFFFFFFFF
                bias_words.append(v & 0xFFFFFFFF)

            for cin_g in range(cin_groups):
                cin_block = min(16, cin - cin_g * 16)

                if is_fc:
                    entries = repack_fc_weights_for_npu(
                        q_weight, oc_g, cin_g, oc_block, cin_block)
                else:
                    entries = repack_conv_weights_for_npu(
                        q_weight, kernel, oc_g, cin_g, oc_block, cin_block)

                # entries: list of (addr, data_144bit), addr=cin_local*16+oc_pair
                # 按 addr 升序写入 ROM (DMA 顺序 = repack 顺序)
                weight_offset = len(weight_words)
                # repack 已经是 (cin_local 0..N, oc_pair 0..14 step 2) 的双重循环 → 自然顺序
                for addr, data_144 in entries:
                    weight_words.append(data_144 & ((1 << 144) - 1))
                weight_count = len(weight_words) - weight_offset

                dma_table.append({
                    "layer_idx": layer_idx,
                    "name": name,
                    "oc_g": oc_g,
                    "cin_g": cin_g,
                    "oc_block": oc_block,
                    "cin_block": cin_block,
                    "kernel": kernel,
                    "is_fc": is_fc,
                    "weight_word_offset": weight_offset,
                    "weight_word_count":  weight_count,
                    "bias_word_offset":   bias_offset,
                })

                print(f" {layer_idx:>2}  {name:<5}  {oc_g:>4} {cin_g:>5} "
                      f"{cin_block:>7} {oc_block:>6}  "
                      f"{weight_offset:>6} {weight_count:>5}   "
                      f"{bias_offset:>5}   {kernel:>1}  {str(is_fc):>5}")

    # -----------------------------------------------------------------
    # 写出 hex
    # -----------------------------------------------------------------
    WEIGHT_HEX.parent.mkdir(parents=True, exist_ok=True)
    with open(WEIGHT_HEX, "w") as f:
        for w in weight_words:
            f.write(f"{w:036X}\n")
    with open(BIAS_HEX, "w") as f:
        for b in bias_words:
            f.write(f"{b:08X}\n")

    print("=" * 90)
    print(f" 总计: weight = {len(weight_words)} × 144-bit = "
          f"{len(weight_words)*18} 字节")
    print(f"        bias   = {len(bias_words)}   × 32-bit  = "
          f"{len(bias_words)*4} 字节")
    print(f" 写入: {WEIGHT_HEX.relative_to(_NPU_IP_ROOT)}")
    print(f"        {BIAS_HEX.relative_to(_NPU_IP_ROOT)}")

    return dma_table, weight_words, bias_words


# -----------------------------------------------------------------
# Sequencer 字节算术 vs 预打包 word 偏移 对账
# -----------------------------------------------------------------
# Sequencer (npu_sequencer.v):
#   w_k_factor       = (kernel==3x3) ? 9 : 1
#   w_dma_length     = 16 * cin_block * k_factor                  bytes
#   w_oc_group_bytes = 16 * cin_total * k_factor                  bytes
#   w_cin_group_bytes= 256 * k_factor                             bytes
#   o_dma_base_addr  = w_weight_base_addr
#                    + r_oc_group_idx  * w_oc_group_bytes
#                    + r_cin_group_idx * w_cin_group_bytes
#   o_bias_base_addr = w_bias_base_addr + r_oc_group_idx * 64
#
# npu_param_rom.v 给出每层 weight_base / bias_base (字节地址)。
# 预打包后每个 144-bit word = 18 字节, 一组 = cin_block * 8 个 word = 144*cin_block 字节。
#
# 对比目标: 把每个 (layer,oc_g,cin_g) 的 sequencer 字节地址 与 我们打包后该
# 组在 144-bit-word ROM 中的字节地址 (= weight_word_offset * 18) 拉出来对账。
# -----------------------------------------------------------------

# 来自 NPU/rtl/npu_param_rom.v 的字节起点表 (拷贝, 以便离线对账)
NPU_PARAM_ROM_TABLE = [
    # layer_id, weight_base, bias_base
    (0, 0,     18),
    (1, 23,    311),
    (2, 320,   384),
    (3, 393,   1257),
    (4, 1270,  2998),
    (5, 3015,  3271),
    (6, 3288,  5592),
    (7, 5609,  6633),
    (8, 6650,  18938),
    (9, 18971, 19051),
]


def reconcile(dma_table):
    """打印 sequencer 字节地址 vs prepack ROM 字节地址 的对账表。"""
    print()
    print("=" * 110)
    print(" 对账: NPU sequencer o_dma_base_addr (字节, 基于 npu_params.hex 原始 INT8) "
          "vs prepack 144-bit ROM 字节地址")
    print("=" * 110)
    print(f" {'L':>2} {'name':<5} {'oc_g':>4} {'cin_g':>5} "
          f"{'seq_W_byte':>11} {'pp_W_byte':>11} {'ΔW':>6}    "
          f"{'seq_B_byte':>11} {'pp_B_byte':>11} {'ΔB':>5}")
    print("-" * 110)

    layer_table = {l: (wb, bb) for l, wb, bb in NPU_PARAM_ROM_TABLE}

    n_w_match = 0
    n_b_match = 0
    n_total = 0

    # 缓存每层的 cin_total / kernel 用于算 oc_group_bytes
    layer_meta = {}
    for spec in LAYER_SPECS:
        name = spec[0]
    for idx, spec in enumerate(LAYER_SPECS):
        _name, _is_fc, _act, _pool, kernel, cin, _cout, *_ = spec
        layer_meta[idx] = (kernel, cin)

    for entry in dma_table:
        layer_idx = entry["layer_idx"]
        oc_g = entry["oc_g"]
        cin_g = entry["cin_g"]
        cin_block = entry["cin_block"]
        kernel = entry["kernel"]
        kernel_code, cin_total = layer_meta[layer_idx]
        k_factor = 9 if kernel_code == 3 else 1

        wb_base, bb_base = layer_table[layer_idx]
        oc_group_bytes  = 16 * cin_total * k_factor
        cin_group_bytes = 256 * k_factor

        seq_w_byte = wb_base + oc_g * oc_group_bytes + cin_g * cin_group_bytes
        seq_b_byte = bb_base + oc_g * 64

        pp_w_byte = entry["weight_word_offset"] * 18
        pp_b_byte = entry["bias_word_offset"]   * 4   # 32-bit/word = 4 bytes

        dw = pp_w_byte - seq_w_byte
        db = pp_b_byte - seq_b_byte
        n_total += 1
        if dw == 0: n_w_match += 1
        if db == 0: n_b_match += 1

        print(f" {layer_idx:>2} {entry['name']:<5} {oc_g:>4} {cin_g:>5} "
              f"{seq_w_byte:>11} {pp_w_byte:>11} {dw:>+6}    "
              f"{seq_b_byte:>11} {pp_b_byte:>11} {db:>+5}")

    print("-" * 110)
    print(f" weight 字节地址完全一致: {n_w_match}/{n_total}")
    print(f" bias   字节地址完全一致: {n_b_match}/{n_total}")
    print()
    if n_w_match == n_total and n_b_match == n_total:
        print(" ✅ Sequencer 字节算术与 prepack 对齐, weight_rom_dma 可直接以 byte->word")
        print("     (byte_addr / 18) 索引 ROM, 无需修改 sequencer 或 npu_param_rom。")
    else:
        print(" ⚠️ 存在不一致 — 需要决策:")
        print("    (a) 改 npu_param_rom.v 的 weight/bias 起点表 + 把 sequencer w_k_factor 强制为 9")
        print("    (b) 在 weight_rom_dma 里维护 (layer,oc_g,cin_g) → word_offset 查找表 (旁路 sequencer 算术)")
        print("    (c) 改用「word 寻址」: 重定义 o_dma_base_addr 为 144-bit word 索引 (改 sequencer)")


if __name__ == "__main__":
    table, _w, _b = build_dma_rom()
    reconcile(table)
