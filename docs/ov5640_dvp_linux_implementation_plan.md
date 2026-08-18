# OV5640 DVP 摄像头 Linux 接入详细实现方案

> 最后更新：2026-08-04
>
> 适用分支：`feature/npu-linux-port`
>
> 目标平台：XC7A200T Chiplab SoC、LoongArch32R Linux 5.14 基线

## 1. 结论

OV5640 不能只靠增加设备树节点接入当前 SoC。Linux 已有的 `ov5640` 驱动只负责
通过 SCCB/I²C 配置图像传感器，并把它注册为 V4L2 sub-device；它不会接收 DVP
像素，也不会自行创建 `/dev/video0`。当前工程还缺少以下硬件和软件组件：

1. 给 OV5640 提供 24 MHz XCLK、供电、复位和电平适配；
2. 一个 Linux 可管理的 SCCB/I²C 主控制器；
3. 一个 DVP 接收器，采集 `PCLK + VSYNC + HREF + D[7:0]`；
4. 跨越 DVP PCLK 和 SoC `sys_clk` 的异步 FIFO；
5. 一个把视频帧直接写入 DDR 的 AXI DMA master；
6. 一个可靠的帧完成/错误中断；
7. 一个基于 V4L2、media-controller 和 videobuf2 的 capture bridge 驱动；
8. 描述传感器与 DVP 接收器连接关系的设备树 media graph；
9. 足够的 Linux 内存和连续 DMA 缓冲区。

推荐第一版只支持：

- 8-bit DVP；
- `640x480 @ 30 fps`；
- `V4L2_PIX_FMT_YUYV` 和 `V4L2_PIX_FMT_UYVY`；
- 3～4 个 MMAP 连续 DMA buffer；
- 每个视频 buffer 由摄像头 DMA 直接写入，不经过 CPU 中转；
- OV5640 使用内核已有 `drivers/media/i2c/ov5640.c`；
- SCCB 使用 OpenCores I²C RTL 和内核已有 `i2c-ocores` 驱动；
- 只为 DVP capture 编写项目专用 V4L2 bridge 驱动。

第一版不做 JPEG、1080p、硬件 ISP、硬件缩放、NPU 零拷贝和显示输出。这些功能应在
VGA 连续采集稳定以后分阶段增加。

## 2. 当前仓库基础与缺口

### 2.1 已有基础

当前分支已经具备：

- XC7A200T FPGA 工程，器件为 `xc7a200tfbg676-2`；
- 100 MHz 板级输入时钟；
- Clocking Wizard 当前产生约 33 MHz CPU、100 MHz system 和 200 MHz DDR
  reference clock；
- 32-bit AXI4 system/DDR 数据通路；
- CPU/JTAG 到 RAM、APB、CONFREG、NPU 的 AXI crossbar；
- NPU 独立 AXI DMA master 和 RAM 侧二选一仲裁器；
- `0x1fe00000` 开始的 64 KiB AXI-to-APB 窗口；
- Linux 5.14 LoongArch32R 固定基线、设备树、内核 overlay、initramfs 和交叉编译
  流程；
- 经过验证的 Linux DMA API 使用经验。

### 2.2 当前缺口

仓库中没有：

- 摄像头或 DVP 接收 RTL；
- 通用视频 DMA；
- I²C/SCCB 控制器；
- GPIO、regulator 或可由 Linux 控制的摄像头时钟控制器；
- V4L2 capture host 驱动；
- 摄像头相关设备树节点；
- camera media graph；
- 摄像头扩展接口的板级引脚约束。

`chiplab/IP/DMA/dma.v`、以太网 MAC DMA 和 NPU DMA 都有各自特定的请求、描述符
或数据接口，不是可直接接收 DVP 字节流的通用视频 DMA。尤其不能把 NPU 的 AXI
master 直接复用成摄像头 DMA。

### 2.3 Linux 基线影响

`linux/npu/prepare.sh` 固定使用：

```text
la32r-Linux branch: la32r-new-world
commit: 4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e
Linux generation: 5.14
```

`linux/npu/build.sh` 为周期精确 RTL smoke 主动裁掉大量非必要功能。摄像头构建必须
重新启用 Media、V4L2、I²C、videobuf2、CMA 和 OV5640。建议保留现有精简 NPU
smoke 配置，再增加独立的 FPGA system/camera 构建配置，不要让摄像头功能显著拖慢
已有 RTL 回归。

## 3. 目标系统架构

```text
                            control plane
Linux ov5640 subdev
        |
        | I²C framework
        v
i2c-ocores driver -> APB I²C master -> SCCB SIOC/SIOD -> OV5640
                                                         |
                                       XCLK 24 MHz ------+
                                                         |
                            pixel plane                  v
                     D[7:0] + HREF + VSYNC + PCLK
                                                         |
                                                         v
                 +-----------------------------------------------+
                 | FPGA DVP capture                              |
                 |                                               |
                 | IOB input registers                           |
                 |   -> PCLK-domain frame/line detector          |
                 |   -> byte + sideband asynchronous FIFO        |
                 |   -> sys_clk byte packer                      |
                 |   -> descriptor queue                         |
                 |   -> AXI4 write DMA                           |
                 +-----------------------------------------------+
                                      |
                                      | AXI4 write master
                                      v
                      CPU/NPU/camera RAM-side arbiter
                                      |
                                      v
                                     DDR
                                      ^
                                      |
                         videobuf2 DMA buffers
                                      |
                                      v
                            /dev/video0 (V4L2)
                                      |
                       userspace capture/preprocess
                                      |
                                      v
                              /dev/xnpu
```

控制平面与数据平面必须分开：SCCB 只配置寄存器，不能承载像素；DVP 数据不能由 CPU
逐字节读取，否则 VGA 30 fps 就会造成不可接受的中断和复制开销。

## 4. 板级与电气设计

### 4.1 必需信号

8-bit DVP 模式至少需要：

| 信号 | 方向（相对 FPGA） | 用途 |
| --- | --- | --- |
| `CAM_D[7:0]` | 输入 | 8-bit 像素字节流 |
| `CAM_PCLK` | 输入 | OV5640 输出像素时钟 |
| `CAM_HREF` | 输入 | 行有效信号 |
| `CAM_VSYNC` | 输入 | 帧同步信号 |
| `CAM_XCLK` | 输出 | OV5640 参考时钟，建议 24 MHz |
| `CAM_SIOC` | 开漏双向/输出 | SCCB 时钟 |
| `CAM_SIOD` | 开漏双向 | SCCB 数据 |
| `CAM_RESET_N` | 输出，可选 | 低有效复位 |
| `CAM_PWDN` | 输出，可选 | 高有效掉电 |

