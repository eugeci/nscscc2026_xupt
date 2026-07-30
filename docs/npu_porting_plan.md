# XUPT-NPU 协处理器移植、Linux 多模型运行时与编译器路线

> 最后更新：2026-07-30
> 项目定位：面向 LoongArch SoC 的轻量级、descriptor-driven、INT8 CNN
> 推理协处理器，而不是支持任意计算图和算子的通用 NPU。

## 1. 目标与范围

本路线的近期目标是在不影响处理器核开发的前提下，将旧工程
`../la32r_xupt_soc_a735t` 中已经验证的 NPU 能力完整迁移到 Chiplab：

1. 在同一套 NPU bitstream 上运行 FaceNet/LBP、LeNet/MNIST 和
   TinyVGG-S1/S2b；
2. 在 Linux 中加载模型参数、descriptor 和输入，等待中断并取得通用结果
   tensor；
3. 在运行时切换模型，不因更换网络重新综合 FPGA；
4. 先在仓库固定的 OpenLA500 baseline 上完成 Linux RTL 仿真，再进行 FPGA
   验证；
5. 最终为摄像头采集、图像预处理、分类/检测结果叠加提供稳定接口。

当前工作继续放在根仓库和 `chiplab` 子模块的
`feature/npu-linux-port` 分支。NPU 集成不得混入 `core` 子模块的处理器开发
改动；处理器核只作为回归对象和 AXI/中断接口提供者。

以下内容暂不作为近期目标：

- 任意 ONNX 模型和动态计算图；
- Transformer、浮点模型或训练任务；
- 在目标 SoC 上完成训练、校准和全功能模型编译；
- 为追求“通用 NPU”名称而无验证地扩大算子集合。

项目文档、答辩和界面可以继续使用 `XUPT-NPU` 或 `XNPU`，但对外完整名称应使用
“轻量级可配置 INT8 CNN 推理协处理器”或
“Lightweight Descriptor-Driven INT8 CNN Inference Coprocessor”。

## 2. 当前已完成基线

### 2.1 Chiplab RTL 与裸机 BSP

当前已经完成第一阶段 ROM/MMIO 集成：

- 从旧工程导入 NPU 计算核、预处理、ROM DMA、AXI DMA 和 AXI slave wrapper；
- 在 Verilator SoC 和 nscscc-team FPGA SoC 中增加 64 KiB AXI slave 地址窗；
- 将 NPU 中断接入处理器外部中断；
- 将 FaceNet 参数、微码和 descriptor 文件加入 Verilator/Vivado 构建；
- 移植裸机 BSP、后处理函数和 `npu_smoke`；
- 保留完整 AXI DMA、packed preload 和 result writeback RTL/BSP 接口。

当前地址约定如下：

| 项目 | 数值 |
| --- | --- |
| 物理 MMIO | `0x1f100000`--`0x1f10ffff` |
| 裸机非缓存地址 | `0xbf100000` |
| Linux 验证用 CPU HWIRQ | `2` |
| 帧输入区 | slave aperture `0x1000` 起 |
| descriptor 区 | slave aperture `0x6000`--`0x63ff` |

### 2.2 Linux ROM/MMIO 基线

仓库已经包含可复现的 Linux 5.14 集成：

- platform/misc driver：`/dev/xupt-npu`；
- 设备树节点和 IRQ；
- descriptor 装载、固定帧写入、启动、IRQ/轮询等待和 bbox 返回；
- 内置 `npu_smoke` 的 initramfs；
- 固定 OpenLA500 baseline 的无波形 Chiplab Verilator 启动路径。

当前 OpenLA500 RTL 仿真已经能够启动 Linux 并运行端到端 smoke，预期成功标志为
`NPU_LINUX_PASS`。复现命令和固定的 Linux/OpenLA500 版本见
[`linux/npu/README.md`](../linux/npu/README.md)。

### 2.3 ROM 基线与 DMA 扩展的边界

SoC 默认构建仍使用：

