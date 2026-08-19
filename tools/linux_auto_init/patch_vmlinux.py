#!/usr/bin/env python3
"""Replace the embedded initramfs in a vmlinux copy without relinking it."""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess


def command_output(argv: list[str]) -> str:
    return subprocess.run(
        argv, check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def symbol_address(nm: str, image: pathlib.Path, symbol: str) -> int:
    pattern = re.compile(rf"^([0-9a-fA-F]+)\s+\S\s+{re.escape(symbol)}$")
    for line in command_output([nm, "-n", str(image)]).splitlines():
        match = pattern.match(line.strip())
        if match:
            return int(match.group(1), 16)
    raise RuntimeError(f"symbol not found in {image}: {symbol}")


def section_location(readelf: str, image: pathlib.Path, name: str) -> tuple[int, int, int]:
    pattern = re.compile(
        rf"^\s*\[\s*\d+\]\s+{re.escape(name)}\s+\S+\s+"
        r"([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+"
    )
    for line in command_output([readelf, "-SW", str(image)]).splitlines():
        match = pattern.match(line)
        if match:
            return tuple(int(value, 16) for value in match.groups())
    raise RuntimeError(f"section not found in {image}: {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nm", required=True)
    parser.add_argument("--readelf", required=True)
    parser.add_argument("--base", required=True, type=pathlib.Path)
    parser.add_argument("--archive", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    start = symbol_address(args.nm, args.base, "__initramfs_start")
    end = symbol_address(args.nm, args.base, "__initramfs_size")
    if end <= start:
        raise RuntimeError("unexpected initramfs symbol ordering")

    section_address, section_offset, section_size = section_location(
        args.readelf, args.base, ".init.data"
    )
    capacity = end - start
    relative = start - section_address
    if relative < 0 or relative + capacity > section_size:
        raise RuntimeError("initramfs symbols are outside .init.data")

    archive = args.archive.read_bytes()
    if len(archive) > capacity:
        raise RuntimeError(
            f"automatic initramfs is too large: {len(archive)} > {capacity} bytes"
        )

    file_offset = section_offset + relative
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.base, args.output)
    with args.output.open("r+b") as output:
        output.seek(file_offset)
        output.write(archive)
        output.write(bytes(capacity - len(archive)))

    print(f"base:       {args.base}")
    print(f"output:     {args.output}")
    print(f"file range: 0x{file_offset:x}..0x{file_offset + capacity - 1:x}")
    print(f"capacity:   {capacity} bytes")
    print(f"archive:    {len(archive)} bytes ({capacity - len(archive)} bytes padded)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
