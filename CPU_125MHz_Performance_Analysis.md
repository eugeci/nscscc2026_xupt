# 125 MHz 下板性能测试与 CPU 架构优化分析

## 1. 文档目的

本文汇总当前 CPU 在完整 SoC、DDR 和 AXI 环境下，以 125 MHz 运行全部性能测试的结果，并结合处理器 RTL、缓存结构、AXI 访问方式以及仿真结果，分析主要性能瓶颈，给出后续架构优化优先级和验证方法。

当前结论是：

> 处理器功能正确，但性能首先受限于无 ICache、I/D 访问串行、AXI 单事务、DCache 容量小以及写穿单拍写。现阶段优先优化存储层次结构的收益明显高于继续提频或直接扩大执行宽度。

## 2. 测试环境

- CPU 频率：125 MHz
- SoC 计数器频率：100 MHz
- 程序运行位置：板载 DDR
- 测试方式：通过 JTAG/VIO 自动切换并运行 20 项性能测试
- 结果：20 项测试全部 PASS
- 原始结果：[all_perf_results.csv](chiplab/fpga/nscscc-team/run_vivado/all_perf_results.csv)
- 自动化脚本：[run_all_perf_jtag.tcl](chiplab/fpga/nscscc-team/run_vivado/run_all_perf_jtag.tcl)

除 `stringsearch` 外，各测试的 CPU 计数和 SoC 计数比例均约为：

```text
CPU Count / SoC Count ≈ 125 MHz / 100 MHz = 1.25
```

这说明板上 CPU 频率、SoC 计数器频率和绝大多数测量结果相互一致。`stringsearch` 由多个很短的计时间隔组成，计数器读取开销会使两种时间换算出现较明显差异。

## 3. 125 MHz 下板结果

| 序号 | 测试程序 | 结果 | CPU 周期数 | CPU 时间 | SoC 时间 |
|---:|---|:---:|---:|---:|---:|
| 1 | bitcount | PASS | 41,886,604 | 335.093 ms | 335.168 ms |
| 2 | bubble_sort | PASS | 162,397,212 | 1,299.178 ms | 1,299.260 ms |
| 3 | coremark | PASS | 406,909,300 | 3,255.274 ms | 3,255.360 ms |
| 4 | crc32 | PASS | 400,705,145 | 3,205.641 ms | 3,206.475 ms |
| 5 | dhrystone | PASS | 4,948,187 | 39.585 ms | 39.673 ms |
| 6 | quick_sort | PASS | 213,171,031 | 1,705.368 ms | 1,705.450 ms |
| 7 | select_sort | PASS | 117,023,741 | 936.190 ms | 936.272 ms |
| 8 | sha | PASS | 250,403,507 | 2,003.228 ms | 2,004.093 ms |
| 9 | stream_copy | PASS | 12,493,765 | 99.950 ms | 100.032 ms |
| 10 | stringsearch | PASS | 26,793,064 | 214.345 ms | 257.543 ms |
| 11 | fireye_A0 | PASS | 77,996,835 | 623.975 ms | 624.057 ms |
| 12 | fireye_B2 | PASS | 55,646,740 | 445.174 ms | 445.252 ms |
| 13 | fireye_C0 | PASS | 74,782,876 | 598.263 ms | 598.341 ms |
| 14 | fireye_D1 | PASS | 388,150,015 | 3,105.200 ms | 3,105.283 ms |
| 15 | fireye_I2 | PASS | 520,882,204 | 4,167.058 ms | 4,167.139 ms |
| 16 | inner_product | PASS | 710,728,649 | 5,685.829 ms | 5,685.909 ms |
| 17 | lookup_table | PASS | 187,721,385 | 1,501.771 ms | 1,501.851 ms |
| 18 | loop_induction | PASS | 894,164,282 | 7,153.314 ms | 7,153.397 ms |
| 19 | my_memcmp | PASS | 215,928,034 | 1,727.424 ms | 1,727.506 ms |
| 20 | minmax_sequence | PASS | 389,440,920 | 3,115.527 ms | 3,115.605 ms |