```verilog
.USE_AXI_DMA(0)
```

因此不传构建选项时，参数和微码仍来自 RTL 内置 ROM，Linux UAPI v1 继续提供
FaceNet bring-up 回归：

```text
GET_INFO -> RESET -> LOAD_DESCRIPTORS -> write(19200-byte frame)
         -> RUN -> WAIT(bbox)
```

现在也可以用 `NPU_AXI_DMA=1` 显式选择 DMA 构建：NPU master 经 RAM 端
2-to-1 仲裁器访问内存，Linux UAPI v2 提供单活动模型的 parameter、scratch 和
result DMA 管理。默认值不变，因而处理器日常回归不会无意启用 NPU DMA。

阶段 3 只固化分段模型 UAPI 和 FaceNet DMA 金标准验证；`.xnpu` 包、目标端
运行时以及四模型循环切换仍属于阶段 4/5，不能把“驱动已经能换模型”误写成
“完整多模型产品链已经完成”。

## 3. 旧工程中已经验证的能力

旧工程使用同一套 NPU bitstream、descriptor 模式和 `NPU_AXI_DMA=1`，已经完成
以下模型族：

| 模型族/预设 | 输入路径 | 输出 | 参数大小 |
| --- | --- | --- | ---: |
| FaceNet/LBP | `160x120` frame，19200 B | bbox5 | 84392 B |
| LeNet/MNIST | `28x28` 有效数据，使用 frame path | 10 类 `u8` | 8208 B |
| TinyVGG-S1 | CHW `3x34x34` packed preload，3468 B | 10 类 `u8` | 36440 B |
| TinyVGG-S2b | CHW `3x34x34` packed preload，3468 B | 10 类 `u8` | 122980 B |

FaceNet seed42/seed7 是同一网络的不同 fixture；TinyVGG-S1/S2b 是同一模型族的
两个结构预设。四套参数镜像总计 252020 B，参数本身不是多模型常驻的主要内存
压力，scratch 空间才需要重点规划。

旧工程的 `cnn_demo` 已经实现 `NPUDv1` 服务：

```text
PING / LIST / SELECT_MODEL / LOAD_PARAM / VERIFY_PARAM
RUN_IMAGE / RUN_FIXTURE / STATUS
```

当前切换语义是“单参数槽”：

1. `SELECT_MODEL` 选择模型元数据；
2. `LOAD_PARAM` 将该模型参数写入公共 DDR 参数槽；
3. 加载成功后清除其他模型的 `param_loaded` 状态；
4. 运行时装载对应 descriptor，设置 parameter/scratch/result 地址；
5. 根据模型选择 frame 或 packed preload 输入路径；
6. 等待计算和 result writeback 完成，再执行 bbox 或 top-k 后处理。

这套行为是 Linux v2 的第一版参考语义。它已经在旧工程完成 VCS 和 FPGA
验证，不需要重新定义模型切换概念。

旧工程的 Python 编译链支持：

```text
facenet_lbp_v1
mnist_lenet_v1
npu_vgg_s1_v1
npu_vgg_s2b_v1
```

它可以生成量化配置、blocked parameter image、microcode、descriptor、BSP
header、fixture 和 manifest。近期应把它作为数值参考实现，而不是立即重写量化
算法。

## 4. 目标软硬件架构

目标数据流如下：

```text
开发机模型编译/打包
        |
        v
    model.xnpu
        |
        v
Linux 用户态 libxnpu / xnpu-run / 展示程序
        |
        v
    /dev/xupt-npu
        |
        v
Linux 驱动：descriptor + DMA parameter/scratch/result + IRQ
        |
        v
NPU AXI slave（控制） + NPU AXI master（访问 DDR）
```

各层职责必须保持清晰：

- **编译器**：量化、算子 lowering、参数布局、descriptor 和模型包生成；
- **用户态运行时**：模型包解析、模型选择、图像预处理、标签、bbox/top-k
  后处理和界面；
