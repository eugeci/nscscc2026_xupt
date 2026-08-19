# 自研核 Linux + uCore VisionArm 双路方案

## 结构

队友已将自研 CPU 与 VisionArm 摄像头、LCD、VGA 终端合入同一
bitstream。这套硬件上在 PMON 中选择两个启动目标：

```text
PMON
  +-- Linux: 完整系统、网络、XNPU、cam/lcdctl/arm
  +-- uCore: 保底 shell、cam/lcdctl/vga，降低对复杂中断的依赖
```

当前是单核，因此两个 OS 是“并行维护、上电时二选一”，不是在
一个 CPU 上同时运行。

## 共用外设 ABI

寄存器和命令行为与 `feature/vision-arm-openla500` 的 VisionArm 文档、
Linux `cam`/`lcdctl` 保持一致：

| 外设 | 物理地址 | Linux | uCore |
|---|---:|---|---|
| 摄像头 | `0x1fd0e100..0x1fd0e13c` | `cam` | `cam` |
| LCD | `0x1fd0e140..0x1fd0e150` | `lcdctl` | `lcdctl` |
| VGA 源选择 | camera CTRL/status bit18 | `cam off/on` | `vga terminal/camera` |
| LCD RGB565 帧 | `0x07800000`, 800x480 | 内置图片 | 内核生成测试卡 |

uCore 用户态不暴露通用 `devmem`，而是通过内核白名单系统调用访问
MMIO。VGA 文本终端仍是 UART0 TX 的被动镜像，不另写一套字符驱动。

## 统一 bitstream 兼容性检查

参考外设实现来自 Chiplab `b4e2b5d7052ac3dc0daeec2b2065d76a577a3e77`，
而当前自研核 bringup 线另外包含 IRQ、AXI 和 cache/MMU 修改。现有统一
bitstream 不用重新合并，但上板必须通过以下 ABI 检查：

1. `cam info` 读回 magic `0x43414d31`；
2. `cam status` 中 Sensor ID、SCCB init、PCLK/VS/HREF 正常；
3. `lcdctl status` 的 initialized=1、AXI error=0；
4. `lcdctl bars` 显示彩条，`vga terminal` 恢复文本终端；
5. `lcdctl show` 完成后再 `cam on`，确认共享 DDR MM2S 没有仲裁回归。

如果第1项读回 `0xffffffff` 或非 `CAM1`，才回到 RTL 核对 CONFREG 地址
解码；不先怀疑 uCore 命令行。

## uCore 启动与验证

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/ucore-kernel-initrd-visionarm-fallback.elf
g
```

uCore 自带 initrd，不加 Linux trampoline。进入 `$` 后执行：

```text
ls
cam info
cam status
lcdctl bars
lcdctl status
lcdctl show
cam on
cam test
vga terminal
vga status
```

## Linux 启动与验证

Linux 继续使用 NAND-disabled 诊断核和 handoff trampoline。进入 `/ #` 后：

```text
lcdctl show
cam on
cam test
```

Linux 当前已稳定到达 `/ #`，但 UART RX timeout/RDA 中断仍未闭环。
uCore 保底线可独立继续外设演示。

## 验收门槛

- 同一 bitstream 分别启动 Linux 和 uCore，不重新综合；
- 两个 OS 下的 camera magic、地址和状态位一致；
- uCore 冷启动至少 5 轮，第一条 `ls`、`lcdctl bars/show`、`cam on/test`
  都成功；
- Linux 到 `/ #`，LCD 先显示再开摄像头，无 AXI error/VDMA error。
