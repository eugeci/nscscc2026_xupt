# SoC 展示内容

## 内容

- `myCPU/`：最终提供的平铺自研 LA32R CPU RTL，共 56 个文件。
- `chiplab/`：从 `chiplab@25ae298` 导出的受版本控制硬件环境，包含
  `IP/`、`chip/`、`fpga/loongson/`、许可证和原始说明。
- `bit/soc_top.bit`：当前自研 LA32R CPU、VisionArm 外设和 NPU 合并设计位流。
- `reports/`：预构建说明、布局布线时序和资源利用率报告。

## 主要硬件参数

- FPGA：XC7A200T-FBG676-2
- 主 bit 记录的 CPU 基线：`core@444c1db98b33c1c3048184a018b57aa067313530`
- CPU 时钟：40 MHz
- NPU/SoC 时钟：约 33.143 MHz
- VGA 时钟：约 50.435 MHz
- NPU 物理地址：`0x1f100000`

`chiplab/IP/myCPU` 保留相对路径标记 `../../myCPU`。`prepare_visionarm_npu.tcl` 和
`build_la32r_linux.tcl` 已改为直接读取平铺的 `.sv`/`.v` 文件，不再依赖仓库外的
`core/02_Design` filelist。

主 bit 的实现结果为 WNS `+0.214 ns`、TNS `0 ns`、WHS `+0.001 ns`、THS `0 ns`。
详细信息见 `reports/visionarm_npu_build_summary.md`。

## 重建说明

原构建入口为：

```sh
cd chiplab/fpga/loongson/2023.2
vivado -mode batch -source build_la32r_linux.tcl
```

该脚本使用本交付包的 `myCPU/` 平铺 RTL。提交前已确认提供目录和交付目录的
56 个文件名称及 SHA-256 内容逐一相同。

## 验证边界

提交的 `soc_top.bit` 已用于 PMON 交接和 Linux 启动，并完成 `ls`、LCD 图片显示、
摄像头启动及 XNPU 轮询 DMA 推理验证。机械臂闭环、NPU 中断模式和长时间压力
测试仍应在决赛现场按硬件接线情况复核。

当前没有提交 `.ltx`：暂存包原有探针文件来自另一份 bitstream，继续保留会造成
VIO 探针与主 bit 错误关联。
