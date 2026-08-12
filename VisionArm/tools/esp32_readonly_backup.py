"""Read-only MicroPython filesystem backup over the raw REPL.

The only bytes sent which alter runtime state are Ctrl-C (stop current script),
Ctrl-A (enter raw REPL), Ctrl-B (leave raw REPL), and Ctrl-D (soft reboot).
No file-write or file-delete operation is issued to the device.
"""

from __future__ import annotations

import argparse
import ast
import json
import pathlib
import time

import serial


class RawRepl:
    def __init__(self, port: str, baudrate: int = 115200):
        self.serial = serial.Serial(port, baudrate=baudrate, timeout=0.2)

    def _drain(self) -> bytes:
        data = bytearray()
        while True:
            part = self.serial.read(4096)
            if not part:
                return bytes(data)
            data.extend(part)

    def _read_until(self, suffix: bytes, timeout: float = 8.0) -> bytes:
        deadline = time.monotonic() + timeout
        data = bytearray()
        while time.monotonic() < deadline:
            part = self.serial.read(4096)
            if part:
                data.extend(part)
                if data.endswith(suffix):
                    return bytes(data)
        raise TimeoutError(f"Timed out waiting for {suffix!r}; received {bytes(data)!r}")

    def enter(self) -> None:
        self.serial.write(b"\r\x03\x03")
        time.sleep(0.25)
        self._drain()
        self.serial.write(b"\r\x01")
        reply = self._read_until(b">", timeout=5.0)
        if b"raw REPL" not in reply:
            raise RuntimeError(f"Could not enter raw REPL: {reply!r}")

    def exec(self, source: str, timeout: float = 10.0) -> bytes:
        encoded = source.encode("utf-8")
        for offset in range(0, len(encoded), 128):
            self.serial.write(encoded[offset : offset + 128])
            time.sleep(0.01)
        self.serial.write(b"\x04")
        reply = self._read_until(b"\x04>", timeout=timeout)
        if not reply.startswith(b"OK"):
            raise RuntimeError(f"Raw REPL rejected command: {reply!r}")
        body = reply[2:-2]
        stdout, separator, stderr = body.partition(b"\x04")
        if not separator:
            raise RuntimeError(f"Malformed raw REPL response: {reply!r}")
        if stderr:
            raise RuntimeError(stderr.decode("utf-8", errors="replace"))
        return stdout

    def close_and_reboot(self) -> None:
        try:
            self.serial.write(b"\x02")
            time.sleep(0.05)
            self.serial.write(b"\x04")
        finally:
            self.serial.close()


LIST_FILES = r'''
import os
result = []
def walk(path):
    try:
        names = os.listdir(path)
    except OSError:
        return
    for name in names:
        full = (path.rstrip('/') + '/' + name) if path != '/' else '/' + name
        try:
            info = os.stat(full)
            if info[0] & 0x4000:
                walk(full)
            else:
                result.append((full, info[6]))
        except OSError:
            pass
walk('/')
print(repr(result))
'''


def backup(port: str, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    repl = RawRepl(port)
    manifest: list[dict[str, object]] = []
    try:
        repl.enter()
        listing_text = repl.exec(LIST_FILES).decode("utf-8", errors="strict").strip()
        files = ast.literal_eval(listing_text)
        if not isinstance(files, list):
            raise RuntimeError("Unexpected file listing returned by board")

        for remote_path, expected_size in files:
            local_path = destination.joinpath(*pathlib.PurePosixPath(remote_path).parts[1:])
            local_path.parent.mkdir(parents=True, exist_ok=True)
            data = bytearray()
            offset = 0
            while offset < expected_size:
                amount = min(384, expected_size - offset)
                source = (
                    "import ubinascii\n"
                    f"f=open({remote_path!r},'rb')\n"
                    f"f.seek({offset})\n"
                    f"d=f.read({amount})\n"
                    "f.close()\n"
                    "print(ubinascii.hexlify(d).decode())\n"
                )
                chunk_hex = repl.exec(source).decode("ascii").strip()
                chunk = bytes.fromhex(chunk_hex)
                if not chunk:
                    raise RuntimeError(f"Unexpected EOF reading {remote_path} at {offset}")
                data.extend(chunk)
                offset += len(chunk)
            if len(data) != expected_size:
                raise RuntimeError(
                    f"Size mismatch for {remote_path}: expected {expected_size}, got {len(data)}"
                )
            local_path.write_bytes(data)
            manifest.append({"path": remote_path, "size": expected_size})
            print(f"BACKED_UP {remote_path} ({expected_size} bytes)")

        (destination / "backup_manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"BACKUP_COMPLETE files={len(manifest)} destination={destination}")
    finally:
        repl.close_and_reboot()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("port")
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    backup(args.port, args.destination)


if __name__ == "__main__":
    main()