总计需要 16 个逻辑信号。还必须提供 GND 和模块要求的电源。

### 4.2 先确认模块，不要直接接裸传感器

必须先确认使用的是：

- 裸 OV5640 sensor/柔性排线转接板；还是
- 带稳压、晶振或电平转换的 OV5640 DVP 模块。

裸 OV5640 的 DOVDD、AVDD、DVDD 是不同电压域，DVP/SCCB I/O 也可能工作在 1.8 V。
当前约束文件里的普通 I/O 是 `LVCMOS33`，不能据此假定摄像头信号可直接连接。若
模块没有电平转换，需要：

- 1.5 V、1.8 V、2.8 V 等符合模块原理图的电源；
- 1.8 V 与 FPGA I/O bank VCCO 相匹配，或增加高速电平转换；
- SCCB 的开漏电平转换和上拉；
- 确认 DVP 数据电平转换器能覆盖目标 PCLK 频率。

直接把 1.8 V 裸 sensor 接到 3.3 V 上拉或 3.3 V FPGA 输出上可能损坏器件。

### 4.3 引脚要求

- `CAM_PCLK` 优先放到 clock-capable pin；
- `CAM_D[7:0]`、`HREF`、`VSYNC` 尽量位于同一 I/O bank；
- 数据线长度匹配，避免跨连接器和飞线造成过大偏斜；
- SCCB 必须有外部上拉，RTL 只能驱动低或高阻，不能主动驱动高；
- 所有管脚必须根据开发板原理图和扩展口定义加入
  `chiplab/fpga/nscscc-team/constraints/soc_lite.xdc`；
- 在原理图未确认前，方案中不指定具体 FPGA PACKAGE_PIN。

### 4.4 XCLK

Linux 5.14 的 OV5640 驱动允许 6～54 MHz XCLK，常用值为 24 MHz。当前 Clocking
Wizard 尚未输出 24 MHz，建议：

1. 启用一个未使用的 Clocking Wizard 输出并配置为 24 MHz；
2. 在 `clk_pll` wrapper 和 `soc_top.v` 增加 `cam_xclk`；
3. 使用 `ODDR` 做 50% duty-cycle clock forwarding，再经 `OBUF` 输出；
4. 第一版让 XCLK 常开，并在设备树中用 `fixed-clock` 描述；
5. 后续如需省电，再实现真正的 clock provider 和 glitch-free clock gating。

不要用普通计数器从 100 MHz 产生抖动较大的近似 24 MHz。

### 4.5 DVP 时序约束

DVP 信号属于 OV5640 产生的 `CAM_PCLK` 时钟域：

- 在 `CAM_PCLK` 域的 IOB register 采样 D、HREF 和 VSYNC；
- 根据 OV5640/模块数据手册设置 `create_clock` 和 `set_input_delay`；
- 将 PCLK 按计划支持的最高像素时钟约束，不能只按 VGA 典型值约束；
- PCLK 域与 `sys_clk`、CPU clock、DDR reference clock 声明为异步；
- 跨域必须使用经过 CDC 审查的异步 FIFO，不能把 8-bit 数据逐位双触发同步到
  `sys_clk`；
- HREF/VSYNC 和像素数据必须在同一 PCLK 域采样后作为 FIFO sideband 一起跨域。

最终采样边沿、HREF/VSYNC 有效电平应由设备树 endpoint 描述，并由驱动写入 DVP
control register。第一次上板必须用逻辑分析仪确认，不能仅依赖模块示例代码。

## 5. SoC 地址规划

为兼容机械臂 UART1 方案，把现有 64 KiB APB 窗口明确划分为四个 16 KiB slot：

| APB slot | 物理地址范围 | 设备 |
| --- | --- | --- |
| 0 | `0x1fe00000`～`0x1fe03fff` | UART0，现有寄存器在 `0x1fe001e0` |
| 1 | `0x1fe04000`～`0x1fe07fff` | 机械臂 UART1，建议寄存器在 `0x1fe041e0` |
| 2 | `0x1fe08000`～`0x1fe0bfff` | SCCB/I²C0，寄存器从 `0x1fe08000` 开始 |
| 3 | `0x1fe0c000`～`0x1fe0ffff` | DVP capture，寄存器从 `0x1fe0c000` 开始 |

设备树建议使用：

```text
I²C0:       reg = <0x1fe08000 0x20>
DVP capture reg = <0x1fe0c000 0x1000>
```

需要把 `apb_mux2.v` 重构为明确的四路 decoder。当前代码把所有非 UART0 地址都别名
到 `apb1`，正式扩展前必须消除这种 catch-all 行为；未映射地址应正常结束总线访问并
返回错误/零值，不能永久等待，也不能误写别的外设。

## 6. SCCB/I²C 实现

### 6.1 选择 OpenCores I²C

推荐加入 OpenCores I²C master RTL，并保持与 Linux `i2c-ocores` 寄存器 ABI 一致。
固定 Linux 5.14 基线已包含该驱动，支持：

- `compatible = "opencores,i2c-ocores"`；
- 8/16/32-bit register I/O；
- 可配置寄存器步长；
- 中断模式；
- 无中断 polling 模式。

第一版建议使用 polling，不占用额外外部中断。SCCB 只在 probe、格式切换和 controls
更新时访问，100 kHz polling 足够。

### 6.2 APB wrapper

OpenCores 原始总线接口外增加薄 APB wrapper：

- system clock：100 MHz `sys_clk`；
- 8-bit 寄存器；
- byte offset 连续排列；
- `reg-io-width = <1>`；
- `reg-shift = <0>`；
- SIOC/SIOD 输出均采用 `drive_low` 加 IOBUF 高阻实现开漏；
- 支持 START、repeated START、ACK/NACK 和 STOP；
- 总线被拉低时必须有超时，不能让 APB/AXI 永久挂起。

如果 APB bridge 对 byte access 的实际行为与 `ioread8/iowrite8` 不一致，应改成 32-bit
寄存器、`reg-io-width = <4>`、`reg-shift = <2>`，但 RTL 和设备树必须完全一致。

### 6.3 地址注意事项

OV5640 的 Linux 设备树地址是 7-bit 地址 `0x3c`。很多模块资料写的 `0x78/0x79`
是包含读写位的 8-bit SCCB 地址，不能在设备树中写成 `reg = <0x78>`。

## 7. DVP capture RTL

### 7.1 模块划分

建议新增：

