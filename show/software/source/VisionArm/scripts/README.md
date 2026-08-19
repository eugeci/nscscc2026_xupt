# 烧录 PMON 后自动启动 Linux

`boot_linux.py` 自动完成 Chiplab 文档中烧录 Flash 之后的全部步骤：

1. 配置主机直连网口；
2. 在 UDP 69 启动只读 TFTP 服务；
3. 用 Vivado Hardware Manager 下载合并后的 FPGA bitstream；
4. 通过 115200 8N1 串口等待 PMON；
5. 自动执行 `ifconfig`、`load` 和 `g`；
6. 等待 Linux 的 `/ #` 提示符，然后进入交互式串口控制台。

## 接线和准备

- SPI Flash 已经烧录 PMON；
- JTAG 下载线、USB 转 TTL 串口线和网线均已连接；
- 串口没有被 minicom、SecureCRT 等其他程序占用；
- Vivado 2023.2 可用；
- `show/soc/bit/soc_top.bit`、`show/software/bin/kernel/vmlinux_xnpu_rxtrig1_nojob_stripped`
  和配套 `linux_handoff_trampoline_a4f_xnpu` 均存在。

查看主机直连网卡和串口名称：

```sh
ip -br link
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
```

## 一条命令启动

假设直连网卡为 `enp3s0`、串口为 `/dev/ttyUSB0`：

```sh
cd show
sudo -E python3 software/source/VisionArm/scripts/boot_linux.py \
  --interface enp3s0 \
  --serial /dev/ttyUSB0 \
  --bit soc/bit/soc_top.bit \
  --kernel software/bin/kernel/vmlinux_xnpu_rxtrig1_nojob_stripped \
  --handoff-elf software/bin/kernel/linux_handoff_trampoline_a4f_xnpu \
  --handoff-tftp-name linux_handoff_trampoline_a4f_xnpu \
  --bootargs ""
```

默认网络参数与现有 VisionArm 文档一致：

- 主机/TFTP：`192.168.1.100/24`
- 开发板：`192.168.1.101`
- TFTP 文件名：`vmlinux_xnpu_rxtrig1_nojob_stripped`
- Linux 参数：`console=ttyS0,115200 rdinit=/sbin/init initcall_debug=1 loglevel=20 ignore_loglevel`

脚本成功后会保持串口交互，按 `Ctrl-]` 退出。

## 常用选项

仅检查文件和工具，不操作硬件：

```sh
./scripts/boot_linux.py --check --interface enp3s0 --serial /dev/ttyUSB0
```

已经手工下载 bitstream 时：

```sh
sudo -E ./scripts/boot_linux.py --interface enp3s0 \
  --serial /dev/ttyUSB0 --skip-program
```

已经配置主机 IP，并使用 Tftpd32/tftpd-hpa 等外部 TFTP 服务时：

```sh
./scripts/boot_linux.py --serial /dev/ttyUSB0 \
  --skip-network-config --external-tftp
```

启动成功后立即退出、不进入交互控制台：

```sh
sudo -E ./scripts/boot_linux.py --interface enp3s0 \
  --serial /dev/ttyUSB0 --no-console
```

## 等价的 PMON 命令

脚本依次发送：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_xnpu_rxtrig1_nojob_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f_xnpu
g
```

设备树使用 `reserved-memory/no-map` 隔离顶部8 MiB视频帧缓冲，因此启动参数
不再用 `mem=120M` 截断物理地址范围；自动脚本仍可看到内核输出和shell提示符。

若 TFTP 绑定 UDP 69 失败，确认使用了 `sudo -E`，并检查系统中是否已有
TFTP 服务占用端口。若等待 PMON 超时，检查 Flash、JTAG bitstream、串口接线
及 115200 波特率。
