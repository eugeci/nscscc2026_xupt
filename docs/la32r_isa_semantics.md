# LA32R 指令语义速查

本文依据《龙架构 32 位精简版参考手册》V1.04（2025 年 2 月）整理。目标是为阅读、RTL 设计和验证提供语义速查；遇到边界行为、编码或例外优先级争议时，仍以仓库中的原 PDF 为准。

## 1. `la32r.md` 转换检查

### 1.1 结论

- 完整性：原 PDF 共 93 个物理页，含前置页以及正文页码 1～82。转换稿可检出目录中的第 1～9 章/附录、全部指令功能小节和正文末尾的指令码表，未发现整章或连续整页缺失。
- 等价性：不具备版式等价性，也不能判定为严格的语义等价文本。正文文字大体保留，但存在足以改变公式、表格和伪码含义的重排。
- 可读性：较差。适合全文检索和辅助定位，不适合直接作为编码、位域、公式或伪码的唯一依据。

### 1.2 主要问题

| 严重度 | 问题 | 典型现象 | 影响 |
| --- | --- | --- | --- |
| 高 | 普通段落被误转为多列表格 | 一个句子被拆到十余个空列中 | 阅读顺序不稳定，复制后可能改变语义 |
| 高 | 上标、下标和幂丢失 | `2^31-1` 类表达式变成 `231-1`，`2^Emin` 被压平 | 数值范围和浮点边界不可直接采用 |
| 高 | 跨页表格断裂 | `FCLASS` 分类表、附录 B 编码行被拆到相邻页 | 位号与含义、指令位域可能错配 |
| 高 | 伪码被表格语法切碎 | 运算符、括号、位选和参数散落到不同单元格 | 不宜自动解析或直接改写成 RTL |
| 中 | 标题未转换为 Markdown 层级 | 正常章节仍为纯文本，伪码注释反而成为 `#` 标题 | 无法生成可靠目录，章节导航困难 |
| 中 | 中英文与数字重排/粘连 | `RDCNTIDCounterID`、`32` 被移到下一行 | 降低可读性，偶尔造成主谓或参数歧义 |
| 中 | 页眉、页脚和页码残留 | 每页重复手册名与页码 | 干扰搜索和后续结构化处理 |
| 中 | 图示退化为散列文本 | 寄存器图、TLB 表项图失去空间关系 | 图中连接关系不能可靠恢复 |

建议：自然语言说明可用 `la32r.md` 检索；指令编码、CSR 位域、FCLASS/FCMP 表、地址翻译伪码和浮点边界必须回看 PDF。

## 2. 通用约定

- `GR[n]`：32 位通用寄存器；`GR[0]` 恒为 0，写入被丢弃。
- `FR[n]`：通常为 64 位浮点寄存器；`.S` 或字整数结果位于 `[31:0]`，高 32 位可为任意值；`.D` 或长整数使用 64 位。
- `CFR[n]`：1 位浮点条件标志。LA32R 基础配置仅定义 `fcc0`。
- `PC`：当前指令地址。顺序执行时前进 4 字节；下文分支目标均以当前指令的 `PC` 为基准。
- 所有指令均为 32 位定长编码，内存采用小端序。
- `SEXT(x,n)`、`ZEXT(x,n)` 分别表示符号扩展、零扩展到 `n` 位；`u32(x)` 表示保留低 32 位。
- 普通 `si12` 地址偏移先符号扩展；分支偏移和 `LL.W/SC.W` 的编码立即数先左移 2 位再符号扩展。汇编中展示的偏移仍以字节为单位。
- PLV0 是特权态，PLV3 是非特权态。基础整数指令可在两者执行；除 `CACOP` 的 Hit 类操作外，基础特权指令只允许在 PLV0 执行。

### 2.1 例外缩写

| 缩写 | 含义 |
| --- | --- |
| `ADEF` | 取指地址错，主要由 PC 非 4 字节对齐产生 |
| `ALE` | 数据访问地址非自然对齐 |
| `SYS` / `BRK` | 系统调用 / 断点例外 |
| `INE` / `IPE` | 指令不存在 / 指令特权等级错 |
| `FPD` / `FPE` | 浮点未使能 / 浮点运算例外 |
| `TLBR` | TLB 重填 |
| `PIF` / `PIL` / `PIS` | 取指 / load / store 页无效 |
| `PPI` / `PME` | 页特权不合规 / 页写允许例外 |

