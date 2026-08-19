# LA32R Linux 下板验证记录

## 固定版本

- 主仓库基线：`origin/main` (`776d1e0`)
- 主仓库 bring-up：`bringup/la32r-linux`（本文所在提交）
- 当前主仓库固定的 CPU：`core/feature/la32r-mmu`
  (`f12ef387810b74dc30a3d70120e83780fe6fa172`，尚未下板)
- 本文已下板 bitstream 使用的 CPU：
  `a9e13bfe93bd57278894f4f59cd1d731a4034cf0`
- Chiplab bring-up：`2b6f74d`
- Vivado：2023.2
- CPU 时钟：33.333 MHz（系统时钟 100 MHz，DDR 参考时钟 200 MHz）

`core` 不创建额外分支，所有 CPU 修复继续提交到共享的
`feature/la32r-mmu`。主仓库和 Chiplab 的 bring-up 分支只负责固定一次
可复现的下板组合。

## 已通过检查

- NSCSCC VCS RTL 回归：19/19
- Vivado 综合、布局、布线和 bitstream：通过
- 布线后 setup：WNS 0.210 ns，TNS 0 ns
- 布线后 hold：WHS 0.050 ns，THS 0 ns
- 未布线网络：0

当前待下板复测产物：

```text
chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.bit
SHA256 814bbb4d9aa2076c05cd157fa1b881c7770813eb01ad1c0f2d552043d2b63fe9

chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.ltx
SHA256 020bcf5a41611e4fad2d6c772cf8b4d8b2d116c2a3adb00eaf863408173ff62b

chiplab/software/examples/linux/vmlinux
SHA256 d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a
ELF entry 0xa07b06e0
```

上述 bitstream 于 2026-08-18 19:55 生成，包含 CPU `f12ef387` 的 MMU、
Cache/AXI 背压修复及 MUL 误预测自重定向结果保持修复，以及原有 56 路
PMON/AXI 一致性探针；综合、布局、布线和 bitgen 均为 0 error。位流和
配套 LTX 已作为普通 Git blob 提交并推送至 Chiplab
`bringup/la32r-linux` 的 `2b6f74d`，不依赖 Git LFS。位流大小为
9,730,756 bytes，SHA256 与上表一致。

该新版已通过 19/19 VCS 回归和 Vivado 构建，但尚未重新下载到板卡。
最新已完成下板复测的版本仍为 CPU `a9e13bfe`、Chiplab `e3abbf8`，其
bitstream SHA256 为
`5d65c4dde048abdcc7a2053c4b4074610a153f83d47a924847d5168c94ed9fc9`。
本文中早于“ICache 握手修复版下板复测”的观察仍来自更早位流
`5b9db1b0336982b0b4d8be83a85f65691abaa1748baa7357f1e612c490e4a9a3`
（Chiplab `b8fdccc`）；各版结论不能混用。

## 重建

```bash
cd chiplab/fpga/loongson/2023.2
vivado -mode batch -source build_la32r_linux.tcl
```

运行前确认 `vivado -version` 为 2023.2。

`build_la32r_linux.tcl` 会在构建前移除被直接加入工程的 VIO stub/sim
netlist，并拒绝 core filelist 中的任何 VIO RTL 文件。当前构建日志报告
`REMOVED_STALE_VIO_SOURCE_COUNT=0`，最终 LTX 中只有一个 56-probe VIO。
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
读 ID 1、写 ID 2，将一笔写事务从 AW 开始连续记录到 WLAST 和 B 响应。

使用 `51f8816` CPU、`21dbd93` Chiplab 和 56 路探针位流再次上板，得到：

```text
pmon_axi_access       0x000ffff1
AW0                   0x070d0b60
AW1..3                0
AWLEN/AWBURST         7/INCR
W0..7                 2/a4f00000/a4f00040/0/0/0/0/0
W seen/WLAST          ff/80
B seen/BRESP          1/OKAY
write_meta            0x00060107
AR0..3                070d0b60/070d0b64/070d0b68/070d0b6c
R0..3                 0/0/0/0
```

这确认四次架构级 cacheable store 落在同一条 32-byte cache line；随后发生
的是一笔 `AWLEN=7` 的完整 dirty writeback，而不是四笔独立 AXI 写。8 个
W beat 的数据、WLAST 位置和源端 B 响应都正确。因此当前 CPU/D-cache 已
不再是“写命令或写数据丢失”的首要嫌疑点，故障边界进一步收敛到写掩码及
写事务经过 clock converter、slave mux、AXI interconnect 和 MIG 后的内存
可见性，或相同路径上的读返回。`BRESP=OKAY` 只能证明源端收到了成功响应，
尚不能替代对 DDR 入口 `WSTRB` 和数据的实际观测。

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

启动脚本还修正了一处独立竞态：PMON 会把输入行回显为
`PMON> load ...`，旧正则只要看到前缀 `PMON>` 就会误以为 TFTP 已结束，
从而在传输中发送 `g` 并破坏命令。现在只接受位于接收缓冲区末尾、后面
没有命令文本的空闲提示符。本轮复测中 12,459,288 bytes 传输完整结束、
PMON 打印 `Entry address is a07b06e0` 后脚本才发送完整 bootargs，因此本文
记录的 CPU 故障不再包含该自动化竞态。

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
- D-cache 定向用例新增 PMON 同 cache line 的四次 cacheable store、冲突
  替换产生的 8-beat dirty writeback，以及随后的四次 uncached load；逐
  beat 检查 `WSTRB=0xf`、数据和 WLAST，已通过并提交为 `51f8816`。
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
4. 当前 56 路探针的正常交接期望为：

```text
pmon_fixed_access = 0x000001ff
pmon_axi_access   = 0x000ffff1
AW0/AWLEN/AWBURST = 070d0b60/7/INCR
W0..7             = 2/a4f00000/a4f00040/0/0/0/0/0
W seen/WLAST/B    = ff/80/OKAY
AR0..3            = 070d0b60/070d0b64/070d0b68/070d0b6c
R0..3             = 2/a4f00000/a4f00040/0
ERTN 前 r4-r7      = 2/a4f00000/a4f00040/0
kernel r4-r7       = 2/a4f00000/a4f00040/0
```

本轮实际结果已经命中“源端写完整而 R 为零”。下一版探针应优先捕获源端及
AXI interconnect/MIG 入口的逐 beat `WSTRB`、W 数据，以及 MIG 返回的 R
数据：若 `WSTRB` 在源端即异常，回查 D-cache/AXI bridge；若源端正确而下游
异常，定位 clock converter 或互连；若 MIG 入口写事务完全正确但仍读零，
再转查 MIG/DDR 地址与写可见性。若 R 正确而 ERTN GPR 为零，问题在寄存器
恢复；若 ERTN GPR 正确而 kernel 参数为零，再调查 ERTN/流水线重定向边界。

## 2026-08-18 无探针分层诊断结果

为避免只依赖 VIO 单点采样，新增了 PMON 可装载的裸机程序
`chiplab/software/examples/cache_ddr_diag`。程序在与故障地址相同的物理地址
`0x070d0b60` 上依次验证：

| 阶段 | 操作 | 板上结果 |
| --- | --- | --- |
| A | uncached 字/字节/半字读写及 `WSTRB` | PASS |
| D | cache refill、store hit、load hit | PASS |
| B | hit CACOP writeback+invalidate | PASS |
| C | 同 set 冲突替换触发 dirty victim writeback | PASS |

板上完整终态为：

```text
DONE pass=0xff fail=0x00 (PASS)
```

其中阶段 B、C 写回后的值均能立即从 DMW1 uncached 别名读回。该结果证明当前
bitstream 上 CPU、D-cache、AXI、clock converter、interconnect、MIG 和 DDR
能够在故障地址完成普通及 dirty-line 写回事务。因此此前 PMON 固定帧“源端
写完整、随后读零”不是这一地址上普遍存在的 DDR 写不可见问题，更可能依赖
PMON `go` 的特定 cache/上下文状态或交接时序。

为了让裸机 ELF 可由 PMON 正确装载，BSP 增加了两个受构建参数控制的兼容
处理：链接区域可覆盖到 PMON 接受的 `0xa0100000/0xa0180000`；定义
`pmon_elf=1` 时不重复执行 raw-bin 的 `.data` 搬运，也不覆盖 PMON 已配置的
UART。默认构建仍保持历史 `0x1c000000/0x1c080000` 布局和原启动行为。