```text
chiplab/IP/CAMERA/
  rtl/
    xupt_dvp_top.v
    xupt_dvp_rx.v
    xupt_dvp_async_fifo.v
    xupt_dvp_packer.v
    xupt_dvp_desc_fifo.v
    xupt_dvp_axi_writer.v
    xupt_dvp_regs_apb.v
    xupt_dvp_irq.v
  sim/
    ov5640_dvp_source.sv
    tb_xupt_dvp.sv
  filelists/
    xupt_camera_soc.f
```

各模块职责：

- `xupt_dvp_rx`：PCLK 域采样、帧/行边界检测、像素计数；
- `xupt_dvp_async_fifo`：PCLK 到 sys_clk 的 CDC；
- `xupt_dvp_packer`：把连续字节打包成 32-bit AXI word；
- `xupt_dvp_desc_fifo`：保存 Linux 提交的空闲 buffer 描述符；
- `xupt_dvp_axi_writer`：产生 AXI4 INCR write burst；
- `xupt_dvp_regs_apb`：配置、状态、描述符和完成 FIFO 寄存器；
- `xupt_dvp_irq`：帧完成、丢帧、FIFO overflow、AXI error 中断。

异步 FIFO 可在 FPGA 综合时封装 `xpm_fifo_async`，仿真时提供等价模型；也可使用经过
CDC 验证的 Gray-code pointer FIFO。不要临时编写未经验证的多 bit CDC。

### 7.2 帧接收规则

第一版按 8-bit byte stream 工作：

1. VSYNC 检测新帧边界；
2. HREF 有效期间每个选定 PCLK 边沿采样一个字节；
3. YUV422/RGB565 每像素两个字节；
4. 统计每行字节数和每帧行数；
5. 帧开始时从 descriptor FIFO 取一个 buffer；
6. descriptor FIFO 为空时丢弃整帧，不覆盖已完成或用户持有的 buffer；
7. 帧尺寸、FIFO overflow 或 AXI response 异常时把当前 buffer 标记为 error；
8. 下一次合法 VSYNC 才重新同步，不能在损坏帧中间继续写一个新 buffer。

### 7.3 格式

第一版硬件只做 byte-preserving capture，不做 YUV/RGB 转换：

| Media bus code | V4L2 pixel format | 每像素字节 |
| --- | --- | ---: |
| `MEDIA_BUS_FMT_YUYV8_2X8` | `V4L2_PIX_FMT_YUYV` | 2 |
| `MEDIA_BUS_FMT_UYVY8_2X8` | `V4L2_PIX_FMT_UYVY` | 2 |

第二阶段可加入：

- `MEDIA_BUS_FMT_RGB565_2X8_LE/BE`；
- Bayer 8-bit raw；
- JPEG byte stream。

JPEG 是可变长度数据，要求硬件以 VSYNC/实际字节数结束 buffer，不能用
`width * height * bytes_per_pixel` 判断完成，因此不应与第一版一起实现。

### 7.4 AXI write DMA

摄像头 DMA 只需要 AXI write channels：AW、W、B。实现约束：

- 地址宽度 32 bit；
- 数据宽度 32 bit；
- INCR burst；
- 建议每个 burst 16 beats，即 64 bytes；
- burst 不得跨越 4 KiB 边界；
- 最后一组不足 4 bytes 时使用正确的 WSTRB；
- 支持 stride，行尾跳到 `base + line * stride`；
- 等待并检查每个 BRESP；
- 一个或有限个 outstanding burst，第一版优先保证正确性；
- soft reset/stream stop 时安全排空或中止当前事务；
- 硬件只接受 4-byte 或 64-byte 对齐、范围合法的 DMA API 地址；
- 不允许用户态直接写物理地址寄存器。

### 7.5 吞吐量

无压缩 YUV422/RGB565 的最低持续带宽为：

| 模式 | 单帧大小 | 30 fps 数据量 |
| --- | ---: | ---: |
| 320x240 | 153,600 B | 4.61 MB/s |
| 640x480 | 614,400 B | 18.43 MB/s |
| 1280x720 | 1,843,200 B | 55.30 MB/s |
| 1920x1080 | 4,147,200 B | 124.42 MB/s |

100 MHz、32-bit AXI 理论带宽为 400 MB/s，但协议开销、DDR 刷新、CPU 和 NPU 竞争
会降低实际带宽。VGA 30 fps 有合理裕量；720p/1080p 必须先完成 DDR 压力测试和仲裁
最坏延迟分析。

异步 FIFO 至少应能吸收正常 DDR burst 仲裁停顿，建议 MVP 使用 4～8 KiB，并记录
高水位和 overflow count。DVP 没有 back-pressure，DDR 停顿超过 FIFO 能力时只能丢弃
当前帧并报告错误。

## 8. DMA buffer descriptor ABI

建议 DVP hardware 使用 4～8 深度的提交 FIFO和完成 FIFO，而不是只有两个固定地址。
Linux 每次 `VIDIOC_QBUF` 后可以立即把该 buffer 交给硬件。

### 8.1 APB register map

基地址：`0x1fe0c000`。

| 偏移 | 名称 | 访问 | 含义 |
| ---: | --- | --- | --- |
| `0x000` | `ID` | RO | 魔数，例如 `0x58445650`（`XDVP`） |
| `0x004` | `VERSION` | RO | major/minor/patch |
| `0x008` | `CAPS` | RO | format、最大尺寸、descriptor 深度能力 |
| `0x00c` | `CONTROL` | RW | enable、soft-reset、abort、polarity |
| `0x010` | `STATUS` | RO | running、in-frame、FIFO/AXI/error 状态 |
| `0x014` | `IRQ_STATUS` | W1C | frame-done、drop、overflow、AXI-error |
| `0x018` | `IRQ_ENABLE` | RW | 中断使能 |
| `0x01c` | `FORMAT` | RW | YUYV/UYVY/RGB565 等 |
| `0x020` | `WIDTH` | RW | 有效像素数 |
| `0x024` | `HEIGHT` | RW | 有效行数 |
| `0x028` | `STRIDE` | RW | 每行目标字节跨度 |
| `0x02c` | `FRAME_BYTES` | RW | buffer 最小长度/期望 payload |
| `0x030` | `FRAME_SEQUENCE` | RO | 成功/错误完成帧序号 |
| `0x034` | `DROP_COUNT` | RO | 无 buffer 等原因丢帧数 |
| `0x038` | `OVERFLOW_COUNT` | RO | 异步 FIFO overflow 数 |
| `0x03c` | `AXI_ERROR_COUNT` | RO | 非 OKAY BRESP 数 |
| `0x040` | `SUBMIT_ADDR` | WO | 待提交 DMA base |
| `0x044` | `SUBMIT_STRIDE` | WO | 待提交 stride |
| `0x048` | `SUBMIT_SIZE` | WO | buffer 可写总长度 |
| `0x04c` | `SUBMIT_TAG` | WO | buffer index/cookie |
| `0x050` | `SUBMIT_PUSH` | WO | 写 1 原子提交上述 descriptor |
| `0x054` | `SUBMIT_LEVEL` | RO | 空闲 descriptor FIFO 占用 |
| `0x058` | `DONE_TAG` | RO | 完成 buffer tag |
| `0x05c` | `DONE_BYTES` | RO | 实际写入字节数 |
| `0x060` | `DONE_STATUS` | RO | done/error 原因 |
| `0x064` | `DONE_POP` | WO | 写 1 弹出一个完成项 |
| `0x068` | `DONE_LEVEL` | RO | 完成 FIFO 占用 |
| `0x06c` | `OBSERVED_WIDTH` | RO | 最近帧实测每行像素/字节 |
| `0x070` | `OBSERVED_HEIGHT` | RO | 最近帧实测行数 |
| `0x074` | `FIFO_HIGH_WATER` | RO | 调优用最大 FIFO 占用 |