访存相关例外的优先级中，`ALE` 高于 TLB/页相关例外。一次访存至多产生一种 TLB/页相关例外。

## 3. 基础整数指令

### 3.1 算术、比较与逻辑

| 指令 | 汇编形式 | 核心语义与 RTL 核对点 |
| --- | --- | --- |
| `ADD.W` | `add.w rd, rj, rk` | `GR[rd] = u32(GR[rj] + GR[rk])`；忽略进位和有符号溢出，不触发溢出例外。 |
| `SUB.W` | `sub.w rd, rj, rk` | `GR[rd] = u32(GR[rj] - GR[rk])`；忽略借位和有符号溢出。 |
| `ADDI.W` | `addi.w rd, rj, si12` | `GR[rd] = u32(GR[rj] + SEXT(si12,32))`。 |
| `LU12I.W` | `lu12i.w rd, si20` | `GR[rd] = si20 || 12'b0`；与 `ORI` 配合可构造 32 位常数。 |
| `PCADDU12I` | `pcaddu12i rd, si20` | `GR[rd] = u32(PC + (si20 || 12'b0))`；`si20` 拼接后直接按 32 位加法使用。 |
| `SLT` | `slt rd, rj, rk` | 按有符号 32 位比较，`GR[rd] = signed(GR[rj]) < signed(GR[rk]) ? 1 : 0`。 |
| `SLTU` | `sltu rd, rj, rk` | 按无符号 32 位比较，小于写 1，否则写 0。 |
| `SLTI` | `slti rd, rj, si12` | `si12` 符号扩展，随后与 `GR[rj]` 作有符号比较。 |
| `SLTUI` | `sltui rd, rj, si12` | `si12` 仍先符号扩展，再把双方按无符号 32 位比较；不要误做零扩展。 |
| `AND` | `and rd, rj, rk` | `GR[rd] = GR[rj] & GR[rk]`。 |
| `OR` | `or rd, rj, rk` | `GR[rd] = GR[rj] \| GR[rk]`。 |
| `NOR` | `nor rd, rj, rk` | `GR[rd] = ~(GR[rj] \| GR[rk])`，结果限 32 位。 |
| `XOR` | `xor rd, rj, rk` | `GR[rd] = GR[rj] ^ GR[rk]`。 |
| `ANDI` | `andi rd, rj, ui12` | `GR[rd] = GR[rj] & ZEXT(ui12,32)`。 |
| `ORI` | `ori rd, rj, ui12` | `GR[rd] = GR[rj] \| ZEXT(ui12,32)`。 |
| `XORI` | `xori rd, rj, ui12` | `GR[rd] = GR[rj] ^ ZEXT(ui12,32)`。 |
| `NOP` | `nop` | `ANDI r0,r0,0` 的别名；除 `PC += 4` 外无软件可见状态变化。 |
| `MUL.W` | `mul.w rd, rj, rk` | 两个 32 位操作数相乘，写乘积 `[31:0]`；低半结果与把输入视为有符号或无符号无关。 |
| `MULH.W` | `mulh.w rd, rj, rk` | 有符号 32×32，写 64 位乘积 `[63:32]`。 |
| `MULH.WU` | `mulh.wu rd, rj, rk` | 无符号 32×32，写 64 位乘积 `[63:32]`。 |
| `DIV.W` | `div.w rd, rj, rk` | 有符号除法，商写 `rd`；余数截断规则与向零取整一致。除数为 0 时结果任意但不触发除零例外。 |
| `DIV.WU` | `div.wu rd, rj, rk` | 无符号除法，商写 `rd`；除数为 0 时结果任意且无例外。 |
| `MOD.W` | `mod.w rd, rj, rk` | 有符号余数，余数符号与被除数一致，绝对值小于除数绝对值；除数为 0 时结果任意。 |
| `MOD.WU` | `mod.wu rd, rj, rk` | 无符号余数；除数为 0 时结果任意。 |

### 3.2 移位

