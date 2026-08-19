#!/usr/bin/env python3
"""Replace a gzip/newc initramfs in a stripped vmlinux without relinking.

The embedded archive is identified by successfully decompressing a gzip
stream whose payload is a newc archive containing TRAILER!!!.  The original
gzip stream is followed by a zero-filled reservation; only that reservation
is replaced, so every kernel byte outside it remains unchanged.
"""

from __future__ import annotations

import argparse
import pathlib
import zlib


GZIP_MAGIC = b"\x1f\x8b\x08"
NEWC_MAGIC = b"070701"
NEWC_TRAILER = b"TRAILER!!!\x00"


def gzip_candidates(image: bytes):
    start = 0
    while True:
        offset = image.find(GZIP_MAGIC, start)
        if offset < 0:
            return
        start = offset + 1
        decompressor = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)
        try:
            payload = decompressor.decompress(image[offset:])
            payload += decompressor.flush()
        except zlib.error:
            continue
        if not decompressor.eof:
            continue
        if not payload.startswith(NEWC_MAGIC) or NEWC_TRAILER not in payload:
            continue

        compressed_size = len(image[offset:]) - len(decompressor.unused_data)
        padded_end = offset + compressed_size
        while padded_end < len(image) and image[padded_end] == 0:
            padded_end += 1
        yield offset, compressed_size, padded_end - offset, len(payload)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, type=pathlib.Path)
    parser.add_argument("--archive", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    image = args.base.read_bytes()
    archive = args.archive.read_bytes()
    candidates = list(gzip_candidates(image))
    if len(candidates) != 1:
        details = ", ".join(
            f"0x{offset:x}/compressed={compressed}/capacity={capacity}"
            for offset, compressed, capacity, _ in candidates
        )
        raise RuntimeError(
            f"expected exactly one embedded newc initramfs, found "
            f"{len(candidates)}: {details}"
        )

    offset, old_compressed, capacity, old_payload = candidates[0]
    if len(archive) > capacity:
        raise RuntimeError(
            f"replacement initramfs is too large: {len(archive)} > {capacity}"
        )

    decompressor = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)
    try:
        new_payload = decompressor.decompress(archive) + decompressor.flush()
    except zlib.error as error:
        raise RuntimeError(f"replacement is not a valid gzip stream: {error}")
    if (
        not decompressor.eof
        or not new_payload.startswith(NEWC_MAGIC)
        or NEWC_TRAILER not in new_payload
    ):
        raise RuntimeError("replacement gzip payload is not a complete newc archive")

    output = bytearray(image)
    output[offset : offset + capacity] = archive + bytes(capacity - len(archive))
    if len(output) != len(image):
        raise AssertionError("ELF size changed while replacing initramfs")

    # Prove that the edit is confined to the discovered reservation.
    if output[:offset] != image[:offset] or output[offset + capacity :] != image[
        offset + capacity :
    ]:
        raise AssertionError("bytes outside the initramfs reservation changed")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)
    print(f"base:              {args.base}")
    print(f"output:            {args.output}")
    print(f"initramfs offset:  0x{offset:x}")
    print(f"old compressed:    {old_compressed} bytes")
    print(f"old payload:       {old_payload} bytes")
    print(f"reservation:       {capacity} bytes")
    print(f"new compressed:    {len(archive)} bytes")
    print(f"new payload:       {len(new_payload)} bytes")
    print(f"zero padding:      {capacity - len(archive)} bytes")
    print("outside range:     byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