### 8.2 寄存器语义要求

- `ID/VERSION/CAPS` 固化硬件 ABI；
- 未知 control bit 写入必须忽略；
- error/status 用 W1C，禁止 read-clear；
- `SUBMIT_PUSH` 必须在 FIFO 满时拒绝并置 error，不能覆盖旧 descriptor；
- `DONE_POP` 前的 `DONE_*` 必须保持稳定；
- soft reset 不得修改 ID/VERSION/CAPS；
- streaming 期间禁止修改 width/height/stride/format，或显式返回 busy；
- 所有跨时钟域状态使用 snapshot/handshake，不能把多 bit counter 直接同步。

## 9. RAM 侧 AXI 仲裁

### 9.1 现状

当前 `soc_top.v` 用 `npu_axi_ram_arbiter` 在以下两路之间仲裁：

1. 原 SoC RAM path；
2. NPU AXI DMA master。

该仲裁器读写通道分别仲裁，一次只允许一个 read burst 和一个 write transaction
outstanding，并在两路之间 round-robin。

### 9.2 推荐改造

摄像头是第三个 RAM initiator。为了保留已经验证的 NPU 路径，第一版推荐级联两个
可复用的 2-to-1 arbiter：

```text
SoC RAM path ----+
                 +-- arbiter A --+
NPU DMA ---------+               |
                                 +-- arbiter B --> MIG/RTL RAM
Camera DMA ----------------------+
```

具体做法：

1. 把 `npu_axi_ram_arbiter` 重命名/泛化为 `axi_ram_arbiter_2x1`，保持协议行为不变；
2. arbiter A 保留现有 SoC/NPU 连接；
3. arbiter B 在 A 输出与 camera DMA 之间仲裁；
4. camera read channel 的 ARVALID 永久为 0；
5. camera burst 限制为 16 beats，保证 CPU/NPU 的最大等待可界定；
6. camera 与 A 在竞争时按 burst round-robin，禁止 camera 永久高优先级饿死 CPU；
7. 通过连续 NPU DMA + camera VGA/720p 仿真测量是否需要 QoS 或更深 FIFO。

若以后要求 720p/1080p 和多 outstanding，可再替换为 3-port AXI interconnect；第一版
不应在 DVP 尚未稳定前同时引入复杂 SmartConnect 配置和协议变化。

### 9.3 DMA 与 cache 一致性

摄像头是 `DMA_FROM_DEVICE`：

- 驱动设置 32-bit DMA mask；
- buffer 必须通过 videobuf2/DMA API 分配和映射；
- 硬件寄存器只能写入 DMA API 返回的 `dma_addr_t`；
- 不在设备树中添加未经证明的 `dma-coherent`；
- buffer 从硬件返回用户态前必须完成正确的 cache invalidate/sync；
- 不把 DVP MMIO 或任意物理 RAM 直接 mmap 给普通用户；
- 必须在真实 LoongArch32R 核上验证 buffer CPU 读取不会看到旧 cache line。

已有 NPU 工作发现此平台的 DMA/cache 行为不能凭接口名称假定正确。摄像头验收必须用
逐帧 CRC、颜色条和变化图案检测 stale cache、零洞和局部旧数据。

## 10. 中断方案

### 10.1 DVP capture 必须有可靠中断

SCCB 可以 polling，但 V4L2 流式采集不能以用户态轮询寄存器作为正式方案。每帧完成、
DMA error、FIFO overflow 都应触发 level-high IRQ，驱动在 handler 中：

1. 读取并屏蔽 `IRQ_STATUS & IRQ_ENABLE`；
2. 清 W1C 状态；
3. 排空 DONE FIFO；
4. 对每个 buffer 调用 `vb2_buffer_done()`；
5. 错误帧返回 `VB2_BUF_STATE_ERROR`；
6. IRQ source 完全清除后返回。

### 10.2 当前团队 CPU 的阻塞点

OpenLA500/Chiplab 把 `intrpt[n]` 映射到 `ESTAT.IS[n+2]`，但当前自研核 wrapper 在
`core/02_Design/platform/nscscc/rtl/mycpu_top.v` 中使用 `|intrpt`，把所有外设中断
汇总成单一 timer pending。这样会丢失中断号，也不能支撑 UART、NPU 和 camera 的独立
Linux IRQ。

最终 FPGA Linux 必须先完成以下两种方案之一：

1. **推荐**：在 CPU CSR/privilege path 中实现逐位外部中断，把 `intrpt[7:0]` 映射到
   独立 `ESTAT.IS` 位，并验证 mask、pending、claim、level re-entry 和 ERTN；
2. **备选**：新增一个带 mask/status 的 SoC interrupt concentrator，以一个 CPU parent
   IRQ 驱动 Linux chained irqchip，再把 NPU、UART、DVP 分发为 child IRQ。

不能把多个设备简单 OR 到同一 IRQ 后仍在设备树中声明成多个独立 HWIRQ。

在 OpenLA500/完整中断映射下，可暂定：

| `intrpt` bit | Linux CPU HWIRQ | 设备 |
| ---: | ---: | --- |
| 0 | 2 | NPU |
| 1 | 3 | UART0 |
| 2 | 4 | DVP capture |
| 3 | 5 | UART1，若后续启用中断 |

实际映射必须通过 RTL 中断 test 和 Linux `/proc/interrupts` 验证后固化。

## 11. Linux 驱动架构

### 11.1 三个驱动的边界