另以 Vivado 2023.2/XSim 直接实例化 Loongson `system_run` 使用的
`axi_clock_converter_0` 和 `axi_interconnect_0`，在三个异步时钟及通道
backpressure 下回放板上观测到的 `AW=0x070d0b60`、`AWLEN=7`、ID 2、8 个
full-strobe beat，再以 ID 1 读回前四个 word。地址、ID、burst、数据、
`WSTRB`、`WLAST` 与响应在 clock converter 后和 MIG 侧均通过检查：

```text
[PASS] Loongson Xilinx AXI CDC/interconnect PMON burst test
```

这进一步排除了当前 IP 配置下可稳定复现的协议转换或数据丢失。Xilinx
behavioral FIFO 模型不模拟同步器延迟，因此该结果不能替代实现后 CDC/时序
检查；实现后 DCP 的静态追踪已同时确认 `WSTRB`、AWLEN、ID 和地址位宽从
CPU 到 MIG 均保持连通，且本 bitstream 的时序报告无违例。

### 第二主设备交叉可见性的边界

当前 Loongson `system_run` 实现后网表中没有 JTAG AXI master；现有 VIO 只
提供探针，不能主动读 DDR。通用 DMA 虽接在 DDR interconnect 的 S02 端，
但它执行的是内存与 APB 外设之间的搬运，而 no-NAND APB 顶层把
`dma_req_o` 固定为 0，不能直接用于 DDR-to-DDR 交叉读取。因此：

- TFTP 装载已覆盖“以太网 DMA 写 DDR、CPU 读/执行”的方向；
- “CPU 写 DDR、独立 master 读回”的方向在现有 bitstream 中缺少可用模块；
- 若必须补齐该方向，应在后续调试位流中加入 JTAG AXI，或接通一个可控的
  DMA requester，再读取裸机程序保存于 `0x070d0c00` 的结果块。

这属于当前调试接口缺失，不是本轮测试失败；不要把只适用于
`nscscc-team` 工程的 JTAG AXI 脚本用于 Loongson `system_run`。

### 本轮 Linux 重测状态

正确 bitstream 已再次下载，PMON、DDR 初始化和串口启动均正常。但下载后
主机 `enp5s0` 从 `LOWER_UP` 变为持续 `NO-CARRIER`；即使固定为
100 Mb/s 全双工仍无载波。PMON 侧 `dmfe0` 显示 `up running`，向主机发送
9 个 ICMP 包全部超时。这一现象持续约两分钟，重新协商后恢复为
100 Mb/s 全双工；它只阻塞了第一次 TFTP 尝试，不是处理器执行失败。

链路恢复后，基础内核再次完整传输 12,459,288 bytes。直接执行 PMON `g`
仍稳定复现原故障，56 路 VIO 与前一轮逐位相同：固定帧 store 和 8-beat AXI
写回完整、B 响应 OKAY，但固定帧 restore load 和内核入口 `r4-r7` 全零，
最终仍在 `fw_init_environ()` 以 `BADV=0x0d` 触发 TLB refill。

### PMON 交接跳板实验

新增 `chiplab/software/examples/linux_handoff_trampoline`，其 ELF 只有一个
位于 `0xa0100000` 的 128-byte PT_LOAD 段。自动化流程先装载原始内核，再
装载该跳板。PMON 仍执行原 `g` 流程，但跳板在进入 `0xa07b06e0` 前显式
重建 `r4-r7`，并提供独立 argv。该方法未修改 bitstream 或内核正文。

跳板生效后，Linux 从第一行版本信息开始稳定输出，完成了以下路径：

- CPU 探测、页表和 MMU 切换；
- I/D cache、异常和时钟中断；
- 128 MiB 内存初始化、SLUB、RCU、VFS 和 initramfs 解包；
- 串口切换、网络协议栈及大部分基础驱动初始化；
- 释放 initmem，并成功执行到 `Run /bin/sh as init process`。

VIO 同时确认内核入口参数为
`2/0xa010002c/0xa4f00040/0`。因此当前处理器能够执行完整 Linux 内核启动，
原先“没有任何 Linux 串口输出”的直接原因是 PMON `go` 恢复参数为零；它
不是内核入口、通用 MMU、DDR 或 AXI 路径故障。跳板可作为继续验证 CPU 的
临时启动方式，但不应替代对 PMON restore 兼容问题的最终修复。

当前仍未达到 `/ #`。内置 rootfs 的 `/bin/sh` 和 `/sbin/init` 都指向一个
2,300,452-byte、静态链接的 LoongArch BusyBox。启用
`print-fatal-signals=1` 后确认其退出不是 CPU 将普通指令误解码为 break：

```text
potentially unexpected fatal signal 5
PID: 1 Comm: sh
epc: 0001045c
ra : 00010448
```

BusyBox 反汇编中 `0x0001045c` 明确就是 `break 0`，位于 glibc 的 `abort()`
状态机。无 `-i` 时也出现过正常 `exitcode=0`，说明当前首要问题是该旧 rootfs
的启动/stdio/ABI 环境导致 BusyBox 主动 abort 或非交互退出，尚不能据此认定
CPU 用户态取指错误。

诊断还暴露了一个次要的软件兼容问题：打印 fatal signal 的寄存器后，内核
在 `__show_regs.part.15+0x158` 进入 ECODE 18 的保留指令递归。该调试函数
读取了当前实现不支持的处理器状态，异常处理又没有安全退出。下一步应：

1. 先用只包含 `write`/`exit`/循环的最小静态用户程序替换 init，验证 PLV3、
   syscall、用户页表与串口输出，不依赖 BusyBox/glibc；
2. 在仿真中回放 BusyBox 入口到 `abort()` 的指令/系统调用序列，定位触发
   abort 的软件条件；
3. 修正或屏蔽 `__show_regs` 中不受支持的 CSR 读取，避免诊断自身递归；
4. 最小用户态通过后再换用与该内核 ABI 匹配的 BusyBox/rootfs，以 `/ #`
   作为最终通过判据。

### 最小用户态下板结论

上述第 1 步已完成。新增
`chiplab/software/examples/linux_user_diag`，其 `/init` 是链接到
`0x00010000` 的 4.8 KiB 静态 LoongArch ELF，不包含 libc、动态加载器或
启动脚本。它只使用寄存器发起 `write(1, message, 36)`，检查返回值，然后在
PLV3 执行整数与分支循环。诊断 rootfs 同时把该 ELF 安装为 `/init` 和
`/bin/sh`，以兼容现有交接跳板内置的 `rdinit=/bin/sh`。

构建过程不改写基础内核。工具从基础 `vmlinux` 的符号表和 `.init.data`
自动计算内置 initramfs 的文件区间，复制内核后仅替换该区间；本轮确认副本
的前缀和后缀均逐字节不变。构建命令为：

```bash
cd chiplab/software/examples/linux_user_diag
make \
  CROSS_COMPILE=/path/to/loongarch32r-linux-gnusf-
```

生成物为 `obj/vmlinux_user_diag`。本轮镜像的 SHA256 为：

```text
b55a44c9e11cdbbfb982ad94a69372eb3b6cda550922bba50adc8419004d38b2
```

使用同一 bitstream、PMON、TFTP 和交接跳板下板后，内核正常执行至：

```text
Run /bin/sh as init process
process '/bin/sh' started with executable stack
[user-diag] PLV3 write syscall PASS
```

这一结果至少覆盖：用户 ELF 装载、PLV3 取指、PLV3 数据读取、用户页表、
系统调用入口、内核访问用户缓冲区、UART 输出及系统调用返回。故障边界因此
从“任意 Linux 用户态执行”收窄到原 BusyBox/glibc 的启动及 `abort()` 软件
路径；当前没有证据支持基础 PLV3 或 syscall 通路存在普遍 RTL 缺陷。

接下来的优先级调整为：

1. 反向追踪原 BusyBox 在 `0x0001045c` 进入 glibc `abort()` 的调用者与软件
   条件，必要时在仿真中回放最短用户态指令/系统调用序列；
2. 修正或规避旧内核 `__show_regs.part.15+0x158` 中对未实现状态的读取，使
   后续用户异常能够留下单次、可分析的寄存器现场；
3. 换用与该 5.14 LA32R 内核 ABI 匹配的最小 BusyBox/rootfs，最终验证稳定
   出现 `/ #`。

### 用户堆与 glibc/BusyBox 分层结果

基础诊断随后增加了独立 RW `PT_LOAD`，并在纯汇编中继续检查：初始用户栈
word store/load、`brk(0)`、扩展一页、按 16 字节对齐后的 4096-byte
demand-zero 扫描、heap 首尾 store/load。最终同一板上运行结果为：

```text
[user-diag] PLV3 write syscall PASS
[user-diag] stack/brk zero/store PASS
```

