# VisionArm 视觉机械臂系统

本目录保存 VisionArm 的使用资料、ESP32 程序和 Linux 工具。

FPGA 源码位于仓库根目录的 `chiplab` 子模块，已经集成：

- OpenLA500 CPU 与 Linux；
- OV5640 摄像头、VDMA/DDR 和 VGA；
- FPGA UART → ESP32 → 机械臂；
- ALIENTEK 4.3 寸 LCD；
- Linux 下的 `arm`、`cam`、`lcdctl` 和贪吃蛇。

## 队友首次使用

只初始化 `chiplab`，不要初始化当前无关的 `core`：

```powershell
git clone -b feature/vision-arm-openla500 https://github.com/eugeci/nscscc2026_xupt.git
cd nscscc2026_xupt
git config submodule.chiplab.url https://gitee.com/eugeci/chiplab.git
git submodule update --init chiplab
```

然后用 Vivado 2023.2 打开：

```text
chiplab/fpga/loongson/2023.2/system_run.xpr
```

工程顶层应为 `soc_top`，器件为 `xc7a200tfbg676-2`。打开后重新运行综合、实现和生成比特流。

## 目录

```text
docs/      使用手册、时钟和寄存器说明
esp32/     ESP32 MicroPython 文件
linux/     arm、cam、lcdctl、贪吃蛇和 LCD 图片资源
tools/     串口安装及调试脚本
```

常用命令和接线说明见 [QUICK_START.md](QUICK_START.md)。

已验证的比特流与 Linux 内核位于 [`release/`](release/) 目录，可直接用于下板演示。
