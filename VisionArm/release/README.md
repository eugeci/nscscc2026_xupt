# 可直接运行的文件

| 文件 | 用途 |
|---|---|
| `visionarm_soc_top.bit` | 最后下板验证的 FPGA 比特流 |
| `visionarm_npu_soc_top.bit` | VisionArm 外设与 NPU 合并后的演示比特流（CPU 40 MHz、NPU 33.14 MHz、VGA 50.43 MHz） |
| `vmlinux_visionarm_lcd` | 集成 VisionArm 工具和 LCD 的 Linux 内核 |
| `vmlinux_visionarm_xnpu` | 集成机械臂、相机、LCD 与 XNPU 驱动和测试工具的 Linux 内核 |
| `vmlinux_visionarm_xnpu_rxtrig1_nojob` | 板测通过的 XNPU Linux 内核；UART RX FIFO trigger=1，启动无 job-control 交互 shell |
| `linux_handoff_trampoline_a4f_xnpu` | 与上述板测内核匹配的 PMON 跳板，入口地址 `0xa0b868f0` |
| `visionarm_npu_build_summary.md` | 合并比特流的综合、布局布线和时序摘要 |
| `SHA256SUMS.txt` | 发布文件的 SHA-256 校验值 |

## 自研核最终板测交付（推荐）

本组文件对应当前已经在板上验证的 NPU/Linux 路径。`visionarm_npu_soc_top.bit`
提供 NPU、摄像头、LCD 和 VGA 外设；本次软件提交不修改比特流或 CPU RTL。

在 PMON 中按顺序执行（TFTP 根目录应包含下面两个文件）：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_visionarm_xnpu_rxtrig1_nojob
load tftp://192.168.1.100/linux_handoff_trampoline_a4f_xnpu
g
```

进入 Linux 后，先做最小验收：

```sh
ls -l /dev/xnpu
devmem 0x1f100158 32       # 期望 0x0000000f：AXI DMA/packed preload/writeback/descriptor RAM
devmem 0x1f10015c 32       # 期望 0x00000002：XNPU hardware ABI v2
xnpu-inspect /models/facenet_lbp_v1.xnpu
xnpu-run --poll --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

最后一条命令应输出 `XNPU_RUN_PASS`、`checksum=0x685184b3` 和
`bbox=58,132,81,104,137`。若使用串口工具手工输入时首字符偶发丢失，可在命令前
先输入一个空格；该镜像已将 UART RX trigger 降为 1 以降低 overrun 风险。

`vmlinux_visionarm_xnpu_rxtrig1_nojob` 的设备树只向 Linux 声明低端 120 MiB DDR；
顶部 8 MiB 固定留给摄像头双帧缓冲。不要用未配套的跳板启动该内核。

## 使用顺序

Flash 已烧录 PMON 后，在 Linux 主机上执行：

```sh
cd VisionArm
sudo -E ./scripts/boot_linux.py --interface enp3s0 --serial /dev/ttyUSB0
```

脚本会自动配置网口、启动 TFTP、下载 bitstream、执行 PMON 命令并等待 Linux
shell。将网卡和串口名称替换为实际设备，完整说明见 `scripts/README.md`。

使用 Windows TFTP 或需要手工排障时，等价的 PMON 命令为：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_visionarm_xnpu
g console=ttyS0,115200 rdinit=/sbin/init mem=120M initcall_debug=1 loglevel=20 ignore_loglevel
```

Windows 校验示例：

```powershell
Get-FileHash .\visionarm_soc_top.bit -Algorithm SHA256
Get-FileHash .\visionarm_npu_soc_top.bit -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_lcd -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_xnpu -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_xnpu_rxtrig1_nojob -Algorithm SHA256
Get-FileHash .\linux_handoff_trampoline_a4f_xnpu -Algorithm SHA256
```

`vmlinux_visionarm_xnpu` 的设备树只向 Linux 声明低端120 MiB DDR；顶部8 MiB
固定留给摄像头在 `0x07c00000` 和 `0x07d00000` 的双帧缓冲。当前PMON不能可靠
把 `g` 命令后的参数传给内核，因此该隔离不能只依赖命令行中的 `mem=120M`。

Linux启动时会自动把 `eth0` 配置为 `192.168.1.101/24`。主机网口使用
`192.168.1.100/24`；进入shell后可用 `ping 192.168.1.100` 检查运行时网络。

启动后可先确认驱动，再分别执行轮询和中断推理：

```sh
ls -l /dev/xnpu
dmesg | grep -i xnpu
xnpu-inspect /models/facenet_lbp_v1.xnpu
xnpu-run --poll --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
xnpu-run --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```