诊断过程中曾出现一次 `brk return FAIL`。十六进制输出为：

```text
brk old=0x006a3000 request=0x00000000 return=0x006a4000
```

这里内核实际已把 break 正确扩展到 `0x006a4000`；`request=0` 是早期诊断
把跨 syscall 状态放在 ABI 保留寄存器 `r21` 所致。修正为 callee-saved
`r23-r31` 后完整通过，因此该中间结果不是 CPU 或 `sys_brk` 缺陷。

为区分 PID 1 的特殊信号语义，另以纯汇编 init 执行
`clone(SIGCHLD)`，把原 rootfs 的静态 BusyBox 作为普通子进程启动。BusyBox
在出现提示符前稳定输出：

```text
[busybox-diag] wrapper PID1 started
[busybox-diag] BusyBox child launched
malloc(): corrupted top size
```

这证明先前 `abort()`/`break 0` 的上游条件是 glibc malloc 的 top chunk
一致性检查。`break 0` 只是 PID 1 不按默认 SIGABRT 动作退出后，glibc abort
状态机使用的兜底终止指令。

最后，以当前 LA32R 工具链重新静态链接了一个带完整符号的
`malloc_diag.c`，只执行 `write`、`malloc(64)`、64-byte 写读校验和 `free`。
对应镜像 SHA256 为：

```text
82758702a7ea1751317d01ab3eb5ad56f34943df38fe57f906676386414efd54
```

板上结果为：

```text
[malloc-diag] before malloc
[malloc-diag] malloc/write/free PASS
```

其符号入口为 `main=0x106c0`、`sysmalloc=0x22670`、
`_int_malloc=0x22e80`、`malloc=0x24d80`、`__sbrk=0x29f00` 和
`__brk=0x4ef90`。这组结果排除了普通用户页、`brk`、demand-zero、基础
glibc malloc 或 syscall 的普遍失败，但不能排除地址或 ELF 布局相关故障；
后续的严格 A/B 实验确实在这一边界复现，见下一节。

### 动态 rootfs 与 `/ #` 结果

从 VisionArm 构建目录提取动态 BusyBox、`ld.so.1`、`libc.so.6`、
`libm.so.6` 和 `libresolv.so.2`，构造了 2.30 MiB 的最小动态 rootfs。对应
内核副本 SHA256 为：

```text
e962c9af5b12d9bab08e1ad8e966f9286df7c33c8808c6fec776fee53efec555
```

该组合在动态加载器中退出：

```text
Inconsistency detected by ld.so: dl-version.c: 205:
_dl_check_map_versions: Assertion `needed != NULL' failed!
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

因此这组库不能作为“已配套”的 ABI 基线；它证明执行已进入动态加载器，
但没有证明完整动态用户空间兼容。

为先完成基础系统的交互判据，新增当前工具链静态链接的诊断 shell。使用
`-Os` 构建时，其两个 `PT_LOAD` 为：

```text
RX file/vaddr 0x000000/0x00010000, filesz 0x7381c
RW file/vaddr 0x073821/0x00084821, filesz 0x03be3, memsz 0x04843
```

ELF 与内核副本 SHA256 分别为：

```text
e5915894dda774b4926ef887f9d6a8b0029be483b83f5969b38b7911b7a0fbc1
7d3a74aa485d91918f18110d63da30cd9f172766730e38468fe3b36c3705ed77
```

板上成功输出：

```text
LA32R Linux diagnostic shell
type 'help' for commands
/ #
heap memtest: PASS
```

`memtest` 完成 4096-byte `malloc`、逐字节写入/读取校验和 `free`。至此，
“基础内核进入可交互 `/ #`”已经用诊断 shell 达成；它不是 BusyBox，也不
代表完整 rootfs 已通过。每次主机重新打开 USB-UART 后，板端会漏掉首个输入
字节，自动交互时应先发送一个无意义前导字符；持续打开串口时输入正常。

### 4 KiB ELF 布局最小复现

诊断 shell 最初用 `-O2` 构建时，在 `main()` 的首个原始 `write` 之前就
稳定出现 `malloc(): corrupted top size`。其 RW `PT_LOAD` 位于
`0x00085821`；改为 `-Os` 后功能不变，RX 段缩短约 `0x150` bytes，RW 段
回到 `0x00084821`，随即稳定进入 `/ #`。

为排除 shell 代码路径差异，`malloc-layout-diag` 对已经通过的
`malloc_diag.c` 只链接一段不会执行的 4096-byte `.text.layout_pad`：

| 镜像 | `main` | RW `PT_LOAD` | 板上结果 |
| --- | --- | --- | --- |
| `vmlinux_malloc_diag` | `0x106c0` | `0x00084821` | malloc/write/free PASS |
| `vmlinux_malloc_layout_diag` | `0x106c0` | `0x00085821` | `malloc(): corrupted top size` |

填充版 ELF 和内核副本 SHA256 为：

```text
1163f244f0b91969ae5bf7238316c8f3b2b6280e3b57de432e161538254dc305
3e5bb79cf59630b8d99861f424a880274ff2d197bb0392db999f522e26509fff
```

两版 `_start=0x104a0`、`main=0x106c0` 和 C 执行路径相同。填充插在
`main` 之后，令 `__libc_start_main` 及后续 libc 代码、GOT 和 RW 数据整体
后移一页。入口处访问 GOT 的 `pcaddu12i` 立即数由 120 变为 121，例如：

```text
通过版：0x104a4  pcaddu12i r4, 120 ; GOT load -> main 0x106c0
失败版：0x104a4  pcaddu12i r4, 121 ; GOT load -> main 0x106c0
```

所以当前至少存在一个可靠的“用户态静态 ELF 后半段整体后移 4 KiB即失败”
现象。候选边界包括：slot-1 `pcaddu12i` 加 GOT load、相邻 4 KiB TLB 奇偶页
选择、跨页 I-cache 取指，以及内核 ELF 映射/页内容装载。它比完整 BusyBox
更适合送入仿真。不能仅凭该现象断定 RTL：必须先在参考执行环境运行两版，
并在 VCS 中检查 `0x104a4` 的结果、GOT load 地址/数据、跳转目标以及第一次
偏离点。

建议的下一轮无探针顺序为：

1. 用 QEMU/参考 LA32R 环境运行两个 ELF，确认工具链产物本身一正一反还是
   都通过；
2. 给 `cpu_smoke` 增加 slot-1 `pcaddu12i` 立即数 120/121 后紧跟 GOT-style
   load 的定向检查；
3. 增加 4 KiB TLB 偶/奇页执行和数据读取测试，分别把代码与 GOT 放到板上
   两组虚拟地址；
4. 在 SoC 仿真可承受时直接预装两个诊断内核，以首次用户态偏离为终点，
   不等待完整交互系统启动。

其中第 2 步已加入 `tb_loongarch_cpu_smoke` 并由 VCS 通过：测试在 slot 1
执行 `pcaddu12i imm=121`，紧跟 `ld.w -380`，读回预置 GOT word。独立
MMU VCS 用例的 39 项检查也通过，其中已覆盖 4 KiB 偶页与奇页的数据地址
翻译。两项结果排除了未分页的 PC-relative/GOT 序列和 MMU 组合翻译的简单
错误，但尚未覆盖 `cpu_top + I-cache + D-cache` 在 PLV3 分页模式下的连续
跨页执行。当前主机未安装 LA32R QEMU/NEMU 可执行文件，所以第 1 步暂时
缺少参考环境；下一项最有信息量的工作是增加完整 CPU 分页执行定向用例，
或让现有 SoC Verilator 在首次用户态分歧处提前停止。

### 诊断镜像的可重复构建

最初下板镜像中的 gzip 时间戳已经固定，但 `cpio newc` 仍记录临时目录的
inode 编号，因此上文记录的板测内核 SHA256 不能由第二次构建逐字节复现；
其中用户 ELF 和文件内容没有变化。构建脚本现已统一使用
`cpio --reproducible`。连续两次强制重建的下列 SHA256 完全一致：

```text
0914d803439fb0b2d5765e6e434aca836c897db6dea52488121417f44a2fde1a  vmlinux_user_diag
d95cfb38bcea732cece52e6e66317c29e68848d7a34e0d25b093c2de6ba1438c  vmlinux_malloc_diag
9f4f9b5c894ecc98c8f37284bf7e82c2d68dee67ce22937df79b8ed42a44ca52  vmlinux_malloc_layout_diag
26b878d2e868202a490f4c08adfcae06c4308c419263cc8a648b154110602ab9  vmlinux_diag_shell
23b89b409fbf80149f19d7ea5b10bf0db2406620a11725d059e08ff4da349433  vmlinux_busybox_diag
8b49cd7247770e9f88fd57835e4f0515ceecb8b920345f84c5901b4de8f7cdea  vmlinux_dynamic_busybox
```

