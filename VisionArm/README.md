# VisionArm SoC

基于官方 Chiplab Loongson/OpenLA500 SoC 的视觉机械臂增量工程。

当前已下板验证的功能：

- OpenLA500 + Linux 5.14.0-rc2；
- OV5640 320x240 RGB565，经 VDMA/DDR 双缓冲输出 640x480 VGA；
- Linux UART 文本镜像到 VGA；
- Linux `cam` 控制摄像头 DMA；
- FPGA UART -> ESP32 -> 机械臂，Linux `arm` 控制 X/Y/Z/夹爪；
- ALIENTEK 4.3-inch NT35510 LCD，支持 DDR RGB565 静态图；
- Linux `lcdctl` 与贪吃蛇程序。

本仓库只保存“相对官方 Chiplab 的新增/修改内容”，不提交 Vivado `.runs/.cache/.gen/.Xil`
等临时目录。已验证 bitstream 和 Linux 内核放在 GitHub Release 附件中。

> 队友若只想立即演示：下载 Release。若要继续修改 RTL：clone 本仓库并执行 overlay 脚本。

队友首次使用请直接看 [QUICK_START.md](QUICK_START.md)。详细架构、时钟和变更记录位于
`docs/`。

若要合入团队现有的 `eugeci/nscscc2026_xupt` 仓库，请看
[INTEGRATE_NSCSCC_REPO.md](INTEGRATE_NSCSCC_REPO.md)。

## 目录

```text
fpga/overlay/       覆盖到官方 chiplab 根目录的当前 FPGA 文件
fpga/baseline/      最初官方快照和稳定 BRAM 摄像头基线源码
fpga/scripts/       一键部署与 Vivado 源文件核对脚本
esp32/              机械臂 MicroPython 文件系统
linux/              arm/cam/lcdctl/snake 与内核构建说明
docs/               时钟、寄存器、变更记录、使用说明
release/            GitHub Release 附件清单（不存大二进制）
```

## 稳定演示顺序

1. 下载 Release 中的当前 bitstream 和 `vmlinux_lcd`。
2. 下载 bitstream，TFTP 启动 Linux。
3. `lcdctl show` 显示静态图片；如需摄像头，随后执行 `cam on`。
4. `arm x forward 200` 等命令控制机械臂。

注意：摄像头运行后再执行 `lcdctl show` 会争用 DDR S04 读通道，当前可能叠图/花屏。
