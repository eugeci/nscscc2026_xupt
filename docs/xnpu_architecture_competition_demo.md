# XNPU 体系结构竞赛演示方案

## 1. 目标

本方案面向体系结构竞赛现场，展示从量化模型中间表示到 FPGA NPU 执行结果的完整
部署链路。演示以手动逐步操作为主，让评委能够观察每一个软硬件边界；编译器内部
转换和最终四模型回归保留自动化，以降低现场操作风险并提供可重复的验收结果。

标准演示链路为：

```text
上位机训练、校准和 INT8 量化
              |
              v
量化中间表示 qmodel v1
              |
              v
LA32 Linux 上运行 xnpu-cc
              |
              v
算子验证、FC SRAM 重排、16-lane 参数打包、描述符生成
              |
              v
XNPU v1 部署包
              |
              v
Linux 驱动通过 DMA、MMIO 和中断控制 FPGA NPU
              |
              v
推理结果、硬件周期计数和 golden 校验
```

## 2. 演示边界

`.qmodel` 不是已经针对 NPU 编译好的二进制文件。它是小端、确定性的量化中间表示，
包含 INT8 权重、INT32 bias、tensor contract、层记录、量化 shift 和模型 metadata。
`.xnpu` 才是 `xnpu-cc` 针对当前 hardware ABI 生成的部署文件。

现场演示从 `.qmodel` 开始，重点展示后端编译、数据布局、设备驱动和 NPU 执行。
模型训练、浮点 checkpoint 导入、激活范围校准和通用 ONNX lowering 在上位机完成，
不应被描述为板上编译器功能。

## 3. 展示原则

1. Linux 正常启动到交互式 shell，演示不随开机自动开始。
2. 演示者手动输入主要命令，工具打印真实输入、输出和执行阶段。
3. `.xnpu` 必须在本次演示新建的 `/tmp` 目录中生成，并从该路径加载执行。
4. 主流程使用确定性 fixture 和 golden 结果，保证竞赛现场可复现。
5. 最后运行自动回归，证明四模型、多输入和模型切换均通过。
6. 每个规划中的新选项在实现前必须标记为“计划新增”，不能当作现有功能展示。

## 4. 现场标准流程

### 4.1 硬件和 Linux 驱动

手动执行：

```sh
dmesg | grep xnpu
ls -l /dev/xnpu
cat /proc/interrupts | grep xnpu
```

应展示 NPU 的设备树匹配结果、`0x1f100000` MMIO 基地址、IRQ 23、hardware ABI 2
和能力位。保留第一次中断计数，推理结束后再次读取，用计数变化证明完成通知来自
硬件中断。

建议新增只读设备信息工具或等效命令：

```sh
xnpu-info /dev/xnpu
```

它只通过正式 UAPI 查询驱动和硬件能力，不通过 `devmem` 修改设备状态。

### 4.2 查看编译器输入

计划新增：

```sh
xnpu-qmodel-info /models/qmodels/facenet_lbp_v1.qmodel
```

输出至少包括：

- qmodel 版本和目标 hardware ABI；
- INT8/INT32 量化契约；
- 输入输出 shape、任务和模型 ID；
- 层数、算子类型、权重和 bias 大小；
- 文件 SHA-256 和完整性检查结果。

这一步用于证明输入是量化 IR，而不是预生成的 `.xnpu`。

### 4.3 在 LA32 Linux 上编译

当前已具备的命令：

```sh
mkdir -p /tmp/xnpu-demo
xnpu-cc /models/qmodels/facenet_lbp_v1.qmodel \
  -o /tmp/xnpu-demo/facenet_lbp_v1.xnpu
```

计划为 `xnpu-cc` 增加详细报告模式：

```sh
xnpu-cc --verbose \
  --emit-report /tmp/xnpu-demo/facenet_lbp_v1.report \
  /models/qmodels/facenet_lbp_v1.qmodel \
  -o /tmp/xnpu-demo/facenet_lbp_v1.xnpu
```

详细模式应展示但不改变编译结果：

1. qmodel 完整性、graph、shape 和资源限制验证；
2. Conv2D、Pooling、FC 和激活到 NPU opcode 的映射；
3. FC 输入按照 SRAM bank 顺序的列重排；
4. Conv/FC 权重的 16x16 通道块打包；
5. bias、shift、parameter offset 和缓冲区需求；
6. 每层 8x32-bit 硬件描述符生成；
7. section CRC32 和 package SHA-256 写入。

编译前应确认输出文件不存在；后续加载必须使用 `/tmp/xnpu-demo` 中的新文件。

### 4.4 查看架构映射结果

当前 `xnpu-inspect` 已能检查包契约、section CRC 和 package SHA-256：

```sh
xnpu-inspect /tmp/xnpu-demo/facenet_lbp_v1.xnpu
```

计划增加 `--layers --layout`：

```sh
xnpu-inspect --layers --layout \
  /tmp/xnpu-demo/facenet_lbp_v1.xnpu
```

扩展输出包括每层 opcode、shape、activation、parameter offset、parameter bytes、
descriptor words、总 MAC 数以及输入、输出和临时缓冲区占用。该输出用于说明模型
如何映射到描述符 RAM、参数存储和 16-lane 计算组织。