这些诊断内核是从已跟踪的基础 `vmlinux` 自动派生的构建产物，不提交到
Git；板测用 FPGA `soc_top.bit`/`soc_top.ltx` 则已按前述路径直接跟踪。

## ICache 握手修复版下板复测（2026-08-18）

本轮实际下载的是 Chiplab `e3abbf80e59e93f2234a7b4fd4d2ca2f9a41517f`
生成的 bitstream，对应 CPU
`a9e13bfe93bd57278894f4f59cd1d731a4034cf0`，SHA256 为：

```text
5d65c4dde048abdcc7a2053c4b4074610a153f83d47a924847d5168c94ed9fc9  soc_top.bit
020bcf5a41611e4fad2d6c772cf8b4d8b2d116c2a3adb00eaf863408173ff62b  soc_top.ltx
```

Vivado 2023.2 下载成功后无需再次物理复位，串口立即出现完整 PMON 启动
日志并进入提示符。此前旧镜像稳定出现的 `fetch_valid=1`、无 commit 的
首次取指死锁未再复现，证明 `a9e13bf` 中“被取消的 ICache 请求仍保持到
后端握手完成”的修复在板上生效。PMON 随后完成 128 MiB DDR 检测和
`dmfe0` 初始化，TFTP 传输也无乱码或内存不足。

本轮使用以下两个不提交到 Git 的测试文件：

```text
0b39006dbf4b5395f946507962249e137f57b9a5262ad63db32558d3b97cfa70  vmlinux_nand_disabled_stripped
e1b582eaf65cb2688bedac5061c7fdf4ed9ad1b32d8ef1bb8bff7c6f8eb54100  linux_handoff_trampoline_a4f
```

先只装载精简内核并直接执行带 bootargs 的 PMON `g`，Linux 仍不能启动。
VIO 保持与上一版相同的特征：PMON 上下文为
`2/0xa4f00000/0xa4f00040/0`，固定帧 store 及 AXI 写数据正确，但 restore
load 和内核入口 `r4-r7` 全零，首个内核异常仍以 `BADV=0x0d` 结束。因此
本轮 ICache 修复没有同时修复 PMON `go` 的上下文恢复问题。