| 指令 | 汇编形式 | 核心语义 |
| --- | --- | --- |
| `SLL.W` | `sll.w rd, rj, rk` | `GR[rd] = u32(GR[rj] << GR[rk][4:0])`。 |
| `SRL.W` | `srl.w rd, rj, rk` | 32 位逻辑右移，移位量为 `GR[rk][4:0]`。 |
| `SRA.W` | `sra.w rd, rj, rk` | 32 位算术右移并复制符号位，移位量为 `GR[rk][4:0]`。 |
| `SLLI.W` | `slli.w rd, rj, ui5` | 逻辑左移 `ui5` 位。 |
| `SRLI.W` | `srli.w rd, rj, ui5` | 逻辑右移 `ui5` 位。 |
| `SRAI.W` | `srai.w rd, rj, ui5` | 算术右移 `ui5` 位。 |

### 3.3 分支与跳转

| 指令 | 汇编形式 | 条件与动作 |
| --- | --- | --- |
| `BEQ` | `beq rj, rd, offs16` | 若 `GR[rj] == GR[rd]`，则 `PC = PC + SEXT(offs16<<2,32)`。 |
| `BNE` | `bne rj, rd, offs16` | 若不相等则按 `offs16` 跳转。 |
| `BLT` | `blt rj, rd, offs16` | 按有符号数比较，`rj < rd` 时跳转。 |
| `BGE` | `bge rj, rd, offs16` | 按有符号数比较，`rj >= rd` 时跳转。 |
| `BLTU` | `bltu rj, rd, offs16` | 按无符号数比较，`rj < rd` 时跳转。 |
| `BGEU` | `bgeu rj, rd, offs16` | 按无符号数比较，`rj >= rd` 时跳转。 |
| `B` | `b offs26` | 无条件 `PC = PC + SEXT(offs26<<2,32)`。 |
| `BL` | `bl offs26` | 先令 `GR[1] = PC + 4`，再按 `offs26` 作 PC 相对跳转。 |
| `JIRL` | `jirl rd, rj, offs16` | `GR[rd] = PC + 4`，`PC = GR[rj] + SEXT(offs16<<2,32)`；源值必须在写回前读取。目标不对齐将在后续取指触发 `ADEF`。 |

未满足条件的分支仅顺序执行 `PC += 4`。`BL` 固定写 `r1`；`JIRL rd=r0` 可作无链接间接跳转。

### 3.4 普通访存

所有下列普通访存的虚地址均为 `vaddr = GR[rj] + SEXT(si12,32)`，随后完成地址翻译和存储访问类型判定。

| 指令 | 汇编形式 | 数据语义 | 对齐与例外重点 |
| --- | --- | --- | --- |
| `LD.B` | `ld.b rd, rj, si12` | 读 8 位并符号扩展到 32 位。 | 字节天然对齐；可能产生 load 类 TLB/页例外。 |
| `LD.BU` | `ld.bu rd, rj, si12` | 读 8 位并零扩展到 32 位。 | 同上。 |
| `LD.H` | `ld.h rd, rj, si12` | 读 16 位并符号扩展到 32 位。 | 地址 `[0]` 必须为 0，否则 `ALE`。 |
| `LD.HU` | `ld.hu rd, rj, si12` | 读 16 位并零扩展到 32 位。 | 地址 `[0]` 必须为 0。 |
| `LD.W` | `ld.w rd, rj, si12` | 读 32 位写入 `rd`。 | 地址 `[1:0]` 必须为 0。 |
| `ST.B` | `st.b rd, rj, si12` | 把 `GR[rd][7:0]` 写入内存。 | 可能产生 store 类 TLB/页例外。 |
| `ST.H` | `st.h rd, rj, si12` | 把 `GR[rd][15:0]` 写入内存。 | 地址 `[0]` 必须为 0。 |
| `ST.W` | `st.w rd, rj, si12` | 把 `GR[rd][31:0]` 写入内存。 | 地址 `[1:0]` 必须为 0。 |
| `PRELD` | `preld hint, rj, si12` | 预取包含 `vaddr` 的 Cache 行；`hint=0` 为 load 预取到 L1 DCache，`hint=8` 为 store 预取到 L1 DCache。 | 其它 hint、非 cached 地址均按 NOP；不会触发 MMU 或地址相关例外。 |

### 3.5 原子访存