- **内核驱动**：硬件状态机、DMA 缓冲区、寄存器编程、中断、超时、并发和资源
  隔离；
- **RTL**：执行已经编译并通过约束检查的 descriptor 和参数。

内核不得理解 FaceNet、LeNet 或 TinyVGG 等模型名称，也不得负责图像缩放、标签
查找或分类后处理。

### 4.1 最终替换为自研 LA32 核时的存疑点与接口契约

NPU RTL、模型参数、descriptor、编译器后端和 Linux UAPI 本身都不依赖
OpenLA500 的微架构，因此不应为换核重写。真正需要重新验收的是处理器与 SoC
边界。当前不能直接假定“顶层端口同名即可无适配替换”，原因如下：

1. **AXI 协议契约**：Chiplab 的 `core_top` 边界是 32-bit、4-bit ID 的
   AXI3 风格接口，仿真侧使用 4-bit burst length、2-bit lock 和 WID，FPGA
   工程再经过 AXI3-to-AXI4 bridge。自研核必须保持握手、burst、ID、错误响应
   和 back-pressure 行为正确，不能只做到信号宽度一致。
2. **外部中断映射**：OpenLA500/Chiplab 当前把 `intrpt[n]` 映射到
   `ESTAT.IS[n+2]`。自研核现有 wrapper 将 `|intrpt` 汇总为一个 timer pending
   信号，这会丢失中断号，也不满足 Linux irqchip 的期望；换核前必须改成逐位
   外部中断并验证 claim/ack、屏蔽、重复触发和异常返回。
3. **Linux 架构能力**：自研核当前文档仍把 CSR/TLB、cache maintenance、
   精确异常、系统调用等列为未完成或未覆盖项。它们是启动 Linux 的前置条件，
   与 NPU 驱动是否完成无关。
4. **DMA 与缓存一致性**：第一版驱动使用 `dma_alloc_coherent()`，只把 DMA API
   返回的 `dma_addr_t` 写给 NPU。自研核必须正确实现其声明的 cache/coherency
   语义；在硬件没有真正 coherent 前，设备树不得添加 `dma-coherent`。如果最终
   平台是 non-coherent，则必须保证 LoongArch DMA API 的 cache clean/invalidate
   路径可用。
5. **内存与时钟复位**：换核后仍要保持 NPU MMIO 地址、RAM 物理地址、字节序、
   时钟域和复位时序不变，或只在设备树/SoC glue 层进行显式调整。

因此，处理器替换采用以下分层契约：

```text
保持不变：
  NPU 寄存器 ABI / descriptor / parameter layout / Linux UAPI
  NPU AXI master 到 RAM 的仲裁器 / 模型编译产物

允许适配：
  core_top wrapper / AXI3-to-AXI4 glue / interrupt mapping
  cache 与 DMA arch glue / 设备树 CPU、memory、interrupt-controller 节点
```

换核验收门槛按顺序执行：

1. 自研核通过 Chiplab func 与 AXI back-pressure/error 基础回归；
2. 能启动同一 Linux kernel/initramfs，并通过用户态、异常、定时器和中断回归；
3. ROM/MMIO `npu_smoke` 通过，证明 MMIO 与 NPU IRQ 没有受影响；
4. DMA 模式完成 parameter read、scratch read/write 和 result writeback；
5. 连续模型切换结果与 OpenLA500 baseline 一致。

在第 2 项尚未完成时，OpenLA500 是 NPU/Linux 集成的固定参考核；这不是把 NPU
绑定到 OpenLA500，而是把“驱动/加速器问题”和“自研核 Linux 完整性问题”隔离。

## 5. 近期实施阶段

### 阶段 0：保留已验证 ROM/MMIO 回归

ROM/MMIO Linux smoke 必须继续保留，作为后续 AXI DMA 修改的最小回归：

- 复位与版本寄存器；
- descriptor 装载；
- 19200 B frame 写入；
- IRQ 和轮询完成路径；
- FaceNet bbox；
- 连续运行和超时复位。