重新下载同一 bitstream 清除失败现场后，板上依次执行：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_nand_disabled_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f
g
```

精简内核入口为 `0xa07b06e0`，跳板入口为 `0xa0100000`。使用 `a4f` 跳板
后，Linux 成功完成 CPU/MMU、I/D cache、128 MiB 内存、SLUB、RCU、VFS、
时钟和网络协议栈初始化，最终稳定运行到：

```text
[    5.384000] Run /bin/sh as init process
[    5.408000] potentially unexpected fatal signal 5.
[    5.436000] epc   : 0001045c 0x1045c
```

`0x1045c` 仍是已知 BusyBox/glibc `abort()` 路径中的 `break 0`；随后的
`__show_regs.part.15` 保留指令递归也是已知诊断兼容问题。故本轮结论为：

- 最新 ICache 握手修复 bitstream 的 PMON 首次启动问题已通过板测；
- Linux 内核主路径已再次通过，未发现 DDR 或 AXI 持续传输故障；
- PMON 直接 `g` 的寄存器恢复问题仍存在，当前启动 Linux 必须保留 `a4f`
  跳板；
- 主仓库随后固定的 CPU `f12ef387`（MulDiv redirect 修复）未包含在本轮
  bitstream 中，仍需单独重新生成并下板验证。

## uCore `ls` 代码页损坏与 WB repair 关键证据（2026-08-19）

### 初步结论与版本边界（已被后续板测修正）

在 CPU `f12ef387810b74dc30a3d70120e83780fe6fa172` 对应的板级镜像上，
uCore 能完成内核初始化、挂载 initrd、进入用户 shell，但执行 `ls` 后稳定在
用户地址 `EPC=0x10000b10` 触发保留指令异常。通过在异常前后同时读取指令
映射、cached 数据别名和 uncached 别名，已经得到一组可与 RTL
`CORE-005` 一一对应的证据。当前最高概率根因不是 `ls` ELF、译码器或简单
MMU 错译，而是旧 core 在 EX 停顿期间让仍属于当前 EX token 的 WB repair
标记继续引用可自由变化的实时 `wb_load_data_ex`。

在 `6e5d375` 尚未生成并下板前，工程判断的概率与排查优先级曾为：

1. **WB repair 在 EX stall 期间没有锁存：约 85%～90%。** 错误双字可以在
   同一 ELF 的更早地址精确找到，且触发模式与 `CORE-005` 的定向仿真首错
   完全一致，应作为第一优先级；
2. **DCache dirty/writeback 或 AXI 背压链路：约 10%。** 只有在包含
   `6e5d375` 的 bitstream 仍能复现时，才进入这一层；
3. **MMU/TLB 简单错译、ELF 镜像或指令译码：低概率。** 当前 PTE/地址和
   “旧内容搬到新位置”的规律均不支持把这些方向放在首位。

上述百分比是基于当前板级证据的工程置信度，不是统计测量。最终确认方法是
保持 uCore 镜像、PMON 命令和测试步骤不变，仅把 bitstream 从 `f12ef38`
替换为包含 `6e5d375` 的版本；若 `ls` 随即恢复，即可确认该根因。

后续已经完成这一严格 A/B 测试，`ls` 的首次异常没有消失，因此上述概率
判断不再成立；`CORE-005` 是已确认并已修复的独立 RTL bug，但不能解释本次
uCore 首次执行失败。更新后的板测证据和排查方向见下一节。

修复提交为：

```text
6e5d3754f4292290e704c07c6096189dfd5a8f0d
fix(pipeline): hold WB repair data across EX stalls
```

`bringup/la32r-linux` 已在 `3aba3b0` 把 `core` 子模块固定到该提交，但这只
说明源码引用已经更新；必须确认 Vivado 实际生成、下载的 bitstream 也来自
`6e5d375` 或更晚版本。此次产生故障截图的 `f12ef38` bitstream 不包含该
修复，不能用于否定 `6e5d375`。

### 板级证据闭环

`ls` ELF 中目标位置的正确内容与板上读取结果如下：

| 位置 | ELF 正确指令字 | 板上 InstD/cached 读取 | 结果 |
| --- | --- | --- | --- |
| `0x10000b0c` | `0x29bfb2c4` | `0x002b0000` | 已损坏 |
| `0x10000b10` | `0x29bfa2c5` | `0x0015016c` | 已损坏并触发 RI |

错误的相邻双字不是随机噪声；它们在同一个 `ls` ELF 的更早位置精确出现：

```text
0x1000067c: 0x002b0000
0x10000680: 0x0015016c
```

源、目标地址相差 `0x490`。也就是说，早先读取的一对合法程序内容被写入了
后续代码位置。这比“目标行发生随机 bit flip”更符合 load consumer 使用旧
数据后继续参与地址/数据计算的故障模型。`EPC=0x10000b10` 的 RI 是代码页
已经损坏后的结果，不是首个错误周期；仿真必须向前追到首次写坏该代码页的
store。

同一诊断还打印了：

```text
Code PTE = 0xa012d005
Code PA  = 0xa012db10
uncached[-1] = 0x47eb2032
uncached[0]  = 0xffdf82a2
```

uncached 视图与 cached/InstD 视图不同，说明抓取时 cache 与 DDR 视图并不
一致；但在对 dirty line 完成 writeback、barrier 和 invalidate 之前，不能
据此单独判定 DDR 或 DCache 是根因。它应作为二级检查项，而不应覆盖上面
已经闭环的“旧 load 数据被后续指令使用”证据。

### RTL 触发条件

旧实现中的最小触发序列是：

1. load A 刚完成，年轻指令以 `*_wb_repair=1` 进入 EX，操作数应取 A；
2. 同一 EX token 因 Slot-0 访存、MMU 或 DCache 背压而保持，
   `ex_allowin=0`；
3. 后一个 load B 推进到 WB，实时 `wb_load_data_ex` 从 A 变成 B；
4. repair 标记仍属于被停住的 EX token，但组合数据已跟随总线变成 B；
5. token 解除停顿后用 B 完成 ALU、LSU 地址或 store-data 计算，最终污染
   后续代码页。

`6e5d375` 在首个阻塞边沿把 A 锁存到
`ex_wb_repair_hold_data`，并在 token 前进或 flush 前通过
`ex_wb_repair_data` 持续提供 A。修复同时覆盖普通/Slot-1 操作数以及 LSU
低地址、对齐判断路径。

### 队友仿真排查清单

优先做以下 A/B 仿真，不要从最终 RI 开始猜测译码：

1. 分别使用 `f12ef38` 和 `6e5d375` 运行：

   ```bash
   bash core/02_Design/verification/loongarch/functional/run_cpu_smoke.sh
   ```

   现有 `tb_loongarch_cpu_smoke.sv` 已构造同型场景：A 为
   `0x11112222`、B 为 `0xaaaa5555`，强制 `mmu_data_ready=0` 让 EX 停顿。
   旧版应稳定暴露 consumer 跟随 B，修复版最终 `$r30` 必须保持 A。

2. 波形至少加入下列信号，并以“repair token 首次进入 EX”为时间零点：

   ```text
   ex_valid, ex_pc, ex_s1_valid, ex_s1_pc
   ex_rs1_wb_repair, ex_rs2_wb_repair
   ex_alu_src1_wb_repair, ex_alu_src2_wb_repair
   ex_s1_rs1_wb_repair, ex_s1_rs2_wb_repair
   ex_s1_alu_src1_wb_repair, ex_s1_alu_src2_wb_repair
   ex_allowin, ex_flush, mmu_data_ready, mem_can_advance
   wb_load_data_ex
   ex_wb_repair_hold_valid, ex_wb_repair_hold_data, ex_wb_repair_data
   ex_alu_src1_repair, ex_alu_src2_repair
   ex_s1_alu_src1_repair, ex_s1_alu_src2_repair
   ex_lsu_addr_low, ex_s1_lsu_addr_low
   ex_rs2_data_repair, ex_s1_store_data_raw
   ```

3. 必须确认下面四个时序判据：

   - `ex_any_wb_repair && !ex_allowin` 的首个上升沿锁存当拍
     `wb_load_data_ex`；
   - 随后即使 `wb_load_data_ex` 由 A 变为 B，`ex_wb_repair_data`、修复后的
     operand、LSU 低地址和 store data 都保持 A 对应值；
   - token 前进后 `ex_wb_repair_hold_valid` 清零，下一条指令才可使用 B；
   - `ex_flush` 和 reset 无条件清除 hold，不能把 A 泄漏给错误路径或下一
     token。

4. 在 uCore/SoC 长仿真中，对支撑 `VA=0x10000b0c` 的物理页设置写监控。
   首次发现写数据不是 `0x29bfb2c4/0x29bfa2c5` 时立即停止，向前回溯该
   store 的源 load、repair 标记和 EX stall；不要等到取指在
   `0x10000b10` 报 RI。同步记录：

   ```text
   commit PC / load PC / store PC
   load VA/PA/data、store VA/PA/data/wstrb
   TLB/DMW 命中与 MAT
   DCache hit/refill/writeback
   AXI AR/R/AW/W/B 的 valid/ready/id/addr/data/strb/last/resp
   ```

5. 若 `6e5d375` 后首次错误 store 仍存在，再按以下顺序排查，避免把缓存
   非一致快照误判成根因：

   - 检查 DCache dirty line 的 writeback 地址、四个 word 和 `WSTRB`；
   - 检查 AXI 背压期间 AR/AW/W payload 是否保持稳定，以及 R/B response
     是否返回给原 owner；
   - 在执行 writeback + DBAR + invalidate 后再比较 cached、InstD 与
     uncached 三种视图；
   - 最后检查同一 VA 的 PTE、物理页号、ASID 和 4 KiB 奇偶页选择。

### 新 bitstream 的板级通过判据

新 bitstream 必须明确记录 core commit 为 `6e5d375` 或更新版本。继续使用
同一个 polling memdiag uCore 镜像执行 `ls`，同时满足以下条件才算闭环：

- `0x10000b0c/0x10000b10` 保持 ELF 中的正确指令字；
- 不再出现 `EPC=0x10000b10`、`ECODE=0x0d`；
- `ls` 正常返回目录并可重复执行；
- shell 进程保持存活，串口输出无随执行路径变化的乱码。

若这一版通过，即可把本次 uCore 故障归并到 core `CORE-005`；若仍失败，
保留首次错误 store 的波形再转入 DCache/AXI 二级定位。

## WB repair 修复版首次 `ls` 失败、第二次成功（2026-08-19）

### 严格 A/B 板测结果

Chiplab `a140b4ae8f4f0c0ca36de1f27f742564c1e1aa9a` 重新生成了包含
core `6e5d3754f4292290e704c07c6096189dfd5a8f0d` 的 bitstream，主仓库由
`0995afa` 固定该 Chiplab 提交。实际下载文件为：

```text
9812ab2052c125b050dafeffda2f56d04c36b82a48804b5a9b8f3e32580eca10  soc_top.bit
50b216abd0ed79598c97f5bb4ba5691c539afc0e1a200b02f9d83da8ead388ad  soc_top.ltx
```

保持 PMON 命令、uCore polling 2-way memdiag 镜像和启动过程不变后，第一次
执行 `ls` 仍在相同位置失败：

```text
InstD[-1]  = 0x002b0000
InstD[0]   = 0x0015016c
Code PTE   = 0xa012d005
Code PA    = 0xa012db10
Cached[-1] = 0x002b0000
Cached[0]  = 0x0015016c
Uncache[-1]= 0xe9840201
Uncache[0] = 0xc3490328
EPC        = 0x10000b10
error: -9 - process is killed
```

这证明 `6e5d375` 的 WB repair hold 并未消除该板级首错，因而不能再把
`CORE-005` 作为本次 uCore 故障的主根因。更关键的是，不复位、不重新下载
bitstream，在同一个 shell 中立即再次执行 `ls`，程序正常列出目录并返回：

```text
@ is [directory] ... @'.'
[d] ... .
[d] ... ..
[-] ... ls
[-] ... test.txt
[-] ... cat
[-] ... sh
lsdir: step 4
$
```

所以 ELF、`0x10000b10` 对应的合法指令和基础用户态执行能力均正常；故障
依赖首次 exec 的物理页/cache 状态。第二次 `ls` 是否复用了同一个物理页尚
未记录，不能直接假定两次 `Code PA` 相同。

### 对缓存维护链路的源码核对

uCore 的磁盘 ELF 装载函数 `load_icode()` 在每次把 segment 内容写入新页后
调用 `fence_i(page2kva(page) + off, size)`。当前 `fence_i()` 顺序为：

```text
DBAR
每 16 bytes：
  CACOP 9, address       # DCache indexed writeback/invalidate, way 0
  CACOP 9, address | 1   # 同一 index，way 1
  CACOP 8, address       # ICache indexed invalidate
