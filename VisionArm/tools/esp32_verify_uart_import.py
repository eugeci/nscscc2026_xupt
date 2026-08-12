"""Verify that the updated UART module imports on the target MicroPython."""

import sys

from esp32_readonly_backup import RawRepl


def main():
    port = sys.argv[1]
    repl = RawRepl(port)
    try:
        repl.enter()
        output = repl.exec("import uart_c\nprint('IMPORT_OK')")
        print(output.decode("utf-8", errors="replace"))
    finally:
        repl.close_and_reboot()


if __name__ == "__main__":
    main()
