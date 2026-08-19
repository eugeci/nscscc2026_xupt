#!/usr/bin/env python3
"""Patch the absolute Linux target encoded by a two-instruction LA32R li.w.

The handoff ELF is already linked and board-tested at 0xa0100000.  Rebuilding
it is unnecessary when only the loaded kernel entry changes: GCC expands
``li.w r12, ENTRY`` to ``lu12i.w r12, entry[31:12]`` plus
``ori r12, r12, entry[11:0]``.  This tool replaces that unique instruction
pair and leaves the ELF layout, boot arguments and PMON environment pointer
unchanged.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import struct


TARGET_REGISTER = 12


def encode_target(entry: int) -> bytes:
    if not 0 <= entry <= 0xFFFFFFFF:
        raise ValueError("entry must fit in 32 bits")
    upper20 = (entry >> 12) & 0xFFFFF
    lower12 = entry & 0xFFF
    lu12i_w = 0x14000000 | (upper20 << 5) | TARGET_REGISTER
    ori = (
        0x03800000
        | (lower12 << 10)
        | (TARGET_REGISTER << 5)
        | TARGET_REGISTER
    )
    return struct.pack("<II", lu12i_w, ori)


def parse_u32(text: str) -> int:
    return int(text, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--old-entry", required=True, type=parse_u32)
    parser.add_argument("--new-entry", required=True, type=parse_u32)
    args = parser.parse_args()

    image = args.input.read_bytes()
    if image[:4] != b"\x7fELF" or image[4:6] != b"\x01\x01":
        raise RuntimeError("expected a little-endian ELF32 handoff image")

    old_code = encode_target(args.old_entry)
    new_code = encode_target(args.new_entry)
    matches = []
    start = 0
    while True:
        found = image.find(old_code, start)
        if found < 0:
            break
        matches.append(found)
        start = found + 1
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one old target instruction pair, found {len(matches)}"
        )

    offset = matches[0]
    patched = image[:offset] + new_code + image[offset + len(old_code) :]
    if len(patched) != len(image):
        raise AssertionError("ELF size changed")
    if patched[:offset] != image[:offset] or patched[offset + 8 :] != image[offset + 8 :]:
        raise AssertionError("bytes outside target instruction pair changed")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(patched)
    print(f"instruction offset: 0x{offset:x}")
    print(f"old entry:         0x{args.old_entry:08x}")
    print(f"new entry:         0x{args.new_entry:08x}")
    print(f"size:              {len(patched)}")
    print(f"sha256:            {hashlib.sha256(patched).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
