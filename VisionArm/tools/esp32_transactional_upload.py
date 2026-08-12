"""Upload selected MicroPython files with read-back verification and rollback copies."""

from __future__ import annotations

import argparse
import pathlib

from esp32_readonly_backup import RawRepl


def remote_exec_text(repl: RawRepl, source: str) -> str:
    return repl.exec(source).decode("utf-8", errors="strict").strip()


def read_remote_file(repl: RawRepl, path: str, size: int) -> bytes:
    result = bytearray()
    offset = 0
    while offset < size:
        amount = min(384, size - offset)
        output = remote_exec_text(
            repl,
            "import ubinascii\n"
            f"f=open({path!r},'rb')\n"
            f"f.seek({offset})\n"
            f"d=f.read({amount})\n"
            "f.close()\n"
            "print(ubinascii.hexlify(d).decode())\n",
        )
        chunk = bytes.fromhex(output)
        if not chunk:
            raise RuntimeError(f"Unexpected EOF reading {path} at offset {offset}")
        result.extend(chunk)
        offset += len(chunk)
    return bytes(result)


def upload_one(repl: RawRepl, local: pathlib.Path, remote: str, backup_suffix: str) -> None:
    content = local.read_bytes()
    source_text = content.decode("utf-8")

    # Compile on the ESP32 before changing its filesystem. This catches syntax
    # differences between desktop Python and the installed MicroPython version.
    remote_exec_text(repl, f"compile({source_text!r}, {remote!r}, 'exec')\nprint('COMPILE_OK')")

    temporary = remote + ".new"
    backup = remote + backup_suffix
    remote_exec_text(repl, f"f=open({temporary!r},'wb')\nf.close()\nprint('TEMP_READY')")

    for offset in range(0, len(content), 256):
        chunk = content[offset : offset + 256]
        remote_exec_text(
            repl,
            "import ubinascii\n"
            f"f=open({temporary!r},'ab')\n"
            f"f.write(ubinascii.unhexlify({chunk.hex()!r}))\n"
            "f.close()\n"
            "print('CHUNK_OK')\n",
        )

    read_back = read_remote_file(repl, temporary, len(content))
    if read_back != content:
        raise RuntimeError(f"Read-back verification failed for {remote}")

    exists = remote_exec_text(
        repl,
        "import os\n"
        f"names=os.listdir('/')\n"
        f"print(int({backup.lstrip('/')!r} in names))\n",
    )
    if exists != "0":
        raise RuntimeError(f"Refusing to overwrite existing on-board backup {backup}")

    remote_exec_text(
        repl,
        "import os\n"
        f"os.rename({remote!r}, {backup!r})\n"
        f"os.rename({temporary!r}, {remote!r})\n"
        "print('COMMIT_OK')\n",
    )
    print(f"UPLOADED {local} -> {remote}; rollback={backup}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("source_directory", type=pathlib.Path)
    parser.add_argument("--backup-suffix", default=".pre_uart_20260804")
    parser.add_argument(
        "--files",
        nargs="+",
        default=["uart_c.py", "main.py"],
        help="Files to upload, in commit order",
    )
    args = parser.parse_args()

    repl = RawRepl(args.port)
    try:
        repl.enter()
        for filename in args.files:
            if pathlib.PurePath(filename).name != filename:
                raise ValueError(f"Only root-level filenames are allowed: {filename}")
            upload_one(
                repl,
                args.source_directory / filename,
                "/" + filename,
                args.backup_suffix,
            )
        print("UPLOAD_COMPLETE")
    finally:
        repl.close_and_reboot()


if __name__ == "__main__":
    main()
