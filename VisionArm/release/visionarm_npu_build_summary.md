# VisionArm + NPU FPGA 构建摘要

- 构建工具：Vivado 2023.2
- FPGA：XC7A200T-FBG676-2
- 顶层：`soc_top`
- CPU 时钟：40.000 MHz
- NPU/配置时钟：32.941 MHz
- 综合：0 errors，0 critical warnings
- 布局布线：0 errors，0 critical warnings
- 建立时间：WNS +0.118 ns，TNS 0 ns，0 failing endpoints
- 保持时间：WHS +0.014 ns，THS 0 ns，0 failing endpoints
- LUT：57,110 / 134,600（42.43%）
- FF：59,451 / 269,200（22.08%）
- BRAM：216.5 / 365 tiles（59.32%）
- DSP：149 / 740（20.14%）
- 位流 SHA-256：`576f2dc8144833c959b56a1ec79a29727c48ee74bd6552afad10a5760bd41638`

完整构建可在 `chiplab/fpga/loongson/2023.2` 下执行：

```text
vivado -mode batch -source build_visionarm_npu.tcl
```

说明：50 MHz CPU 在合并后的高拥塞设计中存在约 0.28–0.49 ns 的建立时间违例，
因此整体演示配置采用 40 MHz CPU；NPU 时钟和功能保持不变。
