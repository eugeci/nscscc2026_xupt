# VisionArm 快速使用

## 0. 直接演示

`release/` 中已经提供：

- `visionarm_soc_top.bit`
- `visionarm_npu_soc_top.bit`（NPU 与机械臂/摄像头/LCD 综合演示）
- `vmlinux_visionarm_lcd`
- `vmlinux_visionarm_xnpu`（机械臂/摄像头/LCD 与 XNPU 驱动综合内核）

不需要重新综合时，综合演示请使用 `visionarm_npu_soc_top.bit` 和
`vmlinux_visionarm_xnpu`。

Flash 已烧录 PMON 后，可在 Linux 主机上一条命令完成 bitstream 下载、TFTP
服务、PMON 命令和 Linux 启动：

```sh
sudo -E ./scripts/boot_linux.py --interface enp3s0 --serial /dev/ttyUSB0
```

将网卡和串口名称替换为实际设备，完整说明见 `scripts/README.md`。

## 1. FPGA 工程

Vivado 2023.2 打开：

```text
chiplab/fpga/loongson/2023.2/system_run.xpr
```

生成并下载比特流后，再按原流程 TFTP 启动 Linux。

## 2. Linux 常用命令

```sh
cam status
cam on
arm status
arm x forward 200
arm y up 200
arm z forward 200
arm grip open
arm grip close
arm home
lcdctl status
lcdctl show
snake
```

XNPU 驱动与推理测试：

```sh
ls -l /dev/xnpu
dmesg | grep -i xnpu
xnpu-inspect /models/facenet_lbp_v1.xnpu
xnpu-run --poll --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
xnpu-run --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

建议先显示 LCD 静态图，再启动摄像头。摄像头运行后重新显示 LCD 静态图，可能因 DDR 读通道争用出现叠图。

## 3. 机械臂 UART

- FPGA TX → ESP32 GPIO17（UART2 RX）
- FPGA RX ← ESP32 GPIO4（UART2 TX；当前 FPGA 尚未实现接收）
- FPGA GND ↔ ESP32 GND
- 串口参数：9600、8N1、无流控

ESP32 文件位于 `VisionArm/esp32/filesystem/`。

## 4. 详细资料

- `docs/视觉机械臂使用手册.md`
- `docs/XNPU积木识别闭环演示与标定指南.md`
- `docs/闭环演示硬件待确认清单.md`
- `docs/寄存器映射.md`
- `docs/时钟说明.md`
- `docs/更新记录.md`
