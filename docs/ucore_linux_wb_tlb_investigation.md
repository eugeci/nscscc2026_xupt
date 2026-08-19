# uCore/Linux 差异、WB repair 与 TLB/MAT 排查结论

更新时间：2026-08-19

## 结论先行

目前至少有两个相互独立的问题，不能用“uCore 能工作”直接推出 Linux 镜像
或硬件一定正确：

1. **Linux 串口 RX 首嫌是中断链，不是 DDR。** uCore 当前 shell 的 stdin
   关闭本地中断后轮询 `cons_getc()`；Linux 8250 则依赖 FIFO、RDA/receiver
   timeout 中断、IRQ18、TTY flip buffer 和 line discipline。板上已经出现
   `ttyS ttyS0: input overrun(s)`，说明字符进入 UART，RLS 中断也至少偶尔到达
   Linux，但普通 RDA/timeout 中断没有及时把 FIFO 排空。
2. **uCore 的所谓 MAT=0 对照尚未成立。** 板上 RI 诊断打印的 `Code PTE` 为
   `...005`，但 uCore 定义 `PTE_PCD=0x010`。如果可执行页确实带 PCD，PTE
   低位至少应为 `...015`。因此现有结果不能证明 `MAT=0` 已进入 TLB，更不能
   据此断言 TLB→ICache 的 MAT 传播错误。
3. **WB repair 仍有一个需要定向仿真的 entry-edge 所有权窗口。** core
   `6e5d375` 只在 EX 已阻塞后锁存 live WB 数据；若消费者在同一个上升沿进入
   EX、旧 load A 离开 WB、下一条 load B 写入 WB，并且消费者紧接着停顿，
   当前保持器可能在下一拍锁存 B，而不是属于该消费者的 A。现有 smoke test
   没有覆盖这个相位。

优先级建议：先用软件 A/B 闭环 Linux RX；同时修正 uCore uncached 镜像并打印
PTE/TLBELO；最后用下面的 entry-edge 用例验证 WB repair。三条可以并行，但
不能把任一条的临时绕过当成另外两条已经修复。

## 为什么 uCore 可以输入而 Linux 不行

uCore 的 `dev_stdin_read()` 最终反复调用 `cons_getc()`。当前实现会临时关闭
本地中断、主动调用 `serial_intr()` 轮询 IIR/RBR，然后一直等到拿到字符。
因此它不依赖以下任何一环：

```text
UART RDA/timeout interrupt
 -> uncore→cpu CDC
 -> ESTAT.IS3 / ECFG.LIE3 / CRMD.IE
 -> timer_irq_request/hold/take
 -> Linux IRQ18 / 8250 ISR
 -> TTY flip buffer / canonical newline
```

Linux 的串口输出能工作只证明 TX/MMIO 基本可用；提示符后没有命令响应，且
出现 input overrun，反而很符合“RX FIFO 收到字符但 IRQ 服务过晚”的特征。

### 可以先做的软件 A/B

按风险从低到高执行：

1. 把 8250 RX trigger 临时设成 1 byte，或在端口初始化后关闭 FIFO。若马上
   可交互，根因锁定在 UART timeout/trigger 兼容，而不是 TLB/WB repair。
2. 在 LA32R 8250 驱动中临时增加低频 polling：当 console read 阻塞时读取
   `LSR.DR`，有数据就读 RBR 并送入 tty flip buffer。若 polling 可用而 IRQ
   版本不可用，硬件排查只需集中在 IRQ 路径。
3. 保留自动 initramfs 作为比赛保底：PID 1 自动执行目录和 VisionArm 外设
   测试并永久保活，不依赖串口 RX。工具位于 `tools/linux_auto_init/`。

Linux 5.14 的最小 trigger=1 A/B 可在 `drivers/tty/serial/8250/8250_port.c`
找到 `PORT_16550A` 的 `uart_config` 项，将：

```c
.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_10,
```

临时改为：

```c
.fcr = UART_FCR_ENABLE_FIFO | UART_FCR_R_TRIG_00,
```

重新编译同一 kernel，其余配置、initramfs 和 bitstream 均保持不变。若该源码
树的初值写法不同，应在 `serial8250_do_set_termios()` 后确认最终写入 FCR 的
trigger bits 为 `00`，不要仅凭补丁能编译就认定 A/B 已生效。

软件 workaround 不能替代硬件闭环。仿真仍需逐级观察：

