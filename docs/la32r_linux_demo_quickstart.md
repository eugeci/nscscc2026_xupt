# LA32R Linux LCD/摄像头演示快速使用

## 1. PMON 启动

每次板卡复位后，PMON 中的网卡 IP 都需要重新配置：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_rxtrig1_interactive_ctty2_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f_rxtrig1_init
g
```

内核镜像信息：

```text
file:   vmlinux_rxtrig1_interactive_ctty2_stripped
size:   9854900
sha256: d138c350c1c703c2f057c7cdbd3d547b81cc1da0c54645056c76db6b6914bee9
entry:  0xa07c4d78
```

正常启动会打印 `INIT_CP1` 至 `INIT_CP5`，最后进入 `/ #`。

## 2. 最小演示流程

进入 Linux 后依次执行：

```sh
ls
lcdctl show
devmem 0x1fd0e100 32 1
```

三条命令的作用：

1. `ls`：确认交互 shell、UART RX/TX、BusyBox 和文件系统正常；
2. `lcdctl show`：把 `/vision/naruto.rgb565` 写入 DDR `0x07800000`，并请求 LCD 显示；
3. `devmem 0x1fd0e100 32 1`：启动摄像头 DMA，并选择摄像头显示通路。

顺序不要颠倒：复位后先执行 `lcdctl show`，再开启摄像头。

## 3. 成功判据

LCD 正常时会看到：

```text
lcdctl: frame requested
lcdctl: image displayed
```

摄像头启动后可使用原始寄存器读取验证：

```sh
devmem 0x1fd0e100 32
devmem 0x1fd0e104 32
devmem 0x1fd0e108 32
sleep 1
devmem 0x1fd0e108 32
```

成功条件：

- control 读回 `0x00000001`；
- activity 两次读取持续增加；
- LCD/VGA 出现摄像头画面。

2026-08-19 已验证的一次板测数据：

```text
control:  0x00000001
status:   0xc53a78fb
activity: 0x000006ce -> 0x000009ab
result:   camera image displayed normally
```

## 4. 停止摄像头

```sh
devmem 0x1fd0e100 32 0
```

## 5. 稳定性复测

每轮完整复位并重新执行 PMON 启动流程，至少连续运行 5 轮。
每轮记录：

```text
round:
INIT_CP1..CP5: PASS/FAIL
ls:            PASS/FAIL
lcdctl show:   PASS/FAIL
camera start:  PASS/FAIL
activity grow: PASS/FAIL
image output:  PASS/FAIL
```

如果 TFTP 报 `can't assign requested address`，先重新执行
`ifconfig dmfe0 192.168.1.101`。PMON 打印的 NAND bad eraseblock 信息与
TFTP/Linux 演示无关。

旧的 `cam on`/`cam status` 脚本含有更多 shell command substitution 和状态
解码步骤。在该脚本完成简化前，正式演示优先使用已验证的
`devmem 0x1fd0e100 32 1`。
