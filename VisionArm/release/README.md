# 可直接运行的文件

| 文件 | 用途 |
|---|---|
| `visionarm_soc_top.bit` | 最后下板验证的 FPGA 比特流 |
| `vmlinux_visionarm_lcd` | 集成 VisionArm 工具和 LCD 的 Linux 内核 |
| `SHA256SUMS.txt` | 两个文件的 SHA-256 校验值 |

## 使用顺序

1. Vivado Hardware Manager 下载 `visionarm_soc_top.bit`。
2. 将 `vmlinux_visionarm_lcd` 放到 Windows TFTP 根目录。
3. PMON 执行：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_visionarm_lcd
g console=ttyS0,115200 rdinit=/sbin/init mem=120M
```

Windows 校验示例：

```powershell
Get-FileHash .\visionarm_soc_top.bit -Algorithm SHA256
Get-FileHash .\vmlinux_visionarm_lcd -Algorithm SHA256
```