IBAR
```

当前 RTL 中：

- DCache line 为 32 bytes，`maint_index=maint_addr[13:5]`；mode 1 用
  `maint_addr[0]` 选择 way，`fence_i()` 每 16 bytes 前进会对同一 DCache
  index 重复维护，虽冗余但不应导致错误；
- ICache line 为 16 bytes，`maint_index=maint_addr[12:4]`，每 16 bytes
  前进与其 line 大小一致；
- DCache 的维护完成依赖 `state_maint_done`，脏行路径应等待 writeback
  response 后才 invalidate/完成；
- RI 异常诊断只读取 InstD、cached 和 uncached 三种视图，没有执行 CACOP，
  因而第二次成功不是诊断代码主动 flush cache 的直接结果，更可能来自
  `do_exit()` 后页释放/重分配、替换或写回状态变化。

第一次失败时 cached/InstD 始终为同一对错误值，而 uncached 值相对旧
bitstream 已变化，进一步把边界收窄到 DCache dirty line、writeback 地址/
数据、CACOP way 维护或 I/D cache 可见性，而不是固定 ELF 内容或译码。

### 更新后的优先排查方向

仿真应从 `load_icode()` 首次装载 `ls` 开始，而不是从最终 RI 开始：

1. 记录第一次和第二次 exec 为 `VA=0x10000b0c` 分配的 PTE、物理页和
   DCache set/tag/way，确认第二次成功是否仅因换了物理页或 cache way；
2. 对目标物理页每条 32-byte DCache line，核对软件发出的两个 mode-1
   `CACOP 9` 是否分别以 `maint_addr[0]=0/1` 被接受并各返回一次 done；
3. 若选中 way 为 valid+dirty，跟踪 `maint_selected_tag` 组成的 writeback
   地址、整条 line 数据、`WSTRB`，并确认 `BVALID/BREADY/BRESP` 返回原
   maintenance owner 后才出现 `dcache_maint_done`；
4. 检查第二条 `CACOP 9` 是否因前一条 valid/done 延续而被误判已完成，或
   是否重复维护 way 0；
5. 检查紧随其后的 `CACOP 8` 是否在对应 DCache 脏行写回真正完成前开始，
   以及 ICache refill 是否可能从旧 DDR 内容取回；
6. 在 `fence_i()` 返回点同时比较目标字在 DCache、DDR 模型和下一次
   ICache refill response 中的值。此时正确值必须已经是
   `0x29bfb2c4/0x29bfa2c5`；
7. 增加“装载→执行失败→释放页→再次装载”的定向用例，固定第二次复用同
   一物理页和改用另一物理页各跑一次，以区分 stale tag/dirty 与地址相关
   的 set/way 问题。

建议波形至少加入：

```text
cache_maint_addr, cache_maint_mode
dcache_maint_valid, dcache_maint_done
maint_start, maint_active_q, maint_selected_way
maint_selected_valid, maint_selected_dirty, maint_needs_writeback
maint_selected_tag, maint_index
wb_state, wb_resp_ok
AWVALID/AWREADY/AWADDR, WVALID/WREADY/WDATA/WSTRB/WLAST
BVALID/BREADY/BRESP
icache_maint_valid, icache_maint_done
irom_req_addr, refill_buffer_line_addr_q, refill line data
```

板级通过标准也应改为“冷复位后第一次 exec 即成功”。第二次或后续 `ls`
成功只能证明系统能够通过 cache/page 状态变化绕过首错，不能视为修复。

### MAT=0 对照实验：问题继续收敛到取指存储属性链路

在同一个 `a140b4a`/core `6e5d375` bitstream 上又完成了两组软件对照：

1. 将 `fence_i()` 改为 DCache 两个 way 完成后增加第二道 `DBAR`，再做
   ICache invalidate 和 `IBAR`；第一次 `ls` 仍失败，第二次成功；
2. 在 `load_icode()` 给用户可执行页 PTE 增加 `PTE_PCD`，并修改
   `la32_tlb.c`，使该页写入 TLBELO 时不再附加 `MAT=coherent cached`，即
   用户代码页以 `MAT=0` 取指；第一次 `ls` 仍在相同用户入口附近 RI，第二次
   `ls` 和随后 `cat test.txt` 正常。

板测文件及 SHA256：

```text
2002fca7e1ed3b45339774e139c23687aee8de1038cda9c46cf2192018902a27  ucore-kernel-initrd-polling-2way-memdiag-dbar2phase
690734aacc893ba58a05c7ab1667db28d3630de4c6a53b950e050d32c960ec66  ucore-kernel-initrd-polling-2way-memdiag-uncached-pte.elf
```

第一组排除了“只缺少 DCache writeback 与 ICache invalidate 之间的一条屏障”
这一简单解释。第二组比普通 cache flush A/B 更关键：若 TLB 的 MAT=0 已正确
传到取指端，ICache 不应命中旧 cached line，而应走 uncached fetch；该路径
仍首错，说明当前最高概率边界是以下两类之一：

- TLB 中的 `MAT=0` 没有稳定传到 `mmu_inst_mat`/
  `irom_req_cacheable`，取指仍被错误地按 cacheable 请求处理；
- `irom_req_cacheable=0` 已正确，但 ICache 的 uncached fetch、AXI 读地址/
  返回数据或 killed/旧 refill response 的归属存在错误。

RTL 静态检查已经确认 `cpu_top.sv` 使用：

```systemverilog
assign irom_req_cacheable = mmu_inst_mat == 2'd1;
```

因此下一次仿真不要继续更换 initrd、DDR 镜像或只增加 CACOP。应在冷启动后
第一次 `ls` 的 `PC=0x10002ce4`（不同构建可能落在邻近地址）抓取：

```text
TLBELO.MAT
mmu_inst_mat
irom_req_cacheable
irom_req_addr / AXI ARADDR
ARVALID / ARREADY
RVALID / RREADY / RDATA / RLAST / RRESP
ICache refill owner、killed 标记、line address 和写入数据
```

判定方法：

- `TLBELO.MAT=0` 但 `mmu_inst_mat` 或 `irom_req_cacheable` 非 0：查 TLB/MMU
  属性选择、奇偶页选择及流水保持；
- 三者均为 0，但返回到前端的指令仍错：查 ICache uncached 状态机、AXI
  request/response 关联和旧 refill 污染；
- AXI `RDATA` 已错：再向下追 DDR 地址映射和读响应；
- AXI `RDATA` 正确而送入译码的指令错：问题已固定在 ICache/取指返回路径。

这组结果不证明 DDR 完全无问题，但已证明内核、initrd、shell、第二次用户
exec 和普通数据读取可工作；当前不应再把“镜像损坏”列为第一嫌疑。仓库中
可直接复现的两个 ELF 及完整命令见 `artifacts/ucore/README.md`。

## WB repair 修复版 Linux/a4f 复测（2026-08-19）

使用同一 `a140b4a`/core `6e5d375` bitstream，冷复位后按以下顺序启动：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_nand_disabled_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f
g
```

先误用 `linux_handoff_trampoline_a5f` 时仍停在 PMON 参数打印之后；改用正确的
`a4f` 跳板后，Linux 完成协议栈、串口、initmem 释放等初始化，并进入：

```text
[    5.388000] Run /bin/sh as init process
[    5.416000] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

这不是内核未启动。`exitcode=0` 表示 PID 1 的 `/bin/sh` 已被成功装载并正常
返回；Linux 规定 PID 1 退出后必须 panic。相较旧 bitstream 上同一镜像进入
glibc/BusyBox `abort()` 并触发 fatal signal 5，本次已越过原用户态异常路径，
CPU/MMU/DDR、内核主路径以及首次用户 ELF 装载均已通过。

TFTP 中实际使用的 `a4f` 跳板已复核为：

```text
e1b582eaf65cb2688bedac5061c7fdf4ed9ad1b32d8ef1bb8bff7c6f8eb54100
console=ttyS0,115200 rdinit=/bin/sh print-fatal-signals=1 -- -i
```

因此当前 Linux 阻塞点调整为 init/console 保活，而非早期硬件启动。下一步应
构造显式 PID 1 supervisor 或诊断 shell：持续读取 `/dev/console`，即使子
shell 返回也不退出；同时记录 BusyBox 实际收到的 argc/argv 和 fd 0/1/2，
确认内核命令行中的 `-- -i` 是否被该 rootfs 的 shell 接受。也可构建独立
`a4f` 跳板改用 `rdinit=/sbin/init` 做对照，但不得再使用 `a5f`。

### NAND-disabled 诊断 shell 与 Linux RX 边界

首次构建的 `vmlinux_diag_shell_stripped` 误以启用 NAND 的原始内核为底包，
启动后停在：

```text
ls1a_nand: mtd struct base address is a102b800
nand: 128 MiB, SLC, erase size: 128 KiB, page size: 2048, OOB size: 64
Scanning device for bad blocks
```

随后改用已确认的 NAND-disabled 内核
`2bce696a1a42ec47b24889d0385144b6f25c50902fb3d7e2e62dfff9f9994892`
作为底包，注入同一静态诊断 shell 并 strip，得到：

```text
9402e803ff00121de014a8aec2dbc5141704d7cf5aeab5672fe923253ebecb52
vmlinux_diag_shell_nand_disabled_stripped
```

使用原 `a4f` `/bin/sh` 跳板启动后，板上稳定达到：

```text
[    1.840000] Run /bin/sh as init process
LA32R Linux diagnostic shell
type 'help' for commands
/ #
```

这组结果覆盖 Linux 内核启动、initramfs 解包、用户 ELF exec、PLV3 取指/
数据访问、用户态 `write()` syscall、ttyS0 输出以及 PID 1 保活。此时串口
输入无响应，无法执行 `help` 或 `memtest`。同一物理串口在本次启动前的
PMON，以及同一 bitstream 的 uCore shell 中均能接收命令，因此主机串口
配置、USB-UART 和 FPGA RX 引脚不是首要嫌疑；故障边界收窄到 Linux
`ttyS0` RX、IRQ 18、控制台 fd 0 或用户 `read()` 路径。

Linux 日志已经识别：

```text
1fe001e0.serial: ttyS0 at MMIO 0x1fe001e0 (irq = 18, base_baud = 2062500)
printk: console [ttyS0] enabled
```

下一轮按以下顺序排查：

1. 在诊断 shell 的 `read(0, ...)` 前后打印标记，确认用户程序确实进入并
   阻塞在 read syscall，而不是命令循环本身未运行；
2. 在 `do_execve` 后核对 PID 1 的 fd 0/1/2 是否都指向 `/dev/console`，
   以及 fd 0 的 file mode 是否允许读取；
3. 按键时观察 UART LSR data-ready、RBR 数据和 IER RX enable，确认字符
   已进入 `0x1fe001e0` UART；
4. 检查 IRQ 18 在外设、中断控制器、CPU `ESTAT.IS`、`ECFG.LIE` 各层是否
   pending/enable，并确认 Linux 8250 ISR 是否实际进入；
5. 若 RBR 有数据但 IRQ 不到，先用定时 polling RX 做最小旁路；若 polling
   能让诊断 shell 接收命令，即可把根因固定在中断路由/应答链路；
6. 若 ISR 已进入但 read 不返回，继续检查 8250 flip buffer、TTY ldisc、
   wait queue wakeup 和 console fd 绑定。

当前板级里程碑应记录为“Linux 进入稳定用户态提示符，TX 正常，RX 未通”，
而不是 Linux 启动失败。

### Linux 串口 RX 静态巡查：外部中断链路为第一嫌疑（2026-08-19）

诊断 shell 的主循环在打印一次 `/ # ` 后立即执行阻塞式
`read(STDIN_FILENO, ...)`；板上只出现一个提示符，之后不重复刷屏。这说明
`read(0)` 正在睡眠等待数据，而不是 fd 0 持续返回 EOF/EIO。结合用户态
`write()` 和 ttyS0 TX 已通过，stdio/fd 绑定及 TTY 公共层不再是第一嫌疑。

