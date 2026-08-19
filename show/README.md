# T2026116640011035 决赛展示交付包

本目录按比赛展示目录要求提供 `soc/`、`software/` 和 `doc/`。其中主 bit、
Linux 内核及 PMON 跳板采用 2026-08-19 已在开发板上完成 Linux、LCD、摄像头和
XNPU 轮询推理验证的组合。

## 已验证启动组合

| 文件 | SHA-256 |
|---|---|
| `soc/bit/soc_top.bit` | `0ac03ff7fe8c3da8bcdf8af53a9680b69788110604f1ec628015dcb88922ab24` |
| `software/bin/kernel/vmlinux_xnpu_rxtrig1_nojob_stripped` | `724d5bedd3e79cefe847da05d2c5e33c114b7cb7b95744631257a9c4de04c299` |
| `software/bin/kernel/linux_handoff_trampoline_a4f_xnpu` | `eeb9897a59be2d6847b2d400a259bc6ce40ea3703284075889b6a7daa042050b` |

PMON 手工启动：

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_xnpu_rxtrig1_nojob_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f_xnpu
g
```

进入 Linux 后的最小验收：

```sh
ls
lcdctl show
devmem 0x1fd0e100 32 1
xnpu-run --poll --expect-checksum 0x685184b3 --expect-bbox 58,132,81,104,137 /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

最后一条命令应输出 `XNPU_RUN_PASS`。完整接线、启动和校验方法见
`doc/README.md` 与 `doc/版本与校验.md`。

## 源码说明

- `soc/myCPU/` 来自最终提供的 `2026-08/mycpu/mycpu`，共 56 个文件；复制后已逐文件校验一致。
- `soc/chiplab/` 是配套 SoC/NPU 工程快照，构建脚本已改为从 `soc/myCPU/` 读取平铺 RTL。
- 未提交与主 bit 不匹配的旧 `soc_top.ltx`，避免调试探针错误关联。
