# SoC—ESP32 机械臂 UART 移植方案

> 最后更新：2026-08-04
>
> 适用分支：`feature/npu-linux-port`

## 1. 目标与范围

本方案将现有机械臂从 ESP32 Wi-Fi/UDP 控制方式迁移为 SoC 通过独立硬件
UART 直接控制 ESP32：

- PC 上位机继续负责红、绿、蓝目标的视觉识别；
- SoC/Linux 接收视觉坐标、执行任务调度并向 ESP32 下发命令；
- ESP32 删除 Wi-Fi、UDP 和网络重连逻辑，仅保留 UART 协议、动作状态机和
  舵机驱动；
- 系统只包含一台机械臂，不包含机械狗或云台控制；
- 第一版优先使用简单、可调试的固定长度协议，稳定后再考虑 CRC、序号等增强。

本方案复用仓库已有 Linux-NPU 的固定内核、设备树、交叉编译和 initramfs
构建方法，但 UART 使用 Linux 标准 8250/16550 驱动，不新增专用 misc 驱动。

## 2. 总体架构

```text
ESP32-CAM/摄像头
        |
        | 图像
        v
PC 上位机（PySide6 + OpenCV）
        |
        | UART0：R + 6 字节坐标，115200 8N1
        v
SoC / Linux robotd
        |
        | UART1：坐标帧和动作命令，115200 8N1
        v
ESP32
        |
        | PWM/舵机总线
        v
机械臂
```

建议的职责边界如下：

| 组件 | 职责 |
| --- | --- |
| PC 上位机 | 接收图像、识别红/绿/蓝目标、生成坐标帧 |
| SoC/Linux | 坐标接收、有效性判断、任务状态机、动作调度、故障处理 |
| ESP32 | UART 解析、舵机插值、限位、抓取动作和失联保护 |

ESP32 仍是机械臂的实时执行控制器，但不再独立参与网络通信。SoC 是机械臂
任务控制的唯一上游。

## 3. 坐标协议

### 3.1 固定七字节帧

PC 到 SoC、SoC 到 ESP32 第一版使用相同的固定七字节二进制帧：

| 偏移 | 类型 | 内容 |
| ---: | --- | --- |
| 0 | `uint8_t` | 帧头 `R`，即 `0x52` |
| 1 | `uint8_t` | 红色目标 `x / 4` |
| 2 | `uint8_t` | 红色目标 `y / 4` |
| 3 | `uint8_t` | 绿色目标 `x / 4` |
| 4 | `uint8_t` | 绿色目标 `y / 4` |
| 5 | `uint8_t` | 蓝色目标 `x / 4` |
| 6 | `uint8_t` | 蓝色目标 `y / 4` |

坐标编码规则：

```text
encoded = clamp(floor(pixel / 4), 0, 255)
```

对于 `640x480` 图像，编码后的正常范围为：

- `x`：0～159；
- `y`：0～119；
- ESP32 如需继续使用原始像素阈值，收到后执行 `pixel = encoded * 4`；
- 量化误差为 0～3 像素。

当前上位机在目标未识别到时发送 `(0, 0)`。第一版约定 `(0, 0)` 表示该目标
无效，因此真实图像左上角 `(0, 0)` 不作为有效控制坐标。后续协议可增加有效位，
解除这一限制。

### 3.2 动作与状态字节

ESP32 仅在等待帧头状态下解释下列单字节命令：

| 方向 | 字节 | 含义 |
| --- | --- | --- |
| SoC -> ESP32 | `S` | 立即停止并保持安全状态 |
| SoC -> ESP32 | `H` | 机械臂回零/回到初始位 |
| SoC -> ESP32 | `G` | 开始一次抓取动作 |
| SoC -> ESP32 | `O` | 张开夹爪 |
| ESP32 -> SoC | `K` | 坐标帧接收成功 |
| ESP32 -> SoC | `D` | 当前动作完成 |
| ESP32 -> SoC | `E` | 执行或硬件故障 |

读取坐标载荷期间，任何字节都必须按坐标处理，即使载荷值恰好等于 `R`、`S`
或其他命令字符，也不能中途重新解释。

### 3.3 后续协议增强