#### IRQ 编号和位映射已经核对一致

Chiplab `a140b4ae8f4f0c0ca36de1f27f742564c1e1aa9a` 中：

```verilog
assign int_out = {npu_irq, dma_int, nand_int, spi_inta_o,
                  uart0_int, mac_int};
.intrpt({2'b0, int_out})
```

因此 `uart0_int -> intrpt[1]`。自研核将 `irq_pending[7:0]` 写入
`CSR.ESTAT.IS[9:2]`，故 `intrpt[1] -> ESTAT.IS3`。Linux DTS 的 UART 节点
使用 `interrupts = <3>`，`mach_irq_dispatch()` 也以 `pending & 0x8` 分发
`LOONGSON_UART_IRQ`，最终日志显示 irq 18。四层编号完全一致，当前没有证据
支持“DTS IRQ 写错一位”。

#### 与 OpenLA500 的关键差异

OpenLA500 与自研核都把外部 `interrupt[7:0]` 映射到
`ESTAT.IS[9:2]`，所以映射本身不是二者差异。OpenLA500 的
`has_int` 使用已经采样进 `csr_estat` 的 IS 位，并把中断作为普通异常随
指令流水提交；自研核则有以下独立路径：

```text
异步 irq_pending
  -> effective_is（直接使用原始 irq_pending）
  -> timer_irq_request
  -> timer_irq_hold
  -> 等待 id_valid && pipeline_empty
  -> timer_irq_take / EENTRY redirect
```

这条路径存在三个需要重点验证的风险：

1. `uart0_int` 在约 33 MHz 的 `uncore_clk/aclk` 域产生，却直接接入
   40 MHz `cpu_clk` 域；顶层没有两级同步器，而且
   `effective_is` 直接组合使用原始异步输入；
2. `timer_irq_hold` 只在 `timer_irq_request && id_valid` 时置位，并在任意
   `frontend_flush` 时清零。必须验证分支 flush、ICache 等待和 IDLE 状态下
   不会丢失或永久推迟外部中断；
3. 完整 CPU 回归 `tb_loongarch_interrupt` 把 `irq_pending` 固定为
   `8'd0`，只覆盖软件中断和核内定时器。`tb_loongarch_mmu_priv` 虽检查过
   外部位映射，却没有覆盖流水线排空、异常入口、IDLE 唤醒、外设清 pending
   和 ERTN。因此当前板上所需的外部中断端到端行为实际上没有回归保护。

截至本次巡查，core `6e5d375` 之后远端最新的 `63041c7` 只包含 WB repair、
ICache killed refill 和 AXI backpressure 等修复，没有外部中断相关修改，不能
预期直接修复该 RX 现象。

#### UART IP 的第二嫌疑：RX timeout 中断

Linux 将该端口识别为 16550A，通常把 FIFO RX trigger 设置为 8 bytes。
Chiplab UART IP 对 1--7 个字符不会立即产生 `rda_int`，而是依赖：

```verilog
ti_int = ier[RDA] && (counter_t == 0) && (rf_count != 0);
```

静态检查中 `counter_t` 会在收字节后装载约四个字符时间，并在 baud enable
脉冲上递减；`ti_int_pnd` 和 `int_o` 也会保持到 RBR 被读，未发现必然失效的
组合错误。因此它目前排在自研核外部中断控制之后，但仍需用 A/B 实验排除：

- 在提示符后快速连续输入至少 16 个字符再回车；若此时突然收到输入，说明
  阈值中断可用而 timeout 路径失效；
- 临时把 8250 的 16550A RX trigger 从 8 改为 1。若 trigger=1 后可交互，
  根因锁定在 UART timeout；若仍无输入，继续查 `uart0_int` 到 CPU 的路径。

#### 最短仿真和下板观测方案

不要先继续改 DDR/AXI。当前系统已经完成内核、initramfs、PLV3 ELF、syscall
和串口 TX，RX 问题应按以下信号从外设向 CPU 单向定位：

```text
UART_RX
 -> rf_push_pulse / rf_count / LSR.DR
 -> IER.RDA / counter_t / rda_int_pnd / ti_int_pnd
 -> uart0_int
 -> intrpt[1]
 -> ESTAT.IS3 / ECFG.LIE3 / CRMD.IE
 -> timer_irq_request / timer_irq_hold / pipeline_empty
 -> timer_irq_take / EENTRY
 -> mach_irq_dispatch(IRQ18) / 8250 ISR / RBR read
 -> TTY flip buffer / read(0) wakeup
```

按第一次出现分歧的位置判断：

| 观测结果 | 结论 |
| --- | --- |
| 按键后 `rf_count` 仍为 0 | UART RX/波特率/引脚采样问题 |
| `rf_count>0`，但 `uart0_int=0` | IER、FIFO trigger 或 timeout IP 问题 |
| `uart0_int=1`，但 `ESTAT.IS3=0` | uncore→CPU CDC/外部中断采样问题 |
| `ESTAT.IS3=1`，但 `timer_irq_request=0` | ECFG/CRMD/effective_is 逻辑问题 |
| request/hold 为 1，但 `timer_irq_take` 不出现 | `timer_irq_ctrl` 的 ID/排空/flush 问题 |
| take 已出现，但 Linux IRQ18 计数不增 | 异常入口、ERA/EENTRY 或 Linux dispatch 问题 |
| IRQ18/8250 ISR 已进入但 RBR 不被读 | 8250 IIR/LSR 兼容问题 |
| RBR 已读且 ISR 收到字符，`read(0)` 仍不醒 | 才转查 TTY/console fd/line discipline |

建议先给 `tb_loongarch_interrupt` 增加真正的 `logic [7:0] irq_pending`，至少覆盖
以下四种 case：

1. 使能 `CRMD.IE` 和 `ECFG.LIE3` 后拉高 `irq_pending[1]`，检查
   `ESTAT.IS3`、ECODE=INT、精确 ERA 和 EENTRY redirect；
2. 在连续 taken-branch/frontend flush 中拉高并保持外部中断，证明不会饥饿；
3. 在 IDLE 且下一条取指受 ICache/backpressure 阻塞时拉高中断，证明不依赖
   偶然存在的 `id_valid` 才能唤醒；
4. 模拟 ISR 读取 UART 后撤销 level pending，再执行 ERTN，检查只进入一次且
   恢复 `CRMD.IE`，同时用不同相位扫 uncore→CPU 跨时钟输入。

修复方向应先在仿真中验证：在 `cpu_clk` 域对外部中断做明确的两级 level
同步，`effective_is` 只使用同步后的/CSR 已采样的值；同时把当前实质上处理
所有中断的 `timer_irq_ctrl` 按“请求独立锁存、提交边界消费”重新审查，避免
锁存依赖 `id_valid` 或被无关 frontend flush 清掉。不能只靠改 IRQ 编号或
重复更换 Linux 镜像来闭环。

### 外部中断同步修复版 bitstream（2026-08-19）