```text
rf_count / LSR.DR / IER / IIR / rda_int_pnd / ti_int_pnd
uart0_int / irq_pending[1] / ESTAT.IS3 / ECFG.LIE3 / CRMD.IE
timer_irq_request / timer_irq_hold / id_valid / frontend_flush
pipeline_empty / timer_irq_take / EENTRY / Linux IRQ18 / RBR read
```

当前 `timer_irq_ctrl` 对所有中断复用同一控制器，只有
`timer_irq_request && id_valid` 才置位 hold，而且任意 `frontend_flush` 都会清
hold。这必须覆盖连续分支 flush、ICache stall、IDLE 和外部 level IRQ，否则
RDA/timeout 可能被长时间推迟。外部 IRQ 还必须先在 CPU 时钟域做明确的两级
level 同步。

## uCore uncached 页实验必须先纠正

软件定义和填 TLB 逻辑为：

```c
#define PTE_PCD 0x010

if ((pte & PTE_PCD) == 0)
    tlbelo |= LOONGARCH_TLB_MAT_CO; /* bit 4 */
```

`load_icode()` 的预期补丁是在 ELF 可执行段对应页上设置 `PTE_PCD`。但现有
板上日志为：

```text
Code PTE = 0xa012d005
```

`0x005` 不含 `0x010`，因此该页仍会在 `pte2tlblow()` 中附加 cached MAT。
这更像以下软件/构建问题之一：

- 加载的 ELF 不是带补丁的那一份，或 TFTP 同名文件没有更新；
- 构建时走了另一套 `load_icode()` 条件分支；
- 设置 PCD 后，PTE 在后续映射/复制路径被覆盖；
- 诊断打印的 PTE 不是最终被 refill 的 PTE。

下一版软件必须同时满足以下验收，缺一不可：

1. `load_icode()` 分配可执行页后打印最终 PTE，低位必须为 `...015`；
2. TLB refill 前打印输入 PTE 和生成的 TLBELO；
3. refill 后执行 `TLBSRCH + TLBRD`，确认实际选中的偶/奇页 TLBELO
   `MAT[5:4]=00`；
4. 仿真确认 `mmu_inst_mat=0` 且 `irom_req_cacheable=0`。

只有前 3 项成立后，板上“第一次 ls 仍 RI”才有资格用于判断
TLB/ICache/AXI uncached 取指路径。此前文档里“MAT=0 仍失败”的结论应视为
无效实验，而不是硬件证据。

### TLB 定向测试

建立一对相邻 4 KiB 页，偶页和奇页使用不同 PPN、不同 MAT，并放置不同的
已知指令序列。分别从 `VA[12]=0/1` 执行，检查：

```text
TLB hit index / selected ELO0 or ELO1 / selected PPN / selected MAT
mmu_inst_paddr / mmu_inst_mat / irom_req_cacheable
AXI ARADDR / RDATA / frontend instruction
```

然后在 ASID 切换、`INVTLB`、`TLBFILL` 后重复。这样能一次覆盖奇偶页选择、
ASID 和 MAT 传播，避免只看最终 RI 猜测 MMU。

## WB repair entry-edge 窗口

core `6e5d375` 的核心逻辑是：

```systemverilog
if (!rst_n || ex_flush)
    hold_valid <= 1'b0;
else if (ex_allowin)
    hold_valid <= 1'b0;
else if (ex_any_wb_repair && !hold_valid) begin
    hold_valid <= 1'b1;
    hold_data  <= wb_load_data_ex;
end
```

风险时序如下：

```text
cycle N before edge: WB=A，ID consumer(A)，EX allowin=1
posedge N:          consumer 进入 EX；WB 同时可更新为 B；hold 因 allowin 被清
cycle N+1:          consumer 因 LSU/MMU/下游反压停在 EX，repair tag 仍为 A
posedge N+1:        第一次 capture 看到 live WB=B，并把 B 绑定给 consumer(A)
```

这正是“repair tag 属于 EX token，但 repair data 来自全局 live WB bus”的所有权
不一致。`63041c7` 把逻辑独立成模块并加强了命名/测试，但保持器的优先级和捕获
条件仍需用上述相位验证；不能仅凭现有 smoke PASS 宣布窗口不存在。

### 必须增加的仿真用例

