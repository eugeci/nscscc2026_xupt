# LA32R Linux 下板验证记录

## 固定版本

- 主仓库基线：`origin/main` (`776d1e0`)
- 主仓库 bring-up：`bringup/la32r-linux` (`6dcc98d`，不含本轮文档提交)
- CPU：`core/feature/la32r-mmu` (`0659f88`)
- Chiplab bring-up：`1a847e3`
- Vivado：2023.2
- CPU 时钟：33.333 MHz（系统时钟 100 MHz，DDR 参考时钟 200 MHz）

`core` 不创建额外分支，所有 CPU 修复继续提交到共享的
`feature/la32r-mmu`。主仓库和 Chiplab 的 bring-up 分支只负责固定一次
可复现的下板组合。

## 已通过检查

- NSCSCC VCS RTL 回归：18/18
- Vivado 综合、布局、布线和 bitstream：通过
- 布线后 setup：WNS 0.180 ns，TNS 0 ns
- 布线后 hold：WHS 0.052 ns，THS 0 ns
- 未布线网络：0

当前产物：

```text
chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.bit
SHA256 24eb97b9364ef165100b7a7e355532915e5d83c02070c3632782ec6574834bce

chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.ltx
SHA256 3ba7346353be440d0bfe3a0d1e2ba82269e0f79ef30ce13137b5b61b86afa0e3

chiplab/software/examples/linux/vmlinux
SHA256 d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a
ELF entry 0xa07b06e0
```

上述 bitstream 于 2026-08-18 14:41 生成，包含最新 PRELD/IDLE 实现、
D-cache 未初始化状态修复及 51 路 PMON/AXI 一致性探针；综合、布局、布线
和 bitgen 均为 0 error。截至本记录提交时，该文件尚未下载到板卡。

## 重建

```bash
cd chiplab/fpga/loongson/2023.2
vivado -mode batch -source build_la32r_linux.tcl
```

运行前确认 `vivado -version` 为 2023.2。

`build_la32r_linux.tcl` 会在构建前移除被直接加入工程的 VIO stub/sim
netlist，并拒绝 core filelist 中的任何 VIO RTL 文件。当前构建日志报告
`REMOVED_STALE_VIO_SOURCE_COUNT=0`，最终 LTX 中只有一个 51-probe VIO。
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
`fw_init_environ()` 读取固件参数之间。

随后使用扩展 VIO 复测得到：

```text
pmon_fixed_access       0x000001ff
固定帧架构级 store 数据  2/a4f00000/a4f00040/0
固定帧架构级 load 数据   0/0/0/0
load 目的寄存器          27/26/25/24
ERTN 前 r4-r7            0/0/0/0
store/load 地址高位摘要  0000/0000
pmon_axi_access          0x0000ff11
旧探针 AXI AW0           0x070d0b60
旧探针 AXI W0            0xa4f00000
AXI AR0..3               070d0b60/64/68/6c
AXI R0..3                0/0/0/0
```

也就是说，处理器在架构级确实向固定恢复帧 `0x070d0b50` 的偏移
`16..28` 发出了四次正确 store，但紧接着从同一组地址 load 时读回全零，
最终 ERTN 前参数也为零。旧 VIO 中 `AW0=0x070d0b60` 与
`W0=0xa4f00000` 不能被组合解释成一次地址/数据错配：AXI 的 AW/W 是独立
通道，且旧探针经一个寄存器状态位延迟启用，可能把相邻事务的 AW 与 W
采到同一槽位。本轮新探针改为由 PMON `go` 特征组合直接启用，并分别使用
读 ID 1、写 ID 2，将 AW/W 以 pending 索引配对后再记录。

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
ECFG、ERA、PRMD、CRMD 和全部 GPR，再由 `ERTN` 进入内核。

静态反汇编进一步确认了两处 GOT 引用：helper 的有效 GOT 地址为
`0x070aaf58`，其原始表项位于 `0x070cdb70`；板上该表项指向运行时当前
上下文 `0x07dfffc0`。restore 的有效 GOT 地址为 `0x070aad1c`，其原始值
直接为固定对象 `0x070d0b50`。这说明 PMON 内部确实存在两个不同的上下文
来源，但板上架构级探针同时证明四次正确参数 store 已发往固定帧
`0x070d0b60..0x070d0b6c`。因此“helper 只写到了另一个上下文”不能单独
解释当前数据；现阶段应优先确认固定帧写事务是否真正到达内存，以及随后
读事务为何返回零。

### 无板阶段回归结果

- VCS NSCSCC RTL 总回归：18/18 gate 通过。
- 新增 CPU+D-cache PMON 固定帧用例
  `run_loongarch_uncached_handoff.sh`：从 `0x070d0b50` 开始，依次向偏移
  `16..28` 写入 `2/a4f00000/a4f00040/0`，再在 command、W、B、R 通道
  可变 backpressure 下连续读回四个值；通过。
