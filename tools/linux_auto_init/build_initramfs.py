#!/usr/bin/env python3
"""Build a deterministic minimal newc initramfs for auto_init."""

from __future__ import annotations

import argparse
import gzip
import pathlib
import stat


def align4(data: bytearray) -> None:
    data.extend(b"\0" * ((-len(data)) & 3))


def append_entry(
    archive: bytearray,
    *,
    inode: int,
    name: str,
    mode: int,
    data: bytes = b"",
    nlink: int = 1,
    rdev_major: int = 0,
    rdev_minor: int = 0,
) -> None:
    encoded_name = name.encode("ascii") + b"\0"
    fields = (
        inode,
        mode,
        0,
        0,
        nlink,
        0,
        len(data),
        0,
        0,
        rdev_major,
        rdev_minor,
        len(encoded_name),
        0,
    )
    archive.extend(b"070701" + b"".join(f"{value:08x}".encode() for value in fields))
    archive.extend(encoded_name)
    align4(archive)
    archive.extend(data)
    align4(archive)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--init", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    init_data = args.init.read_bytes()
    archive = bytearray()
    inode = 1

    for directory in (".", "bin", "dev", "proc", "sys"):
        append_entry(
            archive,
            inode=inode,
            name=directory,
            mode=stat.S_IFDIR | 0o755,
            nlink=2,
        )
        inode += 1

    append_entry(
        archive,
        inode=inode,
        name="dev/console",
        mode=stat.S_IFCHR | 0o600,
        rdev_major=5,
        rdev_minor=1,
    )
    inode += 1
    append_entry(
        archive,
        inode=inode,
        name="dev/null",
        mode=stat.S_IFCHR | 0o666,
        rdev_major=1,
        rdev_minor=3,
    )
    inode += 1
    append_entry(
        archive,
        inode=inode,
        name="dev/mem",
        mode=stat.S_IFCHR | 0o600,
        rdev_major=1,
        rdev_minor=1,
    )
    inode += 1

    # Keep both names so either rdinit=/init or the older rdinit=/bin/sh
    # trampoline launches the same non-interactive PID 1.
    for executable in ("init", "bin/sh"):
        append_entry(
            archive,
            inode=inode,
            name=executable,
            mode=stat.S_IFREG | 0o755,
            data=init_data,
        )
        inode += 1

    append_entry(
        archive,
        inode=inode,
        name="TRAILER!!!",
        mode=0,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(gzip.compress(bytes(archive), compresslevel=9, mtime=0))
    print(f"init ELF:        {len(init_data)} bytes")
    print(f"initramfs newc:  {len(archive)} bytes")
    print(f"initramfs gzip:  {args.output.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
