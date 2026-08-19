# LA32R 最终交付审核清单

本清单对应提交 `release(bringup): package board-verified NPU deliverables`。
它只列出当前可复现、可上板验收的交付物；审核通过前不应替换其中的镜像或跳板。

## 板测组合

| 项目 | 文件 | 结果 |
|---|---|---|
| FPGA 比特流 | `VisionArm/release/visionarm_npu_soc_top.bit` | 包含自研核、NPU、摄像头、LCD、VGA；与软件验收组合匹配 |
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
2. PMON 只加载表中的内核和匹配跳板，不混用旧的 `vmlinux_visionarm_xnpu`。
3. 复现 README 中的 NPU 五步验收命令，并保留串口日志作为比赛交付记录。
