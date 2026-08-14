# XNPU 积木识别闭环演示与标定指南

本文说明 VisionArm 综合演示的目标、当前实现、OV5640 与机械臂标定方法、
部署顺序、安全条件和验收标准。最终数据链路为：

```text
OV5640 → FPGA VDMA/DDR → Linux 图像预处理 → XNPU 类别推理
                                      ↓
                               视觉闭环控制器
                                      ↓
FPGA UART → ESP32 → X/Y/Z 步进电机与夹爪 → OV5640 再次观测
```

## 1. 演示目标与边界

目标演示为：在固定工作台上识别指定颜色和类别的积木，控制机械臂小步
对准、接近、夹取，并通过再次识别确认结果。

系统采用两级识别：

1. Linux 从 640×480 RGB565 图像中用颜色阈值快速产生候选框；
2. 候选区域缩放并填充为 34×34×3 CHW u8，由 XNPU 分类模型确认类别。

当前 `visionarm-block` 已实现颜色候选、XNPU 分类接口、连续帧确认和可选
XY 小步对准。默认是观察模式，不会驱动电机。Z 轴接近、夹取和释放要在
物理标定完成后才能启用，不能用未标定参数直接演示。

当前仓库没有真实积木数据集或 `blocks_v1.xnpu` 权重；已有 FaceNet 和
TinyVGG 包是驱动/硬件回归样例，不能冒充积木模型。

## 2. 安全原则

- 第一次回零和方向标定时，操作人员必须能立即切断电机电源；
- 每次掉电、人工移动或疑似失步后都必须重新回零；
- 未完成回零、方向、工作区和抓取高度标定前，只允许观察模式；
- 自动控制每次最多发送一个 100 步命令，运动稳定后重新识别；
- 单帧结果不能触发动作，至少连续 3 帧类别和位置稳定；
- 丢失目标、超过最大修正次数、限位异常或 XNPU 超时必须停止；
- 当前 Z 轴运动会联动 Y 轴，标定和控制必须包含该耦合；
- 视觉不能替代机械限位，也不能检测夹持力和所有碰撞。

## 3. 机械臂接线与协议

当前 ESP32 固件使用 UART2：

```text
FPGA ARM_UART_TX → ESP32 GPIO17 (RX)
ESP32 GPIO4 (TX) → FPGA ARM_UART_RX（当前 FPGA 尚未实现接收）
FPGA GND          ↔ ESP32 GND
串口              9600, 8N1, 无流控
```

Linux 命令经物理寄存器 `0x1fd0e010` 发送单字节到 ESP32。运动命令每次
100 步；`arm` 工具通过重复发送实现 200～5000 步。

```sh
arm x forward 100
arm x reverse 100
arm y up 100
arm y down 100
arm z forward 100
arm z reverse 100
arm grip open
arm grip close
arm home
arm position
```

ESP32 会发送 `ACK`、`DONE` 和位置文本，但当前 FPGA 通路是单向 TX，Linux
收不到这些回复。首次调试必须同时打开 ESP32 USB 串口。

## 4. 机器零点

X/Y/Z 限位开关分别连接 ESP32 GPIO36、GPIO39、GPIO34，当前定义为高电平
触发。回零前用 `VisionArm/esp32/filesystem/限位器测试.py` 验证：

```text
未触碰：0
触碰：  1
```

当前配置中的限位方向为：

| 轴 | `DIR_TO_LIMIT` | 朝限位的 Linux 命令 | 离开限位的命令 |
|---|---:|---|---|
| X | 1 | `arm x forward 100` | `arm x reverse 100` |
| Y | 1 | `arm y up 100` | `arm y down 100` |
| Z | 0 | `arm z reverse 100` | `arm z forward 100` |

方向名称只是当前软件映射，第一次必须以 100 步实测。若方向不符，应修正
`config.py` 的 `DIR_TO_LIMIT`，禁止带着错误方向执行完整回零。

执行：

```sh
arm home
```

ESP32 的回零过程为：

