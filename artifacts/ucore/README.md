# uCore LoongArch32 镜像

镜像基于 `cyyself/ucore-loongarch32`。当前推荐使用带 initrd、polling 串口输入、
双路 cache 维护和 RI 诊断的 ELF 镜像：

- `ucore-kernel-initrd-visionarm-fallback.elf`：新增 `cam/lcdctl/vga`的保底镜像；
- `ucore-kernel-initrd-polling-2way-memdiag.elf`：板测基线，可输入命令；
- `ucore-kernel-initrd-polling-2way-memdiag-uncached-pte.elf`：原计划把用户
  可执行页的 TLB MAT 设为 uncached 的定位镜像；但板上打印的最终
  `Code PTE=...005` 不含 `PTE_PCD=0x010`，当前只能视为“待验证构建”，
  不能作为 MAT=0 已生效的证据；
- `ucore-kernel-initrd-fence-fix.bin`：早期裸二进制镜像；
- `ucore-kernel-initrd-fence-fix-diag.bin`：早期裸二进制诊断镜像。

## 推荐下板步骤

1. Vivado Hardware Manager 下载
   `soc_top_wb_repair_6e5d375_a140b4a.bit`，然后按一次板卡复位；
2. 把需要测试的 `.elf` 复制到 TFTP 根目录；
3. 串口使用 `115200 8N1`，在 PMON 执行：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/ucore-kernel-initrd-polling-2way-memdiag.elf
g
```

PMON 应识别为 `(elf)`，给出 `Entry address is a0000000`；`g` 后 uCore 完成
初始化并显示 `$`。uCore 已带 initrd，不需要 Linux handoff trampoline，也不
需要再加载第二个文件。进入 shell 后依次输入：

```text
ls
ls
cat test.txt
```

VisionArm 保底镜像的额外验证命令为：

```text
cam info
cam status
lcdctl bars
lcdctl show
cam on
cam test
vga terminal
```

该镜像要求 bitstream 实现 VisionArm 外设寄存器协议。当前队友已将
自研核与这些外设合入同一 bitstream，上板时用 `cam info` 的
`0x43414d31` magic 做第一项 ABI 验收。完整流程见
`docs/ucore_linux_dual_track.md`。

在 `a140b4a` bitstream 上的已知现象是：冷启动后第一次 `ls` 在用户态入口
附近触发 RI 并杀死进程，第二次 `ls` 能列出目录，`cat test.txt` 正常。

在 IRQ 同步重构版 bitstream（Chiplab `6a931ee`，SHA256
`334077203262288dfb2047083dcad81cbbf64fc71c8f9550d1eaa8d86aa530a4`）
上，`uncached-pte` 镜像已经得到一次“冷启动后第一次 `ls` 成功，随后
`cat test.txt` 成功”的板测结果。该结果尚需至少5次完全复位重复，并需再用
普通 cached 基线镜像对照；单次成功不能证明 cache/MMU 根因已经闭环。

要验证 MAT/uncached 取指链路，只把加载文件换成：

```text
load tftp://192.168.1.100/ucore-kernel-initrd-polling-2way-memdiag-uncached-pte.elf
g
```

注意：此前把“第一次 `ls` 仍失败、第二次成功”解释为“MAT=0 不能绕过”并不
成立。板上 RI 诊断打印的 `Code PTE` 低位为 `0x005`，而软件定义
`PTE_PCD=0x010`；真正设置后的 PTE 应至少以 `0x015` 结尾。下一版必须同时
打印最终 PTE、refill 输入 PTE 和 TLBRD 后的 TLBELO，确认 `MAT[5:4]=00` 后
才能继续判断 TLB/ICache。完整纠正和仿真清单见
`docs/ucore_linux_wb_tlb_investigation.md`。

早期 `.bin` 文件不是 ELF。若确需使用，应以 PMON 的 raw load base 选项装到
`0xa0000000` 后从该地址运行；不要写成 `load -r -f 0xa0000000 ...`，因为
该 PMON 中 `-f` 表示写 Flash，会报 `No FLASH at given address`。为减少命令
差异，当前复现统一使用上面的 `.elf`。

## SHA256

```text
8b4c6756cdc860f515797ffc2f1f6f519e398a8e796cb620ae3aa923b9e0d238  ucore-kernel-initrd-visionarm-fallback.elf
c8e35b34d81ad5c6dee1cf03f70545795c7220db4f8277f0a5112e23311937b3  ucore-kernel-initrd-polling-2way-memdiag.elf
690734aacc893ba58a05c7ab1667db28d3630de4c6a53b950e050d32c960ec66  ucore-kernel-initrd-polling-2way-memdiag-uncached-pte.elf
c4a624c3a78911de4ab884adb930f8431aad8d83e9c46f25ca15d648db0c86c5  ucore-kernel-initrd-fence-fix-diag.bin
0feb0181c1364b90202ac049c3f1778ac648cb3886aceecaa774cfbcaf5be6df  ucore-kernel-initrd-fence-fix.bin
```