```text
drivers/i2c/busses/i2c-ocores.c
  负责：SCCB/I²C controller

drivers/media/i2c/ov5640.c
  负责：sensor 探测、寄存器配置、格式、帧率、曝光、白平衡、stream on/off

drivers/media/platform/xupt/xupt_dvp.c
  负责：DVP receiver、DMA、VB2 queue、IRQ、/dev/video0、media link
```

不要在 `xupt_dvp.c` 中复制 OV5640 寄存器表，也不要让用户态脚本绕过 V4L2 直接批量
写 sensor 寄存器。传感器与 host capture 是两个独立 media entity。

### 11.2 `xupt_dvp` 数据结构

驱动至少包含：

- `struct platform_device`、MMIO base、IRQ；
- `struct v4l2_device`；
- `struct media_device`；
- `struct video_device`；
- capture sink `struct media_pad`；
- Linux 5.14 对应版本的 `struct v4l2_async_notifier`；
- 已绑定的 OV5640 `struct v4l2_subdev *`；
- `struct vb2_queue`；
- queued/active buffer list 和 spinlock；
- format、width、height、bytesperline、sizeimage；
- streaming mutex；
- sequence、drop、overflow、AXI error 统计。

### 11.3 V4L2 file/ioctl ops

文件操作：

- `v4l2_fh_open`；
- `vb2_fop_release`；
- `vb2_fop_read`，可选；
- `vb2_fop_poll`；
- `vb2_fop_mmap`；
- `video_ioctl2`。

ioctl 至少实现：

- `VIDIOC_QUERYCAP`；
- `VIDIOC_ENUM_FMT`；
- `VIDIOC_G_FMT`；
- `VIDIOC_TRY_FMT`；
- `VIDIOC_S_FMT`；
- `VIDIOC_ENUM_FRAMESIZES`；
- `VIDIOC_ENUM_FRAMEINTERVALS`；
- videobuf2 标准 `REQBUFS/CREATE_BUFS/QUERYBUF/QBUF/DQBUF/STREAMON/STREAMOFF`；
- sensor 支持的 controls 转发或合并。

第一版 `S_FMT` 只接受硬件验证过的 VGA YUYV/UYVY。驱动先向 sensor subdev 调用
pad `set_fmt`，读取 sensor 最终接受的 media bus code/尺寸，再配置 DVP RTL。不能让
video node 和 sensor subdev 各自认为不同格式。

### 11.4 videobuf2

使用：

```text
vb2_queue.type       = V4L2_BUF_TYPE_VIDEO_CAPTURE
vb2_queue.io_modes   = VB2_MMAP | VB2_DMABUF | VB2_READ（按阶段启用）
vb2_queue.mem_ops    = &vb2_dma_contig_memops
vb2_queue.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC
minimum buffers      = 3
```

实现 `queue_setup`、`buf_prepare`、`buf_queue`、`start_streaming`、`stop_streaming`、
`wait_prepare` 和 `wait_finish`。通过 `vb2_dma_contig_plane_dma_addr()` 获取 DMA 地址。

`start_streaming` 顺序：

1. 确保至少三个 buffer 已排队；
2. 清硬件状态和 completion FIFO；
3. 提交所有可用 descriptor；
4. 配置格式、尺寸、stride 和中断；
5. 先 arm DVP receiver；
6. 最后调用 OV5640 subdev stream-on。

`stop_streaming` 顺序：

1. 先让 OV5640 stream-off；
2. 等待当前 frame/AXI transaction 结束，超时则 abort/reset；
3. 禁止并清中断；
4. 把硬件和软件队列中的全部 buffer 以 ERROR 返回；
5. 保证没有 IRQ handler 再访问已释放 buffer。

### 11.5 media graph 与异步绑定

驱动通过设备树 remote endpoint 和 Linux 5.14 的 V4L2 async notifier 匹配 OV5640。
sensor bind 后创建：

```text
OV5640 source pad -> XUPT DVP capture sink pad -> /dev/video0
```

media link 应为 enabled/immutable。只有 sensor 绑定、video node、media device 和
VB2 queue 全部注册成功后，用户态才能看到可用的 `/dev/video0`。

## 12. 设备树方案

以下示例假设：

- XCLK 常开 24 MHz；
- module 内部或板级电路已经提供三路固定电源；
- RESET_N 已上拉、PWDN 已下拉，MVP 暂不由 Linux GPIO 控制；
- OpenCores I²C 使用 8-bit 连续寄存器；
- HREF/VSYNC 高有效、PCLK 上升沿采样。最后三项必须按示波器结果调整。

```dts
/ {
	cam_xclk: camera-xclk {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <24000000>;
	};

	cam_dovdd: regulator-cam-dovdd {
		compatible = "regulator-fixed";
		regulator-name = "cam-dovdd";
		regulator-min-microvolt = <1800000>;
		regulator-max-microvolt = <1800000>;
		regulator-always-on;
	};

	cam_avdd: regulator-cam-avdd {
		compatible = "regulator-fixed";
		regulator-name = "cam-avdd";
		regulator-min-microvolt = <2800000>;
		regulator-max-microvolt = <2800000>;
		regulator-always-on;
	};

	cam_dvdd: regulator-cam-dvdd {
		compatible = "regulator-fixed";
		regulator-name = "cam-dvdd";
		regulator-min-microvolt = <1500000>;
		regulator-max-microvolt = <1500000>;
		regulator-always-on;
	};

	reserved-memory {
		#address-cells = <1>;
		#size-cells = <1>;
		ranges;

		camera_cma: linux,cma {
			compatible = "shared-dma-pool";
			reusable;
			size = <0x02000000>;       /* 32 MiB，按实际 DDR 调整 */
			alignment = <0x00100000>;
			linux,cma-default;
		};
	};
};

&soc {
	i2c0: i2c@1fe08000 {
		compatible = "opencores,i2c-ocores";
		reg = <0x1fe08000 0x20>;
		opencores,ip-clock-frequency = <100000000>;
		clock-frequency = <100000>;
		reg-io-width = <1>;
		reg-shift = <0>;
		#address-cells = <1>;
		#size-cells = <0>;
		status = "okay";

		ov5640: camera@3c {
			compatible = "ovti,ov5640";
			reg = <0x3c>;
			clocks = <&cam_xclk>;
			clock-names = "xclk";
			DOVDD-supply = <&cam_dovdd>;
			AVDD-supply = <&cam_avdd>;
			DVDD-supply = <&cam_dvdd>;
			status = "okay";

			port {
				ov5640_out: endpoint {
					remote-endpoint = <&dvp_in>;
					bus-width = <8>;
					data-shift = <2>;
					hsync-active = <1>;
					vsync-active = <1>;
					pclk-sample = <1>;
				};
			};
		};
	};

	dvp: video-capture@1fe0c000 {
		compatible = "xupt,dvp-capture-v1";
		reg = <0x1fe0c000 0x1000>;
		interrupt-parent = <&cpuic>;
		interrupts = <4>;
		status = "okay";

		port {
			dvp_in: endpoint {
				remote-endpoint = <&ov5640_out>;
				bus-width = <8>;
				data-shift = <2>;
				hsync-active = <1>;
				vsync-active = <1>;
				pclk-sample = <1>;
			};
		};
	};
};
```

