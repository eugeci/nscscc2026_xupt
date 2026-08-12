"""Install armctl on the running chiplab Linux through its serial console.

The transfer uses only the POSIX shell built-in printf with octal escapes, so
it does not depend on base64, xxd, TFTP, Python, or a compiler on the target.
Characters are paced to avoid the small ttyS0 input FIFO overflowing.
"""

from __future__ import annotations

import argparse
import pathlib
import time

import serial


def read_available(port: serial.Serial, settle: float = 0.15) -> str:
    time.sleep(settle)
    data = bytearray()
    while port.in_waiting:
        data.extend(port.read(port.in_waiting))
        time.sleep(0.03)
    return data.decode("utf-8", errors="replace")


def send_line(port: serial.Serial, line: str, settle: float = 0.15) -> str:
    # Slow character pacing prevents the input overruns observed when long
    # commands are pasted directly into the Linux serial console.
    for value in (line + "\r").encode("ascii"):
        port.write(bytes((value,)))
        port.flush()
        time.sleep(0.002)
    return read_available(port, settle)


def octal_printf_payload(content: bytes) -> str:
    return "".join(f"\\{value:03o}" for value in content)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="Linux console port, for example COM9")
    parser.add_argument("source", type=pathlib.Path)
    args = parser.parse_args()

    content = args.source.read_bytes()
    temporary = "/tmp/armctl.new"

    port = serial.Serial(args.port, baudrate=115200, timeout=0.2)
    try:
        port.reset_input_buffer()
        # Recover from an interrupted previous transfer.  If the shell is
        # waiting for a closing quote it presents a `>` continuation prompt;
        # a literal ETX cancels that partial command and returns to `/ #`.
        port.write(b"\x03")
        port.flush()
        time.sleep(0.3)
        port.reset_input_buffer()
        output = send_line(port, "", settle=0.4)
        if output:
            print(output, end="")

        print(send_line(port, f": > {temporary}"), end="")
        for offset in range(0, len(content), 48):
            payload = octal_printf_payload(content[offset : offset + 48])
            output = send_line(
                port,
                f"printf '{payload}' >> {temporary}",
                settle=0.08,
            )
            if "not found" in output or "syntax error" in output:
                raise RuntimeError("Target shell rejected a transfer command: " + output)

        verify = send_line(
            port,
            f"test \"$(wc -c < {temporary})\" -eq {len(content)} && "
            "echo ARMCTL_SIZE_OK || echo ARMCTL_SIZE_BAD",
            settle=0.3,
        )
        print(verify, end="")
        if "ARMCTL_SIZE_OK" not in verify:
            raise RuntimeError("Target file size verification failed")

        install = send_line(
            port,
            f"if cp {temporary} /usr/bin/armctl 2>/dev/null; then "
            "chmod 755 /usr/bin/armctl; echo ARMCTL_INSTALLED:/usr/bin/armctl; "
            f"else cp {temporary} /tmp/armctl; chmod 755 /tmp/armctl; "
            "echo ARMCTL_INSTALLED:/tmp/armctl; fi",
            settle=0.5,
        )
        print(install, end="")
        if "ARMCTL_INSTALLED:" not in install:
            raise RuntimeError("armctl installation did not report success")

        help_output = send_line(port, "armctl --help", settle=0.5)
        print(help_output, end="")
        if "armctl x forward|reverse" not in help_output:
            raise RuntimeError("Installed armctl did not pass its help smoke test")

        print("\nARMCTL_INSTALL_COMPLETE")
    finally:
        port.close()


if __name__ == "__main__":
    main()