| 指令 | 汇编形式 | 语义与核对点 |
| --- | --- | --- |
| `LL.W` | `ll.w rd, rj, si14` | 地址为 `GR[rj] + SEXT(si14<<2,32)`；读取一个字到 `rd`，记录关联地址并置 `LLbit=1`。要求 4 字节对齐，且 LL/SC 地址属性应为 Cached。 |
| `SC.W` | `sc.w rd, rj, si14` | 使用执行开始时 `GR[rd]` 作为待写数据；仅在 `LLbit=1` 且监视条件仍成立时写入同一地址。把成功标志写回 `rd`：成功为 1，失败为 0。RTL 必须避免写回标志覆盖尚未取用的 store 数据。 |

其它核或一致性 I/O 主设备对被监视 Cache 行完成 store 会清 `LLbit`。执行 `ERTN` 时，若 `CSR.LLBCTL.KLO != 1` 也清除 `LLbit`。非 Cached 地址上的 LL/SC 结果不确定。

### 3.6 栅障与杂项

| 指令 | 汇编形式 | 核心语义 |
| --- | --- | --- |
| `DBAR` | `dbar hint` | 数据访存栅障。`hint=0` 为全栅障：前序 load/store 全部完成后栅障才完成，后序访存只能在栅障完成后开始；未专门实现的其它 hint 必须按 0 处理。 |
| `IBAR` | `ibar hint` | store 与后续取指之间的同步。`hint=0` 保证其后的取指能观察到其前所有 store 的效果。 |
| `SYSCALL` | `syscall code` | 无条件触发 `SYS`；`code` 可供处理程序读取/解释，指令本身不写通用寄存器。 |
| `BREAK` | `break code` | 无条件触发 `BRK`；`code` 作为处理程序参数。 |
| `RDCNTVL.W` | `rdcntvl.w rd` | 把 64 位恒频 `StableCounter[31:0]` 写入 `rd`。 |
| `RDCNTVH.W` | `rdcntvh.w rd` | 把 `StableCounter[63:32]` 写入 `rd`；若软件需要一致的 64 位快照，应自行处理低半回绕。 |
| `RDCNTID` | `rdcntid rj` | 把软件配置的 `CounterID`（即 `CSR.TID`）写入 `rj`。附录编码表写作 `RDCNTID.W`，功能章节汇编名为 `RDCNTID`。 |

## 4. 基础浮点数指令

### 4.1 共同规则

- 浮点功能遵循 IEEE 754-2008。若 `CSR.EUEN.FPE=0`，执行本章指令触发 `FPD`。
- 算术与转换指令可产生 `V/Z/O/U/I`（非法、除零、上溢、下溢、不精确）并更新 `FCSR0.Cause`；未使能的例外累积到 `Flags`，已使能的例外触发 `FPE`，且目标寄存器不修改。
- `FCSR0.RM`：0=最近偶数 RNE，1=向零 RZ，2=向正无穷 RP，3=向负无穷 RM。
- `.S` 读取/写入 FR 低 32 位；`.D` 读取/写入 64 位。位搬运类指令不进行数值解释。

### 4.2 浮点算术

| 指令 | 语义 |
| --- | --- |
| `FADD.S`, `FADD.D` | `fd = fj + fk`，分别按 binary32/binary64 舍入。 |
| `FSUB.S`, `FSUB.D` | `fd = fj - fk`。 |
| `FMUL.S`, `FMUL.D` | `fd = fj * fk`。 |
| `FDIV.S`, `FDIV.D` | `fd = fj / fk`。 |
| `FMADD.S`, `FMADD.D` | 融合计算 `fd = fj*fk + fa`，只进行一次最终舍入。 |
| `FMSUB.S`, `FMSUB.D` | 融合计算 `fd = fj*fk - fa`。 |
| `FNMADD.S`, `FNMADD.D` | 融合计算 `fd = -(fj*fk + fa)`。 |
| `FNMSUB.S`, `FNMSUB.D` | 融合计算 `fd = -(fj*fk - fa)`。 |
| `FMAX.S`, `FMAX.D` | IEEE `maxNum(fj,fk)`。 |
| `FMIN.S`, `FMIN.D` | IEEE `minNum(fj,fk)`。 |
| `FMAXA.S`, `FMAXA.D` | IEEE `maxNumMag`，选择绝对值较大的操作数。 |
| `FMINA.S`, `FMINA.D` | IEEE `minNumMag`，选择绝对值较小的操作数。 |
| `FABS.S`, `FABS.D` | 清除 `fj` 的符号位，其余位保持。 |
| `FNEG.S`, `FNEG.D` | 翻转 `fj` 的符号位，其余位保持。 |
| `FSQRT.S`, `FSQRT.D` | `fd = sqrt(fj)`。 |
| `FRECIP.S`, `FRECIP.D` | `fd = 1.0 / fj`。 |
| `FRSQRT.S`, `FRSQRT.D` | `fd = 1.0 / sqrt(fj)`。 |
| `FCOPYSIGN.S`, `FCOPYSIGN.D` | 数值部分取自 `fj`，符号位取自 `fk`。 |
| `FCLASS.S`, `FCLASS.D` | 对 `fj` 分类并将 one-hot 类别写入 `fd`：bit0=SNaN，1=QNaN，2=-∞，3=负 normal，4=负 subnormal，5=-0，6=+∞，7=正 normal，8=正 subnormal，9=+0；其余位为 0。 |