固定七字节帧没有长度、序号和校验。第一版通过固定长度、半帧超时和周期性新帧
实现恢复；完成基础联调后，建议升级为：

```text
0xA5 | type | sequence | length | payload | CRC8
```

增强协议必须保留 `S` 紧急停止的低延迟处理能力，并明确版本兼容策略。

## 4. SoC RTL 改造

### 4.1 复用现有 APB UART

仓库已经有一个 16550 风格 `UART_TOP`，通过 `axi2apb_misc` 接入。现有
`apb_mux2` 还保留了未使用的 `apb1` 通道，因此推荐实例化第二个相同 UART，
而不是重新设计 UART 寄存器接口。

建议地址：

| 项目 | 数值 |
| --- | --- |
| UART0 物理基址 | `0x1fe001e0` |
| 机械臂 UART1 物理基址 | `0x1fe041e0` |
| 寄存器窗口 | `0x10` 字节 |
| 波特率 | 115200 |
| 数据格式 | 8N1，无流控 |

`0x1fe041e0` 位于现有 `0x1fe00000` UART/APB AXI 窗口内，可以使用
`apb1` 区域，通常不需要为此增加 AXI crossbar master/slave 端口。

主要修改点：

1. `chiplab/IP/APB_DEV/apb_dev_top_no_nand.v`
   - 增加 UART1 的 TX/RX/控制/中断端口；
   - 将当前空置的 `apb1` 接到 UART1；
   - 复制 UART0 的 `UART_TOP` 实例作为 UART1。
2. `chiplab/IP/APB_DEV/apb_mux2.v`
   - 明确 UART0 与 UART1 地址区间；
   - 避免未定义 APB 地址无意别名到 UART1；
   - 为非法地址提供可结束的错误或空响应，禁止 AXI 永久等待。
3. `chiplab/chip/soc_demo/nscscc-team/soc_top.v`
   - 增加 `ARM_UART_RX`、`ARM_UART_TX` 顶层端口；
   - 连接 UART1 到 `axi2apb_misc`；
   - 按选定 CPU 的中断能力决定是否接入 UART1 IRQ。
4. `chiplab/chip/soc_demo/sim/soc_top.v`
   - 同步增加 UART1，保证 Verilator/RTL 仿真与 FPGA 结构一致。
5. `chiplab/fpga/nscscc-team/constraints/soc_lite.xdc`
   - 根据实验箱扩展接口原理图选择 UART1 引脚；
   - 设置 `LVCMOS33`；
   - 不得在未核对原理图前猜测 FPGA 管脚。

### 4.2 中断策略

当前团队 CPU 包装层将 `intrpt[7:0]` 归并为单一中断输入，无法区分 NPU、UART0
和 UART1。第一阶段建议：

- UART1 使用轮询方式；
- 不给机械臂 UART1 声明 IRQ；
- SoC 到 ESP32 的低速七字节帧不依赖中断即可满足吞吐要求；
- 在支持独立外部中断向量的 OpenLA500/后续 CPU 上，再接入 UART1 IRQ。

如果需要 ESP32 的 `D/E` 异步反馈，Linux 用户态可以通过无中断 UART 的轮询定时器
读取；待 CPU 中断体系完整后再切换到中断接收。

## 5. Linux 接入

### 5.1 设备树

在 XUPT SoC 设备树的 `soc` 节点中增加：

```dts
arm_uart: serial@1fe041e0 {
	compatible = "ns16550a";
	reg = <0x1fe041e0 0x10>;
	clock-frequency = <33000000>;
	no-loopback-test;
	status = "okay";
};
```

第一阶段省略 `interrupts`。当 CPU 能区分 UART1 外部中断后，再增加正确的
`interrupt-parent` 和 `interrupts`，并用仿真确认 Linux HWIRQ 编号。

设备树匹配成功后，UART1 应由标准 8250/16550 驱动注册为 `/dev/ttyS1`。
无需创建 `/dev/xupt-uart`，也无需复制 NPU 的 misc 驱动。

### 5.2 `robotd` 用户态服务

新增静态链接的 `robotd`，建议职责如下：

