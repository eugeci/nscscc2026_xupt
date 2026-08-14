"""ESP32 mechanical-arm entry point controlled by external UART commands."""

import uart_c


def main():
    print("Mechanical arm UART mode")
    uart_c.uart_handler()


if __name__ == "__main__":
    main()