注意：

- 当前 DTS 中的节点写作 `soc { ... }`；若采用上面的 `&soc` overlay 写法，先把它改成
  `soc: soc { ... }`，或者直接把 I²C/DVP 节点放进现有 `soc` 节点；
- endpoint 两端的 bus-width、polarity 和 sample edge 必须一致；
- OV5640 8-bit parallel binding 要求 `data-shift = <2>`；
- 裸 sensor 若连接 RESET/PWDN，应增加 `reset-gpios` 和 `powerdown-gpios`；
- 当前 SoC 尚无 GPIO controller，MVP 可硬件固定安全电平，正式版应增加 GPIO；
- `interrupts = <4>` 只适用于上述完整逐位 IRQ 映射；
- 不要添加 `dma-coherent`；
- 当前 RTL smoke DTS 只声明 16 MiB RAM，不足以承担完整 media 内核、应用和 32 MiB
  CMA。应另建真实 FPGA system DTS，并按实际 DDR 容量填写 memory；
- MIG 配置暴露 27-bit DDR byte address 能力，但最终可用容量仍必须以板卡 DDR 原理图和
  MIG 配置报告为准。

建议新增项目 binding：

```text
Documentation/devicetree/bindings/media/xupt,dvp-capture.yaml
```

至少约束 compatible、reg、interrupts、port/endpoint 和 DMA address width，避免设备树
与 RTL ABI 漂移。

## 13. 内核配置与构建流程

### 13.1 必需配置

在现有 `la32_defconfig` 基础上通过 `scripts/config` 显式启用，具体 symbol 以固定
5.14 tree 的 Kconfig 为准：

```text
CONFIG_I2C=y
CONFIG_I2C_CHARDEV=y                 # bring-up 可选
CONFIG_I2C_OCORES=y

CONFIG_MEDIA_SUPPORT=y
CONFIG_MEDIA_CAMERA_SUPPORT=y
CONFIG_MEDIA_CONTROLLER=y
CONFIG_VIDEO_DEV=y
CONFIG_VIDEO_V4L2=y
CONFIG_V4L2_FWNODE=y
CONFIG_VIDEO_OV5640=y

CONFIG_VIDEOBUF2_CORE=y
CONFIG_VIDEOBUF2_V4L2=y
CONFIG_VIDEOBUF2_MEMOPS=y
CONFIG_VIDEOBUF2_DMA_CONTIG=y
CONFIG_VIDEO_XUPT_DVP=y

CONFIG_CMA=y
CONFIG_DMA_CMA=y
CONFIG_REGULATOR=y
CONFIG_REGULATOR_FIXED_VOLTAGE=y
CONFIG_COMMON_CLK=y
```

如果正式加入 GPIO，再启用 `CONFIG_GPIOLIB` 和所选 GPIO controller 驱动。

### 13.2 仓库组织

建议不要把所有 BSP 内容长期放在 `linux/npu` 名下。可先按最小改动实现，再逐步整理：

```text
linux/
  board/
    prepare.sh
    kernel/
      arch/loongarch/boot/dts/loongson/loongson32_xupt_system.dts
  npu/
    kernel/drivers/misc/xnpu.c
  camera/
    README.md
    build.sh
    kernel/drivers/media/platform/xupt/xupt_dvp.c
    kernel/drivers/media/platform/xupt/Kconfig
    kernel/drivers/media/platform/xupt/Makefile
    userspace/camera_smoke.c
```

若暂不重构，则：

- 在 `linux/npu/prepare.sh` 增加 `xupt_dvp.c` 安装；
- 新增 patch，把 `drivers/media/platform/xupt` 接入 Media Kconfig/Makefile；
- 更新 combined system DTS；
- 在 `build.sh` 增加 `SYSTEM_PROFILE=npu-camera`，保持默认 `npu-smoke` 不变。

### 13.3 initramfs

当前 initramfs 只有一个静态 `/init` smoke 程序，没有完整 shell 和 udev。摄像头 bring-up
至少加入：

- `/dev/video0`、`/dev/media0` 所需 devtmpfs；
- `/proc`、`/sys`；
- 静态 `camera_smoke`；
- 可选 `v4l2-ctl`、`media-ctl`；
- 输出单帧 CRC、首尾字节和 frame sequence 的工具；
- 彩条原始帧导出途径，例如 UART 分块校验或以太网/存储。

V4L2 工具链交叉编译较重时，先使用项目内最小 `camera_smoke.c`，不要因缺少完整
v4l-utils 阻塞驱动验证。

## 14. 用户态 smoke 程序

`camera_smoke` 应只使用标准 V4L2 ioctl：

1. 打开 `/dev/video0`；
2. `VIDIOC_QUERYCAP` 检查 `VIDEO_CAPTURE` 和 `STREAMING`；
3. 枚举 formats/frame sizes；
4. `VIDIOC_S_FMT` 设置 640x480 YUYV；
5. `VIDIOC_REQBUFS` 请求 4 个 MMAP buffer；
6. QUERYBUF + mmap；
7. 把全部 buffer QBUF；
8. STREAMON；
9. poll + DQBUF，检查 `bytesused == 614400`；
10. 逐帧打印 sequence、timestamp、CRC32；
11. 再 QBUF；
12. 采集 1000 帧后 STREAMOFF；
13. 统计超时、sequence gap、error buffer 和 CRC 变化。

第一阶段让 OV5640 输出 color bar/test pattern。若每帧 CRC、行结构和颜色顺序稳定，再
切换到真实镜头，能快速区分 DVP/DMA 错误与自动曝光造成的画面变化。

## 15. 与 NPU 的衔接

第一版数据路径：

```text
/dev/video0 YUYV frame
  -> userspace crop/resize
  -> YUV to RGB/gray
  -> normalize/quantize
  -> NPU input ioctl
```

这与现有 `docs/npu_porting_plan.md` 的 V4L2 输入方向一致，但需要注意：

