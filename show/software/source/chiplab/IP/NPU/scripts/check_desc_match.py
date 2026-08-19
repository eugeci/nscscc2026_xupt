#!/usr/bin/env python3
"""Verify descriptor decode matches generated microcode for active layers."""
import argparse
import json
import sys, os

sys.path.insert(0, os.path.dirname(__file__))
from gen_descriptors import BIAS_OFFSETS, WEIGHT_OFFSETS, decode_microcode, load_microcode_words

DESC_HEX = os.path.join(os.path.dirname(__file__), 'npu_desc.hex')
MICROCODE_HEX = os.path.join(os.path.dirname(os.path.dirname(__file__)), "sim", "microcode_face.hex")


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Check descriptor hex against generated microcode.")
    parser.add_argument("--desc-hex", default=DESC_HEX,
                        help="Descriptor RAM hex file.")
    parser.add_argument("--microcode-hex", default=MICROCODE_HEX,
                        help="Microcode hex file.")
    parser.add_argument("--quant-config",
                        help="Optional quant_config.json containing expected ROM offsets.")
    return parser


def load_offsets(path, count):
    if path:
        with open(path, "r", encoding="utf-8") as f:
            config = json.load(f)
        layers = config.get("layers", [])
        if len(layers) < count:
            raise SystemExit(f"{path}: has {len(layers)} layers, need {count}")
        return (
            [int(layer["rom_weight_start"]) for layer in layers[:count]],
            [int(layer["rom_bias_start"]) for layer in layers[:count]],
        )
    if count <= len(WEIGHT_OFFSETS):
        return WEIGHT_OFFSETS[:count], BIAS_OFFSETS[:count]
    return None, None


def main():
    args = build_arg_parser().parse_args()

    print('Layer  Legacy(ROM)            Descriptor           Match?')
    print('-' * 70)

    all_ok = True
    microcode = load_microcode_words(args.microcode_hex, min_active_words=1)
    with open(args.desc_hex) as f:
        lines = [l.strip() for l in f.readlines() if l.strip()]

    active_count = len(microcode)
    expected_woff, expected_boff = load_offsets(args.quant_config, active_count)

    for i in range(active_count):
        d = decode_microcode(microcode[i])

        w0 = int(lines[i*8 + 0], 16)
        w1 = int(lines[i*8 + 1], 16)
        w2 = int(lines[i*8 + 2], 16)
        w3 = int(lines[i*8 + 3], 16)
        w5 = int(lines[i*8 + 5], 16)
        w6 = int(lines[i*8 + 6], 16)
        w7 = int(lines[i*8 + 7], 16)

        desc_fc = ((w0>>24)&0xF) == 1
        desc_pool = ((w1>>20)&0xF) != 0
        desc_kh = (w0>>12)&0xF
        desc_kw = (w0>>8)&0xF
        desc_pad = (w1&0xF) != 0
        desc_cin = w2 & 0xFFFF
        desc_cout = (w2 >> 16) & 0xFFFF
        desc_iw = w3 & 0xFFFF
        desc_ih = (w3 >> 16) & 0xFFFF
        desc_shift = w7 & 0xF
        desc_act = (w0 >> 20) & 0xF

        if desc_kh >= 3 and desc_kw >= 3:
            desc_ks = 2
        elif desc_kh >= 2 and desc_kw >= 2:
            desc_ks = 1
        else:
            desc_ks = 0

        leg_fc = d['is_fc']
        leg_act = 1 if d['activation'] == 0 else 4 if d['activation'] == 1 else d['activation']
        leg_pool = d['pool_en']
        leg_ks = d['kernel_size']
        leg_pad = d['padding_en']
        leg_cin = d['cin_total']
        leg_cout = d['cout_total']
        leg_iw = d['img_width']
        leg_ih = d['img_height']
        leg_shift = d['shift_bits']
        leg_woff = expected_woff[i] if expected_woff is not None else w5
        leg_boff = expected_boff[i] if expected_boff is not None else w6

        desc_woff = w5
        desc_boff = w6

        mismatches = []
        if leg_fc != desc_fc: mismatches.append('fc')
        if leg_act != desc_act: mismatches.append('act')
        if leg_pool != desc_pool: mismatches.append('pool')
        if leg_ks != desc_ks: mismatches.append('ks')
        if leg_pad != desc_pad: mismatches.append('pad')
        if leg_cin != desc_cin: mismatches.append('cin')
        if leg_cout != desc_cout: mismatches.append('cout')
        if leg_iw != desc_iw: mismatches.append('iw')
        if leg_ih != desc_ih: mismatches.append('ih')
        if leg_shift != desc_shift: mismatches.append('shift')
        if leg_woff != desc_woff: mismatches.append('woff')
        if leg_boff != desc_boff: mismatches.append('boff')

        match_str = 'MATCH' if not mismatches else f'MISMATCH: {mismatches}'
        print(f'L{i}: fc={leg_fc}/{desc_fc} act={leg_act}/{desc_act} pool={leg_pool}/{desc_pool} '
              f'ks={leg_ks}/{desc_ks} pad={leg_pad}/{desc_pad} '
              f'cin={leg_cin}/{desc_cin} cout={leg_cout}/{desc_cout} '
              f'iw={leg_iw}/{desc_iw} ih={leg_ih}/{desc_ih} '
              f'shift={leg_shift}/{desc_shift} woff={leg_woff}/{desc_woff} boff={leg_boff}/{desc_boff} '
              f'-> {match_str}')
        if mismatches:
            all_ok = False

    result_str = 'ALL MATCH' if all_ok else 'HAS MISMATCHES'
    print(f'\nOverall: {result_str}')
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
