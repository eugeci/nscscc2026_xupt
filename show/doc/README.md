# VisionArm + XNPU 总体使用说明

## 1. 硬件准备

- 龙芯杯开发板，器件 XC7A200T-FBG676-2；
- JTAG 下载器、USB 转 TTL 串口和主机直连网线；
- SPI Flash 已烧录 PMON；
- 使用 Vivado 2023.2；
- 主机具备 Python 3，并允许以 root 权限绑定 TFTP UDP 69 和配置网卡。

机械臂 UART 默认接线：FPGA TX 接 ESP32 GPIO17，FPGA RX 接 ESP32 GPIO4，
两侧共地，串口参数为 9600、8N1、无流控。当前 FPGA 主要使用发送通道。

## 2. 文件校验

在 `show/` 目录执行：

```sh
sha256sum -c soc/bit/SHA256SUMS.txt
cd software/bin
sha256sum -c SHA256SUMS.txt
```

版本来源和已知验证状态见 `版本与校验.md`。

## 3. 启动 Linux

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

默认网络为主机 `192.168.1.100/24`、开发板 `192.168.1.101/24`，串口为
115200 8N1。脚本依次下载 bit、启动只读 TFTP、向 PMON 发送内核加载命令并等待
Linux shell。先用 `--check` 可以只检查文件、工具和参数，不操作硬件。

## 4. 基础展示

进入 Linux 后依次检查：

```sh
cam status
arm status
lcdctl status
ls -l /dev/xnpu
dmesg | grep -i xnpu
```

建议先执行 `lcdctl show` 验证静态图，再启动摄像头。机械臂运动前必须完成回零、
方向和限位检查。

## 5. NPU 展示

```sh
xnpu-inspect /models/facenet_lbp_v1.xnpu
xnpu-run --poll \
  --expect-checksum 0x685184b3 \
  --expect-bbox 58,132,81,104,137 \
  /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin

xnpu-run \
  --expect-checksum 0x685184b3 \
  --expect-bbox 58,132,81,104,137 \
  /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

第一条使用轮询，第二条验证中断等待路径。预期 checksum 为 `0x685184b3`，
bbox 字节为 `58,132,81,104,137`。

## 6. 参考资料

- `reference/QUICK_START.md`：原始快速启动说明；
- `reference/VisionArm-docs/视觉机械臂使用手册.md`：接线和机械臂命令；
- `reference/VisionArm-docs/XNPU积木识别闭环演示与标定指南.md`：标定流程；
- `reference/xnpu/UAPI.md`：Linux XNPU ABI；
- `reference/xnpu/XNPU_FORMAT.md`：模型包格式。