为验证上述第一嫌疑，使用主仓库 `254be433583b9cf91b72ad9dcf78b495e14b46e3`、
Chiplab 源码 `061ba0d11c93d7d2a2b15d7de67f170531a80fc6` 和 core
`6e5d3754f4292290e704c07c6096189dfd5a8f0d`，通过 Vivado 2023.2 重新完成
综合、布局、布线和 bitstream 生成。该 Chiplab 版本已经在 `cpu_clk` 域对
`int_async`（包括 `uart0_int`）加入 `int_sync_meta`、`int_sync_cpu` 两级
同步，CPU 只接收同步后的 level 中断。

生成文件已由 Chiplab `6a931ee` 跟踪：

```text
334077203262288dfb2047083dcad81cbbf64fc71c8f9550d1eaa8d86aa530a4  soc_top.bit
50b216abd0ed79598c97f5bb4ba5691c539afc0e1a200b02f9d83da8ead388ad  soc_top.ltx
```

最终路由结果为 WNS `0.263 ns`、TNS `0 ns`、WHS `0.021 ns`、THS `0 ns`，
无 failed、unrouted 或 partially routed net，所有用户时序约束均满足。该镜像
尚未下板；应继续使用已稳定到达 `/ #` 的同一 Linux 诊断镜像做严格 A/B：

- 若串口 RX 恢复，说明 uncore→CPU CDC 是本次问题的主因；
- 若现象不变，立即观察 `rf_count/uart0_int/ESTAT.IS3/timer_irq_take`，优先
  区分 UART timeout/trigger 与 CPU 中断请求锁存问题，不再回退排查 DDR、
  initramfs 或用户态 exec。

### IRQ 同步版板测：Linux 已进入 RX ISR，但短报文仍不返回（2026-08-19）

使用上节 `6a931ee` 生成、SHA256 为
`334077203262288dfb2047083dcad81cbbf64fc71c8f9550d1eaa8d86aa530a4`
的 bitstream，保持 NAND-disabled 诊断内核和 `a4f` 跳板不变，Linux 再次稳定
达到：

```text
LA32R Linux diagnostic shell
type 'help' for commands
/ #
```

本次与旧 bitstream 的差异是：连续发送较长字符串后，Linux 明确打印：

```text
ttyS ttyS0: 1 input overrun(s)
```

后续压力发送中 overrun 计数还出现 `2`、`4`，并能看到一部分接收字符被 TTY
回显。但普通 `help`、单独 CR/LF 和短帧仍不能使 canonical `read()` 返回，
诊断 shell 不执行命令。主机串口工具的 HEX 模式存在发送格式歧义，因此其
界面显示不作为硬件字节值证据；内核自己的 overrun 日志和 TTY 部分回显才是
本次结论依据。

`ttyS0` 的 overrun 日志只能在 8250 ISR 读取 LSR 后产生。这证明新 bitstream
上至少有一种 UART 中断（最可能是 receiver line status）已经沿以下路径到达
Linux：

```text
uart0_int -> 两级同步 -> ESTAT.IS3 -> Linux IRQ18 -> 8250 ISR
```

因此“两级同步完全无效”和“IRQ编号错误”均可降级。当前故障变为：正常
received-data/timeout 中断没有及时服务 RX FIFO；字符堆满后才靠 overrun 的
line-status IRQ 进入驱动，导致开头字符丢失且短命令永远凑不成一行。

#### UART RTL 独立 XSim 结果

对 `6a931ee` 中原样的 `uart_regs/uart_receiver/uart_rfifo` 使用 Vivado 2023.2
XSim 做了两层最小测试：

1. 写入 `IER=0x05`，强制 `rf_count=1,counter_t=0`，得到
   `ti_int_pnd=1,int_o=1,IIR=0x0c`；把 FIFO trigger 写为8并令
   `rf_count=8`，得到 `rda_int_pnd=1,int_o=1,IIR=0x04`；
2. 不强制内部状态，按 8N1/divisor 18 在 RX 引脚实际发送单字节 `0x68`；
   字节进入 FIFO 后，四字符时间计数归零，得到：

```text
UART_SERIAL_TIMEOUT_PASS count=1 counter_t=0 iir=0x0c ier=5
```

这排除了“`uart_regs.v` 中 timeout pending/IIR 组合逻辑必然失效”这一简单
根因。远端主仓库 `89339b8` 新固定的 Chiplab `731ebc2` 只增加 UART burst
仿真和初始化 Verilator UART model，没有修改综合 RTL，也没有生成替代
`6a931ee` bitstream，所以不能期待仅更新该 submodule 指针改变板上现象。

#### 现在最短的硬件/内核定位顺序

优先在同一时刻观察或由内核打印寄存器回读，不再盲改串口工具：

1. Linux 8250 startup 写 IER 后立即读回，必须为 `0x05`（RDA+RLS）；若实际
   只有 `0x04`，现有板测现象可被完整解释，继续查 MMIO byte write/APB
   `PWDATA`、地址和 DLAB；
2. 收到第一个字符后确认 `rf_count=1`、`counter_t` 从 `toc_value` 递减到0、
   `ti_int_pnd=1`、IIR=`0x0c`；
3. 依次比较 `uart0_int/int_sync_meta/int_sync_cpu/ESTAT.IS3`。若 UART 侧已
   pending 而同步后不再变化，查 level 中断保持；
4. 若 `ESTAT.IS3=1`，确认 `timer_irq_request/hold/take` 和 Linux IRQ18 计数
   是否在 FIFO overrun 之前增长；
5. 在 8250 ISR 记录每次 IIR、LSR 和实际读取 RBR 的字节数。若只见
   IIR=`0x06`（RLS）而没有 `0x04/0x0c`，问题已经固定在 RDA/TI 生成或传播；
6. 临时把 FIFO trigger 改为1。若单字符即可唤醒 shell，则 timeout 路径有
   问题；若仍必须等到 overrun，优先核对 IER.RDA 和 CPU IRQ 重入。

### 同一 IRQ 同步版上 uCore 首次 `ls` 单次通过

同一 bitstream 随后加载了此前在 `a140b4a` 上稳定复现“第一次 `ls` RI、
第二次成功”的 MAT=0 定位镜像：

```text
690734aacc893ba58a05c7ab1667db28d3630de4c6a53b950e050d32c960ec66
ucore-kernel-initrd-polling-2way-memdiag-uncached-pte
```

PMON 将其识别为 ELF，入口 `0xa0000000`。虽然非 stripped ELF 因符号表空间
不足打印了 `not enough memory ... table`，加载段和入口仍然有效，uCore 完成
初始化进入 `$`。本次冷启动后的第一条 `ls` 直接成功列出 `cat/ls/sh/test.txt`，
随后：

```text
$ cat test.txt
hello World! Haha...
$
```

这是相对旧 bitstream 的明确正向变化，但暂时只记录为“单次冷启动通过”。
IRQ CDC 修改与 uCore 用户代码页取指没有直接因果关系，而重新实现 bitstream
会改变布局布线、上电状态和时序裕量；不能因一次成功就宣布 ICache/MMU 根因
已修复。闭环标准为：

- 完全复位/重新加载后连续至少5轮，第一条 `ls` 均成功；
- 同时复测普通 cached polling 2-way memdiag 镜像，而不只测 MAT=0 变体；
- 每轮继续执行 `cat test.txt`，并记录 bitstream 与 uCore ELF SHA256；
- 任一轮首错则保留当轮 `Code PA/PTE/cached/uncached`，继续按前文取指链路
  波形定位。

### 最新 bringup 基线重建 bitstream（2026-08-19）

为使位流与远端最新 bringup 基线一致，使用主仓库 `fed6285`（该提交仅增加
uCore fallback 资料，RTL 子模块指针未变化）、Chiplab `731ebc2` 和 core
`6e5d375`，在 Vivado 2023.2 / `xc7a200t-fbg676-2`
上重新完成综合、布局、布线和 bitgen。生成的文件由 Chiplab 提交
`1095444` 跟踪：

```text
soc_top.bit  SHA256 78d1b6c29fd0b1ba7775d14dc9f0aaddb3185d2988c3ff17b1a061c6bb35ba4d
soc_top.ltx  SHA256 50b216abd0ed79598c97f5bb4ba5691c539afc0e1a200b02f9d83da8ead388ad
```

布线后 WNS `0.263 ns`、TNS `0 ns`、WHS `0.021 ns`、THS `0 ns`，无未布线
网络。该位流尚未完成新一轮下板复测；下板时应使用本节 SHA256，并保持诊断
内核、PMON 跳板和串口参数不变，与上一版 `334077203...` 做 A/B 对比。