1. 已经压住限位时先反向退出，再额外退 80 步消除回差；
2. 单独搜索 X 限位；
3. 交替搜索 Y/Z 限位；
4. 连续 4 次采样有效才确认触发；
5. 最大搜索步数为 X=12000、Y=12000、Z=14000；
6. 超限仍未触发则报错、停止并释放电机；
7. 成功后将 ESP32 相对计数设为 `X=0,Y=0,Z=0`。

必须在 ESP32 USB 串口看到：

```text
DONE HOME X=0 Y=0 Z=0
```

Linux 的 `homing requested` 仅表示字节已经发出。普通步进也会逐步检查朝
限位方向的开关，避免回零后继续顶住端点。

## 5. 工作零点

限位点是机器零点，不是安全抓取姿态。工作零点应满足：

- 夹爪位于摄像头有效视野附近；
- 夹爪与桌面、底座和支架保持安全距离；
- 三个轴向正反方向都留有调整余量；
- 夹爪标记可被 OV5640 稳定识别。

标定步骤：

1. 完成机器回零；
2. 使用离开限位方向的命令，每次移动 100 步；
3. 到达安全姿态后记录三轴累计步数；
4. 将其保存为 `work_zero_x/y/z`；
5. 重新回零并再次移动相同步数，验证重复性；
6. 连续重复 3～5 次，确认没有失步和结构干涉。

旧 `go_to_origin.py` 中的 3800/4419/5081 是旧装置实测值，未经当前机械结构
复测不得直接使用。

## 6. 为什么最终必须用 OV5640 标定

相机内参、畸变和外参都与实际镜头、分辨率和安装姿态绑定。最终闭环使用
OV5640，就必须使用 OV5640 拍摄的数据求最终参数。

手机可以作为外部测量参考或辅助检查，但不能把手机标定参数直接用于
OV5640。手机与 OV5640 的焦距、光心、畸变、分辨率和安装位置均不同。

固定相机后不必每次开机重新做完整标定；以下变化发生时才需要重标：

- 摄像头、机械臂底座或桌面移动；
- 镜头重新调焦或更换；
- 分辨率、裁剪、旋转或缩放路径改变；
- 工作平面高度改变。

## 7. 标定程序放在哪里运行

采用“电脑离线求解，SoC 在线执行”的分工。

电脑负责：

- 相机内参和畸变求解；
- 桌面单应矩阵求解；
- 图像—机械臂运动映射拟合；
- 标定质量报告；
- 积木模型训练、量化和 `.xnpu` 打包。

SoC负责：

- 每次上电进行机械限位回零；
- 加载已生成的标定参数；
- 实时读取 OV5640 图像；
- 颜色候选和 XNPU 推理；
- 执行像素/桌面坐标变换；
- 小步闭环控制和安全状态机。

## 8. OV5640 相机标定

### 8.1 准备

- 将 OV5640 固定在最终位置；
- 使用最终运行时相同的 640×480 DDR 图像路径；
- 准备尺寸准确的棋盘格或 AprilTag 标定板；
- 保持正常演示照明，避免自动曝光剧烈变化；
- 从 SoC DDR framebuffer 保存原始 RGB565 帧并传到电脑。

SoC端采集命令：

```sh
mkdir -p /tmp/calibration
visionarm-capture --prefix /tmp/calibration/checkerboard --count 20
```

工具会为每帧保存 `.rgb565` 和包含frame count、camera status的 `.ini`。当前
版本为了得到稳定帧会短暂停止DMA；活动乒乓buffer选择仍需按硬件清单H01验证。

不要使用 VGA 采集画面代替 DDR 原始帧，因为 VGA 路径可能包含缩放、时序
或采集卡二次处理。

### 8.2 内参与畸变

在标定板不同位置、角度和画面边缘采集 15～30 张清晰图像。电脑求解：

```text
fx, fy          焦距
cx, cy          光心
k1, k2, k3      径向畸变
p1, p2          切向畸变
```

