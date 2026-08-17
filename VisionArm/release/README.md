# 可直接运行的文件

| 文件 | 用途 |
|---|---|
| `visionarm_soc_top.bit` | 最后下板验证的 FPGA 比特流 |
| `visionarm_npu_soc_top.bit` | VisionArm 外设与 NPU 合并后的演示比特流（CPU 40 MHz、NPU 33.14 MHz、VGA 50.43 MHz） |
| `vmlinux_visionarm_lcd` | 集成 VisionArm 工具和 LCD 的 Linux 内核 |
| `vmlinux_visionarm_xnpu` | 集成机械臂、相机、LCD 与 XNPU 驱动和测试工具的 Linux 内核 |
| `visionarm_npu_build_summary.md` | 合并比特流的综合、布局布线和时序摘要 |
| `SHA256SUMS.txt` | 发布文件的 SHA-256 校验值 |

当前 `visionarm_npu_soc_top.bit` 固化了摄像头启停修复：软件关闭摄像头时
只停止新帧输入，不再单独复位仍可能存在未完成 DDR 事务的 AXI VDMA。
该版本已通过综合、布局布线和 bitstream 生成，连续抓帧下板复测尚未完成。

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
g console=ttyS0,115200 rdinit=/sbin/init initcall_debug=1 loglevel=20 ignore_loglevel
```

Windows 校验示例：

```powershell
Get-FileHash .\visionarm_soc_top.bit -Algorithm SHA256
Get-FileHash .\visionarm_npu_soc_top.bit -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_lcd -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_xnpu -Algorithm SHA256
```

`vmlinux_visionarm_xnpu` 的设备树声明完整128 MiB DDR，并通过
`reserved-memory/no-map` 将顶部8 MiB固定留给LCD暂存帧以及摄像头在
`0x07c00000` 和 `0x07d00000` 的双帧缓冲。当前PMON不能可靠传递 `g` 命令后的
参数，因此内存隔离完全由设备树保证，不依赖命令行中的 `mem=`。

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