### 4.3 浮点比较

汇编形式为 `fcmp.<cond>.{s/d} cd, fj, fk`，结果真写 `CFR[cd]=1`，否则写 0。`UN` 表示至少一个操作数为 NaN，`EQ/LT/GT` 表示有序比较结果。`C` 组是 quiet 比较，QNaN 本身不导致非法操作；`S` 组是 signaling 比较，遇到 QNaN 也产生 `V`。

| `<cond>` | 真值集合 | 类型 | `<cond>` | 真值集合 | 类型 |
| --- | --- | --- | --- | --- | --- |
| `CAF` | 恒假 | quiet | `SAF` | 恒假 | signaling |
| `CUN` | UN | quiet | `SUN` | UN | signaling |
| `CEQ` | EQ | quiet | `SEQ` | EQ | signaling |
| `CUEQ` | UN 或 EQ | quiet | `SUEQ` | UN 或 EQ | signaling |
| `CLT` | LT | quiet | `SLT` | LT | signaling |
| `CULT` | UN 或 LT | quiet | `SULT` | UN 或 LT | signaling |
| `CLE` | LT 或 EQ | quiet | `SLE` | LT 或 EQ | signaling |
| `CULE` | UN、LT 或 EQ | quiet | `SULE` | UN、LT 或 EQ | signaling |
| `CNE` | LT 或 GT | quiet | `SNE` | LT 或 GT | signaling |
| `COR` | LT、EQ 或 GT | quiet | `SOR` | LT、EQ 或 GT | signaling |
| `CUNE` | UN、LT 或 GT | quiet | `SUNE` | UN、LT 或 GT | signaling |

每个条件各有 `.S` 和 `.D` 两条形式，共 44 个具体比较助记符。

### 4.4 浮点转换

| 指令 | 语义 |
| --- | --- |
| `FCVT.S.D` | binary64 转 binary32，按 `FCSR.RM` 舍入。 |
| `FCVT.D.S` | binary32 转 binary64。 |
| `FFINT.S.W`, `FFINT.D.W` | 把 `fj[31:0]` 解释为有符号 32 位整数，转换为单/双精度。 |
| `FFINT.S.L`, `FFINT.D.L` | 把 `fj[63:0]` 解释为有符号 64 位整数，转换为单/双精度。 |
| `FTINT.W.S`, `FTINT.W.D` | 按 `FCSR.RM` 把单/双精度转换为有符号 32 位整数，结果放在 `fd[31:0]`。 |
| `FTINT.L.S`, `FTINT.L.D` | 按 `FCSR.RM` 转换为有符号 64 位整数，结果放在 `fd[63:0]`。 |
| `FTINTRM.W.S`, `FTINTRM.W.D`, `FTINTRM.L.S`, `FTINTRM.L.D` | 固定向负无穷舍入后转为 W/L。 |
| `FTINTRP.W.S`, `FTINTRP.W.D`, `FTINTRP.L.S`, `FTINTRP.L.D` | 固定向正无穷舍入。 |
| `FTINTRZ.W.S`, `FTINTRZ.W.D`, `FTINTRZ.L.S`, `FTINTRZ.L.D` | 固定向零舍入。 |
| `FTINTRNE.W.S`, `FTINTRNE.W.D`, `FTINTRNE.L.S`, `FTINTRNE.L.D` | 固定向最近偶数舍入。 |

转换到整数时使用 IEEE `convertToIntegerExact...` 行为，即仍检测不精确例外。W/L 定点数据位于浮点寄存器文件，不是通用寄存器；这也是 LA32R 中仍存在 `.L` 转换的原因。

