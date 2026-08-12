"""UART command entry for the existing mechanical-arm motor driver.

UART2 wiring on ESP32:
    TX: GPIO4
    RX: GPIO17 (the carrier-board connector labelled IO17 / 5V / G)
    baud: 9600, 8 data bits, no parity, 1 stop bit

Accepted commands:
    1  X axis forward, 100 steps
    2  X axis reverse, 100 steps
    3  Y axis forward, 100 steps
    4  Y axis reverse, 100 steps
    5  Z axis forward, 100 steps
    6  Z axis reverse, 100 steps
    7  Open gripper to a conservative test position
    8  Close gripper to a conservative test position
    HELLO  link test; replies ARMOK

Single digit commands may be sent with or without CR/LF. Text commands must end
with CR or LF. Replies are newline terminated ASCII strings.
"""

import machine
import time
import motor_c


UART_ID = 2
UART_BAUDRATE = 9600
UART_TX_PIN = 4
UART_RX_PIN = 17
COMMAND_STEPS = 100
# Keep away from the mechanical end stops. The first verified 10% open
# position produced gear noise, so the UART control range is deliberately
# narrowed until final calibration is complete.
GRIP_OPEN_POSITION = 30
GRIP_CLOSE_POSITION = 70
MAX_LINE_LENGTH = 64

uart = machine.UART(
    UART_ID,
    baudrate=UART_BAUDRATE,
    bits=8,
    parity=None,
    stop=1,
    tx=UART_TX_PIN,
    rx=UART_RX_PIN,
)


def _reply(message):
    uart.write((message + "\n").encode("ascii"))


def _set_gripper(position):
    """Set the existing GPIO16 servo target without blocking UART reception."""
    duty = int(1638 + (position / 100) * (8192 - 1638))
    motor_c.servo.duty_u16(duty)


def execute_command(command):
    """Parse one complete command and call the existing motor functions."""
    command = command.strip().upper()

    if not command:
        return

    # USB/UART0 diagnostic output for a safe first link test. This does not
    # share pins with the external UART2 receiver on GPIO17.
    print("UART RX:", command)

    if command == "HELLO":
        _reply("ARMOK")
        return

    if command == "7":
        _reply("ACK GRIP OPEN")
        try:
            _set_gripper(GRIP_OPEN_POSITION)
        except Exception as exc:
            _reply("ERR GRIP OPEN")
            print("Gripper open failed:", exc)
            return
        _reply("DONE GRIP OPEN")
        return

    if command == "8":
        _reply("ACK GRIP CLOSE")
        try:
            _set_gripper(GRIP_CLOSE_POSITION)
        except Exception as exc:
            _reply("ERR GRIP CLOSE")
            print("Gripper close failed:", exc)
            return
        _reply("DONE GRIP CLOSE")
        return

    actions = {
        "1": (motor_c.move_x_axis, 1),
        "2": (motor_c.move_x_axis, 0),
        "3": (motor_c.move_y_axis, 1),
        "4": (motor_c.move_y_axis, 0),
        "5": (motor_c.move_z_axis, 1),
        "6": (motor_c.move_z_axis, 0),
    }

    action = actions.get(command)
    if action is None:
        _reply("ERR UNKNOWN " + command)
        return

    move_function, direction = action
    _reply("ACK " + command)
    try:
        move_function(COMMAND_STEPS, direction)
    except Exception as exc:
        _reply("ERR MOTOR " + command)
        print("Motor command failed:", command, exc)
        return
    _reply("DONE " + command)


def uart_handler():
    """Continuously receive commands without losing split or joined packets."""
    line_buffer = bytearray()
    _reply("READY UART2 9600")

    while True:
        if not uart.any():
            time.sleep_ms(10)
            continue

        incoming = uart.read()
        if not incoming:
            continue

        for value in incoming:
            # The six motion commands are intentionally valid as single bytes,
            # because a simple FPGA UART transmitter may not append a newline.
            if not line_buffer and 49 <= value <= 56:
                execute_command(chr(value))
                continue

            if value in (10, 13):
                if line_buffer:
                    try:
                        command = line_buffer.decode("ascii")
                    except UnicodeError:
                        _reply("ERR ENCODING")
                    else:
                        execute_command(command)
                    line_buffer = bytearray()
                continue

            if 32 <= value <= 126:
                line_buffer.append(value)
                if len(line_buffer) > MAX_LINE_LENGTH:
                    line_buffer = bytearray()
                    _reply("ERR TOO_LONG")


if __name__ == "__main__":
    uart_handler()
