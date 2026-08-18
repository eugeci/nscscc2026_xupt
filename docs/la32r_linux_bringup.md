# LA32R Linux 下板验证记录

## 固定版本

- 主仓库基线：`origin/main` (`776d1e0`)
- 主仓库 bring-up：`bringup/la32r-linux`（本文所在提交）
- CPU：`core/feature/la32r-mmu` (`a9e13bfe93bd57278894f4f59cd1d731a4034cf0`)
- Chiplab bring-up：`e3abbf8`
- Vivado：2023.2
- CPU 时钟：33.333 MHz（系统时钟 100 MHz，DDR 参考时钟 200 MHz）

`core` 不创建额外分支，所有 CPU 修复继续提交到共享的
`feature/la32r-mmu`。主仓库和 Chiplab 的 bring-up 分支只负责固定一次
可复现的下板组合。

## 已通过检查

- NSCSCC VCS RTL 回归：19/19
- Vivado 综合、布局、布线和 bitstream：通过
- 布线后 setup：WNS 0.296 ns，TNS 0 ns
- 布线后 hold：WHS 0.051 ns，THS 0 ns
- 未布线网络：0

当前待下板复测产物：

```text
chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.bit
SHA256 5d65c4dde048abdcc7a2053c4b4074610a153f83d47a924847d5168c94ed9fc9

chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.ltx
SHA256 020bcf5a41611e4fad2d6c772cf8b4d8b2d116c2a3adb00eaf863408173ff62b

chiplab/software/examples/linux/vmlinux
SHA256 d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a
ELF entry 0xa07b06e0
```

上述 bitstream 于 2026-08-18 19:27 生成，包含 CPU `a9e13bfe` 的 MMU
物理地址传递、AXI cache command 背压锁定及被取消 ICache 请求的后端
握手保持修复，以及原有 56 路 PMON/AXI 一致性探针；综合、布局、布线和
bitgen 均为 0 error。位流和配套 LTX 已作为普通 Git blob 提交至 Chiplab
`bringup/la32r-linux` 的 `e3abbf8`，不依赖 Git LFS。位流大小为
9,730,756 bytes，SHA256 与上表一致。

该新版已通过 19/19 VCS 回归和 Vivado 构建，但尚未重新下载到板卡。
本文后续已有的 PMON/Linux 下板观察来自上一版已验证位流
`5b9db1b0336982b0b4d8be83a85f65691abaa1748baa7357f1e612c490e4a9a3`
（Chiplab `b8fdccc`）；复测新版时应另行追加结果，不能混用两版结论。

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
