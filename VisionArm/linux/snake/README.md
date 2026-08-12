# VisionArm Snake

`snake.c` 是面向当前 VisionArm Linux 与 FPGA VGA 文本终端的贪吃蛇。
程序只使用标准 C/POSIX 接口，不依赖 ncurses。

在 Ubuntu 虚拟机中交叉编译：

```sh
loongarch32r-linux-gnusf-gcc -O2 -Wall -Wextra \
  -o snake snake.c
loongarch32r-linux-gnusf-strip snake
file snake
```

控制键：

- `W/A/S/D` 或方向键：移动
- `P`：暂停/继续
- `Q` 或 `Ctrl+C`：退出

首次测试建议通过 TFTP 放到 `/tmp/snake`，验证后再加入 initramfs 的
`/usr/bin/snake`。
