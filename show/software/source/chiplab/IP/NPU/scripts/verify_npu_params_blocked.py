#!/usr/bin/env python3
"""
[M0/Path B] 离线对账：npu_params.hex (块状字节流) vs face_inference_ref.repack_*

验证 scripts/quant_calibrated.py 或 scripts/quant_int8.py 输出的 hex 文件
与 sim/face_inference_ref.py 的 load_quantized_model / repack_conv_weights_for_npu /
repack_fc_weights_for_npu / get_bias_for_group 完全一致。

通过 = 217/217 group 全部 bit-true match。
失败 = 报告首个 mismatch 的层 / oc_g / cin_g / addr / 期望 / 实际。

依赖：
  - params/fpga_face_net.pth
  - params/npu_params.hex
  - params/quant_config.json (可选; 存在时使用校准量化)
  - sim/face_inference_ref.py (load_quantized_model, repack_*, get_bias_for_group)
"""
import argparse
import os
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
NPU_IP_ROOT = os.path.dirname(THIS_DIR)
PARAMS_DIR = os.path.join(NPU_IP_ROOT, "params")
sys.path.insert(0, os.path.join(NPU_IP_ROOT, "sim"))

from face_inference_ref import (
    LAYER_SPECS,
    load_quantized_model,
    repack_conv_weights_for_npu,
    repack_fc_weights_for_npu,
    get_bias_for_group,
)


DEFAULT_PARAMS_HEX = os.path.join(PARAMS_DIR, "npu_params.hex")


def load_hex_words(path):
    """读取 hex 文件，返回 32-bit word 列表（int）。跳过 @ 起始行和空行。"""
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("@") or line.startswith("//"):
                continue
            words.append(int(line, 16))
    return words


def _compute_out_dims(spec):
    """Return previous layer per-OC spatial size for FC column permutation."""
    _name, is_fc, _act, pool, kernel, _cin, _cout, w, h, padding = spec
    if is_fc:
        return 1, 1, 1
    if kernel == 1:
        out_w, out_h = w, h
    elif kernel == 2:
        out_w, out_h = (w + 1, h + 1) if padding else (w - 1, h - 1)
    else:
        out_w, out_h = (w, h) if padding else (w - 2, h - 2)
    if pool:
        out_w //= 2
        out_h //= 2
    return out_w, out_h, out_w * out_h


def words_to_144bit_entries(words, kernel):
    """把 16×16×K² 字节块（= block_words 个 32-bit word）解出 128 个 144-bit 条目。

    迭代顺序与 quant_int8._build_weight_block / repack_conv_weights_for_npu 一致：
      for ic_local in 0..15:
        for oc_pair in 0..7:
          even (K² bytes) + odd (K² bytes)  → 一个 144-bit 条目

    返回 [(addr, data_144), ...]，128 项。
    """
    K2 = kernel * kernel
    # 先把 32-bit word 流还原成字节流（little-endian）
    bs = []
    for w in words:
        bs.append(w        & 0xFF)
        bs.append((w >>  8) & 0xFF)
        bs.append((w >> 16) & 0xFF)
        bs.append((w >> 24) & 0xFF)
    expected_bytes = 16 * 16 * K2
    assert len(bs) == expected_bytes, f"got {len(bs)}, want {expected_bytes}"
    entries = []
    p = 0
    for ic_local in range(16):
        for oc_pair in range(0, 16, 2):
            # even
            raw_even = 0
            for t in range(K2):
                raw_even |= bs[p] << (t * 8); p += 1
            # odd
            raw_odd = 0
            for t in range(K2):
                raw_odd |= bs[p] << (t * 8); p += 1
            data_144 = (raw_odd << 72) | raw_even
            addr = ic_local * 16 + oc_pair
            entries.append((addr, data_144))
    assert p == expected_bytes
    return entries


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Verify blocked NPU parameter hex against the Python reference.")
    parser.add_argument("--params-hex", default=DEFAULT_PARAMS_HEX,
                        help="Blocked INT8 parameter hex file.")
    return parser


