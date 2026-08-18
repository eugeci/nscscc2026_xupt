# uCore LoongArch32 镜像

镜像基于 `cyyself/ucore-loongarch32`。当前推荐使用带 initrd、polling 串口输入、
双路 cache 维护和 RI 诊断的 ELF 镜像：

- `ucore-kernel-initrd-polling-2way-memdiag.elf`：板测基线，可输入命令；
- `ucore-kernel-initrd-polling-2way-memdiag-uncached-pte.elf`：把用户可执行页
  的 TLB MAT 设为 uncached 的定位镜像；
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

该镜像的第一次 `ls` 仍失败而第二次成功，说明只把用户代码页改成 MAT=0
不能绕过问题，需继续检查 TLB MAT 到 ICache/AXI 取指请求的硬件传播和响应
归属。

早期 `.bin` 文件不是 ELF。若确需使用，应以 PMON 的 raw load base 选项装到
`0xa0000000` 后从该地址运行；不要写成 `load -r -f 0xa0000000 ...`，因为
该 PMON 中 `-f` 表示写 Flash，会报 `No FLASH at given address`。为减少命令
差异，当前复现统一使用上面的 `.elf`。

## SHA256

```text
c8e35b34d81ad5c6dee1cf03f70545795c7220db4f8277f0a5112e23311937b3  ucore-kernel-initrd-polling-2way-memdiag.elf
690734aacc893ba58a05c7ab1667db28d3630de4c6a53b950e050d32c960ec66  ucore-kernel-initrd-polling-2way-memdiag-uncached-pte.elf
c4a624c3a78911de4ab884adb930f8431aad8d83e9c46f25ca15d648db0c86c5  ucore-kernel-initrd-fence-fix-diag.bin
0feb0181c1364b90202ac049c3f1778ac648cb3886aceecaa774cfbcaf5be6df  ucore-kernel-initrd-fence-fix.bin
```