AXI DMA 版本不能以删除这套基线为代价。需要允许通过构建参数或 wrapper 参数
选择 ROM/MMIO 与 DMA 模式。

### 阶段 1：迁移模型源文件与部署产物

从旧工程按来源清单迁移，而不是复制整个工作树：

- 四个编译 target 的 config；
- 模型 compiler/backend 脚本；
- FaceNet、LeNet、TinyVGG-S1/S2b 的参数、descriptor 和 fixture；
- 模型输入输出契约；
- checksum、预期 bbox/top1 和已验证日志摘要；
- 生成物的上游 commit、编译器版本和 SHA-256。

生成物中不能保留开发机绝对路径作为运行依赖。训练数据和 `.pth` checkpoint
不进入 Linux rootfs；Linux 只消费最终模型包。

### 阶段 2：打通 NPU AXI master

当前 nscscc-team crossbar 实际配置为两个 slave-side initiator port 和四个
master-side target port，即 `NUM_SI=2`、`NUM_MI=4`。M03 是 CPU/JTAG 访问 NPU
寄存器的 MMIO target，不是 NPU 的 DMA 端口。

启用 DMA 时应：

1. 把 NPU 作为独立的第三个逻辑 initiator 接入 RAM；
2. 保持 NPU MMIO 为现有 target，不新增一个错误的 M04 “DMA 外设”；
3. 只允许 NPU master 访问 RAM/DDR 地址区，避免访问自身 MMIO 或无关外设；
4. 明确 AXI ID 宽度转换、burst、仲裁、outstanding transaction 和错误响应；
5. 在 Verilator SoC 中增加相同的第三 initiator 和 RAM 路径；
6. 将 `npu_rom_mmio` 扩展为可选 DMA wrapper，并在 DMA 模式设置
   `USE_AXI_DMA=1`；
7. 不得在 DMA 模式把 master response 输入绑为常量。

本仓库采用的具体实现是：不修改由 Vivado 2023.2 生成且用户正在调整的
`axi_crossbar_2x3.xci`，而是在 crossbar 的 RAM target 输出与实际 RAM/MIG
之间加入可综合的 2-to-1 AXI 仲裁器。crossbar 汇总后的 CPU/JTAG RAM 流量是
输入 0，NPU master 是输入 1，仲裁器输出只连接 RAM。仿真 SoC 在 SRAM bridge
前采用同一结构。这样 NPU 仍是独立发起者，同时在拓扑上无法访问 MMIO 外设，
也不引入 Vivado 版本相关的 XCI 重生成改动。

底层 BSP 保留固定物理地址的 parameter/scratch/result 配置和 packed-preload
接口。当前 Chiplab 验收直接使用更严格的 Linux DMA API 端到端用例覆盖
parameter read、scratch read/write 和 result writeback；若后续需要脱离 Linux
定位板级问题，再增加独立固定地址裸机命令，不改变此处的 RTL 拓扑。

### 阶段 3：Linux UAPI v2 与单活动模型

第一版 Linux 多模型实现应忠实复现旧工程的单参数槽语义，以控制复杂度：

- 驱动只保留一个活动模型；
- 新模型加载成功后替换旧 parameter image 和 descriptor；
- 切换过程中设备必须空闲，否则返回 `-EBUSY`；
- 加载、运行或等待失败后可以 reset 并重新加载；
- v1 smoke ABI 尽量保留，v2 通过 `abi_version/capabilities` 探测。

固化后的 v2 操作语义为：

```text
QUERY_CAPS
LOAD_MODEL       原子复制 metadata + descriptors + parameters
LOAD_INPUT
RUN
WAIT_V2
READ_RESULT
```

结构体、限制、兼容性和失败恢复已经在
[`linux/npu/UAPI.md`](../linux/npu/UAPI.md) 固化。模型包应在用户态解析，驱动
只接收已经分段的元数据、descriptor、参数和输入，并独立验证：