运行时间最长的七项为：

1. `loop_induction`：7.153 s
2. `inner_product`：5.686 s
3. `fireye_I2`：4.167 s
4. `coremark`：3.255 s
5. `crc32`：3.206 s
6. `minmax_sequence`：3.116 s
7. `fireye_D1`：3.105 s

绝对运行时间同时受程序工作量、`LOOPTIMES`、初始化和正确性检查影响，不能仅凭时间长度判断某个硬件单元的瓶颈占比。

## 4. CoreMark 仿真与下板差异

仿真结果中：

```text
Iterations       : 1
Total CPU Count  : 2,781,594
Total SoC Count  : 3,060,594
```

仿真 CPU 频率约为 90.909 MHz，因此实际仿真时间约为：

```text
2,781,594 / 90.909 MHz ≈ 30.60 ms
```

CoreMark 输出的 `0.084291 s` 使用了软件中遗留的 33 MHz 时间常数，并不是当前仿真时钟下的真实时间。

下板运行使用 10 次迭代：

```text
总 CPU 周期数     = 406,909,300
每次迭代 CPU 周期 = 40,690,930
```

归一化到每次迭代后：

```text
下板周期 / 仿真周期
= 40,690,930 / 2,781,594
≈ 14.6
```

也就是说，DDR 环境下每次 CoreMark 迭代消耗的 CPU 周期约为仿真 AXI RAM 环境的 14.6 倍。硬件 CPU 频率比仿真更高，因此该差异不能用 CPU 频率解释，主要来自真实 DDR、AXI 事务开销以及当前取指/访存结构。

## 5. 当前存储系统结构

### 5.1 指令侧没有 ICache

平台顶层将 CPU 指令请求直接接入 AXI bridge，没有实例化 ICache：

- [mycpu_top.v](core/02_Design/platform/nscscc/rtl/mycpu_top.v)

每个 64 位指令块被转换为一次两拍、32 位 AXI burst：

- [irom_backend_adapter.sv](core/02_Design/rtl/memory/backends/irom_backend_adapter.sv)

该适配器采用：

```text
S_IDLE -> S_READ -> S_RESP
```

同一时刻只能存在一个取指请求。即使程序顺序执行，每取得两条 32 位指令，仍要重新承担一次 DDR 读地址和返回延迟。

这与双发射前端的带宽需求不匹配。理想情况下前端每周期可能消耗两条指令，而当前每个新的 8 字节指令块都依赖一次完整的外部存储事务。

### 5.2 指令和数据访问完全串行

共享后端仲裁器只有三种 owner 状态：

```text
OWNER_NONE
OWNER_IROM
OWNER_DCACHE
```

相关实现：

- [memory_backend_arbiter.sv](core/02_Design/rtl/bus/axi/memory_backend_arbiter.sv)

仲裁器具有以下特点：

- 同一时刻只能有一个 owner。
- DCache 请求优先。
- 读 burst 或写响应完成前持续锁定 owner。
- 指令请求和数据请求不能同时在途。

由此产生的直接影响包括：

- DCache miss 会阻塞取指。
- 写穿 store 等待 AXI 写响应时会阻塞取指。
- 指令读占用后端时，数据 miss 也必须等待。
- 分支跳转后的新取指仍要等待旧事务完成或返回。

### 5.3 DCache 容量小且采用写穿

当前 DCache 参数为：

```text
容量              2 KB
组相联            2-way
组数              64
Cache line        16 B（4 个 word）
写策略            write-through
Store miss        write-no-allocate
Store buffer      2 项
```

相关实现：

- [dcache.sv](core/02_Design/rtl/memory/dcache.sv)

NSCSCC 平台配置还包括：

```text
BACKEND_CANCEL      = 0
DIRECT_BRAM         = 0
CRITICAL_WORD_FIRST = 0
```

