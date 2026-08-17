# LA32R Linux 下板验证记录

## 固定版本

- 主仓库基线：`origin/main` (`776d1e0`)
- CPU：`core/feature/la32r-mmu` (`715ee5d`)
- Chiplab bring-up 配置：`7062aba`
- Vivado：2023.2
- CPU 时钟：33.333 MHz（系统时钟 100 MHz，DDR 参考时钟 200 MHz）

`core` 不创建额外分支，所有 CPU 修复继续提交到共享的
`feature/la32r-mmu`。主仓库和 Chiplab 的 bring-up 分支只负责固定一次
可复现的下板组合。

## 已通过检查

- NSCSCC VCS RTL 回归：17/17
- Vivado 综合、布局、布线和 bitstream：通过
- 布线后 setup：WNS 0.978 ns，TNS 0 ns
- 布线后 hold：WHS 0.052 ns，THS 0 ns
- 未布线网络：0

当前产物：

```text
chiplab/fpga/nscscc-team/run_vivado/project/loongson.runs/impl_1/soc_top.bit
SHA256 7d1a784eb24ea347fcef24a8e2da810c5cc273ec35c73d3b45b0d5fad70a77a2

chiplab/software/examples/linux/vmlinux
SHA256 d19514524a4e14a290df36f0c7bc16019fb564b75e3ed543c2a53af7edce985a
ELF entry 0xa07b06e0
```

## 重建

```bash
cd chiplab/fpga/nscscc-team/run_vivado
/home/eugeci/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -source create_project.tcl
/home/eugeci/Xilinx/Vivado/2023.2/bin/vivado \
  -mode batch -source bit.tcl
```

`bit.tcl` 使用 4 个并行 job。`create_project.tcl` 会清理 VIO 生成的仿真
netlist，避免其在下一次递归扫描时被错误加入综合。

## 首轮下板判据

1. 下载 `soc_top.bit` 后 PMON 能稳定进入提示符。
2. 通过 TFTP 加载上述基础 `vmlinux`。
3. Linux 串口无异常循环、TLB refill 死循环或 kernel panic。
4. 最终稳定出现 `/ #`。

首轮只验证 CPU、MMU、Cache、AXI、DDR、串口和基础 Linux，不接入
VisionArm、XNPU、LCD 或机械臂驱动。
