# LA32R 最终交付审核清单

本清单用于审核 `bringup/la32r-linux` 的最终交付物。镜像分为“最新同步镜像”和
“已板测组合”，审核时不要混用内核、比特流和跳板。

## 板测组合

| 项目 | 文件 | 结果 |
|---|---|---|
| FPGA 比特流 | `VisionArm/release/visionarm_npu_soc_top.bit` | 包含自研核、NPU、摄像头、LCD、VGA；与软件验收组合匹配 |
| 最新软件镜像 | `VisionArm/release/vmlinux_visionarm_xnpu` | 已用微信暂存包镜像替换旧文件；SHA256 为 `067f7a2aadb83075de3acfd2ebc80dfb21fa7791e4570cf4a2c9d6cb56a65c65`；尚未在本轮板上复测 |
| Linux 内核 | `VisionArm/release/vmlinux_visionarm_xnpu_rxtrig1_nojob` | 已在板上启动；UART RX trigger=1；无 job-control 交互 shell |
| PMON 跳板 | `VisionArm/release/linux_handoff_trampoline_a4f_xnpu` | 已按内核入口 `0xa0b868f0` 修补，必须与该内核配套 |

## 验收结果

- `/dev/xnpu` 已创建设备节点。
- `devmem 0x1f100158 32` 返回 `0x0000000f`。
- `devmem 0x1f10015c 32` 返回 `0x00000002`。
- `xnpu-inspect /models/facenet_lbp_v1.xnpu` 成功解析 ABI v2 模型。
- `xnpu-run --poll ...` 输出 `XNPU_RUN_PASS`，checksum 为 `0x685184b3`，bbox 为
  `58,132,81,104,137`。
- LCD `lcdctl show`、摄像头寄存器启动和 Linux `ls` 已分别通过板测。

## 审核前检查

1. 用 `VisionArm/release/SHA256SUMS.txt` 校验文件完整性。
2. 稳定板测只加载 `vmlinux_visionarm_xnpu_rxtrig1_nojob` 和匹配跳板；不要把新同步的通用镜像与旧跳板混用。
3. 复现 README 中的 NPU 五步验收命令，并保留串口日志作为比赛交付记录。