对于数十 KB 的数组工作集，2KB DCache 很容易出现容量 miss。写穿又会使每次 store 最终产生外部写事务。

### 5.4 AXI 后端仅支持单事务

当前 AXI master：

- 只支持一个 outstanding transaction。
- 读事务可以使用 burst。
- 写事务固定 `AWLEN=0`，每次只写一个 32 位 word。
- AXI 读写通道没有得到充分并行利用。

相关实现：

- [axi_master_adapter.sv](core/02_Design/rtl/bus/axi/axi_master_adapter.sv)

因此当前主要问题不是简单的“DDR 峰值带宽不足”，而是：

> 固定访问延迟高、事务粒度小、没有多个 outstanding 请求、读写互相阻塞、I/D 请求完全串行。

## 6. 各类程序瓶颈分析

### 6.1 loop_induction

代码位置：

- [shell18.c](chiplab/software/examples/nscscc_perf/bench/loop_induction/shell18.c)

主要数据：

```text
intSrc[3200] = 12.8 KB
intDst[3200] = 12.8 KB
总工作集约 25.6 KB
```

该程序不只执行 copy，还包括：

- `rand()` 填充源数组。
- `rand()` 填充目标数组。
- 三遍复制循环。
- `memcmp()` 正确性检查。
- 板上外层重复 10 次。

主要瓶颈：

1. 工作集远大于 2KB DCache。
2. 连续 store 通过 write-through 产生大量单拍 AXI 写。
3. 2 项 store buffer 很快填满。
4. store drain 与取指不能并行。
5. `rand()` 含多次乘法、加载、存储和函数调用，增加取指压力。

该测试最适合验证：

- 更大 DCache。
- store buffer 扩容。
- 相邻 store 合并。
- AXI burst write。
- ICache。

### 6.2 inner_product

代码位置：

- [shell16.c](chiplab/software/examples/nscscc_perf/bench/inner_product/shell16.c)

程序分别测试有符号/无符号 8、16、32 位数据，每种数据包含两个长度为 8000 的数组。不同数据类型下，两个数组总容量约为 16～64KB。

主要瓶颈：

1. 数组初始化产生大量 store。
2. 两个输入数组远大于 2KB DCache。
3. 点积每次迭代包含两个 load、一个 multiply 和一次累加。
4. 当前每个双发射 pair 最多只能包含一个 LSU。
5. 累加变量形成循环携带的数据依赖。
6. 乘法器虽然使用 DSP 流水线，但加载吞吐和累加依赖限制了整体吞吐。

存储系统优化后，下一阶段可能暴露：

- 单 LSU 吞吐限制。
- load-use 延迟。
- 乘加累加依赖链。

### 6.3 fireye_I2

代码位置：

- [shell15.c](chiplab/software/examples/nscscc_perf/bench/fireye_I2/shell15.c)

该程序具有：

- 多层嵌套循环。
- 大量条件分支和提前退出。
- 字节数组和标记数组的不规则访问。
- 除法和取余运算。

现有汇编中确实可以看到 `div.w` 和 `mod.w`，并非全部被编译器强度削弱。

主要瓶颈：

1. 分支密集，容易产生方向预测和 BTB miss。
2. 分支错误恢复后要重新等待 DDR 取指。
3. 不规则数据访问对 2KB DCache 不友好。
4. 当前 radix-4 除法器正常除法需要 16 次迭代。

该测试适合验证：

- ICache。
- 分支预测器和 BTB。
- DCache 容量。
- 除法 busy cycle 优化。

### 6.4 CoreMark

CoreMark 同时覆盖：

- 链表访问。
- 矩阵计算。
- 状态机。
- CRC。
- 大量函数调用和条件分支。

它的热点代码和控制流比简单循环更复杂，因此无 ICache 带来的损失特别明显。仿真和下板每次迭代相差约 14.6 倍，是当前取指/DDR 延迟瓶颈最直接的证据。

主要瓶颈优先级：

1. 无 ICache。
2. I/D AXI 串行。
3. DCache 容量和 miss 延迟。
4. 分支预测。
5. 双发射配对限制。