- AXI bridge 用例增加四组连续 PMON 写，交替覆盖 AW-first 与 W-first；
  通过。
- privileged 用例在 ERTN 前加入四次连续 load，连同 CSR/GPR 恢复路径；
  通过。
- LA32R MMU 定向测试继续通过 39 项检查；Chiplab Verilator 直接启动
  Linux 与三个随机复位种子仍通过。

上述定向用例在 VCS 中发现一个真实缺陷：D-cache 的
`refill_cpu_pending`、`refill_target_valid` 及部分 refill 控制/数据寄存器
没有复位。若 CPU 在任何 refill 之前先执行 uncached 访问，且总线施加
backpressure，未知状态会污染 `cpu_ready`。`0659f88` 已为这些寄存器加入
显式复位；修复前定向用例可稳定暴露 X，修复后与 18 项总回归均通过。

这个缺陷具备影响 PMON uncached 交接的条件，但尚不能直接等同于板上根因：
FPGA 上电初值以及 PMON 之前是否已发生 cache refill 都可能掩盖或改变症状。
必须用包含该修复的新 bitstream 复测，并以配对后的 AXI 事务作为最终证据。

### 仿真复现方案

当前最小复现已经纳入总回归：

```bash
cd core
./02_Design/verification/platform/nscscc/functional/run_loongarch_uncached_handoff.sh
./02_Design/verification/platform/nscscc/functional/run_rtl_regression.sh
```

该用例回放了板上最关键的固定帧 store/load 序列，但不是完整 PMON
二进制；正常路径通过只证明修复后的 CPU+D-cache+AXI bridge 在同类时序下
行为正确。若新 bit 上板后故障仍存在，下一层复现应使用 Chiplab SoC 顶层、
同一 PMON 和同一基础内核。现有 Verilator `run_prog` 直接预装 Linux，绕过
SPI 启动、PMON `go` 和调度恢复，不能覆盖本故障。专用
`pmon_linux_handoff` 模式至少需要：

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

SoC 级测试只有在自然执行中得到“固定帧写入没有到达内存”或“写入正确但
恢复读出错误”，才算复现候选根因。仅看到 Linux 卡住，或由 testbench
强制把入口参数清零，都只能算症状复现。

决策规则：

1. 配对 AXI 写地址/数据不完整或 B 响应异常：转查 D-cache uncached 写状态
   与 AXI bridge 通道握手。
2. store 地址和数据正确但 restore load 为零或旧值：
   转查 D-cache 的同地址 store-to-load 顺序、写回和 uncached/cache alias。
3. restore load 正确而入口 GPR 为零：转查全 GPR 恢复尾部、流水线 flush、
   CSR 写后 `ERTN` 边界。
4. 入口 GPR 正确但随后变零：转查内核入口保存 `_fw_arg0..3` 的 store/load
   及编译产物，不再归因于 PMON。
5. 仿真三层都不能自然复现而板上可重复：保留实现后时序、DDR/复位、地址
   别名和 PMON 运行时状态为板级专属变量，依靠新 VIO 把差异继续向前收敛。

### 下一次上板判据

新 VIO 在内核入口第四条参数保存指令提交后锁存 `r4-r7`；同时捕获 PMON
特征参数、固定帧架构级 store/load、ERTN 前 GPR，以及经过事务配对的 AXI
AW/W/AR/R。状态位 13 表示已观察到 PMON 参数写入，位 14 表示运行时当前
上下文指针等于恢复对象 `0x070d0b50`，位 15 表示两者不一致。继续上板时：

1. 下载本文件记录 SHA256 的新 bitstream。
2. 重复 PMON TFTP 启动，不换内核、不改变 bootargs。
3. 用 `check_linux_debug.tcl` 读取首异常、CSR、DMW 和入口参数。
4. 正常交接的完整期望为：

```text
pmon_fixed_access = 0x000001ff
pmon_axi_access   = 0x0000ffff
AW/AR 地址         = 070d0b60/070d0b64/070d0b68/070d0b6c
W/R 数据           = 2/a4f00000/a4f00040/0
ERTN 前 r4-r7      = 2/a4f00000/a4f00040/0
kernel r4-r7       = 2/a4f00000/a4f00040/0
```

若 AW/W 不完整，问题在 uncached 写入或 AXI 握手；若写完整而 R 为零，问题
在存储可见性或读通路；若 R 正确而 ERTN GPR 为零，问题在寄存器恢复；若
ERTN GPR 正确而 kernel 参数为零，再调查 ERTN/流水线重定向边界。只有上述
各层都正确后，才把排查点移动到内核 `_fw_arg0..3` 的保存与使用。
