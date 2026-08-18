# LA32R Linux 下板验证记录

## 固定版本

- 主仓库基线：`origin/main` (`776d1e0`)
- 主仓库 bring-up：`bringup/la32r-linux` (`4db8f83`，不含本轮文档提交)
- CPU：`core/feature/la32r-mmu` (`b897a7d`)
- Chiplab bring-up：`95d10db`（RTL/构建防护为 `a2531f4`）
- Vivado：2023.2
- CPU 时钟：33.333 MHz（系统时钟 100 MHz，DDR 参考时钟 200 MHz）

`core` 不创建额外分支，所有 CPU 修复继续提交到共享的
`feature/la32r-mmu`。主仓库和 Chiplab 的 bring-up 分支只负责固定一次
可复现的下板组合。

## 已通过检查

- NSCSCC VCS RTL 回归：17/17
- Vivado 综合、布局、布线和 bitstream：通过
- 布线后 setup：WNS 0.096 ns，TNS 0 ns
- 布线后 hold：WHS 0.053 ns，THS 0 ns
- 未布线网络：0

当前产物：

```text
chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.bit
SHA256 8c954e2316ae0ecfc64e236697d005a626327d119318d7c82a72998680b0f8b3

chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.ltx
SHA256 a975bfbe8167d16dbf34916dce8fc3393d593ba93b41d0d1681a89ee9c63ee32

chiplab/software/examples/linux/vmlinux
SHA256 d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a
ELF entry 0xa07b06e0
```

上述 bitstream 于 2026-08-18 12:24 生成，包含不依赖 PMON 提交 PC 的
上下文探针；综合、布局、布线和 bitgen 均为 0 error。截至本记录提交时，
该文件尚未下载到板卡。

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

同一轮复测还得到以下状态：

```text
linux_debug_snapshot 0x007f1fff
status[12:0]         全部为 1
status[15:13]        全部为 0
kernel entry args    r4/r5/r6/r7 = 0/0/0/0
```

其中 bit 10、11 分别证明入口 `0xa07b06e0` 和 `start_kernel`
`0xa09c077c` 已提交，bit 12 证明随后在高地址内核代码中发生异常。这排除了
“PMON 没有跳进内核”，也把故障边界收敛为 PMON 上下文恢复到
`fw_init_environ()` 读取固件参数之间。bit 13 没有置位不是 PMON helper
没有执行的证据：首版探针同时匹配链接地址 `0x07053f10..0x07053f1c`，而
板上提交 PC 可能使用其地址别名。下一版改为匹配唯一的参数寄存器组和非零
上下文指针，不再依赖该 PC。

本次故障的最小可核验特征是：

1. PMON 完成 ELF 装载并报告入口 `0xa07b06e0`。
2. 执行 `g` 后内核入口和 `start_kernel` 都有提交。
3. 内核入口保存参数时 `r4-r7` 全零。
4. `fw_init_environ()` 在 `0xa09c38c8` 执行
   `ld.bu r22, r8, 13`，以 `BADV=0x0000000d` 触发 TLB refill。
5. 串口没有出现任何 Linux 启动文本。

以下两类同时出现的输出不能单独归因于 CPU：PMON 的
`not enough memory for ... table`/`cannot read sym table` 发生在装载符号表
时，之后仍能得到正确 ELF 入口；第一次自动化流程的串口 `EIO` 则是把
Digilent 下载口 `/dev/ttyUSB0` 当成串口造成的，实际串口是独立 FTDI
`/dev/ttyUSB1`。后者修正后上述内核故障仍可稳定复现。

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

### 仿真复现方案

这里必须区分“复现相同症状”和“证明根因”。现有
`tb_loongarch_cpu_smoke.sv` 只覆盖正常路径：参数和 CSR 被写入一个上下文，
调度恢复同一个上下文，再由 `ERTN` 到达 Linux 入口替身。该测试通过只能
说明 CPU 对同一上下文的 store/load、CSR 恢复和 `ERTN` 正常，尚未覆盖
板上最可疑的“写上下文与恢复上下文不是同一对象”。

当前正常路径基线可用下面的命令重复：

```bash
cd core
./02_Design/verification/loongarch/functional/run_cpu_smoke.sh
```

截至本记录，正常路径已通过，板上故障签名尚未在仿真中自然出现。

#### 第一级：双上下文差分测试

先在现有 VCS CPU smoke 上增加可切换的两个上下文：

- `write_context`：模拟 `0x07053eec` helper 使用的当前上下文指针。
- `restore_context`：模拟 `0x070572d8..0x07057384` 调度返回使用的上下文。
- 正常组令两者相等，故障注入组令两者指向两个独立、初始清零的对象。

两组都执行同一条真实数据通路：依次把
`2/0xa4f00000/0xa4f00040/0` store 到偏移 `16/20/24/28`，恢复 5 个 CSR
和全部 GPR，最后执行 `ERTN`。断言如下：

| 检查点 | 正常组 | 故障注入组 |
| --- | --- | --- |
| helper 的四次写地址 | `write_context+16..28` | 相同 |
| 调度器的四次参数读地址 | 同一对象 `+16..28` | 另一对象 `+16..28` |
| 内核入口 `r4-r7` | `2/a4f00000/a4f00040/0` | `0/0/0/0` |
| 入口后的环境访问替身 | 合法地址 | `BADV=0x0000000d`、ECODE `0x3f` |

