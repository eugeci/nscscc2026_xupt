# uCore VisionArm 保底方案源码覆盖层

本目录是相对 `cyyself/ucore-loongarch32` 源码树的可直接覆盖层，同时
包含前期为自研核下板增加的 polling 串口、双路 cache 维护和诊断修改。

主要新增内容：

- `kern/driver/visionarm.c`：内核态 MMIO 白名单、LCD RGB565 测试卡；
- `user/cam.c`：`cam on|off|status|info|test`；
- `user/lcdctl.c`：`lcdctl status|show|bars|switch|off`；
- `user/vga.c`：`vga terminal|camera|status`；
- `SYS_vision_mmio`/`SYS_vision_lcd_test`：用户程序仅能访问 VisionArm
  机械臂、摄像头和 LCD 寄存器白名单。

## 安装与编译

把本目录中除 `README.md` 外的内容原样覆盖到 uCore 源码根目录：

```sh
make clean
make ON_FPGA=y
loongarch32r-linux-gnusf-strip --strip-all \
  -o ucore-kernel-initrd-visionarm-fallback.elf obj/ucore-kernel-initrd
```

输出 ELF 入口是 `0xa0000000`。精简符号表可避免 PMON 的
`not enough memory ... table` 提示。

## 地址与安全边界

- uCore DMW1 把 `0x80000000..0x9fffffff` 未缓存直映射到低 512 MiB；
- 物理 `0x1fd0e100` 由内核地址 `0x9fd0e100` 访问；
- LCD 帧缓冲物理地址为 `0x07800000`，uCore 通过 `0x87800000` 写入；
- LCD 和摄像头共用 DDR MM2S 路径，`lcdctl show` 会先停摄像头。

镜像要求 bitstream 实现 VisionArm 寄存器协议。首项上板检查是
`cam info`，magic 必须为 `0x43414d31`。
