# NSCSCC 性能测试程序导读与特征分析

## 1. 文档目的

本文面向处理器设计与性能优化，说明 Chiplab 中 20 个 NSCSCC 性能测试程序：

1. 程序名字表示什么概念；
2. 当前源码实际执行了什么；
3. 它形成怎样的指令、控制流和访存行为；
4. 它主要考验处理器的哪些部分；
5. 分析时应重点观察哪些性能指标。

本文不是一份“看到程序名字就给出优化结论”的列表。程序名称只说明大致算法，真正决定处理器表现的是编译后的动态指令流。因此，文中把内容分成两类：

- **源码事实**：可以从当前测试源码直接确认的规模、循环和数据结构。
- **分析判断**：根据程序行为推测的潜在压力，需要用性能计数器或对照实验验证。

分析对象为仓库当前版本：

- 测试总览：[chiplab/nscscc_readme.md](../chiplab/nscscc_readme.md)
- 测试源码：[chiplab/software/examples/nscscc_perf/bench](../chiplab/software/examples/nscscc_perf/bench)
- 联合测试反汇编：[chiplab/software/examples/nscscc_perf/obj/allbench/test.s](../chiplab/software/examples/nscscc_perf/obj/allbench/test.s)

快速入口：

- [20 个程序速查表](#benchmark-overview)
- [各程序详细说明](#benchmark-details)
- [按处理器部件分类](#subsystem-groups)
- [推荐的实际分析流程](#analysis-workflow)
- [常见误判](#common-mistakes)

---

## 2. 阅读程序特征时要看什么

每个测试可以从五个角度理解。

### 2.1 指令侧

关注热点代码有多大、函数是否频繁切换、是否存在大量展开循环，以及取指地址是否连续。这些特征主要影响：

- ICache 容量、相联度和行大小；
- ICache miss 延迟；
- 前端取指带宽；
- Fetch Queue 是否经常断粮。

### 2.2 控制流

关注条件分支是否频繁、方向是否容易预测、是否存在递归、间接调用和返回。这些特征主要影响：

- 条件分支预测器；
- BTB；
- Return Address Stack（RAS）；
- 分支错误恢复代价。

### 2.3 数据访存

关注工作集大小、访问宽度、连续性、步长和读写比例。这些特征主要影响：

- DCache 容量与相联度；
- byte、half-word 和 word 访存路径；
- Cache refill、dirty writeback；
- AXI burst 和外部存储延迟；
- LSU 吞吐率。

### 2.4 执行与数据依赖

关注移位、逻辑、乘法、除法是否密集，以及后一条指令是否立即依赖前一条结果。这些特征主要影响：

- ALU、乘法器和除法器；
- forwarding/bypass；
- load-use 延迟；
- 流水线阻塞周期。

### 2.5 指令级并行性

关注相邻指令是否彼此独立、双发射配对是否合法，以及循环是否存在跨迭代依赖。这些特征主要影响：

- 实际 IPC；
- 双发射率；
- 发射限制；
- 单 LSU、单乘除法单元等结构冲突。

---

## 3. 所有测试共有的运行条件

### 3.1 最终执行的是编译结果

测试程序普遍使用如下优化选项：

```text
-O3
-funroll-all-loops
-finline-functions
-falign-jumps=16
-falign-functions=16
```

因此源码中的短循环可能被展开，函数可能被内联，最终代码尺寸和指令组合可能与源码外观明显不同。处理器优化应以 `obj/allbench/test.s` 和动态退休指令流为准。

### 3.2 上板重复次数不同

当前 `machine.h` 中的上板设置为：

```text
普通测试          10 次
fireye_A0          1 次
fireye_C0          4 次
```

部分程序内部还会重复多轮。因此，程序总耗时不能直接代表“每次基本操作有多慢”。

### 3.3 各程序的计时边界并不完全相同

大多数测试在 `shellN()` 外层计时，初始化、核心计算和正确性检查都会计入总时间。

以下程序在内部选择更窄的计时区间：

- `coremark`
- `crc32`
- `dhrystone`
- `sha`
- `stringsearch`

其中 `stringsearch` 会对许多很短的搜索分别读取计数器，再累加时间。它比其他测试更容易受到计数器读取开销影响。

### 3.4 最终目标是实际时间

比赛使用固定 100MHz SoC 计时器测量实际执行时间。对处理器而言可以近似写成：

```text
执行时间 = CPU 周期数 / CPU 频率
```

所以一个减少周期数但明显降低最高频率的优化未必有收益。每次架构修改都应同时比较：

- 周期数；
- CPU 频率；
- 完整 SoC 实现后的 WNS；
- 最终 SoC 计时器结果。

---

<a id="benchmark-overview"></a>

## 4. 20 个测试程序速查表

| 序号 | 程序名 | 名称对应的概念 | 主要程序行为 | 首要考验 |
|---:|---|---|---|---|
| 1 | [`bitcount`](#bench-bitcount) | 位计数、汉明重量 | 多种位计数算法、间接调用、移位和查表 | 分支、间接跳转、ALU、旁路 |
| 2 | [`bubble_sort`](#bench-bubble-sort) | 冒泡排序 | 相邻元素比较和条件交换 | 分支预测、DCache hit、store/load |
| 3 | [`coremark`](#bench-coremark) | 综合嵌入式整数基准 | 链表、矩阵、状态机和 CRC | 前端、Cache、预测器、双发射 |
| 4 | [`crc32`](#bench-crc32) | 32 位循环冗余校验 | 顺序读字节、查表、移位和异或 | load-use、DCache、整数依赖链 |
| 5 | [`dhrystone`](#bench-dhrystone) | 综合整数与系统程序基准 | 函数、字符串、结构体和分支 | BTB、RAS、分支、前端 |
| 6 | [`quick_sort`](#bench-quick-sort) | 快速排序 | 递归、分区和双向扫描 | RAS、分支预测、DCache |
| 7 | [`select_sort`](#bench-select-sort) | 选择排序 | 反复扫描并寻找最小值 | load/compare、分支、DCache |
| 8 | [`sha`](#bench-sha) | 160 位 SHA 散列 | 80 轮移位、逻辑和加法 | ICache、ALU、旁路、双发射 |
| 9 | [`stream_copy`](#bench-stream-copy) | 流式内存复制 | 连续读源数组并写目标数组 | DCache、LSU、AXI、写回 |
| 10 | [`stringsearch`](#bench-stringsearch) | 字符串模式搜索 | Boyer-Moore 类跳表搜索 | byte load、分支、DCache |
| 11 | [`fireye_A0`](#bench-fireye-a0) | 用例编号；非标准算法名 | 变步长翻转数组并反复全表统计 | 大工作集、步长访存、写回 |
| 12 | [`fireye_B2`](#bench-fireye-b2) | 用例编号；非标准算法名 | Sparse Table、区间查询和二分 | DCache、分支、load/shift |
| 13 | [`fireye_C0`](#bench-fireye-c0) | 用例编号；非标准算法名 | Trie 建树和递归约束搜索 | DCache、递归、RAS、分支 |
| 14 | [`fireye_D1`](#bench-fireye-d1) | 用例编号；非标准算法名 | 数组清零、离散聚合和扫描 | store流量、DCache、AXI |
| 15 | [`fireye_I2`](#bench-fireye-i2) | 用例编号；非标准算法名 | 字符网格中的图形模式识别 | ICache、分支、byte 访问 |
| 16 | [`inner_product`](#bench-inner-product) | 向量内积、点积 | 双数组加载、乘法和累加 | LSU、DCache、乘法器、依赖链 |
| 17 | [`lookup_table`](#bench-lookup-table) | 查找表映射 | 用输入值随机索引 LUT | ICache、DCache、子字访存 |
| 18 | [`loop_induction`](#bench-loop-induction) | 循环归纳变量 | 随机填充、三遍复制和 memcmp | DCache、LSU、AXI、循环控制 |
| 19 | [`my_memcmp`](#bench-my-memcmp) | 手写内存比较 | 逐字节比较两个缓冲区 | byte load、DCache、双 load 吞吐 |
| 20 | [`minmax_sequence`](#bench-minmax-sequence) | 序列最值与位置 | 多数据类型反复扫描序列 | ICache、load/compare、分支 |

---

<a id="benchmark-details"></a>

## 5. 各测试程序详细说明

<a id="bench-bitcount"></a>

### 5.1 `bitcount`：位计数

**名称与概念**

Bit count 是统计一个整数中二进制位 `1` 的数量，也叫 population count 或汉明重量。

**源码实际行为**

程序对一组递增输入运行 7 种实现：

1. `x & (x - 1)`，每轮清除最低位的一个 `1`；
2. 掩码、移位和分组求和；
3. 递归的 4-bit 查表；
4. 固定展开的 4-bit 查表；
5. 两种 8-bit 查表写法；
6. 逐位右移并统计。

不同算法通过函数指针数组调用。每种算法处理 100 个输入，上板时整个过程再重复 10 次。

源码：[bitcount](../chiplab/software/examples/nscscc_perf/bench/bitcount)

**程序特征**

- 工作集很小，通常不是大容量 DCache 测试。
- 包含大量移位、按位与、异或和加法。
- 部分循环次数由输入中 `1` 的数量决定。
- 查表版本会产生 byte load 和 load-use 依赖。
- 函数指针调用形成间接控制转移，多个小函数之间频繁切换。

**主要考验**

- 整数 ALU 和移位路径；
- forwarding/bypass；
- 条件分支预测；
- 间接跳转目标预测、BTB 和函数返回；
- 小循环的前端连续供给能力。

**建议重点观察**

- 各类位运算指令占比；
- 条件分支预测错误数；
- 间接调用和 return 的目标错误数；
- load-use 阻塞周期；
- 双发射配对成功率。

---

<a id="bench-bubble-sort"></a>

### 5.2 `bubble_sort`：冒泡排序

**名称与概念**

Bubble sort 反复比较相邻元素，如果顺序错误就交换。较大的元素会逐轮“冒泡”到数组末端。

**源码实际行为**

- 数组长度为 200。
- 每次先把原始数组复制到 `result`。
- 复制循环条件写成了 `m <= N`，会比声明长度多访问一个元素；精确行为应以当前编译结果和链接布局为准。
- 随后执行固定的双重循环。
- 每次调用进行 `200 × 199 / 2 = 19,900` 次相邻比较。
- 每轮测试最后顺序读取结果数组进行正确性检查。
- 上板重复 10 次，每次都从相同的原始无序数组重新开始。

源码：[bubble_sort.c](../chiplab/software/examples/nscscc_perf/bench/bubble_sort/bubble_sort.c)

**程序特征**

- 热点循环很小，取指地址高度集中。
- 数据访问连续，主要是相邻 word load。
- 比较结果决定是否执行两个 store。
- 数据规模较小，进入 Cache 后以 hit 为主。
- 相邻迭代之间可能出现 store 后很快重新 load 同一位置的情况。

**主要考验**

- 数据相关分支预测；
- DCache hit 延迟；
- store-to-load forwarding 或 BRAM 写后读旁路；
- load、compare、branch 的流水线衔接；
- 小循环的双发射效率。

**建议重点观察**

- 比较分支的 taken 比例和 misprediction；
- DCache hit/miss；
- store 后相关 load 的阻塞；
- 每次内层迭代平均周期；
- slot1 退休比例。

---

<a id="bench-coremark"></a>

### 5.3 `coremark`：综合嵌入式整数基准

**名称与概念**

CoreMark 是面向嵌入式处理器的综合整数基准。它不是单一算法，而是用几类常见工作负载共同衡量处理器。

**源码实际行为**

当前测试启用三类核心算法：

- 链表处理；
- 矩阵运算；
- 状态机处理。

运行过程中还会计算 CRC。当前配置的数据区总量为 2000 字节，上板迭代 10 次。

源码：[coremark](../chiplab/software/examples/nscscc_perf/bench/coremark)

**程序特征**

- 控制流和热点函数比简单循环复杂。
- 链表阶段包含指针追踪和数据相关分支。
- 矩阵阶段包含规律访存、乘法和累加。
- 状态机阶段包含较多字符判断和条件分支。
- 多个函数和算法阶段会轮流占用 ICache、BTB 和 DCache。

**主要考验**

- ICache 容量和取指延迟；
- 分支预测器、BTB 和 RAS；
- DCache 对规律访问和指针访问的综合表现；
- 乘法、load-use 和 forwarding；
- 双发射处理混合指令流的能力。

**建议重点观察**

- 各子算法的周期占比；
- IPC 和双发射率；
- ICache、DCache MPKI；
- 分支方向错误和目标错误；
- MUL 指令数及等待周期。

CoreMark 适合作为综合成绩，但不适合单独定位瓶颈。必须同时查看各子算法和 stall 分类。

---

<a id="bench-crc32"></a>

### 5.4 `crc32`：32 位循环冗余校验

**名称与概念**

CRC32 用一个 32 位状态对字节流进行循环冗余校验。当前实现用 256 项查找表把每个字节的处理加速为一次查表、移位和异或。

**源码实际行为**

- 输入是固定字节串。
- CRC 表包含 256 个 32 位元素，大小约 1KB。
- 计时区域主要覆盖逐字节处理循环。
- 每个字节都会更新下一次迭代所需的 CRC 状态。
- 上板对同一输入重复 10 次。

源码：[crc32.c](../chiplab/software/examples/nscscc_perf/bench/crc32/crc32.c)

**程序特征**

核心循环近似为：

```text
读取下一个字节
计算表索引
加载 CRC 表项
旧 CRC 右移
异或得到新 CRC
```

- 输入读取连续；
- 表索引依赖当前输入和上一轮 CRC；
- 新 CRC 依赖旧 CRC，存在明显循环携带依赖；
- CRC 表不大，但可能与栈和其他数据发生 Cache 组冲突。

**主要考验**

- byte load；
- indexed load；
- DCache hit 延迟；
- load-use forwarding；
- 移位、异或和循环分支；
- 对串行依赖链的处理效率。

**建议重点观察**

- 每处理一个字节的平均周期；
- byte load 和 word load 数量；
- DCache miss 及冲突 miss；
- load-use stall；
- 核心循环 IPC。

---

<a id="bench-dhrystone"></a>

### 5.5 `dhrystone`：综合整数与系统程序基准

**名称与概念**

Dhrystone 是传统的合成整数基准，模拟系统程序中常见的过程调用、记录操作、字符串处理、枚举和条件判断。

**源码实际行为**

- 当前编译参数中 `RUNNUMBERS=10`。
- 上板调用 `dhrystone(LOOPTIMES × RUNNUMBERS)`，即执行 100 轮主循环。
- 数据集较小。
- 核心计时在 Dhrystone 内部完成，初始化和最终打印不属于主要计时区间。

源码：[dhrystone](../chiplab/software/examples/nscscc_perf/bench/dhrystone)

**程序特征**

- 函数调用和返回较多；
- 包含结构体、全局变量、数组和字符串操作；
- 分支密度较高，但数据工作集较小；
- 编译器可能内联一部分函数，所以必须结合反汇编判断真实调用关系。

**主要考验**

- BTB 和 RAS；
- 条件分支预测；
- 小函数和基本块的取指效率；
- 整数 ALU、比较和地址生成；
- 双发射对控制密集代码的利用率。

**建议重点观察**

- call、return 和条件分支数量；
- BTB/RAS 命中率；
- 分支恢复周期；
- ICache miss；
- 小数据集下的基础流水线 IPC。

---

<a id="bench-quick-sort"></a>

### 5.6 `quick_sort`：快速排序

**名称与概念**

Quick sort 选择一个枢轴，把数组划分为较小和较大两部分，再递归处理两个子区间。

**源码实际行为**

- 数组长度为 1000，即单个整数数组约 4KB。
- 每次先把原始数组复制到 `result`。
- 使用区间第一个元素作为 pivot。
- `partition` 从两端向中间扫描，并在扫描过程中移动元素。
- 递归处理左右子区间。
- 上板重复 10 次，每次输入相同。

源码：[quick_sort.c](../chiplab/software/examples/nscscc_perf/bench/quick_sort/quick_sort.c)

**程序特征**

- 双向扫描的步数取决于数据分布；
- 分支方向数据相关；
- 递归深度和子区间规模变化；
- result 数组约 4KB，此外还有原始数组、参考数组和递归栈；
- 同一区间内有一定局部性，但递归会不断改变活跃区域。

**主要考验**

- 条件分支预测；
- RAS 和递归返回；
- BTB 容量；
- DCache 容量与相联度；
- load/store 地址生成；
- 分支错误后的前端恢复。

**建议重点观察**

- partition 占总周期的比例；
- 递归 call/return 次数和 RAS miss；
- 方向预测错误数；
- DCache miss；
- 平均每个比较或移动操作的周期。

---

<a id="bench-select-sort"></a>

### 5.7 `select_sort`：选择排序

**名称与概念**

Selection sort 每轮扫描尚未排序的区间，找到最小元素，再与区间首元素交换。

**源码实际行为**

- 数组长度为 200。
- 每次先复制原始数组。
- 复制循环同样使用 `m <= N`，会额外访问一个元素。
- 共进行 19,900 次候选元素比较。
- 每个外层循环结束时只进行一次交换。
- 上板重复 10 次。

源码：[select_sort.c](../chiplab/software/examples/nscscc_perf/bench/select_sort/select_sort.c)

**程序特征**

- 大部分操作是连续 load 和 compare；
- store 数量明显少于 bubble sort；
- “发现新的最小值”分支方向由数据决定；
- 最小值位置形成跨迭代依赖；
- 数据规模小，主要观察 Cache hit 路径。

**主要考验**

- load/compare 吞吐；
- load-use 延迟；
- 条件分支预测；
- 循环携带依赖；
- 单 LSU 对双发射的限制。

**建议重点观察**

- 每次比较平均周期；
- load 数量及 load-use stall；
- 最小值更新分支的预测准确率；
- DCache hit 延迟；
- 双发射拒绝原因。

---

<a id="bench-sha"></a>

### 5.8 `sha`：160 位 SHA 散列

**名称与概念**

SHA 是 Secure Hash Algorithm。当前源码实现输出 160 位摘要，按 64 字节数据块执行 80 轮变换；这里应理解为这份具体实现，而不是泛指所有 SHA 版本。

**源码实际行为**

- 每次读取最多 512 字节输入。
- 每个 64 字节块扩展为 80 个 32 位字。
- 每轮包含移位或旋转、逻辑组合、多次加法和状态寄存器更新。
- `W[80]` 在栈上约占 320 字节。
- 上板对固定长字符串重复 10 次。
- 编译器启用了循环展开和内联。

源码：[sha.c](../chiplab/software/examples/nscscc_perf/bench/sha/sha.c)

**程序特征**

- 计算密集，主要是 ALU 指令；
- 状态 `A/B/C/D/E` 在轮次之间形成强依赖；
- 消息扩展数组访问规律；
- 展开后热点代码可能明显增大；
- 数据集不大，进入 Cache 后可能从访存瓶颈转向取指和执行瓶颈。

**主要考验**

- ICache 容量和相联度；
- 移位、旋转、逻辑和加法路径；
- forwarding；
- ALU 指令的双发射；
- 强依赖链下的基础流水线延迟。

**建议重点观察**

- ICache miss 和热点代码占用的 Cache line 数；
- ALU 指令比例；
- RAW 阻塞；
- 双发射率；
- 每个 64 字节块或每轮的平均周期。

---

<a id="bench-stream-copy"></a>

### 5.9 `stream_copy`：流式内存复制

**名称与概念**

Stream copy 是最简单的流式内存操作：从源数组顺序读取数据，并顺序写入目标数组。

**源码实际行为**

- 源数组和目标数组各有 1000 个 `int`，各约 4KB。
- 核心复制循环执行 1000 次 word load 和 1000 次 word store。
- 随后再次顺序读取两个数组进行正确性检查。
- 上板重复 10 次。

源码：[stream_copy.c](../chiplab/software/examples/nscscc_perf/bench/stream_copy/stream_copy.c)

**程序特征**

- 地址完全连续；
- 每个元素只有一次读取和一次写入；
- 运算量很低，访存占比高；
- 约 8KB 的主要数组工作集会超过较小的 DCache；
- 写策略会显著改变外部事务数量。

**主要考验**

- DCache refill 和替换；
- write-through 或 write-back 策略；
- dirty writeback；
- AXI burst 利用率；
- LSU 吞吐率；
- ICache 与 DCache 请求能否并发。

**建议重点观察**

- load/store 数量；
- DCache miss 和 writeback 数；
- AXI 读写事务数与 beat 数；
- 每个 Cache line 的有效数据利用率；
- 因 LSU 或存储系统导致的阻塞周期。

该程序是分析顺序访存通路的代表，不应首先用分支预测器解释它的性能。

---

<a id="bench-stringsearch"></a>

### 5.10 `stringsearch`：字符串模式搜索

**名称与概念**

String search 是在一个较长字符串中寻找短模式串。当前实现属于 Boyer-Moore 家族，使用按字符建立的坏字符跳转表来跨过不可能匹配的位置。

**源码实际行为**

- 跳转表有 256 项，在 LA32 上约为 1KB。
- 每组测试先建立跳转表，再开始计时搜索。
- 搜索使用数据相关步长前进。
- 候选位置命中时调用 `strncmp` 进一步比较。
- 大约有 57 组模式串与目标字符串。
- 每次短搜索分别读取开始和结束计数器，再把时间累加。
- 上板将整组搜索重复 10 次。

源码：[pbmsrch_small.c](../chiplab/software/examples/nscscc_perf/bench/stringsearch/pbmsrch_small.c)

**程序特征**

- 大量 byte load；
- 跳表访问由输入字符决定；
- 搜索步长不固定；
- 分支方向和循环次数依赖字符串内容；
- 跳转表刚在计时前初始化，通常具有较好的时间局部性；
- 多个短计时间隔使固定计时开销占比上升。

**主要考验**

- byte load 路径；
- DCache 对小型随机查表的命中延迟；
- 条件分支预测；
- 字符串比较函数的取指和调用；
- 短循环与函数切换。

**建议重点观察**

- 搜索核心周期和计数器读取周期的占比；
- byte load 数量；
- 跳表 load-use stall；
- 分支预测错误；
- 每组字符串的耗时分布，而不只是累加总数。

---

<a id="bench-fireye-a0"></a>

### 5.11 `fireye_A0`：变步长翻转与全数组统计

**名称与概念**

`A0` 是当前测试中的用例编号，不是公开通用的算法名称。理解该程序应直接看它执行的数组操作。

**源码实际行为**

- `pos[10000]` 是 10000 个 `int`，大小约 40KB。
- 输入包含 20 个不同步长 `x`。
- 对每个 `x`，先访问 `x, 2x, 3x...` 并翻转对应元素。
- 随后完整扫描 `pos[1..10000]` 并求和。
- 保存所有轮次中的最大结果。
- 该测试上板外层只执行 1 次。

源码：[shell11.c](../chiplab/software/examples/nscscc_perf/bench/fireye_A0/shell11.c)

**程序特征**

- 工作集明显大于小型 DCache；
- 同时包含变步长读改写和连续全数组扫描；
- 完整扫描会反复读取同一 40KB 数组；
- 翻转操作会产生 dirty line 或外部 store；
- 循环边界规律，控制流相对容易预测。

**主要考验**

- DCache 容量和替换策略；
- 不同步长下的空间局部性；
- writeback 或 store buffer；
- AXI 读写效率；
- 顺序预取是否有效。

**建议重点观察**

- 各步长对应的 miss 数；
- DCache writeback 数；
- 全数组扫描的带宽；
- 每轮 `x` 的耗时；
- 总线读写 beat 和有效数据比例。

---

<a id="bench-fireye-b2"></a>

### 5.12 `fireye_B2`：Sparse Table 区间查询与二分

**名称与概念**

`B2` 是用例编号。程序的核心算法是 Sparse Table 区间最值查询，并在每个起点上进行二分搜索。

**源码实际行为**

- 输入长度为 100。
- 栈上建立 `dl[20][100]` 和 `dr[20][100]`，合计约 16KB。
- `dl` 保存区间最大值信息，`dr` 保存区间最小值信息。
- 查询前通过右移循环计算 `log2`。
- 对每个位置进行二分，判断某个区间长度是否满足条件。
- 核心求解内部重复 2 次，上板外层重复 10 次。

源码：[shell12.c](../chiplab/software/examples/nscscc_perf/bench/fireye_B2/shell12.c)

**程序特征**

- 初始化阶段规律地写二维数组；
- 查询阶段在不同层和不同位置读取 Sparse Table；
- 包含二分搜索、区间条件判断和可变次数的 `log2` 循环；
- 栈工作集超过较小 DCache；
- load 后很快参与 max/min 和分支判断。

**主要考验**

- DCache 容量与相联度；
- 栈数据访问；
- load-use forwarding；
- 条件分支预测；
- 移位和地址计算。

**建议重点观察**

- 初始化阶段和查询阶段的周期占比；
- DCache miss；
- 二分分支错误数；
- load-use stall；
- 每次区间查询的平均周期。

---

<a id="bench-fireye-c0"></a>

### 5.13 `fireye_C0`：Trie 与递归约束搜索

**名称与概念**

`C0` 是用例编号。程序使用两个 Trie 保存两组二字符单词，再递归枚举同时满足横向和纵向前缀约束的字符网格。

**源码实际行为**

- 两组输入各有 50 个长度为 2 的字符串。
- 两个 Trie 的主要数组为 `2 × 100 × 26 × sizeof(int)`，约 20.8KB。
- DFS 每个位置尝试 26 个字符。
- 每次选择都要同时检查两个 Trie 中的下一条边。
- 搜索使用递归函数调用。
- 核心 DFS 内部重复 2 次，上板外层重复 4 次。

源码：[shell13.c](../chiplab/software/examples/nscscc_perf/bench/fireye_C0/shell13.c)

**程序特征**

- Trie 边访问由当前搜索路径决定；
- 大量分支会快速跳过无效字符；
- 递归深度不大，但调用频繁；
- Trie 数据大于小型 DCache；
- 访问位置在两个 Trie 和状态数组之间切换。

**主要考验**

- DCache 容量和不规则访问；
- 条件分支预测；
- 函数调用和 RAS；
- ICache 对递归搜索代码的供给；
- 地址生成和 load-use。

**建议重点观察**

- DFS 调用次数；
- 每个候选字符平均指令数；
- 分支预测错误；
- Trie 访问的 DCache miss；
- call/return 目标预测。

---

<a id="bench-fireye-d1"></a>

### 5.14 `fireye_D1`：离散聚合与扫描

**名称与概念**

`D1` 是用例编号。程序先按一个坐标聚合另一坐标的最小值和最大值，再扫描候选位置计算代价最小值。

**源码实际行为**

- 输入包含 492 对整数。
- `mn`、`mx`、`in`、`out` 各声明为 10000 个 `int`。
- 当前参数只清零和访问前约 1001 项，因此四个主要数组的活跃区域合计约 16KB。
- 输入数组另外约占 4KB。
- 每轮先执行多次 `memset`，再做离散索引更新，最后反向连续扫描。
- 核心算法内部重复 2 次，上板外层重复 10 次。

源码：[shell14.c](../chiplab/software/examples/nscscc_perf/bench/fireye_D1/shell14.c)

**程序特征**

- `memset` 形成连续 store 流；
- 输入处理阶段产生离散索引的读改写；
- 最后阶段顺序扫描多个数组；
- 包含整数乘法、加法和 min/max；
- 活跃工作集明显大于小型 DCache。

**主要考验**

- store 吞吐和写策略；
- DCache 容量；
- dirty writeback 和 AXI burst；
- 离散索引访问；
- 乘法器和 forwarding。

**建议重点观察**

- `memset`、离散聚合、最终扫描各自的周期；
- store 数量和 writeback；
- DCache miss；
- AXI 写事务粒度；
- MUL 指令数与等待周期。

---

<a id="bench-fireye-i2"></a>

### 5.15 `fireye_I2`：字符网格图形识别

**名称与概念**

`I2` 是用例编号。程序在由 `#` 和 `.` 组成的二维字符网格中寻找特定图形模式，可视为小型图像或字符识别工作负载。

**源码实际行为**

- 网格规模约为 `32 × 19`。
- `vis[32][19]` 约占 2.4KB。
- 程序先清理孤立点，再扫描候选图形边界。
- 对候选区域执行多层检查，并调用 `find()`、`check()`。
- 包含 `/ 3`、`% 3` 等整数除法或取模表达式；最终是否成为 DIV/MOD 指令取决于编译结果。
- 核心算法内部重复 10 次，上板外层又重复 10 次。

源码：[shell15.c](../chiplab/software/examples/nscscc_perf/bench/fireye_I2/shell15.c)

**程序特征**

- 数据工作集不大，但控制流复杂；
- 多层嵌套循环和大量提前退出分支；
- 大量 byte load；
- 访问二维数组时既有连续访问，也有邻域和候选区域访问；
- 编译器循环展开可能显著增大热点代码。

**主要考验**

- ICache 容量和取指连续性；
- 条件分支预测；
- byte load；
- DIV/MOD 单元或编译器生成的强度削弱序列；
- 分支错误恢复延迟。

**建议重点观察**

- ICache miss；
- 条件分支密度和预测错误；
- byte load 数量；
- 实际 DIV/MOD 指令数；
- `check()`、`find()` 和主扫描各自的周期。

---

<a id="bench-inner-product"></a>

### 5.16 `inner_product`：向量内积

**名称与概念**

Inner product，也叫 dot product，对两个向量逐元素相乘并累加：

```text
sum = Σ(a[i] × b[i])
```

**源码实际行为**

当前真正启用的类型为：

- `int8_t`
- `uint8_t`
- `int16_t`
- `uint16_t`

32 位整数和浮点路径已经写在源码中，但当前被注释，不参与测试。

每个向量长度为 8000：

- 两个 8 位数组合计约 16KB；
- 两个 16 位数组合计约 32KB。

每种类型先初始化两个数组，再执行 2 遍内积；整个 `shell16_main()` 上板重复 10 次。

源码：[shell16.c](../chiplab/software/examples/nscscc_perf/bench/inner_product/shell16.c)

**程序特征**

- 两条连续 load；
- 一次乘法；
- 一次累加；
- 循环控制；
- 累加值形成跨迭代依赖；
- 数组规模明显超过小型 DCache；
- byte 和 half-word load 需要扩展到处理器运算宽度。

**主要考验**

- DCache 和外部存储带宽；
- LSU 每周期可接受的 load 数；
- byte/half-word load；
- 乘法器吞吐和延迟；
- 累加依赖的 forwarding；
- 双发射是否允许两条 load 或 load+MUL 配对。

**建议重点观察**

- 每个元素的平均周期；
- load 数量、DCache miss 和等待周期；
- MUL 数量和 busy 周期；
- load-use stall；
- 双发射结构冲突；
- 不同数据宽度之间的性能差异。

---

<a id="bench-lookup-table"></a>

### 5.17 `lookup_table`：查找表映射

**名称与概念**

Lookup table 使用输入值作为索引，从预先构造的表中读取输出值：

```text
result[i] = LUT[input[i]]
```

**源码实际行为**

测试以下四种数据类型：

- `uint8_t`
- `int8_t`
- `uint16_t`
- `int16_t`

每种类型都测试：

- 20 项小数组；
- 1000 项大数组；
- 原地写回；
- 写入独立结果数组。

主要数据规模：

- 8 位 LUT：256 字节；
- 16 位 LUT：8192 项，约 16KB；
- 8 位输入/结果各约 1KB；
- 16 位输入/结果各约 2KB。

输入索引通过伪随机数生成。整个测试上板重复 10 次。

源码：[shell17.c](../chiplab/software/examples/nscscc_perf/bench/lookup_table/shell17.c)

**程序特征**

- 输入数组顺序读取；
- LUT 地址由输入值决定，属于间接数据访问；
- 结果数组顺序写入；
- 同时覆盖 byte 和 half-word load/store；
- 16 位 LUT 明显大于小型 DCache；
- 多类型和多场景经过内联、展开后可能形成较大的代码体积。

**主要考验**

- DCache 对随机 LUT 访问的表现；
- byte/half-word load/store；
- load-use 延迟；
- ICache 容量；
- 原地访问时的 store-to-load 行为；
- LSU 吞吐。

**建议重点观察**

- 四种类型、small/large、in-place/out-of-place 的分项周期；
- LUT load 的 DCache miss；
- byte/half-word 访存数量；
- ICache miss；
- load-use 和 store 相关阻塞。

---

<a id="bench-loop-induction"></a>

### 5.18 `loop_induction`：循环归纳变量

**名称与概念**

Loop induction variable 是随循环按固定规律变化的变量，例如 `i++` 或 `地址 += 4`。该测试原本用于观察编译器是否能合并冗余归纳变量并完成强度削弱。

**源码实际行为**

核心复制循环写成：

```c
for (i = 0, j = 0, k = 0; k < count; ++i, ++j, ++k)
    dest[i] = source[j];
```

当前规模为：

- 源数组：3200 个 `int32_t`，约 12.8KB；
- 目标数组：约 12.8KB；
- 两个数组合计约 25.6KB；
- 复制循环执行 3 遍。

但外层总计时还包含：

- 用 `rand()` 填充源数组；
- 用 `rand()` 填充目标数组；
- 最后调用 `memcmp()` 检查结果。

整个过程上板重复 10 次。

源码：[shell18.c](../chiplab/software/examples/nscscc_perf/bench/loop_induction/shell18.c)

**程序特征**

- 名称强调归纳变量，但最终负载并不只是一个 copy 循环；
- 编译器很可能把 `i/j/k` 合并成更简单的指针或单索引循环；
- 两次随机填充和 memcmp 可能占据明显周期；
- 数组工作集远大于小型 DCache；
- 复制阶段属于连续 load/store。

**主要考验**

- DCache refill、writeback；
- AXI 顺序读写；
- LSU 吞吐；
- `rand()` 路径中的整数运算和状态访问；
- 编译后复制循环的指令级并行性。

**建议重点观察**

- 源填充、目标填充、三遍 copy、memcmp 的分项周期；
- 实际退休指令中是否还存在三个归纳变量；
- DCache miss/writeback；
- AXI beat；
- copy 核心 IPC 和双发射率。

不能仅根据程序名字把总耗时归因于“地址递增慢”。

---

<a id="bench-my-memcmp"></a>

### 5.19 `my_memcmp`：手写内存比较

**名称与概念**

`memcmp` 逐字节比较两段内存，在发现第一个不同字节时停止。`my_memcmp` 表示该测试使用自己的 C 循环，而不是把核心比较直接交给标准库。

**源码实际行为**

- 常量名为 `SIZE_3M`，但当前实际值是 8192 字节，不是 3MB。
- 第一个缓冲区为 8192 字节。
- 第二个缓冲区额外保留 1024 字节，合计 9216 字节。
- 先把两个缓冲区填成相同内容，并完整比较一次。
- 再修改第一个缓冲区的最后一个字节。
- 第二次比较要扫描到最后一个字节才发现不同。
- 上板重复 10 次。

源码：[shell19.c](../chiplab/software/examples/nscscc_perf/bench/my_memcmp/shell19.c)

**程序特征**

- 两次比较都会读取完整的 8KB 有效区域；
- 每个循环迭代通常包含两个 byte load、比较和循环分支；
- “字节不同”分支在几乎所有迭代中都不跳转；
- 初始化阶段包含较长的连续 store；
- 工作集超过小型 DCache。

**主要考验**

- byte load 吞吐；
- 单 LSU 是否限制两个输入流；
- DCache 容量和顺序访问；
- load-use；
- 高度偏置分支的预测；
- 初始化 store 和 writeback。

**建议重点观察**

- fill 和 compare 的分项周期；
- 每比较一个字节的平均周期；
- byte load 数量；
- DCache miss/writeback；
- 双 load 导致的结构冲突；
- 分支预测错误数。

---

<a id="bench-minmax-sequence"></a>

### 5.20 `minmax_sequence`：序列最值与位置

**名称与概念**

Min/max sequence 在一段序列中寻找最小值、最大值，以及它们第一次出现的位置。

**源码实际行为**

当前启用六种整数类型：

- `int8_t`
- `uint8_t`
- `int16_t`
- `uint16_t`
- `int32_t`
- `uint32_t`

浮点路径被注释，不参与当前测试。

每种类型处理 800 个元素：

- 8 位数组约 800 字节；
- 16 位数组约 1.6KB；
- 32 位数组约 3.2KB。

每种类型都进行：

- 随机数填充；
- 基准最小值扫描；
- 基准最大值扫描；
- 基准最小位置扫描；
- 基准最大位置扫描；
- 重复的最小值和最大值测试。

需要特别注意：

```text
minmax_sequence_iter = 2
位置测试前执行 minmax_sequence_iter / 5
整数除法结果为 0
```

因此后面的“位置测试重复循环”实际执行 0 次；不过前面的基准位置扫描仍各执行一次。整个 `shell20_main()` 上板重复 10 次。

源码：[shell20.c](../chiplab/software/examples/nscscc_perf/bench/minmax_sequence/shell20.c)

**程序特征**

- 单个数据数组可以放入中等规模 DCache；
- 同一数组被反复顺序扫描，时间局部性较好；
- 每个元素产生 load、compare 和可能的条件更新；
- 最值或最值位置形成循环携带依赖；
- 六种类型和大量相似函数形成较大的整体代码体积；
- byte、half-word、word 三种访问宽度都会出现。

**主要考验**

- ICache 容量和函数切换；
- byte/half-word/word load；
- load/compare forwarding；
- 数据相关分支；
- 小工作集下的 DCache hit 性能；
- 不同数据宽度的执行效率。

**建议重点观察**

- 六种类型的分项周期；
- ICache miss；
- 各宽度 load 数量；
- load-use stall；
- 最值更新分支的预测准确率；
- `rand()` 填充和真正扫描的周期占比。

---

<a id="subsystem-groups"></a>

## 6. 按处理器部件重新分类

同一个程序通常同时考验多个部件。下面的分类表示“优先用哪些程序验证某项优化”，不是互斥分类。

### 6.1 前端、ICache 和取指带宽

优先观察：

- `coremark`
- `sha`
- `fireye_I2`
- `lookup_table`
- `minmax_sequence`

共同特点是热点函数较多、代码经过展开或不同阶段频繁切换。以当前 `allbench` 二进制为例，部分静态函数已经大于 4KB；具体尺寸会随编译结果变化，应每次重新统计。

### 6.2 条件分支预测

优先观察：

- `bubble_sort`
- `quick_sort`
- `select_sort`
- `stringsearch`
- `fireye_C0`
- `fireye_I2`
- `minmax_sequence`

应分别统计方向错误和目标错误。把所有 redirect 都记成“方向预测错误”会掩盖 BTB、RAS 和间接跳转问题。

### 6.3 BTB、间接跳转和 RAS

优先观察：

- `bitcount`：函数指针间接调用；
- `dhrystone`：大量过程调用；
- `quick_sort`：递归；
- `fireye_C0`：递归 DFS；
- `coremark`：多函数混合控制流。

### 6.4 DCache 容量与外部存储系统

优先观察：

- `stream_copy`
- `fireye_A0`
- `fireye_B2`
- `fireye_C0`
- `fireye_D1`
- `inner_product`
- `loop_induction`
- `my_memcmp`

这些测试的主要工作集大于几 KB，适合评价 Cache 容量、行大小、替换、writeback 和 AXI 事务效率。

### 6.5 byte/half-word 访存

优先观察：

- `crc32`
- `stringsearch`
- `fireye_I2`
- `inner_product`
- `lookup_table`
- `my_memcmp`
- `minmax_sequence`

这些程序可用于检查：

- 地址低位处理；
- 符号扩展和零扩展；
- byte-enable；
- BRAM 读出后的对齐选择；
- 子字 load-use 延迟。

### 6.6 乘法与除法

优先观察：

- `coremark` 的矩阵阶段；
- `fireye_D1`；
- `inner_product`；
- `fireye_I2` 中可能保留下来的 DIV/MOD。

必须先看反汇编和动态计数。源码中的乘除表达式可能被常量折叠或强度削弱，不能只从 C 代码判断。

### 6.7 LSU 吞吐和双发射限制

优先观察：

- `stream_copy`
- `inner_product`
- `lookup_table`
- `loop_induction`
- `my_memcmp`

如果处理器每个发射组最多只能包含一条 LSU 指令，这些程序通常会较早暴露结构吞吐上限。

---

<a id="analysis-workflow"></a>

## 7. 推荐的实际分析流程

### 7.1 第一步：静态分析实际二进制

对 `obj/allbench/main.elf` 或 `test.s` 统计：

- 各函数代码尺寸；
- load/store/branch/MUL/DIV 静态数量；
- 热点循环的指令组合；
- 分支目标；
- 理论可双发射的相邻指令比例。

静态分析用于提出假设，不能代替动态计数。

### 7.2 第二步：采集动态程序画像

在退休端记录：

- PC 和指令；
- load/store 有效地址和访问宽度；
- 分支方向和实际目标；
- call、return、间接跳转；
- 每个函数或基本块的执行次数。

由此可以得到：

- 动态指令分类；
- 热点 PC；
- 实际代码工作集；
- 数据工作集和访问步长；
- 分支方向序列；
- 独立于当前 Cache 配置的程序特征。

### 7.3 第三步：加入微架构性能计数器

建议的最小计数器集合：

#### 退休与发射

- 总周期；
- 退休指令数；
- slot1 退休数；
- 单发射周期；
- 双发射周期；
- 无发射周期；
- 各种配对拒绝原因。

#### 前端

- ICache access、hit、miss；
- ICache refill 等待周期；
- Fetch Queue 空周期；
- 分支重定向次数；
- 错误路径取指丢弃数。

#### 控制流

- 条件分支数；
- 方向预测错误数；
- BTB target miss；
- return 预测错误；
- 间接跳转目标错误；
- 分支恢复损失周期。

#### 数据侧

- 各宽度 load/store 数量；
- DCache hit/miss；
- dirty writeback；
- DCache 等待周期；
- load-use stall；
- LSU 结构冲突。

#### 乘除法和总线

- MUL、DIV、MOD 指令数；
- 乘除法 busy 周期；
- AXI 读写事务数；
- AXI 读写 beat 数；
- 平均返回延迟；
- ICache 与 DCache 同时有请求在途的周期。

最好再建立一组互斥的顶层周期分类：

```text
有效退休
+ 前端缺指令
+ 分支恢复
+ 数据存储系统等待
+ 执行单元或数据相关等待
= 总周期
```

这样可以直接回答“时间到底花在哪里”。

### 7.4 第四步：做理想化对照实验

建议每次只改变一个因素：

1. 理想 ICache；
2. 理想 DCache；
3. 完美分支预测；
4. 单周期或无限吞吐 MUL/DIV；
5. 放宽双发射配对；
6. 模拟第二 LSU；
7. 扫描不同 Cache 容量、相联度和行大小。

对每个程序记录：

```text
周期收益 = baseline_cycles / new_cycles
时间收益 = (baseline_cycles / baseline_frequency)
         / (new_cycles / new_frequency)
```

只有同时改善最终时间、保持功能正确并满足完整 SoC 时序的方案，才是有效优化。

---

<a id="common-mistakes"></a>

## 8. 常见误判

### 8.1 “运行最久的程序就是最值得优化的程序”

不一定。总时间还受重复次数和工作量影响。最终应看官方评分权重以及每项相对加速比。

### 8.2 “程序名字说明了全部瓶颈”

不成立。例如：

- `loop_induction` 还包含随机填充和 `memcmp`；
- `minmax_sequence` 还包含随机数生成；
- `coremark` 是多个算法的混合；
- Fireye 名称只是用例编号。

### 8.3 “源码中存在除法，所以一定需要优化除法器”

不一定。常数除法可能被编译器变成乘法和移位。应统计反汇编和动态 DIV/MOD 指令。

### 8.4 “Cache 越大一定越好”

更大的 Cache 可能增加 BRAM 使用、命中路径延迟和布线压力，降低最高频率。应同时计算周期收益和频率损失。

### 8.5 “仿真无延迟模式的周期就是最终性能”

无延迟模式适合验证功能和分析核心依赖，但不能代表 DDR、AXI、refill 和 writeback 的真实代价。最终判断必须使用规定的性能内存延迟和上板结果。

---

## 9. 本文结论

这 20 个程序大致覆盖了五类处理器压力：

1. **控制密集型**：排序、字符串搜索、Trie、网格识别；
2. **计算密集型**：SHA、bitcount、CRC32；
3. **流式访存型**：stream copy、loop induction、memcmp；
4. **大工作集或间接访问型**：A0、B2、C0、D1、lookup table；
5. **综合混合型**：CoreMark、Dhrystone、minmax sequence。

正确的优化顺序不是先选一个看起来重要的硬件模块，而是：

```text
理解程序
→ 统计实际动态行为
→ 定量拆分周期
→ 做单因素对照实验
→ 同时评估周期数和最高频率
→ 再决定修改处理器
```

本文提供的是第一步的程序地图。后续性能计数结果应继续补充到本文或单独的测量报告中，使“程序特征”和“当前处理器瓶颈”始终保持区分。