该测试应以“正常组通过、故障组精确产生板上签名”为成功。它能验证上下文
错配足以解释全部现象，但因为错配是 testbench 主动注入的，不能单独证明
板上 PMON 确实发生了错配。

建议把差分用例独立为
`core/02_Design/verification/loongarch/tb/tb_loongarch_pmon_handoff.sv`，并由
`functional/run_pmon_handoff.sh` 同时运行 `same_context` 和
`split_context`，避免继续扩大通用 smoke。

#### 第二级：真实 PMON 指令片段回放

在 CPU+AXI 内存模型中装入已核对 SHA256 的 PMON 二进制片段，而不是用
手写的等价指令替代：

1. 从 `0x07034594..0x070345b0` 开始，执行 `go` 参数构造和 BL。
2. 执行 `0x07053eec..0x07053f1c` 的上下文选择与四次参数 store。
3. 执行 `0x070572d8..0x07057384` 的 CSR/GPR 恢复和 `ERTN`。
4. 在内核入口放置最小替身，先保存 `r4-r7`，再执行与
   `fw_init_environ()` 等价的空环境访问。

测试平台应记录每条提交 PC、store 地址/数据、调度器 load 地址/数据、
`ERTN` 前的 ERA/CRMD/PRMD/ESTAT，以及入口前四次提交的 GPR。这里同时
扫描 PMON 的链接地址和可能的物理/DMW 别名，避免重演首版 VIO 因 PC
别名漏采样的问题。

先把全局当前上下文指针 `0x070cdb70` 分别初始化为恢复对象
`0x070d0b50` 和另一对象，重复上述正常/错配差分。若手写 smoke 通过而
真实片段的同对象组失败，才说明问题来自 CPU 对 PMON 具体指令序列、相关
冒险或地址别名的处理；若只有错配组失败，则继续优先调查 PMON 的上下文
选择状态，而不是修改 MMU。

#### 第三级：SoC 级 PMON 到 Linux

最终复现必须使用 Chiplab SoC 顶层、同一 PMON 和同一基础内核。现有
Verilator `run_prog` 是直接预装 Linux，绕过了 SPI 启动、PMON `go` 和
调度恢复，因此它启动成功不能覆盖本故障。需要新增专用
`pmon_linux_handoff` 运行模式，至少具备：

- 将 `gzrom.bin`（SHA256
  `38ddef6e2a294d7be96e565a68d46763426008fb1c4ccbdad98c75cafad19329`）
  提供给 SPI flash 模型，或从 PMON `go` 前保存的确定性内存快照启动。
- 将基础 `vmlinux`（SHA256
  `d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a`）
  放到与板上相同地址，并使用相同 bootargs。
- 通过 UART 输入 `g console=ttyS0,115200 rdinit=/sbin/init`，或在等价快照
  中设置完全相同的命令状态。
- 在上述三个 PMON 地址段、内核入口、`start_kernel` 和首异常处设置
  提交级监视器；运行复位种子 `3`、`31`、`20260818` 并加入 AXI
  backpressure。

SoC 级测试只有在自然执行中得到“helper 选择了不同上下文”或“同一上下文
写入正确但恢复读出错误”，才算在仿真中复现了候选根因。仅看到 Linux
卡住、或者由 testbench 强制把入口参数清零，都只能算症状复现。

#### 仿真结果的决策规则

1. 双上下文错配组精确复现、真实 PMON 自然产生错配：转查 PMON 当前线程
   指针更新、上下文对象生命周期及其缓存一致性。
2. helper 和 restore 地址相同，store 数据正确但 restore load 为零或旧值：
   转查 D-cache 的同地址 store-to-load 顺序、写回和 uncached/cache alias。
3. restore load 正确而入口 GPR 为零：转查全 GPR 恢复尾部、流水线 flush、
   CSR 写后 `ERTN` 边界。
4. 入口 GPR 正确但随后变零：转查内核入口保存 `_fw_arg0..3` 的 store/load
   及编译产物，不再归因于 PMON。
5. 仿真三层都不能自然复现而板上可重复：保留实现后时序、DDR/复位、地址
   别名和 PMON 运行时状态为板级专属变量，依靠新 VIO 把差异继续向前收敛。

### 下一次上板判据

当前已生成但尚未烧录的新 VIO 在内核入口第四条参数保存指令提交后锁存
`r4-r7`，避免在重定向边界过早采样；同时通过 PMON 特征参数组锁存实际
上下文指针和 `r5-r8`，不再依赖 `0x07053f10..0x07053f1c` 的提交 PC。
状态位 13 表示已观察到 PMON 参数写入，位 14 表示上下文指针等于恢复对象
`0x070d0b50`，位 15 表示两者不一致。继续上板时：

1. 下载本文件记录 SHA256 的新 bitstream。
2. 重复 PMON TFTP 启动，不换内核、不改变 bootargs。
3. 用 `check_linux_debug.tcl` 读取首异常、CSR、DMW 和入口参数。
4. 比较 `LINUX_DEBUG_PMON_CONTEXT` 与 `LINUX_DEBUG_KERNEL_ARGS`：若 PMON
   参数正确但指针不等于 `0x070d0b50`，可直接判定写错上下文；若指针和
   PMON 参数都正确但内核入口为零，再转查上下文恢复阶段；若入口参数
   正确，则转查内核保存 `_fw_arg0..3` 之后的数据通路。