- 当前 NPU UAPI 管理自己的 DMA buffer，不支持直接 import camera DMA-BUF；
- 不能把 videobuf2 的 DMA/物理地址暴露给 NPU 用户 ioctl；
- 第一版允许一次用户态预处理和 copy，以正确性为先；
- LA32 当前 memcpy 和图像处理性能可能成为瓶颈；
- 后续可增加硬件 YUV-to-RGB、resize/letterbox，或在两个驱动中实现受控的 DMA-BUF
  import/export；
- 零拷贝必须同时解决 buffer ownership、fence、cache sync、格式和 stride，不能只传
  一个物理地址。

摄像头和 NPU 同时运行时，必须验证 RAM arbiter 公平性：摄像头不能 overflow，NPU
不能超时，CPU 也不能因 DMA 饥饿失去响应。

## 16. 分阶段实现计划

### 阶段 0：硬件信息冻结

交付物：引脚表、电源表、时序表。

1. 确认 OV5640 模块型号和原理图；
2. 确认 DVP 数据电压、SCCB 上拉电压和模块输入电压；
3. 确认 RESET_N/PWDN 默认电平；
4. 从开发板原理图选出 16 个可用 I/O；
5. 确认 PCLK 是否可接 clock-capable pin；
6. 确认真实 DDR 容量；
7. 确认最终 CPU 是 OpenLA500 还是团队自研核；
8. 确认第一版目标为 VGA 30 fps YUYV/UYVY。

缺少以上信息时可以写仿真 RTL，但不能安全上板。

### 阶段 1：XCLK 与 SCCB

1. Clocking Wizard 增加 24 MHz 输出；
2. 用示波器测量 XCLK 频率、duty 和电平；
3. 加入 OpenCores I²C APB wrapper；
4. 把 APB decoder 扩展为四路；
5. 裸机读取 OV5640 chip ID `0x300a/0x300b`；
6. Linux 启用 `i2c-ocores` 和 `ov5640`；
7. 用 `/sys/bus/i2c`、probe log 或 `i2cdetect` 确认地址 `0x3c`；
8. 确认 OV5640 subdev probe 成功。

验收：重复冷启动 100 次，均能读到正确 chip ID，无总线卡死。

### 阶段 2：DVP receiver 纯 RTL

1. 写行为级 DVP source；
2. 验证 PCLK/HREF/VSYNC 极性和采样边沿；
3. 验证异步 FIFO；
4. 验证 YUYV/UYVY byte order；
5. 验证异常短行、长行、少行、多行；
6. 验证 VSYNC 丢失和流中断；
7. 验证 FIFO overflow 后只丢当前帧并在下一帧恢复。

验收：随机 PCLK/sys_clk 相位和 back-pressure 下，完整帧逐字节匹配 reference model。

### 阶段 3：AXI DMA

1. 实现 descriptor submit/done FIFO；
2. 实现 AXI write burst；
3. 接 RTL AXI RAM；
4. 验证不跨 4 KiB；
5. 验证所有 WSTRB；
6. 注入 BRESP error；
7. 验证 stride 和 buffer guard area；
8. 验证无 descriptor 时绝不写 RAM；
9. 级联 RAM arbiter；
10. 与 NPU DMA 并发随机压力测试。

验收：地址范围 assertion 无违例，guard bytes 不变，错误可恢复。

### 阶段 4：中断

1. 在 OpenLA500 仿真中接 DVP IRQ；
2. 验证 W1C、mask、level deassert 和重复帧；
3. 补齐团队 CPU 外部中断映射或中断控制器；
4. 跑 Linux IRQ smoke；
5. 检查 `/proc/interrupts` 每帧增加一次；
6. 验证同时触发 NPU + camera 时两个 handler 都完成；
7. 验证 STREAMOFF 后无 late IRQ/use-after-free。

### 阶段 5：V4L2 驱动

1. 注册 platform driver、media device、video device 和 VB2 queue；
2. 解析 endpoint；
3. 异步绑定 OV5640 subdev；
4. 实现 format negotiation；
5. 实现 QBUF/STREAMON/DQBUF/STREAMOFF；
6. 实现 IRQ completion；
7. 实现错误 unwind、remove 和重复 open/close；
8. 运行 `camera_smoke` 的模拟 DMA/RTL 测试。

验收：标准 V4L2 应用不依赖私有 ioctl 即可连续取帧。

### 阶段 6：实机 VGA

1. 断开镜头或启用 sensor color bar；
2. 先以低 PCLK/低帧率验证；
3. 捕获 DVP 波形与 DDR 内容；
4. 升到 640x480@30；
5. 连续采集至少 10 万帧；
6. 验证 sequence、CRC、颜色顺序、overflow/drop/AXI error；
7. 测试拔插电源、sensor reset、应用异常退出和重复 STREAMON。

### 阶段 7：NPU 联调

1. 保持摄像头独立 smoke 可复现；
2. 加入 YUYV 预处理；
3. 单帧喂入 NPU；
4. 再启用连续 pipeline；
5. 测量 capture、preprocess、NPU、UART 控制各阶段耗时；
6. 做 NPU DMA + camera DMA + CPU memory 并发压力；
7. 最后再考虑硬件预处理和 DMA-BUF 零拷贝。

## 17. 验证矩阵

### 17.1 RTL

- 不同 PCLK/sys_clk 频率比和随机相位；
- HREF/VSYNC 两种极性；
- PCLK 上升/下降沿采样；
- 0、1、奇数和非 4-byte 对齐的尾数据；
- stride 等于/大于 bytesperline；
- buffer 边界和 4 KiB 边界；
- AXI AW/W/B back-pressure；
- BRESP SLVERR/DECERR；
- descriptor FIFO 满/空；
- done FIFO 满；
- reset、abort 和 stream stop；
- camera/NPU/CPU 并发。

### 17.2 Linux

- probe defer：I²C、clock、regulator、sensor、receiver 的任意加载顺序；
- 打开/关闭、重复 STREAMON/OFF；
- 应用被 SIGKILL；
- buffer 数量 3、4、8；
- MMAP 和后续 DMABUF；
- 无 buffer、DQBUF 过慢；
- IRQ storm 和 spurious IRQ；
- CMA 分配失败；
- DMA address 超过 32-bit 或不对齐；
- sensor I²C timeout；
- cache consistency；
- NPU 并发回归。

### 17.3 硬件

- XCLK 和 PCLK 频率；
- 电源上电/掉电顺序；
- SCCB rise time 和 ACK；
- DVP setup/hold；
- FIFO high-water；
- DDR 实测带宽；
- 温度、电源噪声和长时间运行；
- 机械臂舵机电源噪声同时存在时的摄像头稳定性。