### 6.5 CRC32

CRC32 主要执行字节读取、查表、移位、异或和循环分支。

CRC 表约为 1KB，理论上能够放入 2KB DCache，但还会受到：

- 数据和栈对 cache set 的竞争。
- load-use 数据依赖。
- 循环取指持续访问 DDR。
- 分支和函数调用开销。

该测试预计会从 ICache 和低延迟 DCache hit 路径中明显获益。

### 6.6 minmax_sequence

代码位置：

- [shell20.c](chiplab/software/examples/nscscc_perf/bench/minmax_sequence/shell20.c)

该程序针对多种数据类型执行多种 min/max 值和位置扫描：

- 代码体积较大。
- 有大量 load、compare、conditional update。
- 多个相似扫描函数反复切换。
- 分支方向与数据内容相关。

主要瓶颈：

1. 无 ICache导致大代码足迹反复从 DDR 取指。
2. 加载和比较依赖。
3. 分支预测。
4. 单 LSU 和保守配对策略。

### 6.7 fireye_D1

代码位置：

- [shell14.c](chiplab/software/examples/nscscc_perf/bench/fireye_D1/shell14.c)

每轮会对多个数组执行 `memset`，随后进行离散索引更新和扫描。虽然数组声明很大，但主要访问的前 1001 项区域合计也约为 16KB，仍远大于当前 DCache。

主要瓶颈：

1. `memset` 产生连续 store 流量。
2. write-through 和单拍写效率低。
3. `mn/mx/in/out` 离散索引容易出现 miss。
4. 数据访问阻塞取指。

## 7. 架构优化路线

### P0：加入性能计数器并固定基线

目前只有总周期数，只能确定程序“慢”，不能定量拆分各类 stall。

建议加入以下计数器：

#### 流水线与发射

- `cycle_count`
- `instret_count`
- `single_issue_cycles`
- `dual_issue_cycles`
- `no_issue_cycles`
- `raw_stall_cycles`
- `backend_stall_cycles`

由此计算：

```text
IPC = retired instructions / CPU cycles
双发射率 = dual issue cycles / active cycles
```

#### 前端

- Fetch Queue 空周期
- IROM 请求数
- IROM 等待周期
- 平均取指 AXI 延迟
- redirect/flush 次数
- 因数据事务占用后端而阻塞取指的周期

加入 ICache 后继续统计：

- ICache access
- ICache hit
- ICache miss
- refill 次数和等待周期

#### 数据侧

- load/store 数量
- DCache hit/miss
- refill 数量
- refill 等待周期
- store buffer full 周期
- store drain 周期
- uncached 访问数量

#### AXI

- ARVALID 等待 ARREADY 周期
- R 通道等待周期
- AW/W 等待周期
- B 响应等待周期
- IROM owner 周期
- DCache owner 周期
- 总线空闲但 CPU 等待周期

#### 控制流和乘除法

- branch 数
- branch mispredict 数
- BTB miss 数
- redirect penalty
- MUL 指令数和 busy cycles
- DIV/MOD 指令数和 busy cycles

### P1：增加 ICache

建议第一版配置：

```text
容量           8 KB
组相联         2-way
Cache line     32 B
前端读取宽度   64 bit
DDR refill     8-beat × 32 bit
```

设计要点：

- 采用 BRAM 保存 data array。
- tag 可使用 LUTRAM 或寄存器。
- ICache hit 路径最好寄存一级，避免恶化前端时序。
- miss 返回后向前端提供 64 位指令块。
- 分支重定向后使用 epoch/tag 丢弃错误路径返回。
- 后续再评估 next-line prefetch。

预期首先改善：

- CoreMark
- CRC32
- minmax_sequence
- fireye_I2
- 排序程序
- SHA

增加 ICache 还会间接降低共享 AXI 上的 I/D 竞争。

当前 FPGA 资源余量充足：