### 4.5 浮点搬运与选择

| 指令 | 语义与关键边界 |
| --- | --- |
| `FMOV.S` | `FR[fd][31:0] = FR[fj][31:0]`；不产生 IEEE 浮点例外。 |
| `FMOV.D` | `FR[fd] = FR[fj]`。 |
| `FSEL` | `FR[fd] = CFR[ca] ? FR[fk] : FR[fj]`，按完整 FR 位宽选择。 |
| `MOVGR2FR.W` | `FR[fd][31:0] = GR[rj]`；高 32 位为任意值。 |
| `MOVGR2FRH.W` | `FR[fd][63:32] = GR[rj]`；低 32 位保持不变。 |
| `MOVFR2GR.S` | `GR[rd] = FR[fj][31:0]`。 |
| `MOVFRH2GR.S` | `GR[rd] = FR[fj][63:32]`。 |
| `MOVGR2FCSR` | 用 `GR[rj]` 更新所选 FCSR 的软件可写域；若写后 `Cause & Enables != 0`，该搬运本身也不触发 `FPE`。不存在的 FCSR 编号结果不确定。 |
| `MOVFCSR2GR` | 把所选 FCSR 的 32 位读值写入 `GR[rd]`。 |
| `MOVFR2CF` | `CFR[cd] = FR[fj][0]`。 |
| `MOVCF2FR` | `FR[fd] = ZEXT(CFR[cj],64)`；除 bit0 外全部清零。 |
| `MOVGR2CF` | `CFR[cd] = GR[rj][0]`。 |
| `MOVCF2GR` | `GR[rd] = ZEXT(CFR[cj],32)`；除 bit0 外全部清零。 |

### 4.6 浮点分支与访存

| 指令 | 语义 |
| --- | --- |
| `BCEQZ` | `CFR[cj]==0` 时，`PC = PC + SEXT(offs21<<2,32)`。 |
| `BCNEZ` | `CFR[cj]!=0` 时按 `offs21` 跳转。 |
| `FLD.S` | 从 `GR[rj]+SEXT(si12)` 读取 32 位到 `FR[fd][31:0]`；地址须 4 字节对齐，高 32 位任意。 |
| `FLD.D` | 读取 64 位到 `FR[fd]`；地址须 8 字节对齐。 |
| `FST.S` | 把 `FR[fd][31:0]` 写入内存；地址须 4 字节对齐。 |
| `FST.D` | 把 `FR[fd][63:0]` 写入内存；地址须 8 字节对齐。 |

浮点访存还可能产生与对应整数 load/store 相同的 TLB/页例外；非对齐先报 `ALE`。

## 5. 基础特权指令

除特别说明外，本节指令只允许 PLV0，PLV3 执行触发 `IPE`。

### 5.1 CSR 访问

| 指令 | 汇编形式 | 语义 |
| --- | --- | --- |
| `CSRRD` | `csrrd rd, csr_num` | `GR[rd] = CSR[csr_num]`。未定义或未实现 CSR 读回 0。 |
| `CSRWR` | `csrwr rd, csr_num` | 原子交换：先保存 `old=CSR`，用原 `GR[rd]` 更新 CSR 的可写位，再令 `GR[rd]=old`。未实现 CSR 不改变状态且 `rd=0`。 |
| `CSRXCHG` | `csrxchg rd, rj, csr_num` | `old=CSR`；对 `GR[rj]` 掩码为 1 且 CSR 可写的位写入原 `GR[rd]` 对应位，其余位保持；最后 `GR[rd]=old`。 |

CSR 相关 RAW/WAR/WAW 冲突必须由硬件维护，软件无需插入栅障。

### 5.2 Cache 维护

`CACOP code,rj,si12` 使用 `VA=GR[rj]+SEXT(si12,32)`：`code[2:0]` 选择 Cache（0=L1 ICache，1=L1 DCache，2=L2 共享混合 Cache），`code[4:3]` 选择操作。

