# LA32R Linux UART RX 最小仿真

`tb_uart_serial_timeout.v` 配合 Chiplab `6a931ee` 或 `731ebc2` 的
`IP/APB_DEV/URT` 使用。它按 Linux 板测配置写入 divisor 18、8N1、FIFO
trigger 8 和 `IER=0x05`，随后在真实 RX 引脚时序上只发送一个字节，检查四个
字符时间后是否产生 timeout IRQ/IIR `0x0c`。

Vivado 2023.2 XSim 运行示例（在 Chiplab 根目录执行，并按实际 Vivado 路径
调整命令）：

```powershell
xvlog -i IP/APB_DEV/URT IP/APB_DEV/URT/raminfr.v `
  IP/APB_DEV/URT/uart_sync_flops.v IP/APB_DEV/URT/uart_tfifo.v `
  IP/APB_DEV/URT/uart_rfifo.v IP/APB_DEV/URT/uart_transmitter.v `
  IP/APB_DEV/URT/uart_receiver.v IP/APB_DEV/URT/uart_regs.v `
  artifacts/uart/tb_uart_serial_timeout.v
xelab tb_uart_serial_timeout -s tb_uart_serial_timeout_sim
xsim tb_uart_serial_timeout_sim -runall
```

当前原样 RTL 的通过标记为：

```text
UART_SERIAL_TIMEOUT_PASS count=1 counter_t=0 iir=0x0c ier=5
```

Chiplab `731ebc2` 已有32字节 `tb_uart_rx_burst.sv`；两个用例应同时保留：
burst 用例覆盖 FIFO trigger/RDA 和持续服务，本用例覆盖短命令依赖的 timeout。
