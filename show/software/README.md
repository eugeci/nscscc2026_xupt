# 展示软件

## 目录

- `source/VisionArm/`：ESP32 MicroPython、Linux 端工具、机械臂/摄像头程序、
  启动脚本和标定工具源码。
- `source/linux/npu/`：XNPU Linux 驱动、UAPI、用户态运行库、补丁和构建脚本。
- `source/chiplab/IP/NPU/`：NPU 模型、参数、部署包生成脚本及相关源码。
- `bin/kernel/vmlinux_xnpu_rxtrig1_nojob_stripped`：已完成板测的 VisionArm/XNPU LA32R Linux
  内核及 initramfs，包含 UART RX trigger=1 与无 job-control 交互 shell 修正。
- `bin/kernel/linux_handoff_trampoline_a4f_xnpu`：与上述内核入口匹配的 PMON
  交接跳板。
- `bin/xnpu-tools/`：LA32R 静态链接的 `xnpu-inspect`、`xnpu-run`、
  `xnpu-regress` 和 `libxnpu.a`。
- `bin/models/`：四个 `.xnpu` 部署包和回归清单。
- `bin/fixtures/`：模型演示/回归输入及期望结果二进制。
- `bin/assets/`：LCD RGB565 演示图片和预览图。

只复制了明确的最终产物，没有复制整个 `linux/npu/.work/` 构建目录。

## 启动

从 `show/` 目录执行，并将网卡、串口名称替换为本机实际设备：

```sh
sudo -E python3 software/source/VisionArm/scripts/boot_linux.py \
  --interface enp3s0 \
  --serial /dev/ttyUSB0 \
  --bit soc/bit/soc_top.bit \
  --kernel software/bin/kernel/vmlinux_xnpu_rxtrig1_nojob_stripped \
  --handoff-elf software/bin/kernel/linux_handoff_trampoline_a4f_xnpu \
  --handoff-tftp-name linux_handoff_trampoline_a4f_xnpu \
  --bootargs ""
```

复制的启动脚本保持原始源码不变，因此必须显式提供本交付包中的 bit、内核和
跳板路径。Windows 下也可按 `../README.md` 中的三条 PMON 命令手工启动。

## 常用演示命令

```sh
cam status
cam on
arm status
arm home
lcdctl status
lcdctl show
snake

xnpu-inspect /models/facenet_lbp_v1.xnpu
xnpu-run --poll \
  --expect-checksum 0x685184b3 \
  --expect-bbox 58,132,81,104,137 \
  /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

`visionarm-block` 的闭环控制还需要有效标定文件和专用积木分类模型；交付包没有
将其描述为已完成的默认演示。
