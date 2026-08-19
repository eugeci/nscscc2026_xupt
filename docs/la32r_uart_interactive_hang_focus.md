# LA32R Linux 交互式 UART 卡死重点排查清单

日期：2026-08-19

## 适用版本与已知边界

本清单只针对以下已板测组合：

```text
main:           8015b91 及其父提交
core:           444c1db98b33c1c3048184a018b57aa067313530
Chiplab source: dd12226f5a649c17a3f7da96b2a036c97b9e3119
bitstream:      25ae298ff83cdd9d0916e473852347d01b595f99
BIT SHA256:     237c2f69fc0807fcb4ef36727f4ecd969c9c5f73ccaa694e97072c65d4dceef2
```

板测已经完成两个严格正对照：

- 静态 PID 1 的 fork、COW、exec、退出和 wait 全部通过；
- 只替换原 rootfs 的 `/init` 后，原动态 BusyBox shell、`/bin/echo`、
  `/bin/ls /`、动态加载器和 libc 全部通过并返回 `BB2_LS_RC:0`。

因此当前不要再泛查 DDR、TLB、ICache、通用 fork/exec、BusyBox 文件内容或
`ls/getdents`。故障只在 UART 收到交互行后出现，排查必须围绕 RX 中断撤销和
interactive TTY/job-control。

## P0：现有端到端仿真没有覆盖真实失败时序

文件：
`chiplab/chip/soc_demo/loongson/sim/tb_la32r_linux_uart_irq_e2e.sv`

当前测试在 817--847 行明确执行：

1. 接收四字节期间把 IER 写成 `0x00`；
2. 等 `rf_count == 4` 后才写 IER=`0x05`；
3. handler 在 799--804 行固定读取一次 IIR、一次 LSR、四次 RBR。

这与真实 Linux 不同。板上 IER 始终开启，`6c 73 0a` 的字节分时到达；RDA、
RLS、timeout 可能分别进入 handler，8250 依据实时 IIR/LSR 决定读取次数。当前
测试把最可能出现 pending/clear 竞争的时序主动移除了。

### 必须增加的仿真

1. 初始化完成后立即保持 IER=`0x05`，禁止接收期间临时屏蔽。
2. 分别注入单字节、`6c 73 0a`、`20 6c 73 0a`，字节间隔覆盖：小于 timeout、
   等于 timeout、刚大于 timeout 和真实 115200 波特率间隔。
3. handler 必须循环读取 IIR，按 RLS/RDA/TI 原因读取 LSR/RBR，直到 IIR.IP=1；
   禁止写死“四次 RBR”。
4. 每次 ERTN 后继续运行至少 200 个 CPU 周期，断言没有第二次异常入口；再发送
   下一行，覆盖连续 20 行。
5. 在 APB ready/AXI RREADY 上加入随机 backpressure，并扫 CPU/uncore 相位。

通过标准：每个输入字节按顺序只 pop 一次；最后一个 RBR 读后 UART、CDC、
ESTAT 在有限周期内全部清零；每个 burst 不丢、不重、不乱序且无额外 IRQ。

## P0：`rda_int_pnd` 清除条件可能在最后一次 pop 时错过

文件：`chiplab/IP/APB_DEV/URT/uart_regs.v:635-642`

当前逻辑：

```verilog
always @(posedge clk) d1_fifo_read <= fifo_read;

rda_int_pnd <= ((rf_count == {1'b0,trigger_level}) && d1_fifo_read) ? 0 :
               rda_int_rise ? 1 :
               rda_int_pnd && ier[`UART_IE_RDA];
```

高风险点是清除依赖“延迟一拍的 read”和“当前 count 恰好等于 trigger”的组合。
若 `rf_pop`、FIFO count 更新和 `d1_fifo_read` 在 APB 拉长或 push/pop 同拍时错位，
清除拍可能看到 `rf_count==0` 或其他值，`rda_int_pnd` 会在 FIFO 已空时永久保持，
从而令 IRQ18 持续触发。

### 必抓信号

```text
fifo_read, d1_fifo_read, rf_pop, rf_push_pulse
rf_count, trigger_level
rda_int, rda_int_d, rda_int_rise, rda_int_pnd
ti_int, ti_int_rise, ti_int_pnd
int_o, iir, lsr
```

### 必须添加的断言

```text
最后一个 RBR transfer 完成
 -> rf_count 在预期拍变为 0
 -> rda_int_pnd 和 ti_int_pnd 在有限拍内为 0
 -> int_o=0 且 IIR.IP=1
```

修复前先根据波形定义 `count_after_pop`；清除条件应依据完成后的 FIFO 占用量，
不能只把 `==` 猜测性改为 `<=` 而不验证 push/pop 同拍语义。

## P0：拉长 APB read 时一次 RBR transaction 可能产生多个 `rf_pop`

文件：`chiplab/IP/APB_DEV/URT/uart_regs.v:287-296`

当前 `rf_pop` 在 `re` 持续为高时按“置一、清零、再置一”运行：

```verilog
if (rf_pop)
    rf_pop <= 0;