1. 以 raw 模式打开上位机输入串口和 `/dev/ttyS1`；
2. 从输入流中寻找 `0x52`，随后固定读取六字节；
3. 半帧超过 20 ms 未完成时丢弃并重新寻找帧头；
4. 校验坐标范围和目标有效性；
5. 根据任务状态决定转发坐标或发送 `G/H/O/S`；
6. 使用 `write_all()` 保证七字节不会因短写而丢失；
7. 读取 ESP32 的 `K/D/E` 并更新状态；
8. 超时、串口错误或进程退出前必须发送 `S`。

串口配置：

```text
115200 baud
8 data bits
no parity
1 stop bit
no hardware/software flow control
raw mode
```

现有 Linux-NPU initramfs 的 `/init` 是 smoke 程序，完成测试后会永久休眠，
不是完整发行版。集成机械臂时需要：

- 将 `robotd` 静态编译并加入 initramfs；
- 使用统一 `/init` 挂载 `devtmpfs`、`proc`、`sysfs`；
- 启动 NPU/机械臂所需服务；
- 保留一个独立 `uart_smoke`，使没有完整 shell 时也能验证 UART1。

### 5.3 UART0 与 Linux 控制台冲突

如果 PC 上位机通过现有 UART0 向 SoC 发送二进制坐标，UART0 不能同时输出 Linux
启动日志或运行串口 getty，否则日志字节会混入协议流。

量产/展示配置应从 bootargs 中移除：

```text
console=ttyS0,115200
```

并禁止在 UART0 上启动 getty。调试阶段可先保留控制台，只验证 UART1；正式接入
上位机坐标前再关闭控制台。若必须永久保留串口控制台，则需要增加另一个上位机
输入 UART，或者把 PC 到 SoC 的坐标链路迁移到以太网。

## 6. ESP32 固件改造

### 6.1 删除网络组件

ESP32 固件应删除：

- `WiFi.h`、`WiFiUDP` 等网络依赖；
- SSID、密码、静态 IP 和 UDP 端口；
- Wi-Fi 连接与重连状态机；
- UDP socket、网络握手和网络超时逻辑；
- 只服务于网络通信的 FreeRTOS task 和缓冲区。

保留：

- 舵机初始化、角度限制和插值；
- 红/绿/蓝坐标到机械臂动作的原有算法；
- 抓取、回零、停止等动作状态机；
- 必要的 USB 串口调试输出，但调试输出不得写入机械臂 UART。

### 6.2 UART 初始化

Arduino 框架示例：

```cpp
constexpr int ARM_UART_RX_PIN = 16; // 根据实际 PCB 修改
constexpr int ARM_UART_TX_PIN = 17; // 根据实际 PCB 修改

void setup()
{
	Serial.begin(115200); // 可选 USB 调试口
	Serial2.begin(115200, SERIAL_8N1,
	              ARM_UART_RX_PIN, ARM_UART_TX_PIN);

	initServos();
	emergencyStopArm();
}
```

ESP32 引脚必须根据实际板卡确认，避开下载、启动绑带、Flash/PSRAM 和已使用的
PWM 引脚。

### 6.3 非阻塞解析状态机

ESP32 主循环不得使用会长期阻塞舵机控制的字符串读取。推荐状态：

```text
WAIT_HEADER
  R -> READ_COORDS
  S -> emergencyStopArm
  H -> homeArm
  G -> startGrab
  O -> openGripper

READ_COORDS
  连续收满 6 字节 -> 更新坐标，返回 K，回到 WAIT_HEADER
  20 ms 半帧超时 -> 丢弃，回到 WAIT_HEADER
```

坐标还原：

```cpp
red_x   = payload[0] * 4;
red_y   = payload[1] * 4;
green_x = payload[2] * 4;
green_y = payload[3] * 4;
blue_x  = payload[4] * 4;
blue_y  = payload[5] * 4;
```

解析完成后调用原固件中负责更新机械臂目标的函数，不要直接在 UART 接收循环中
执行长时间阻塞的整套抓取动作。

### 6.4 安全机制

机械臂固件至少实现：

