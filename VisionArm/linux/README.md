# Linux 侧文件

## 已提供工具

- `tools/arm`：机械臂控制，安装为 `/usr/bin/arm` 或 `/usr/bin/armctl`。
- `tools/cam`：摄像头 DMA 控制，安装为 `/usr/bin/cam` 或 `/usr/bin/camctl`。
- `tools/lcdctl`：LCD 控制和 DDR 静态图显示。
- `snake/snake.c`：贪吃蛇源码。
- `assets/naruto_800x480.rgb565`：800x480 RGB565 LCD 测试图。

## 当前已验证命令

```sh
cam status
cam on
arm status
arm x forward 200
arm y up 200
arm grip open
lcdctl status
lcdctl show
snake
```

已编译的 Linux 内核不提交到 Git 历史，请从 GitHub Release 下载。`vmlinux_lcd`
含 `arm`、`cam`、`lcdctl`；`vmlinux_vision_snake_run` 是较早的贪吃蛇集成镜像，二者不是同一个最终统一镜像。

