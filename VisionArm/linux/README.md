# Linux 侧文件

## 已提供工具

- `tools/arm`：机械臂控制，安装为 `/usr/bin/arm` 或 `/usr/bin/armctl`。
- `tools/cam`：摄像头 DMA 控制，安装为 `/usr/bin/cam` 或 `/usr/bin/camctl`。
- `tools/lcdctl`：LCD 控制和 DDR 静态图显示。
- `snake/snake.c`：贪吃蛇源码。
- `visionarm-block/`：颜色候选、XNPU 积木分类与安全 XY 对准程序。
- `assets/naruto_800x480.rgb565`：800x480 RGB565 LCD 测试图。

## 当前已验证命令

```sh
cam status
cam on
arm status
arm x forward 200
arm y up 200
arm grip open
arm home
lcdctl status
lcdctl show
snake
```

`arm home` 使用 ESP32 上的 X/Y/Z 三路限位开关，将限位位置定义为
`(0,0,0)`。当前 FPGA 机械臂 UART 只有发送通道，所以需要从 ESP32 USB
串口确认出现 `DONE HOME`。

`visionarm-block` 默认只观察，不会驱动电机；只有同时提供专用积木分类
模型和 `--control` 时才会发出 100 步的 XY 对准命令。

已编译的 Linux 内核不提交到 Git 历史，请从 GitHub Release 下载。`vmlinux_lcd`
含 `arm`、`cam`、`lcdctl`；`vmlinux_vision_snake_run` 是较早的贪吃蛇集成镜像，二者不是同一个最终统一镜像。
