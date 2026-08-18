# LA32R Linux 下板验证记录

## 固定版本

- 主仓库基线：`origin/main` (`776d1e0`)
- 主仓库 bring-up：`bringup/la32r-linux` (`0bed310`，不含本文档提交)
- CPU：`core/feature/la32r-mmu` (`b897a7d`)
- Chiplab bring-up：`0ae86e2`（RTL/构建防护为 `a2531f4`）
- Vivado：2023.2
- CPU 时钟：33.333 MHz（系统时钟 100 MHz，DDR 参考时钟 200 MHz）

`core` 不创建额外分支，所有 CPU 修复继续提交到共享的
`feature/la32r-mmu`。主仓库和 Chiplab 的 bring-up 分支只负责固定一次
可复现的下板组合。

## 已通过检查

- NSCSCC VCS RTL 回归：17/17
- Vivado 综合、布局、布线和 bitstream：通过
- 布线后 setup：WNS 0.162 ns，TNS 0 ns
- 布线后 hold：WHS 0.057 ns，THS 0 ns
- 未布线网络：0

当前产物：

```text
chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.bit
SHA256 768e78be353186eac6699a245f7e9d96384cac5ca6c2122eaf2fb9c1ae43b5b3

chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.ltx
SHA256 a975bfbe8167d16dbf34916dce8fc3393d593ba93b41d0d1681a89ee9c63ee32

chiplab/software/examples/linux/vmlinux
SHA256 d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a
ELF entry 0xa07b06e0
```

## 重建

```bash
cd chiplab/fpga/loongson/2023.2
vivado -mode batch -source build_la32r_linux.tcl
```

运行前确认 `vivado -version` 为 2023.2。

`build_la32r_linux.tcl` 会在构建前移除被直接加入工程的 VIO stub/sim
netlist，并拒绝 core filelist 中的任何 VIO RTL 文件。当前构建日志报告
`REMOVED_STALE_VIO_SOURCE_COUNT=0`，最终 LTX 中只有一个 18-probe VIO。
不要使用同目录中 2026-08-17 生成的旧 `soc_top_post_route_opt.bit`。

## 首轮下板判据

1. 下载 `soc_top.bit` 后 PMON 能稳定进入提示符。
2. 通过 TFTP 加载上述基础 `vmlinux`。
3. Linux 串口无异常循环、TLB refill 死循环或 kernel panic。
4. 最终稳定出现 `/ #`。

首轮只验证 CPU、MMU、Cache、AXI、DDR、串口和基础 Linux，不接入
VisionArm、XNPU、LCD 或机械臂驱动。

## 2026-08-18 PMON 交接排查

### 板上已观察到的状态

基础内核经 TFTP 正常装载，PMON 跳到入口 `0xa07b06e0` 后没有串口
输出。VIO 捕获的首个异常为：

```text
PC       0xa09c38c8
INST     0x2a003516    # ld.bu r22, r8, 13
ECODE    0x3f          # TLB refill
BADV     0x0000000d
CRMD     0x000000a8
DMW0     0xa0000011
DMW1     0x80000001
EENTRY   0x00000180
TLBRENTRY 0x00000000
r4-r7    0, 0, 0, 0
```

该指令来自 `fw_init_environ()`。`r8 == 0` 导致访问地址 `0x0d`，所以
TLB refill 是空 `envp` 的结果，不是最先发生的 MMU 故障。

### PMON 二进制结论

分析对象为 Chiplab 文档链接的 2023-06-09 PMON：

```text
gzrom.bin
SHA256 38ddef6e2a294d7be96e565a68d46763426008fb1c4ccbdad98c75cafad19329

解压后的 pmon.bin
SHA256 8766a664befeca4b2dc808be1aaca2ec75a51b6925880ee4e8466a5f518ac3f9
```

串口输出的下面一行是无格式参数的硬编码字符串，不能作为运行时
寄存器值的证据：

```text
ac = 0x2, nsp @ 0xa5f00000, env @ 0xa5f00040, en @ 0x0
```

实际 `go` 路径在 `0x07034594..0x070345b0` 构造：

```text
r5 = 2
r6 = 0xa4f00000
r7 = 0xa4f00040
r8 = 0
r4 = 0
bl 0x07053eec
```

`0x07053eec` 将这四个值写入当前线程上下文的偏移 `16..28`。最终
交接也不是直接 `jirl`：`0x070572d8..0x07057384` 依次恢复 ESTAT、
ECFG、ERA、PRMD、CRMD 和全部 GPR，再由 `ERTN` 进入内核。辅助函数
通过 `0x070cdb70` 中的当前上下文指针写参数，而恢复路径使用固定上下文
对象 `0x070d0b50`。复测时应确认这两个指针在 `go` 时指向同一对象；若
不一致，参数会被写入非运行上下文，现象正好是内核入口 `r4-r7` 全零。

### 无板阶段回归结果

- VCS NSCSCC RTL 总回归：17/17 gate 通过。
- CPU smoke 新增真实 PMON 路径：先写上下文参数，再恢复 5 个 CSR、
  全部 GPR 并执行 `ERTN`；Linux 入口读到
  `2/0xa4f00000/0xa4f00040/0`，通过。
- LA32R MMU 定向测试：39 项检查通过，覆盖 Linux 使用的 DMW 配置。
- Chiplab Verilator 直接启动基础 Linux：随机 AXI 延迟下运行
  25,000,000 cycles、18,593,841 条指令，进入 devtmpfs/random 初始化。
- 复位随机种子 `3`、`31`、`20260818` 各运行 2,500,000 cycles，均能
  输出早期 Linux 启动信息。

因此当前已排除通用 JIRL 重定向、上下文 store/load、全 GPR 恢复、CSR
恢复、ERTN、早期 DMW/MMU 和随机复位初值问题。剩余最高优先级是板上
PMON 当前上下文对象与恢复对象是否一致，以及入口参数被写入/恢复的确切
时刻。

### 下一次上板判据

下一版 VIO 在内核入口第四条参数保存指令提交后锁存 `r4-r7`，避免在
重定向边界过早采样；同时识别 PMON `0x07053f10..0x07053f1c` 的特征
参数组，锁存实际上下文指针和 `r5-r8`。状态位 13 表示已观察到 PMON
参数写入，位 14 表示上下文指针等于恢复对象 `0x070d0b50`，位 15 表示
两者不一致。板卡重新可用后：

1. 重新生成并下载带该 VIO 的 bitstream。
2. 重复 PMON TFTP 启动，不换内核、不改变 bootargs。
3. 用 `check_linux_debug.tcl` 读取首异常、CSR、DMW 和入口参数。
4. 比较 `LINUX_DEBUG_PMON_CONTEXT` 与 `LINUX_DEBUG_KERNEL_ARGS`：若 PMON
   参数正确但指针不等于 `0x070d0b50`，可直接判定写错上下文；若指针和
   PMON 参数都正确但内核入口为零，再转查上下文恢复阶段；若入口参数
   正确，则转查内核保存 `_fw_arg0..3` 之后的数据通路。