- ABI 和硬件版本；
- layer count、descriptor 长度和字段范围；
- parameter/scratch/result 的最大长度和对齐；
- 输入模式和精确输入长度；
- result tensor 形状、dtype 和写回长度；
- 用户指针复制、整数溢出和 DMA 边界。

驱动使用 DMA API：

- 设置硬件实际支持的 DMA mask；
- 用 `dma_alloc_coherent()`，或经过论证的 reserved-memory/CMA；
- 向硬件写入 DMA API 返回的 `dma_addr_t`；
- 不接受用户态提供的任意物理地址；
- 不把整个 MMIO 或 DMA buffer 直接 `mmap` 给普通用户；
- 在硬件未证明 coherent 前，不在设备树中声明 `dma-coherent`。

输入路径至少支持：

```text
FRAME            FaceNet；LeNet 的 28x28 数据按当前 frame 契约填充
PACKED_PRELOAD   TinyVGG-S1/S2b 的 CHW 3x34x34 数据
```

结果接口必须返回通用 tensor 和运行元数据，而不是固定 bbox：

```text
status / error
perf_cycles
result_bytes
result_shape / layout / dtype
result_checksum
result payload
```

bbox、top1/top-k 和类别名称均在用户态计算。

### 截止阶段 3 的实现记录

本轮在阶段 3 结束处停下，已经完成：

- [x] 阶段 1：迁移四个 target 的 config、Python 数值参考后端、参数、
  descriptor、microcode 和 fixture，并用 `models/catalog.json` 记录来源、
  输入输出契约和 SHA-256；
- [x] 阶段 2：在仿真与 nscscc-team FPGA SoC 的 RAM target 前加入同构
  2-to-1 AXI 仲裁器；默认 ROM 模式不变，`NPU_AXI_DMA=1` 显式启用 DMA；
- [x] 阶段 2：增加只读 hardware ABI/capability 寄存器，裸机 BSP 增加对应
  查询接口，保留 parameter/scratch/result/packed-preload API；
- [x] 阶段 3：发布 UAPI v2，驱动实现单打开者、单活动模型、32-bit DMA mask、
  coherent parameter/scratch/result 缓冲区、输入模式、IRQ/轮询、通用结果
  tensor 与 v1 兼容；
- [x] 阶段 3：initramfs smoke 根据 capability 自动选择 ROM v1 或 DMA v2，
  DMA 路径加载 FaceNet 参数并检查 result byte count、checksum 和 bbox；
- [x] Linux 5.14 内核、设备树、驱动和静态 smoke 完整交叉编译；
- [x] OpenLA500 + DMA 的完整 Verilator SoC 展开和 C++ 模型编译；
- [x] OpenLA500 Linux DMA smoke 串口输出 `abi=2`、`hw_abi=2`、
  `caps=0x3f`，结果为 16 B、checksum `0x685184b3`、bbox
  `58,132,81,104,137`、`perf_cycle=734915`，最终输出
  `NPU_LINUX_PASS`。

尚未开始阶段 4 的 `.xnpu` 格式、packer、`libxnpu`、`xnpu-run` 或原生编译器。

### 阶段 4：模型包与用户态运行时

定义稳定的小端部署格式 `*.xnpu`。建议至少包含：

```text
header:
  magic
  package_version
  hardware_abi
  model_id / model_name
  task
  input mode / shape / layout / dtype / bytes
  output shape / layout / dtype / bytes
  layer_count
  parameter / scratch / result requirements
  section offsets and lengths

sections:
  descriptors
  parameter image
  optional labels
  optional preprocess/postprocess metadata

integrity:
  section checksum
  package SHA-256
```

模型名称、标签和预处理元数据只用于用户态；内核只依赖硬件 ABI 和有边界的二进制
section。

近期先扩展现有 Python 编译链或增加轻量 packer 来生成 `.xnpu`。发布仓库提交
经过验证的模型包，因此 Linux 构建、目标 rootfs 和最终演示都不依赖 PyTorch、
NumPy 或 Python 环境。

用户态至少提供：