1. load A 在 WB，依赖 A 的 ALU/LSU/store consumer 在同拍 ID→EX；
2. 同一个上升沿让 load B 进入 WB；
3. consumer 进入 EX 后立即施加 2～4 拍 stall；
4. 分别覆盖 rs1、rs2、ALU src1/src2、store data、LSU address 和 slot1；
5. 在 stall 每一拍断言 consumer 使用 A，且 repair data 对同一 EX token 稳定；
6. 再覆盖 flush，确认旧 A 不会泄漏到新 token。

建议的结构性修复是把 repair value 在 `id_to_ex_fire` 时直接装入 ID/EX payload，
使 tag 和 data 一起随 token 前进；如果仍使用旁路保持器，则必须有明确的
`entry_capture` 输入，并让“新 token 入 EX 时捕获 A”优先于简单清 hold。

示意断言：

```systemverilog
assert property (@(posedge clk) disable iff (!rst_n)
  ex_token_stalled && $past(ex_token_stalled) && ex_repair_valid
  |-> $stable(ex_wb_repair_data));

assert property (@(posedge clk) disable iff (!rst_n)
  id_to_ex_fire && id_repair_valid
  |=> ex_repair_data == $past(wb_load_data_ex));
```

## D-cache/CACOP 与 I-cache 后续判定

当且仅当 PTE/TLBELO/MAT 的软件证据正确后，再按下列边界定位第一次 `ls`：

| 第一次分歧 | 判断 |
| --- | --- |
| 最终 PTE 不是 `...015` | uCore 构建/映射错误 |
| TLBELO.MAT=0，但 `mmu_inst_mat` 非 0 | TLB 奇偶页/MAT 选择错误 |
| `mmu_inst_mat=0`，但 `irom_req_cacheable=1` | CPU 顶层属性传播错误 |
| AXI RDATA 正确，frontend instruction 错 | ICache uncached/旧 refill 所有权错误 |
| AXI RDATA 已错 | AXI response 归属、DDR 地址或缓存写回错误 |
| cached 页在 CACOP 后仍读旧值 | D-cache way/line、maintenance accept/done 或写回错误 |

Linux 已经能完成 MMU 初始化、用户态启动、串口 TX 和自动 PID 1，说明 DDR、
TLB 和异常路径不是“完全不可用”。但 Linux 对页表/ASID、I/D cache、外部中断
和并发流水的覆盖远强于 uCore polling shell，因此仍可能更早暴露这些边角窗口。

## 建议执行顺序

1. **软件组今天可做：** 8250 trigger=1/关 FIFO A/B；使用自动 initramfs 跑
   `ls + camera + LCD + heartbeat`；重编 uCore 并确保 PTE 打印为 `...015`。
2. **RTL 组第一组波形：** UART RX 到 IRQ take 全链路；优先判断是 UART
   timeout 还是 `timer_irq_ctrl`/CDC。
3. **RTL 组第二组波形：** WB A→B 同拍切换 + consumer entry-edge stall。
4. **RTL 组第三组波形：** 偶/奇页不同 MAT 的 TLB→ICache→AXI 定向测试。

最终通过标准不是“第二次 ls 成功”，而是冷复位后 uCore 第一次 exec 成功；
Linux 则既要自动测试通过，也要在恢复 IRQ 方案后无 overrun 地交互输入。

## 8250 trigger=1 镜像已构建（2026-08-19）

已在独立 Ubuntu 源码副本中应用：

```text
linux/patches/0003-8250-force-16550a-rx-trigger-1-for-ab-test.patch
```

构建使用原板测环境的 LA32R GCC 8.3/Binutils 2.31.1、同一 NAND-disabled
配置和 initramfs。验收结果：

```text
release: 5.14.0-rc2-uart-rxtrig1
entry:   0xa07c4d78
NAND:    ls1a_nand_init symbol absent
size:    9854900 bytes
sha256:  58779f0f98f3d23c4ac8d230dae78ea3bc5ee953bb807c40ffde5810d7b43d82
```

Windows TFTP 文件名为 `vmlinux_nand_disabled_rxtrig1_stripped`，启动命令：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_nand_disabled_rxtrig1_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f
g
```

提示符出现后只发送一次 `ls` 和回车：

- 能立即执行且无 overrun：UART RDA trigger=1 可用，优先修 UART timeout；
- 仍 overrun/无响应：不是 FIFO 阈值过高这一单点，继续查 `uart0_int`、CDC、
  `timer_irq_hold/take` 和 Linux IRQ18；
- 连提示符都到不了：先检查启动版本是否包含 `-uart-rxtrig1`，不要把不同
  initramfs/旧 TFTP 同名文件造成的启动差异算进 RX A/B。