- 500 ms 未收到有效坐标或心跳时停止运动；
- `S` 命令最高优先级；
- 每个关节的软限位、最大速度和最大单步变化量；
- 上电默认保持安全姿态，不因随机串口字节启动动作；
- 非法坐标、半帧、缓冲区溢出时丢弃数据；
- 故障后返回 `E`，必须收到明确恢复或回零命令才能继续；
- 舵机电源与 FPGA/ESP32 逻辑电源合理隔离，同时保证信号共地。

## 7. 上位机简化

当前 `F` 目录是 PC 上位机 Python 代码，不是 ESP32 固件。系统只保留机械臂后，
应简化为：

- 只创建 `ArmController`；
- 删除 `PlatformController` 和云台页面；
- 删除机械狗、云台 IP/端口及命令映射；
- `send_serial_coords()` 始终发送红、绿、蓝坐标；
- 删除 PC 作为 UDP 中继向 ESP32 发指令的代码；
- 串口发送周期暂定 100 ms，后续根据控制响应调整到 20～100 ms；
- 串口关闭、页面退出或识别停止时，通知 SoC 进入停止状态。

上位机只负责提供观察结果，不直接驱动舵机。

## 8. 分阶段实施与验证

### 阶段 1：ESP32 独立 UART 验证

1. 删除 Wi-Fi/UDP 入口，但暂不改机械臂算法；
2. 使用 USB-UART 向 ESP32 发送七字节测试帧；
3. 先断开舵机动力，通过日志验证坐标解析；
4. 验证 `S/H/G/O` 和 `K/D/E`；
5. 验证半帧、乱码和 500 ms 超时不会触发危险动作。

### 阶段 2：SoC UART1 裸机验证

1. 实例化第二个 `UART_TOP`；
2. 通过 JTAG/裸机程序访问 `0x1fe041e0`；
3. 使用逻辑分析仪确认 115200 8N1 波形；
4. 完成 SoC TX -> ESP32 RX；
5. 如需要反馈，再验证 ESP32 TX -> SoC RX。

### 阶段 3：Linux UART 验证

1. 在设备树增加 UART1；
2. 确认启动日志出现第二个 8250 端口和 `/dev/ttyS1`；
3. 使用静态 `uart_smoke` 发送固定坐标和停止命令；
4. 连续发送至少 10 万帧，检查短写、阻塞和错帧恢复；
5. 验证无 IRQ 轮询模式不会影响 NPU smoke。

### 阶段 4：`robotd` 与上位机

1. 关闭 UART0 Linux console/getty；
2. 上位机发送红/绿/蓝坐标；
3. `robotd` 解析并转发到 UART1；
4. 注入丢字节、断线和 ESP32 重启；
5. 验证所有异常都进入停止状态。

### 阶段 5：机械臂实机

1. 低速度、低力矩、空载验证；
2. 校准图像坐标与机械臂工作空间；
3. 验证红/绿/蓝目标缺失、重叠和边界情况；
4. 连续运行并记录 UART 错误、动作超时和复位次数；
5. 最后再与 NPU/摄像头完整链路联合验证。

## 9. 验收标准

- ESP32 固件不初始化 Wi-Fi，不创建 UDP socket；
- Linux 能稳定识别 `/dev/ttyS1`；
- PC 到 SoC、SoC 到 ESP32 的七字节坐标语义一致；
- ESP32 能正确还原红/绿/蓝坐标并复用原机械臂算法；
- `S`、失联看门狗、坐标无效和进程退出均能停止机械臂；
- UART0 协议流中没有 Linux console/getty 输出；
- 连续运行过程中无串口死锁、帧永久错位或机械臂失控；
- NPU Linux 回归和无 NPU 的 UART smoke 均可独立复现。

## 10. 实施前待确认项

在开始实机修改前仍需确认：

1. ESP32 型号、开发框架（Arduino 或 ESP-IDF）；
2. 原机械臂固件使用的舵机库、关节数量、引脚和角度限制；
3. FPGA 实验箱可用于 UART1 的扩展接口和管脚；
4. PC 上位机最终是否固定占用 UART0；
5. 实机 Linux 使用 OpenLA500 还是补齐后的团队 CPU；
6. 是否需要 ESP32 向 SoC 返回动作完成和错误状态。

这些信息不影响 UART1 与 Linux 基础链路的先行实现，但会影响 ESP32 引脚、
中断方案和最终动作协议。