else if (re && addr == `UART_REG_RB && !dlab)
    rf_pop <= 1;
```

若 `PSEL && PENABLE && !PWRITE` 因 wait state 连续保持超过两拍，同一个 APB
访问可能每隔一拍再次产生 `rf_pop`，导致一次 RBR load 消耗两个 FIFO 字节，或
让 pending-clear 与 count 更新错位。现有理想 ready 仿真不足以排除该情况。

必须断言：一个 APB RBR transaction 从 setup 到 completion 只能让 FIFO bottom
递增一次、`rf_count` 减一一次。建议把读副作用绑定到明确的 APB completion
one-shot，而不是直接使用电平 `re`。

同时抓取：

```text
PSEL, PENABLE, PREADY/ack, PADDR, PWRITE
re, fifo_read, rf_pop
FIFO top, bottom, count, data_out
AXI ARVALID/ARREADY/ARADDR/ARSIZE, RVALID/RREADY/RDATA
```

## P1：UART level IRQ 被 CDC 同时当作 level 和 edge replay

文件：`chiplab/chip/soc_demo/loongson/soc_top.v:43-87,1234-1241`

当前所有六路外设中断统一经过：

```verilog
assign irq_dst = level_sync_dst | (event_sync_dst ^ event_seen_dst);
```

UART `int_o` 本来就是 level IRQ，但这里既同步 level，又对每个上升沿生成额外
event pulse。即使它不一定是根因，也可能在 UART level 刚清除时向 CPU 侧补一个
ghost pulse。应区分 level source 与 pulse source；UART 只走 level synchronizer。

另一个覆盖缺口是端到端 TB 的 104--116 行自行实现了简单
`int_sync_meta/int_sync_cpu` 两级同步器，并没有实例化 soc_top 中真实的
`peripheral_irq_cdc`；独立 CDC TB 也没有与 UART pending/ERTN 联动。因此两个
测试分别通过仍不能证明组合链路没有 ghost pulse。

断言：`uart0_int` 撤销后，
`u_peripheral_irq_cdc.level_meta_dst[1]`、`level_sync_dst[1]` 和 `int_out[1]`
在两个目标时钟同步延迟后单调撤销；`event_sync_dst[1]^event_seen_dst[1]`
不得在 handler 清源后补出新的 UART 脉冲。

## P1：ERTN 时 service snapshot 与仍未撤销的 UART level 竞争

文件：
`core/02_Design/rtl/isa/loongarch/loongarch_priv_unit.sv:556-573,616-636,675-680`

core 会把中断入口时的 source 保存在 `irq_service_pending`，直到 ERTN 才清除。
这是为了保证精确中断，但若 UART/CDC 在 ERTN 拍仍为高，
`external_irq_pending` 会重新写入 `csr_estat[9:2]`，导致刚返回立即再次进入 IRQ18。

必须同时观察：

```text
irq_pending[1], irq_pending_d[1]
irq_service_pending[1], irq_service_active
external_irq_pending[1], external_irq_effective[1]
csr_estat[3], csr_ecfg[3], csr_crmd.IE
timer_irq_take, ex_return_fire, csr_era
```

断言：当 8250 handler 已完成最后一个 RBR/LSR/IIR 服务时，ERTN 后不得在没有
新 RX 字节的情况下再次 `timer_irq_take`。若发生重入，先判断源头是 UART
`int_o`、CDC ghost pulse，还是 core snapshot 释放顺序。

## P2：若硬件 IRQ 已完全撤销，再查 interactive ash/TTY

只有波形证明 UART `int_o`、CDC 和 `ESTAT.IS3` 均正常清零后，才继续软件侧：

1. 原 rootfs 自动执行 `read line -> echo marker -> /bin/ls /`；
2. 记录 interactive ash 的 `TCGETS/TIOCSPGRP`、foreground pgrp、`SIGCHLD` 和
   `wait4`，与已通过的非交互脚本比较；
3. marker 不出现：查 canonical read/TTY wakeup；marker 出现但 `ls` 卡住：查
   RX IRQ 抢占或交互 job-control；marker 和 `ls` 都通过：查原 inittab/ctty。

## 建议波形分组

| 分组 | 信号 | 判定 |
|---|---|---|
| UART RX | `rf_push_pulse/rf_pop/rf_count/top/bottom/data_out` | 字节不丢、不重 |
| UART cause | `IER/IIR/LSR/rda_int_pnd/ti_int_pnd/int_o` | 最后读取后清零 |
| APB/AXI | `PSEL/PENABLE/PREADY/PADDR`, `AR/R` | 一个事务一个副作用 |
| CDC | `uart0_int/level_meta/level_sync/event_sync/event_seen` | 无 ghost pulse |
| core IRQ | `irq_pending/service_pending/ESTAT/ERTN/take` | 无 ERTN 后重入 |

第一优先级不是修改代码，而是用“真实 IER 始终开启、字符分时到达、动态读取
IIR”的仿真先复现板上卡死。能够复现后，再在上述 P0 点做单变量修复。
