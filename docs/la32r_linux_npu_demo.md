# LA32R Linux + XNPU 板测记录

2026-08-19 在现有 VisionArm/NPU bitstream 上完成实测。不需要更换
比特流；本次只更换 Linux 软件镜像和 PMON 跳板。镜像内含 XNPU
驱动、`/dev/xnpu`、`xnpu-inspect` 和 `xnpu-run`。

## PMON 启动

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_xnpu_rxtrig1_nojob_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f_xnpu
g
```

TFTP 文件校验值：

```text
724d5bed3e79cefe847da05d2c5e33c114b7cb7b95744631257a9c4de04c299
  vmlinux_xnpu_rxtrig1_nojob_stripped
eeb9897a59be2d6847b2d400a259bc6ce40ea3703284075889b6a7daa042050b
  linux_handoff_trampoline_a4f_xnpu
```

注意：PMON 复位后必须重新执行 `ifconfig`。跳板与该镜像匹配的
Linux ELF 入口为 `0xa0b868f0`，不能使用旧的 `a07c4d78` 跳板。

## 基础检查

```sh
ls -l /dev/xnpu
devmem 0x1f100158 32
devmem 0x1f10015c 32
xnpu-inspect /models/facenet_lbp_v1.xnpu
```

raw `HW_CAPS` 寄存器返回 `0x0000000f` 是正常的，表示已有：

- AXI DMA；
- packed preload；
- result writeback；
- descriptor RAM。

Linux 驱动会额外加上 IRQ 和 legacy 兼容位，因此用户态 capability
通常显示 `0x0000003f`。ABI 寄存器 `0x1f10015c` 应返回 `0x00000002`。

## 轮询推理（首选）

为避免串口首字节丢失，手动输入时在命令前加一个空格：

```sh
 xnpu-run --poll --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

已验证输出：

```text
status=0x00000002
bbox=58,132,81,104,137
XNPU_RUN_PASS
```

这一次通过同时证明了模型包解析、DMA 读取输入、NPU 执行、
结果 writeback 和校验值均正常。轮询成功后再测中断版：

```sh
 xnpu-run --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

## 串口注意

NPU 队友发布内核与已稳定 Linux 内核的 8250 trigger 配置不同，因此
在部分串口工具中仍可能看到 `ttyS0: input overrun(s)`或首字节污染。
`vmlinux_xnpu_rxtrig1_nojob_stripped` 在 `/init` 中尝试把 16550A FCR 设为
RX trigger=1，但手动输入仍建议在命令前加空格。这不影响已验证的
XNPU 推理结果。
