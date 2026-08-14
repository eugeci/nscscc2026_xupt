# 可直接运行的文件

| 文件 | 用途 |
|---|---|
| `visionarm_soc_top.bit` | 最后下板验证的 FPGA 比特流 |
| `visionarm_npu_soc_top.bit` | VisionArm 外设与 NPU 合并后的演示比特流（CPU 40 MHz、NPU 33.14 MHz、VGA 50.43 MHz） |
| `vmlinux_visionarm_lcd` | 集成 VisionArm 工具和 LCD 的 Linux 内核 |
| `visionarm_npu_build_summary.md` | 合并比特流的综合、布局布线和时序摘要 |
| `SHA256SUMS.txt` | 发布文件的 SHA-256 校验值 |

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
load tftp://192.168.1.100/vmlinux_visionarm_lcd
g console=ttyS0,115200 rdinit=/sbin/init mem=120M
```

Windows 校验示例：

```powershell
Get-FileHash .\visionarm_soc_top.bit -Algorithm SHA256
Get-FileHash .\visionarm_npu_soc_top.bit -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_lcd -Algorithm SHA256
```