### 4.5 执行 NPU 推理

当前已具备的命令：

```sh
xnpu-run \
  --expect-checksum 0x685184b3 \
  --expect-bbox 58,132,81,104,137 \
  /tmp/xnpu-demo/facenet_lbp_v1.xnpu \
  /fixtures/facenet_seed42.bin
```

计划增加 `--trace`，依次显示正式 UAPI 生命周期：

```text
QUERY_CAPS
LOAD_MODEL
LOAD_INPUT
RUN
WAIT_V2
READ_RESULT
```

输出同时包含 descriptor 数量、参数和输入 DMA 字节数、IRQ、结果长度、checksum、
bbox 和 `perf_cycle`。执行后再次读取 `/proc/interrupts`，确认 NPU 中断计数增加。

### 4.6 动态切换模型

现场继续编译并运行 LeNet：

```sh
xnpu-cc /models/qmodels/mnist_lenet_v1.qmodel \
  -o /tmp/xnpu-demo/mnist_lenet_v1.xnpu

xnpu-run --expect-top1 7 \
  /tmp/xnpu-demo/mnist_lenet_v1.xnpu \
  /fixtures/mnist_lenet_7.bin
```

同一 Linux、驱动和 FPGA 配置下从 FaceNet 切换到 LeNet，用于证明 NPU 不是固化的
单模型电路，而是由描述符和参数动态配置的 CNN 加速器。

### 4.7 自动回归收尾

手动讲解完成后运行：

```sh
xnpu-demo verify
```

该命令属于计划新增的自动验收入口。它应在新的临时目录中编译 FaceNet、LeNet、
TinyVGG-S1 和 TinyVGG-S2b，运行五组 fixture，执行连续模型切换和错误输入测试，
并保存 `/tmp/xnpu-demo.log`。

最终成功标志为：

```text
XNPU_DEMO_COMPILE_PASS models=4
XNPU_DEMO_PACKAGE_PASS models=4
XNPU_DEMO_INFER_PASS fixtures=5
XNPU_DEMO_SWITCH_PASS
XNPU_DEMO_ERROR_PASS
XNPU_LINUX_DEMO_PASS
```

## 5. 手动操作与自动化的分工

正式答辩以 4.1 至 4.6 的手动步骤为主。编译器内部的数据转换仍由 `xnpu-cc`
自动完成，但详细模式必须把关键架构决策打印出来。这样既避免现场手工生成描述符
和参数镜像的风险，也不会把体系结构映射隐藏在一条不透明脚本之后。

`xnpu-demo verify` 只在讲解后用于完整性证明和失败重试，不代替主要展示。评委追问
时可单独重复 `qmodel-info`、`xnpu-cc`、`xnpu-inspect` 或 `xnpu-run` 任一阶段。

## 6. 建议的竞赛讲解主线

1. 上位机负责训练和量化，LA32 负责部署阶段的原生后端编译。
2. 编译器根据自研 NPU 的 16-lane 数据通路、SRAM bank 顺序和描述符格式重排数据。
3. CPU 通过 Linux UAPI 提交模型和输入，驱动负责校验、DMA 缓冲区和设备状态机。
4. NPU 从 DDR/片上存储读取描述符和参数，完成计算后通过 IRQ 通知 CPU。
5. `perf_cycle`、golden checksum 和输出内容分别证明性能计数、执行完整性和功能正确性。
6. 不重新生成比特流即可切换网络，证明体系结构的可编程性。

## 7. 实施清单

- 将 `xnpu-cc` 和四个 qmodel 放入可交互 LA32 Linux 演示镜像；
- 将 `xnpu-inspect`、`xnpu-run`、fixture 和 regression manifest 放入镜像；
- 实现 `xnpu-qmodel-info` 或等效的 qmodel 展开功能；
- 为 `xnpu-cc` 增加 `--verbose` 和 `--emit-report`；
- 为 `xnpu-inspect` 增加 `--layers --layout`；
- 为 `xnpu-run` 增加 `--trace`；
- 实现只读 `xnpu-info`；
- 实现 `xnpu-demo verify` 自动回归入口；
- 编写现场命令清单、预期输出和异常恢复步骤；
- 在真实 FPGA SoC 上完成冷启动后的完整验收。

所有新增展示选项必须保持默认输出和 `.xnpu` 字节结果不变。实现前备份相关文件，
测试产物写入临时目录，避免覆盖已提交基准和队友工作。

## 8. 当前板级基线

2026-08-16 已在真实 LA32 Linux/FPGA SoC 上完成第一条端到端基线：

```text
facenet_lbp_v1.qmodel
  -> LA32 xnpu-cc
  -> facenet_lbp_v1.xnpu (85,488 bytes, 10 layers)
  -> 与参考包逐字节一致
  -> /dev/xnpu 推理
  -> checksum 0x685184b3
  -> bbox 58,132,81,104,137
  -> XNPU_STAGE4_PASS
```

该结果证明板上编译和单模型执行链路已经成立。实施清单中的可视化信息、四模型
回归和交互式镜像用于把现有技术基线升级为适合体系结构竞赛现场的完整演示。