def main():
    args = build_arg_parser().parse_args()
    hex_path = args.params_hex
    if not os.path.exists(hex_path):
        sys.exit(f"❌ {hex_path} 不存在。先跑 python3 scripts/quant_calibrated.py")

    layers = load_quantized_model()

    words = load_hex_words(hex_path)
    print(f"loaded {len(words)} words from {hex_path}")

    cur = 0
    total_groups = 0
    fail = 0
    for layer_idx, L in enumerate(layers):
        spec = L["spec"]
        prefix, is_fc, _act, _pool, kernel, Cin, Cout, _w, _h, _pad = spec
        q_weight = L["q_weight"]
        if is_fc:
            from quant_int8 import permute_fc_weights_for_npu

            _pw, _ph, prev_per_oc = _compute_out_dims(LAYER_SPECS[layer_idx - 1])
            q_weight = permute_fc_weights_for_npu(q_weight, prev_per_oc)

        oc_groups = (Cout + 15) // 16
        cin_groups = (Cin + 15) // 16
        K2 = kernel * kernel
        block_words = (16 * 16 * K2) // 4

        # 权重比对（每 oc_g × cin_g 块）
        for oc_g in range(oc_groups):
            for cin_g in range(cin_groups):
                rom_block_words = words[cur:cur + block_words]
                cur += block_words
                got = words_to_144bit_entries(rom_block_words, kernel)
                cin_block = min(16, Cin  - cin_g * 16)
                oc_block  = min(16, Cout - oc_g  * 16)
                if not is_fc:
                    exp = repack_conv_weights_for_npu(
                        q_weight, kernel, oc_g, cin_g,
                        oc_block=oc_block, cin_block=cin_block)
                else:
                    exp = repack_fc_weights_for_npu(
                        q_weight, oc_g, cin_g,
                        oc_block=oc_block, cin_block=cin_block)
                # 期望长度 = cin_block * 8；ROM 里我们 pad 到 128（cin_local=cin_block..15 全 0）
                effective_n = cin_block * 8
                got_eff = got[:effective_n]
                got_pad = got[effective_n:]
                if got_eff != exp:
                    fail += 1
                    for i, ((a1, d1), (a2, d2)) in enumerate(zip(got_eff, exp)):
                        if (a1, d1) != (a2, d2):
                            print(f"❌ {prefix} oc_g={oc_g} cin_g={cin_g} entry#{i}/{effective_n}: "
                                  f"got=(addr={a1},data=0x{d1:036x}) "
                                  f"exp=(addr={a2},data=0x{d2:036x})")
                            break
                    if fail >= 3:
                        sys.exit("too many failures, abort")
                # 检查 padding 区全 0
                for i, (a, d) in enumerate(got_pad):
                    if d != 0:
                        fail += 1
                        print(f"❌ {prefix} oc_g={oc_g} cin_g={cin_g} pad#{i}: addr={a} data=0x{d:036x} (应为 0)")
                        if fail >= 3:
                            sys.exit("too many failures, abort")
                        break
                total_groups += 1

        # bias 比对
        for oc_g in range(oc_groups):
            block_words_bias = words[cur:cur + 16]
            cur += 16
            exp_bias = get_bias_for_group(L['q_bias'], oc_g)
            for ch in range(16):
                got_v = block_words_bias[ch]
                # 把 INT16 期望值符号扩展到 INT32 比对
                exp_v_i32 = exp_bias[ch] & 0xFFFFFFFF
                if got_v != exp_v_i32:
                    fail += 1
                    print(f"❌ {prefix} bias oc_g={oc_g} ch={ch}: "
                          f"got=0x{got_v:08x} exp=0x{exp_v_i32:08x}")
                    if fail >= 3:
                        sys.exit("too many failures, abort")

        # shift（不参与 repack 比对，但消耗 1 word）
        cur += 1

    print()
    if fail == 0:
        bias_groups = sum((L["spec"][6] + 15) // 16 for L in layers)
        print(f"✅ 全部 PASS：{total_groups} weight groups + {bias_groups} bias groups bit-true match")
        print(f"   消耗 {cur}/{len(words)} words（剩余 {len(words) - cur}）")
    else:
        print(f"❌ 失败 {fail} 项")
        sys.exit(1)


if __name__ == "__main__":
    main()
