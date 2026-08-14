# VisionArm + NPU FPGA 构建摘要

- 构建工具：Vivado 2023.2
- FPGA：XC7A200T-FBG676-2
- 顶层：`soc_top`
- CPU 时钟：40.000 MHz
- NPU/配置时钟：32.941 MHz
- 综合：0 errors，0 critical warnings
- 布局布线：0 errors，0 critical warnings
- 建立时间：WNS +0.395 ns，TNS 0 ns，0 failing endpoints
- 保持时间：WHS +0.031 ns，THS 0 ns，0 failing endpoints
- LUT：57,066 / 133,800（42.65%）
- FF：59,438 / 269,200（22.08%）
- BRAM：216.5 / 365 tiles（59.32%）
- DSP：149 / 740（20.14%）
- 位流 SHA-256：`423b7485623ddbe76f584108b581b66be0b3c042bef91334180111fc0d3be166`

完整构建可在 `chiplab/fpga/loongson/2023.2` 下执行：

```text
vivado -mode batch -source build_visionarm_npu.tcl
```

说明：50 MHz CPU 在合并后的高拥塞设计中存在约 0.28–0.49 ns 的建立时间违例，
因此整体演示配置采用 40 MHz CPU；CONFREG 的 CPU 频率标识同步为 40 MHz，
NPU 时钟和功能保持不变。