应保存每张图的重投影误差，并剔除模糊、角点缺失或误差明显偏大的图片。

如果最终只在画面中央很小的桌面区域工作，可用密集平面点直接拟合映射，
但完整内参和畸变标定对画面边缘精度更可靠。

### 8.3 桌面坐标

将标定板平放在积木所在平面，用至少 4 个不共线、实际坐标已知的点求单应
矩阵 `H`：

```text
[X, Y, 1]^T ~ H [u, v, 1]^T
```

其中 `(u,v)` 是去畸变后的图像坐标，`(X,Y)` 是桌面毫米坐标。用未参与
求解的检查点验证误差；误差超过抓取允许范围时不得进入自动控制。

单目相机只对已知平面可靠。不同高度的积木需要提供已知高度、增加多高度
标定，或采用额外深度信息；不能从一个未知物体的单张图像直接得到可靠 Z。

## 9. 图像—机械臂自动标定

在夹爪上固定高对比度圆点或 AprilTag。完成机器回零并移动到工作零点后，
自动标定程序按安全顺序执行：

1. 拍摄并检测夹爪中心 `(u0,v0)`；
2. X 轴向安全方向移动 100 步，等待稳定后检测 `(u1,v1)`；
3. 回到初始位置；
4. 对 Y、Z 轴重复；
5. 在工作区多个位置重复采样；
6. 拟合局部图像雅可比矩阵和耦合补偿；
7. 保存拟合误差、有效区域和方向；
8. 自动回到工作零点并进行独立验证。

局部关系为：

```text
[du]   [J00 J01] [dstep_a]
[dv] = [J10 J11] [dstep_b]
```

闭环控制使用 `J` 的逆或最小二乘解估算下一次小步动作。由于机械臂非线性
且 Z/Y 有耦合，不应只用覆盖整个工作区的一个固定比例；可以保存多个区域
的局部矩阵，或始终采用“小步运动—重新观测”的视觉伺服方式。

当前 FPGA 缺少 ESP32→SoC 回传。初次自动采集可采用保守固定等待并监视
ESP32 USB串口；正式自动演示建议补充 UART RX、动作完成应答和坐标状态。
当前仓库提供的是CSV拟合工具，自动发动作并采集图片的编排器要等应答通路和
真实方向通过确认后再接入，现阶段不会自动驱动机械臂。

## 10. 标定文件建议

电脑最终生成一个版本化文件；演示镜像默认部署为 `/vision/calibration.ini`：

```ini
[meta]
version=1
validated=0
image_width=640
image_height=480

[camera]
matrix=0,0,0,0,0,0,0,0,0
distortion=0,0,0,0,0

[workspace]
homography=1,0,0,0,1,0,0,0,1
valid_polygon=0,0,639,0,639,479,0,479

[arm]
alignment_axes=x,z
work_zero_x=0
work_zero_y=0
work_zero_z=0
jacobian=0,0,0,0
gripper_target_pixel=0,0
invert_x=0
invert_y=0
invert_z=0
max_x_steps=0
max_y_steps=0
max_z_steps=0

[grasp]
align_deadband_px=30
stable_frames=3
max_align_moves=30
```

所有占位零值必须由实测替换。标定文件还应记录相机安装状态、标定板尺寸、
日期和误差报告，以避免错误参数被用于另一套机械结构。

电脑端工具位于 `VisionArm/tools/visionarm_calibrate/`：

```sh
python3 convert_rgb565.py frame_0000.rgb565 frame_0000.png
python3 calibrate_camera.py --images 'checkerboard/*.png' \
  --columns 9 --rows 6 --square-mm 20 --output calibration.ini
python3 calibrate_workspace.py --points workspace.csv --config calibration.ini
python3 calibrate_arm.py --samples arm.csv --axes x,z \
  --work-zero 1000,2000,1500 --max-steps 8000,9000,10000 \
  --target-pixel 315,238 --config calibration.ini
python3 validate_calibration.py calibration.ini --mark-valid
```