```text
Slice LUTs       17.43%
Registers         7.28%
Block RAM         0.96%
DSP               0.54%
```

资源报告：

- [soc_top_utilization_placed.rpt](chiplab/fpga/nscscc-team/run_vivado/project/loongson.runs/impl_1/soc_top_utilization_placed.rpt)

### P2：优化 DCache 和 store 路径

建议先实施低风险方案：

1. Store buffer 从 2 项增加到 8～16 项。
2. 合并相同 cache line 内的 store。
3. 合并相邻地址形成 AXI burst write。
4. 写响应在后台完成，不阻塞新的 AXI read。
5. 扩大 DCache 到 8～16KB。
6. Cache line 从 16B 扩大到 32B。

随后通过计数器比较两种策略：

- write-through + write combining
- write-back + write-allocate

对于 `loop_induction` 等纯流式写，盲目 write-allocate 可能产生不必要的 read-for-ownership。因此可以考虑：

- 普通数据使用 write-back/write-allocate。
- 可识别的流式 store 使用 no-allocate。
- 或保留 no-allocate，但使用更大的 write-combining buffer。

#### Critical-word-first

当前 `CRITICAL_WORD_FIRST=0`。可以增加：

- critical-word-first
- early restart

但不能只修改参数。当前 AXI adapter 固定使用 INCR burst；若从 cache line 中间的关键字地址开始读取，必须：

- 使用正确的 AXI WRAP burst，或
- 将 refill 拆成两个不跨 line 的 INCR burst。

否则会将下一条 cache line 的数据错误地写入当前 cache line。

### P3：提高 AXI 并发能力

目标是至少允许以下事务同时在途：

```text
1 个 ICache refill
1 个 DCache refill
1 个后台 store/writeback
```

建议：

- ICache 和 DCache 使用不同 AXI ID。
- 读写使用独立状态机。
- 写响应等待期间允许继续发起读事务。
- 增加请求 FIFO 和返回路由。
- 支持多个 outstanding read。
- 将固定优先级改为带防饥饿机制的仲裁。

即使暂时不支持多 ID，也应首先解除“写响应锁住所有读请求”的限制。

### P4：优化分支预测

当前已有：

- 256 项 2-bit PHT
- 8-bit GHR
- 小型 2-way BTB
- 双发射前端

应在取得动态分支统计后再调整。候选优化包括：

- PHT 扩到 1K 项。
- BTB 扩到 128～256 项。
- 增加 Return Address Stack。
- 区分条件分支、间接跳转和 return 的 miss。
- 根据数据决定是否增加 loop predictor。

优先受益程序：

- fireye_I2
- quick_sort
- bubble_sort
- select_sort
- minmax_sequence
- CoreMark

### P5：提高实际双发射率

当前配对策略比较保守：

- 每对最多一个 LSU。
- 不能同时发射两个 CFI。
- 除 ALU 到 store-data 外，slot0 到 slot1 的 RAW 通常禁止配对。
- MUL/DIV 主要限制在 slot0。

相关实现：

- [frontend_pair_policy.sv](core/02_Design/rtl/core/frontend/frontend_pair_policy.sv)

在缓存瓶颈缓解后，可考虑：

- slot0 ALU 到 slot1 ALU/branch 的旁路。
- 放宽安全的跨包配对限制。
- 优化 load-use forwarding。
- 根据统计决定是否增加第二 LSU。
- 使用双端口 DCache 支持两个独立 load。
- 对相邻 load 做 64 位合并。

这些改动可能影响关键路径，应避免把新的大范围旁路 mux 直接放在 decode/issue 的组合路径上。

### P6：优化 DIV/MOD

当前乘法器使用 FPGA DSP，除法器为 radix-4 迭代结构：

- [muldiv_unit.sv](core/02_Design/rtl/core/execute/muldiv_unit.sv)

正常 32 位除法需要 16 次 radix-4 迭代，另有特殊值和小于除数等快速路径。

可选优化：

1. 保留最近一次除法的：
   - operands
   - quotient
   - remainder