| `code[4:3]` | 操作 |
| --- | --- |
| `0` | StoreTag 初始化：按 VA 中的路号/索引直接定位并把指定行 tag 置 0。 |
| `1` | IndexInvalidate / InvalidateAndWriteback：直接索引无效化；数据/混合 Cache 还执行必要写回。 |
| `2` | HitInvalidate / HitInvalidateAndWriteback：像 load 一样查询 VA，命中才维护；可能触发 TLB/页例外，但不检查自然对齐。此 Hit 类允许 PLV3 执行。 |
| `3` | 实现自定义，架构不规定统一功能。 |

### 5.3 TLB 维护

| 指令 | 语义与关键状态更新 |
| --- | --- |
| `TLBSRCH` | 用 `CSR.ASID.ASID` 与 `CSR.TLBEHI.VPPN` 查询 TLB。命中：`TLBIDX.Index=命中索引`、`NE=0`；未命中：`NE=1`。 |
| `TLBRD` | 用 `TLBIDX.Index` 读项。有效项把 ASID、VPPN、PS、ELO0/1 写回对应 CSR 并令 `NE=0`；无效项令 `NE=1`，并把 ASID、TLBEHI、ELO0/1、PS 清 0。索引越界结果不确定。 |
| `TLBWR` | 把 ASID、TLBEHI、TLBELO0/1、TLBIDX.PS 组成的项写到 `TLBIDX.Index`。若 `ESTAT.Ecode==0x3f`（TLB 重填处理），项强制有效；否则项有效位 `E=!TLBIDX.NE`。 |
| `TLBFILL` | 数据来源及有效位规则与 `TLBWR` 相同，但目标项由硬件随机选择。 |
| `INVTLB` | 按 `op`、`GR[rj][9:0]` 指定 ASID 和 `GR[rk]` 指定 VA 无效化 TLB；未定义 `op` 触发 `INE`。 |

`INVTLB` 操作表：

| `op` | 无效化条件 |
| --- | --- |
| `0x0`, `0x1` | 所有项。 |
| `0x2` | 所有 `G=1` 项。 |
| `0x3` | 所有 `G=0` 项。 |
| `0x4` | `G=0 && ASID==rj[9:0]`。 |
| `0x5` | `G=0 && ASID==rj[9:0] && VA匹配rk`。 |
| `0x6` | `(G=1 || ASID==rj[9:0]) && VA匹配rk`。 |

### 5.4 其它特权指令

| 指令 | 语义与 RTL 核对点 |
| --- | --- |
| `ERTN` | `CRMD.PLV=PRMD.PPLV`、`CRMD.IE=PRMD.PIE`、`PC=ERA`。若 `ESTAT.Ecode==0x3f`，还令 `CRMD.DA=0, PG=1`。若 `LLBCTL.KLO!=1` 则清 `LLbit`；无论原值如何，KLO 影响本次后由硬件自动清 0。 |
| `IDLE` | 执行后停止取指，等待中断唤醒或复位。由中断唤醒后从 `IDLE` 的下一条指令继续；若中断随后被响应，按正常中断机制转入入口。`level` 为实现相关提示。 |

## 6. RTL 实现时最容易出错的点

1. `SLTUI` 的 `si12` 是符号扩展，不是零扩展。
2. `JIRL`、`CSRWR`、`CSRXCHG`、`SC.W` 都存在“同一寄存器既是旧值输入又是新值输出”的时序要求。
3. 分支和 LL/SC 的编码偏移左移 2 位；汇编偏移已经以字节表示，不应重复乘 4。
4. `r0` 读恒为 0、写丢弃，但指令的其它副作用（跳转、访存、例外、CSR 写等）不能因此取消。
5. `PRELD` 不产生地址/MMU 例外；普通 load/store 和浮点访存会产生。
6. `ALE` 在访存 TLB/页例外之前判定。
7. `TLBWR/TLBFILL` 在 TLB 重填处理期间强制写有效项，忽略 `TLBIDX.NE`。
8. `ERTN` 不只恢复 PLV/IE；TLB 重填返回时还恢复 DA/PG，并按 KLO 规则处理 LLbit。
9. 单精度结果只保证 FR 低 32 位，高 32 位不要加入架构可见断言。
10. `MOVCF2FR`、`MOVCF2GR` 会把目标中除 bit0 外的所有位清零，不是保持原值。
11. 浮点融合乘加只能进行一次最终舍入，不能等价替换成独立乘法再加法。
12. 附录 B 的转换稿存在跨页错位；译码常量应从原 PDF 逐行复核，不能直接解析 `la32r.md`。
