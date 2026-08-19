#!/usr/bin/env python3
"""Replace one file in an embedded gzip/newc initramfs without relinking."""

from __future__ import annotations

import argparse
import gzip
import pathlib
import zlib

from patch_stripped_vmlinux import gzip_candidates


def align4(value: int) -> int:
    return (value + 3) & ~3


def parse_newc(payload: bytes):
    entries = []
    offset = 0
    while offset + 110 <= len(payload):
        header = payload[offset : offset + 110]
        if header[:6] != b"070701":
            raise RuntimeError(f"bad newc magic at 0x{offset:x}")
        fields = [int(header[6 + i * 8 : 14 + i * 8], 16) for i in range(13)]
        name_size = fields[11]
        file_size = fields[6]
        name_start = offset + 110
        name_end = name_start + name_size
        if name_end > len(payload) or not payload[name_end - 1 : name_end] == b"\0":
            raise RuntimeError(f"bad newc name at 0x{offset:x}")
        name = payload[name_start : name_end - 1].decode("utf-8")
        data_start = align4(name_end)
        data_end = data_start + file_size
        if data_end > len(payload):
            raise RuntimeError(f"bad newc data for {name}")
        entries.append((name, fields, payload[data_start:data_end]))
        offset = align4(data_end)
        if name == "TRAILER!!!":
            return entries
    raise RuntimeError("newc TRAILER!!! was not found")


def build_newc(entries) -> bytes:
    archive = bytearray()
    for name, original_fields, data in entries:
        fields = list(original_fields)
        encoded_name = name.encode("utf-8") + b"\0"
        fields[6] = len(data)
        fields[11] = len(encoded_name)
        archive.extend(b"070701")
        archive.extend(b"".join(f"{value:08x}".encode() for value in fields))
        archive.extend(encoded_name)
        archive.extend(b"\0" * ((-len(archive)) & 3))
        archive.extend(data)
        archive.extend(b"\0" * ((-len(archive)) & 3))
    return bytes(archive)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, type=pathlib.Path)
    parser.add_argument("--entry", default="init")
    parser.add_argument("--replacement", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    image = args.base.read_bytes()
    candidates = list(gzip_candidates(image))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one initramfs, found {len(candidates)}")
    image_offset, compressed_size, capacity, _ = candidates[0]
    decompressor = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)
    payload = decompressor.decompress(image[image_offset:]) + decompressor.flush()
    entries = parse_newc(payload)

    if args.list:
        for name, fields, data in entries:
            print(f"{fields[0]:8d} {fields[1]:08o} {len(data):8d} {name}")
    if args.replacement is None:
        return 0
    if args.output is None:
        parser.error("--output is required with --replacement")

    replacement = args.replacement.read_bytes()
    matches = 0
    rewritten = []
    for name, fields, data in entries:
        if name == args.entry:
            data = replacement
            matches += 1
        rewritten.append((name, fields, data))
    if matches != 1:
        raise RuntimeError(f"expected one {args.entry!r} entry, found {matches}")

    new_payload = build_newc(rewritten)
    verified = parse_newc(new_payload)
    if len(verified) != len(entries):
        raise AssertionError("newc entry count changed")
    for old, new in zip(entries, verified):
        old_name, old_fields, old_data = old
        new_name, new_fields, new_data = new
        if old_name != new_name or old_fields[:6] != new_fields[:6] or old_fields[7:] != new_fields[7:]:
            raise AssertionError(f"metadata changed for {old_name}")
        expected_data = replacement if old_name == args.entry else old_data
        if new_data != expected_data:
            raise AssertionError(f"data changed unexpectedly for {old_name}")
    new_archive = gzip.compress(new_payload, compresslevel=9, mtime=0)
    if len(new_archive) > capacity:
        raise RuntimeError(
            f"rewritten archive is too large: {len(new_archive)} > {capacity}"
        )
    output = bytearray(image)
    output[image_offset : image_offset + capacity] = new_archive + bytes(
        capacity - len(new_archive)
    )
    if output[:image_offset] != image[:image_offset] or output[
        image_offset + capacity :
    ] != image[image_offset + capacity :]:
        raise AssertionError("bytes outside initramfs reservation changed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)
    print(f"entry:           {args.entry}")
    print(f"old compressed:  {compressed_size}")
    print(f"new compressed:  {len(new_archive)}")
    print(f"capacity:        {capacity}")
    print(f"new payload:     {len(new_payload)}")
    print(f"entries checked: {len(entries)} (only {args.entry!r} replaced)")
    print("outside range:   byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