2. 如果下一条 DIV/MOD 使用相同操作数，直接复用另一个结果。
3. 评估 radix-8 或 radix-16。
4. 只有在 `div_busy_cycles` 占比足够高时才增加更复杂的除法硬件。

这种 quotient/remainder 复用对连续计算 `/` 和 `%` 的代码可能比较有效。

## 8. 频率和时序

当前 125 MHz CPU 时钟周期为 8ns，CPU 建立时间 WNS 为：

```text
WNS = +0.382 ns
```

关键路径位于执行和旁路相关逻辑，说明继续直接提频的空间已经较小。

完整设计仍存在：

```text
WHS = -0.064 ns
```

即一个 hold violation，因此实现报告显示 timing constraints are not met。

时序报告：

- [soc_top_timing_summary_routed.rpt](chiplab/fpga/nscscc-team/run_vivado/project/loongson.runs/impl_1/soc_top_timing_summary_routed.rpt)

该 hold 问题位于 SoC/DDR 相关路径，虽然当前所有测试均 PASS，但最终提交和继续提频前应先修复。

从性能角度看，降低 CPU 到 33 MHz 会使计算部分明显变慢；DDR 固定延迟在 CPU 周期中的表现可能有所变化，但绝对运行时间不会因此缩短。当前架构下，提高 CPU 频率也难以获得线性加速，因为 CPU 会更频繁地等待相同的 DDR/AXI 延迟。

## 9. 推荐实施顺序

推荐按以下顺序开发：

```text
性能计数器
    ↓
8KB ICache
    ↓
更大 store buffer + store 合并
    ↓
8～16KB DCache
    ↓
AXI 读写并发和多个 outstanding
    ↓
分支预测和双发射优化
    ↓
DIV/MOD、双 LSU 等专项优化
    ↓
最终时序收敛和频率提升
```

不建议一开始同时修改 ICache、DCache、AXI 和发射逻辑，否则性能变化难以归因，功能问题也不容易定位。

## 10. 每阶段验证方法

每次只引入一类主要改动，并保持：

- CPU 固定 125 MHz。
- DDR 和 SoC 频率不变。
- 编译器和编译选项不变。
- 测试数据和 `LOOPTIMES` 不变。
- 每项测试运行至少 3 次，取中位数。

### 阶段一：ICache

重点观察：

- IROM AXI 请求数是否大幅下降。
- Fetch Queue 空周期是否下降。
- CoreMark、CRC32、minmax 是否明显改善。
- DCache miss 等待时是否仍完全阻塞取指。

### 阶段二：store/DCache

重点观察：

- AXI 单拍写数量。
- store-buffer-full 周期。
- loop_induction、fireye_D1、inner_product。
- DCache miss rate 和 refill 等待周期。

### 阶段三：AXI 并发

重点观察：

- ICache refill 和 DCache refill 是否可以重叠。
- 写响应等待期间是否仍能发读请求。
- AXI 通道利用率。
- CPU 因 backend busy 停顿的周期。

### 阶段四：分支和执行

重点观察：

- branch mispredict rate。
- 实际 IPC。
- 双发射率。
- RAW stall。
- DIV/MOD busy cycles。

## 11. 最终结论

当前 CPU 在 125 MHz 下功能正确，但完整 SoC 环境中的性能主要受存储访问延迟和串行化限制：

1. 无 ICache，使每个 64 位指令块都访问 DDR。
2. IROM 和 DCache 共用一个单 owner 后端。
3. AXI master 只支持一个 outstanding transaction。
4. 写事务固定为单拍。
5. DCache 只有 2KB，且为 write-through。
6. 数据 miss 和 store drain 会进一步阻塞取指。

因此总体优化优先级为：

> 性能计数器 → ICache → store 合并与更大 DCache → AXI 并发 → 分支/双发射/除法 → 最后再提频。

其中，增加 ICache 是当前最明确、覆盖程序最多、资源代价相对较低的第一项架构优化。
