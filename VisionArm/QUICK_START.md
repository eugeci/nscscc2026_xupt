# 队友快速上手

## A. 只想直接演示

从 GitHub Release 下载：

- `soc_top_current.bit`
- `vmlinux_lcd`
- `naruto_800x480.rgb565`（需要 LCD 静态图时）

bitstream 对应 Vivado 2023.2、Artix-7 `xc7a200tfbg676-2`。

附件可用 PowerShell 校验：

```powershell
Get-FileHash .\soc_top_current.bit -Algorithm SHA256
Get-FileHash .\vmlinux_lcd -Algorithm SHA256
```

## B. 在官方 Chiplab 上继续开发

要求队友已有同版本官方 `chiplab` 目录。管理员 PowerShell 不必使用，普通 PowerShell 即可：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\fpga\scripts\apply_overlay.ps1 `
  -ChipRoot "D:\longarch\nscscc2026_xupt\chiplab"
```

脚本会先备份被替换的顶层、CONFREG、XDC 和 XPR，再复制当前 overlay。然后：

1. 用 Vivado 2023.2 打开 `<chiplab>/fpga/loongson/2023.2/system_run.xpr`；
2. 在 Tcl Console 执行：

```tcl
source <本仓库绝对路径>/fpga/scripts/check_project_sources.tcl
```

3. 看到 `VISIONARM_PROJECT_READY` 后，运行 Synthesis、Implementation、Generate Bitstream。

为避免 `dbg_hub` 路径过长，建议把仓库和 Chiplab 放在较短路径，或使用 Windows `subst`。

## C. 最需要先看的源码

- `fpga/overlay/chiplab/chip/soc_demo/loongson/soc_top.v`
- `fpga/overlay/chiplab/IP/CONFREG/confreg_syn.v`
- `fpga/overlay/chiplab/fpga/loongson/soc_up.xdc`
- `docs/时钟说明.md`
- `docs/更新记录.md`
- `docs/寄存器映射.md`
- `docs/视觉机械臂使用手册.md`

## D. Linux 常用命令

```sh
cam status
cam on
arm status
arm x forward 200
arm y up 200
arm grip open
lcdctl status
lcdctl show
snake
```
