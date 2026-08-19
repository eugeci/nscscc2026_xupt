# VisionArm + NPU FPGA 构建摘要

- 构建工具：Vivado 2023.2
- FPGA：XC7A200T-FBG676-2
- 顶层：`soc_top`
- CPU 时钟：40.000 MHz
- NPU/配置时钟：33.143 MHz
- VGA 时钟：50.435 MHz（内部二分频为约 25.217 MHz 像素节拍）
- 综合：0 errors，0 critical warnings
- 布局布线：0 errors，0 critical warnings
- 建立时间：WNS +0.214 ns，TNS 0 ns，0 failing endpoints
- 保持时间：WHS +0.001 ns，THS 0 ns，0 failing endpoints
- LUT：57,091 / 133,800（42.67%）
- FF：59,437 / 269,200（22.08%）
- BRAM：216.5 / 365 tiles（59.32%）
- DSP：149 / 740（20.14%）
- 位流 SHA-256：`0ac03ff7fe8c3da8bcdf8af53a9680b69788110604f1ec628015dcb88922ab24`

完整构建可在 `chiplab/fpga/loongson/2023.2` 下执行：

```text
vivado -mode batch -source build_visionarm_npu.tcl
```

说明：50 MHz CPU 在合并后的高拥塞设计中存在约 0.28–0.49 ns 的建立时间违例，
因此整体演示配置采用 40 MHz CPU；VGA 使用独立的约 50.435 MHz 时钟，避免随
CPU 降频后产生显示器不支持的约 47.6 Hz 帧率。CONFREG 的 CPU 频率标识为 40 MHz，
NPU 功能保持不变。
