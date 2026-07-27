# NPU 协处理器移植与 Linux 驱动路线

## 1. 当前落地状态

本次工作在根仓库和 `chiplab` 子模块的同名分支
`feature/npu-linux-port` 上进行，`core` 子模块未修改。

已经完成的第一阶段是可独立验证的 ROM/MMIO 模式：

- 从旧工程导入 NPU 计算核、预处理、ROM DMA、AXI DMA 和 AXI slave wrapper；
- 在仿真 SoC 和 nscscc-team FPGA SoC 中新增 64 KiB AXI slave 地址窗；
- 将 NPU 中断接到处理器 `intrpt[0]`；
- 将模型参数、微码和描述符文件加入 Verilator/Vivado 构建；
- 移植裸机 BSP、后处理代码和 `npu_smoke` 示例；
- 保留 AXI DMA 源码，但暂不把 NPU master 接入 DDR。

当前地址约定如下：

| 项目 | 数值 |
| --- | --- |
| 物理 MMIO | `0x1f100000`--`0x1f10ffff` |
| 裸机非缓存地址 | `0xbf100000` |
| CPU 外部中断线 | `intrpt[0]` |
| 帧输入区 | slave aperture `0x1000` 起 |
| 描述符区 | slave aperture `0x6000`--`0x63ff` |

ROM/MMIO 模式先跑通 Linux 的理由是：它不需要新增 DDR master、连续物理内存
和缓存一致性策略，能先验证地址译码、中断、模型计算和用户接口。吞吐优化放到
AXI DMA 阶段，不改变软件 ABI 的上层语义。

本次已完成的构建检查：

- NPU SoC wrapper 通过 Verilator lint；
- 完整 `simu_top` 通过 Verilator 展开和 C++ model 编译；
- 默认 Chiplab C++ testbench 链接成功；
- BSP 通过宿主机 `-Wall -Wextra -Werror` 语法检查；
- `npu_smoke` 通过 LoongArch32R 交叉编译和链接；
- AXI crossbar XCI 通过 JSON 语法检查，所有修改通过 `git diff --check`。

当前机器没有 Vivado，因此还没有完成 FPGA IP 重新生成、综合和 bitstream。
端到端 Verilator smoke 也尚未形成通过结论：现有处理器 RTL 与 NEMU 在启动阶段
第 3 条提交指令 `CACOP` 处出现异常状态不一致，程序还没有执行到 NPU MMIO。
应先用处理器分支的基准裸机用例确认该仿真前置问题，再进行 NPU 功能联调。

## 2. 验证顺序

### 阶段 A：当前 RTL/BSP 基线

1. Verilator lint NPU wrapper；
2. Verilator 编译完整 `simu_top` 并链接 testbench；
3. 交叉编译 `software/examples/npu_smoke`；
4. 仿真或 FPGA 上检查复位、描述符装载、19200 字节帧输入、完成状态、bbox；
5. FPGA 生成 bitstream 后，用裸机程序先完成板级回归。

### 阶段 B：Linux 最小驱动

内核树加入 platform driver，例如 `drivers/misc/xupt_npu.c`。驱动负责：

- 从设备树取得 MMIO resource 和 IRQ；
- `devm_platform_ioremap_resource()` 映射物理地址；
- 用 `readl()/writel()` 访问寄存器；
- 用 mutex 保证同一时刻只有一个推理任务；
- ISR 清中断并唤醒 wait queue，保留轮询作为早期调试后备；
- 用 misc/character device 暴露受控的 `ioctl`，不允许用户态直接 mmap 整个寄存器窗；
- 对描述符数量、帧大小、超时和状态机进行边界检查。

建议第一版 UAPI 只提供：

```text
GET_INFO -> RESET -> LOAD_DESCRIPTORS -> LOAD_FRAME -> RUN -> WAIT -> GET_BBOX
```

设备树节点的结构可以先按下面设计；`interrupts` 的具体编码需要以本项目最终
irqchip binding 为准，不能直接把裸机的位号当作 Linux IRQ 号：

```dts
npu@1f100000 {
    compatible = "xupt,npu-v1";
    reg = <0x0 0x1f100000 0x0 0x00010000>;
    interrupts = <...>;
    status = "okay";
};
```

当前仓库只含 Linux 启动镜像/说明，没有可修改的 Linux kernel source tree，
因此本分支先固定硬件 ABI 和 BSP。取得 Chiplab 所用内核源码及 `.config` 后，
再把驱动、Kconfig、Makefile、DTS 和用户态 demo 一起加入并做启动验证。

### 阶段 C：Linux 展示程序

用户态程序通过 `/dev/xupt-npu`：

1. 读取摄像头、文件或测试图；
2. 缩放/转换为 NPU 需要的 `160x120` 输入；
3. 提交推理并等待中断；
4. 读取 `{confidence, cx, cy, w, h}`；
5. 在 framebuffer/DRM 或串口界面叠加检测框和周期统计。

将图像预处理和显示留在用户态，内核驱动只承担硬件访问与资源隔离。

### 阶段 D：AXI DMA 性能版

ROM/MMIO 版本稳定后再启用 `USE_AXI_DMA=1`：

- 在 FPGA 与仿真 SoC 中为 NPU 增加到 DDR 的 AXI master；
- 明确 AXI ID、burst、仲裁和地址范围；
- 用 `dma_alloc_coherent()` 或 reserved-memory/CMA 分配参数、scratch、result；
- 所有传给硬件的地址使用 DMA API 返回的 `dma_addr_t`；
- 禁止把用户虚拟地址或任意物理地址直接写给硬件；
- 加入越界、总线错误、超时、并发和缓存一致性回归。

## 3. 阶段验收标准

- ROM/MMIO：裸机与 Linux 对同一测试帧给出一致 bbox，连续运行无状态残留；
- 中断：完成事件无丢失、无中断风暴，超时后可复位恢复；
- Linux：普通用户不能越界访问寄存器或任意 DMA 地址；
- DMA：结果与 ROM/MMIO bit-true，且吞吐/周期数据达到展示目标；
- 回归：处理器原有 func、性能测试和 Linux 启动不受 NPU 分支影响。