摄像头与舵机必须合理分离供电并共地。舵机动作造成的压降和地弹噪声可能表现为 SCCB
失败、随机坏帧或 FPGA 输入抖动，不能只从软件排查。

## 18. 主要风险与规避

| 风险 | 后果 | 规避措施 |
| --- | --- | --- |
| 模块 I/O 为 1.8 V，直接接 LVCMOS33 | 器件损坏 | 先确认原理图，匹配 VCCO/加电平转换 |
| PCLK 未接 clock-capable pin | 时序难收敛 | 优先选择时钟管脚，IOB register |
| 逐位同步 DVP 数据 | 随机撕裂/坏像素 | PCLK 域采样 + async FIFO |
| DDR 仲裁长时间阻塞 | FIFO overflow/丢帧 | 短 burst、公平仲裁、FIFO 和计数器 |
| 仍使用 16 MiB smoke DTS | CMA/内核内存不足 | 独立 FPGA DTS、实际 DDR、32 MiB CMA |
| 团队 CPU 中断仍 `|intrpt` | 无法可靠完成 buffer | 逐位 IRQ 或 irqchip 是前置任务 |
| 错误声明 `dma-coherent` | 用户看到旧帧/脏数据 | DMA API、无 coherent 声明、CRC 验证 |
| OV5640 驱动与 receiver 格式不一致 | 颜色错位/行长度错误 | media bus code 联合协商 |
| 固定两个 framebuffer | 用户慢时覆盖图像 | descriptor queue + VB2 ownership |
| 在 IRQ 中处理图像 | 丢帧、长中断 | IRQ 只完成 buffer，处理留给用户态 |
| 第一版直接做 1080p/JPEG/ISP | 难以定位问题 | VGA YUV422 分阶段验证 |

## 19. 预计文件改动

RTL/FPGA：

```text
chiplab/IP/CAMERA/**                                  新增
chiplab/IP/APB_DEV/apb_mux2.v                         重构为四路
chiplab/IP/APB_DEV/apb_dev_top_no_nand.v              接入 I²C/DVP APB
chiplab/IP/NPU/rtl/wrappers/npu_axi_ram_arbiter.v      泛化或保留后级联
chiplab/chip/soc_demo/nscscc-team/soc_top.v            DVP pin/DMA/IRQ/clock
chiplab/chip/soc_demo/sim/soc_top.v                    同步仿真结构
chiplab/chip/soc_demo/nscscc-team/xilinx_ip/clk_pll/*  增加 24 MHz
chiplab/fpga/nscscc-team/run_vivado/create_project.tcl 加入 camera filelist
chiplab/fpga/nscscc-team/constraints/soc_lite.xdc      pin/timing/CDC
```

Linux：

```text
linux/camera/kernel/drivers/media/platform/xupt/xupt_dvp.c
linux/camera/kernel/drivers/media/platform/xupt/Kconfig
linux/camera/kernel/drivers/media/platform/xupt/Makefile
linux/camera/kernel/Documentation/devicetree/bindings/media/xupt,dvp-capture.yaml
linux/camera/userspace/camera_smoke.c
linux/camera/build.sh
linux/board/kernel/arch/loongarch/boot/dts/loongson/loongson32_xupt_system.dts
```

如果不做目录重构，则上述 Linux overlay 暂时放到 `linux/npu` 对应目录，并通过
`prepare.sh` 安装到固定 kernel worktree。

## 20. 最终验收标准

- Linux 冷启动可稳定探测 I²C controller 和 OV5640 chip ID；
- media graph 中 OV5640 正确连接到 XUPT DVP capture；
- `/dev/video0` 支持标准 V4L2 streaming ioctl；
- 640x480 YUYV/UYVY `bytesused` 恒为 614,400；
- color bar 的 byte order、行长度、CRC 和颜色正确；
- 连续 10 万帧无永久错位、越界 DMA、死锁或不可恢复 IRQ；
- buffer 不足时只增加 drop count，不覆盖用户 buffer；
- FIFO overflow、AXI error、sensor 断流均返回 error buffer 并可重新 STREAMON；
- CPU 读取 DMA frame 无 stale cache/局部旧数据；
- camera DMA 与 NPU DMA 并发时系统可响应，摄像头和 NPU 都无超时；
- 原有 NPU ROM/MMIO、NPU DMA 和 UART 回归不受破坏；
- 所有实机 pin、电压、时钟、内存和 IRQ 信息在设备树/约束/文档中一致。

## 21. 开始编码前必须取得的信息

1. OV5640 模块购买链接、型号、原理图和 pinout；
2. 模块是否自带 24 MHz 晶振；
3. 模块 DVP/SCCB 电平；
4. 模块 RESET_N/PWDN 是否已有上下拉；
5. FPGA 开发板扩展口原理图；
6. 计划使用的 PACKAGE_PIN 和所在 I/O bank VCCO；
7. 真实 DDR 型号和容量；
8. 最终 Linux CPU 核及外部中断完成状态；
9. 第一版只需 VGA，还是存在硬性 720p/1080p 要求；
10. 上层算法最终需要 YUYV、RGB565、RGB888 还是灰度输入。

其中 1～7 决定能否安全接线，8 决定 V4L2 streaming 能否可靠工作，9～10 决定 DMA
吞吐、buffer 大小和是否需要硬件预处理。

## 22. 上游依据

- Linux OV5640 设备树 binding：
  <https://www.kernel.org/doc/Documentation/devicetree/bindings/media/i2c/ov5640.txt>
- Linux 5.14 OV5640 驱动：
  <https://github.com/torvalds/linux/blob/v5.14/drivers/media/i2c/ov5640.c>
- Linux 5.14 OpenCores I²C binding：
  <https://github.com/torvalds/linux/blob/v5.14/Documentation/devicetree/bindings/i2c/i2c-ocores.txt>
- Linux 5.14 `i2c-ocores` 驱动：
  <https://github.com/torvalds/linux/blob/v5.14/drivers/i2c/busses/i2c-ocores.c>
- Linux V4L2 core 和 videobuf2 文档：
  <https://www.kernel.org/doc/html/latest/driver-api/media/v4l2-core.html>
  <https://www.kernel.org/doc/html/latest/driver-api/media/v4l2-videobuf2.html>
- Linux camera sensor driver 文档：
  <https://www.kernel.org/doc/html/latest/driver-api/media/camera-sensor.html>
- Linux parallel/CSI receiver 文档：
  <https://www.kernel.org/doc/html/latest/driver-api/media/tx-rx.html>