- `xnpu-inspect`：显示模型 ABI、输入输出契约、大小和 hash；
- `xnpu-run`：加载模型、提交一个输入并打印结果；
- `libxnpu`：供摄像头和图形界面复用；
- 回归工具：按清单连续切换模型并检查 checksum/top1/bbox。

### 阶段 5：OpenLA500 Linux RTL 验证

真实 NPU 数值和 DMA 必须在 Chiplab Verilator/RTL 仿真验证。QEMU 可以配合 mock
设备测试模型包解析和 UAPI 错误路径，但不能代替 NPU RTL 验证。

建议的端到端顺序为：

1. 启动固定 OpenLA500 baseline 和 Linux；
2. 加载 FaceNet 包，运行两个 fixture 并检查 bbox；
3. 加载 LeNet 包，检查 10 类结果和 top1；
4. 加载 TinyVGG-S1 包，检查 result checksum 和 top1；
5. 加载 TinyVGG-S2b 包，检查 result checksum 和 top1；
6. 执行 `FaceNet -> LeNet -> VGG-S1 -> VGG-S2b -> FaceNet` 循环；
7. 每次切换检查旧参数、descriptor、输入和中断状态没有残留；
8. 注入坏 magic、坏 checksum、超长 section、错误 descriptor 和 timeout；
9. reset 后重新加载模型并恢复推理；
10. 运行处理器原有 func、性能和 Linux 启动回归。

当前 RTL Linux 验证设备树只声明 16 MiB RAM。实现 DMA 前应测量 kernel/initramfs
占用和最大 scratch 需求；不足时提高仿真 RAM 到 32/64 MiB。该调整不改变 FPGA
SoC 的 128 MiB DDR 布局。

### 阶段 6：FPGA 与展示程序

RTL 仿真通过后，在 nscscc-team Vivado 工程中重新生成 interconnect，完成综合、
实现和 bitstream：

- 先验证 Linux 下四个预编译模型；
- 记录时钟频率、周期、延迟、资源和 DDR 流量；
- 连续切换和运行，检查 AXI 错误、死锁和中断丢失；
- 保留 UART 命令行 smoke 作为图形界面之外的恢复路径。

推荐的 NPU 主展示链路为：

```text
V4L2/图像文件 -> 用户态裁剪/缩放/量化
              -> libxnpu -> NPU
              -> bbox 或 top-k -> framebuffer/DRM/GUI 叠加
```

不同模型使用不同预处理契约：FaceNet/LBP 接受 `160x120` 灰度/LBP 输入，
TinyVGG 接受带边界填充的 CHW `3x34x34`。预处理不能写成一个固定的
“摄像头数据直接送 NPU”步骤，应由模型包元数据驱动。

视觉小说引擎属于 SoC 图形与 Linux 软件生态展示，可以作为独立可选项目，不纳入
NPU 多模型运行时的核心验收。

## 6. 后续：无 Python 的原生编译器

原生编译器不阻塞近期 Linux 多模型运行时。先以现有 Python 结果作为 bit-true
参考，待硬件和 UAPI 稳定后再实施。

需要区分：

1. **训练与校准**：读取 `.pth`、数据集统计、BN 融合、激活范围校准和精度评估；
2. **NPU 后端编译**：约束检查、量化参数读取、权重重排、blocked packing、
   microcode、descriptor、内存规划和 `.xnpu` 生成。

近期原生化目标只覆盖第二部分。建议定义稳定的 NPU IR：

```text
graph.npuir:
  input/output contract
  ordered layers
  conv/fc/pool/activation attributes
  tensor shapes
  int8/int32 quantization parameters
  per-layer shift

weights.qbin:
  canonical, unpacked quantized weights and biases
```

原生 `xnpu-cc` 的编译阶段为：