验证工具只有在相机、工作台、机械臂矩阵、拟合误差和三轴实测最大行程均
满足要求时才写入 `validated=1`。

## 11. 积木模型准备

每个类别应采集不同位置、旋转、距离和正常光照变化下的图片，并包含空背景、
相似颜色和非目标物体等负样本。颜色只用于候选定位，最终类别由 XNPU模型
确认。

当前程序要求模型满足：

```text
task        classification
input mode  packed_preload
shape       34×34×3
layout      NCHW
dtype       u8
```

模型输出标签顺序、训练集版本、量化参数和 `.xnpu` SHA256 必须一同记录。
正式启用控制前，先在 SoC 上连续推理至少 100 帧，统计准确率、误触发率、
耗时和稳定性。

## 12. 构建与运行

主机自测：

```sh
make -C VisionArm/linux/visionarm-block test
```

`linux/npu/build.sh` 的 demo 模式会把 `visionarm-block` 静态编译并加入根文件
系统。需要提供现有 VisionArm rootfs：

```sh
NPU_INIT=demo \
VISIONARM_ROOTFS=/path/to/initrd_d \
VISIONARM_CALIBRATION=/path/to/validated-calibration.ini \
./linux/npu/build.sh
```

`VISIONARM_CALIBRATION`是可选项；提供时嵌入为 `/vision/calibration.ini`。
构建脚本不会生成或默认启用占位标定参数。

只观察颜色候选：

```sh
cam on
visionarm-block --color red --loops 100
```

加载专用积木模型但不运动：

```sh
visionarm-block --color red \
  --model /models/blocks_v1.xnpu --class 0 \
  --calibration /vision/calibration.ini --loops 100
```

只有在机器回零、工作零点、方向、工作区和分类模型全部通过验收后，才允许：

```sh
visionarm-block --color red \
  --model /models/blocks_v1.xnpu --class 0 \
  --calibration /vision/calibration.ini --control
```

如果图像误差使机械臂远离目标，立即停止并用 `--invert-x` 或 `--invert-y`
修正方向。不要在运动状态下试错大步数。

## 13. 分阶段验收

### A. 机械安全

- 三路限位极性和方向正确；
- 完整回零连续通过 3～5 次；
- 断开或按住任一限位时能安全失败；
- 普通运动到限位时自动停止；
- 工作零点重复到达且没有结构干涉。

### B. 相机与标定

- `cam test` 通过，帧计数持续增长；
- 原始帧无明显撕裂和缓存一致性问题；
- 内参重投影误差满足要求；
- 桌面检查点误差小于允许抓取误差；
- 摄像头或桌面移动能够被启动检查发现。

### C. XNPU识别

- `/dev/xnpu` 正常，IRQ推理稳定；
- 连续 100 帧无超时和DMA错误；
- 目标类别连续帧稳定；
- 非目标和空场景不会触发动作。

### D. 闭环

- 先只做 XY 对准，不执行 Z 和夹爪；
- 每次只运动 100 步并重新观测；
- 丢失目标或达到 30 次修正后停止；
- 再加入 Z 接近和抓取阈值；
- 抓取后重新识别，确认目标消失或随夹爪移动；
- 最后才加入连续分拣和LCD叠框。

## 14. 当前缺项

- 真实积木数据集和 `blocks_v1.xnpu`；
- OV5640真实标定图片和实测 `calibration.ini`；
- ESP32→FPGA UART RX、动作完成应答和可靠坐标回传；
- 另一端软件行程边界和独立急停命令；
- Z/Y耦合的实测补偿；
- 完整 APPROACH、GRASP、VERIFY、RELEASE 状态机；
- 板卡重新上电后的实际标定和闭环验收。

这些缺项完成以前，当前程序应视为“识别与XY对准原型”，不是无人值守的
完整自动抓取系统。

所有必须依赖真实装置完成的项目见
[闭环演示硬件待确认清单](闭环演示硬件待确认清单.md)。
