"""Close an unfinished single-quoted shell command on the Linux console."""

import sys
import time

import serial


port = serial.Serial(sys.argv[1], baudrate=115200, timeout=0.2)
try:
    port.reset_input_buffer()
    # Ask the terminal line discipline for EOF. BusyBox ash abandons an
    # incomplete continuation command and returns to its primary prompt.
    port.write(b"\x04")
    port.flush()
    time.sleep(1.0)
    data = bytearray()
    while port.in_waiting:
        data.extend(port.read(port.in_waiting))
        time.sleep(0.05)
    print(data.decode("utf-8", errors="replace"), end="")
finally:
    port.close()