1. 读取和版本检查 NPU IR；
2. shape inference 与算子 lowering；
3. 检查 layer 数、kernel、Cin/Cout、shift、输入 buffer 和 FM bank 限制；
4. FC 权重重排；
5. 16x16 blocked 参数打包；
6. parameter/scratch/result 内存规划；
7. 生成 microcode 和 8x32-bit descriptor；
8. 生成确定性的 `.xnpu`；
9. 用整数参考解释器和 golden fixture 验证。

原生编译器的输出必须与 Python 参考实现逐字节对比：

- parameter image；
- descriptor；
- microcode；
- section offset、长度和 hash；
- 四个模型 fixture 的结果。

现有 `.pth` 不是稳定的原生编译器输入。第一次迁移可以在受控 Python 环境中将
现有模型导出为 `NPU IR + weights.qbin` 并提交；以后构建和发布只需要原生
`xnpu-cc`。后续若确有需要，再增加受限 ONNX importer 和原生 PTQ 校准器。

为了保证可复现性，编译器输出不得把时间戳、绝对路径或主机环境写入参与 hash 的
内容；必须固定舍入规则、饱和规则、字节序、对齐和编译器/硬件 ABI。

## 7. 多模型常驻优化

单活动模型稳定后，可以增加 model handle：

```text
CREATE_MODEL -> model_handle
SELECT_MODEL(model_handle)
DESTROY_MODEL(model_handle)
```

每个模型保留独立 parameter DMA buffer，切换时只重新编程 parameter base、
descriptor 和结果配置；scratch/result 可以按最大需求共享。必须先解决：

- 总内存上限和每进程配额；
- handle 生命周期和进程退出清理；
- 模型切换与正在运行任务的互斥；
- DMA buffer 泄漏和碎片；
- 多进程策略。

该优化不是第一版 Linux 多模型功能的前置条件。

## 8. 验收标准

### 8.1 核心功能

- 同一 bitstream 在 Linux 下运行 FaceNet、LeNet 和至少一个 TinyVGG；
- 不重新综合即可加载参数并切换模型；
- frame 和 packed preload 两条输入路径均通过；
- bbox 和通用分类 tensor 与旧工程 golden 结果一致；
- IRQ、轮询、timeout、reset 和重复运行稳定；
- 非法模型包不能造成越界 DMA 或任意物理内存访问。

### 8.2 工程质量

- ROM/MMIO smoke 和 DMA 多模型测试都可一条命令复现；
- 模型包记录 ABI、来源和 hash；
- Linux UAPI 有独立文档和兼容性策略；
- RTL、驱动和用户态均有边界与错误注入测试；
- NPU 分支不引入 `core` 处理器功能回归；
- FPGA 构建只修改 nscscc-team 所需的 SoC/interconnect，不影响其他无关工程。

### 8.3 展示

- 界面可以选择模型并显示加载状态；
- 输入图像、模型名称、bbox 或 top-k、周期/延迟同时可见；
- 摄像头不可用时可用固定图片和 fixture 完成同一条展示链；
- 串口 smoke 可以独立确认 NPU 和 Linux 驱动状态。

## 9. 近期交付物清单

- [x] 从旧工程迁移四个模型 target、参数和 fixture，并记录来源/hash；
- [ ] 固化 `*.xnpu` v1 文件格式；
- [ ] 实现 Python reference packer 和 `xnpu-inspect`；
- [x] 在仿真与 FPGA SoC 中增加 NPU 第三个逻辑 AXI initiator；
- [x] 启用可选 `USE_AXI_DMA=1` 并完成 RAM/DMA 集成回归；
- [x] 实现 Linux UAPI v2 和单活动模型 DMA 管理；
- [ ] 实现 `libxnpu`、`xnpu-run` 和四模型切换回归；
- [ ] 在 OpenLA500 Linux RTL 仿真中完成四模型端到端验证（阶段 3 只验证
  FaceNet DMA 金标准）；
- [ ] 完成 nscscc-team Vivado 综合、bitstream 和 FPGA 回归；
- [ ] 完成摄像头/图片展示程序；
- [ ] 在运行时稳定后实现原生 `xnpu-cc` 后端。
