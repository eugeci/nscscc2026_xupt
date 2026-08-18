# 仓库与分支协作说明

本文说明主仓库、CPU 子仓库和 Chiplab 子仓库之间的关系，以及 NPU
集成和 LA32R Linux bring-up 两条开发线的提交规则。

## 仓库结构

主仓库为 `eugeci/nscscc2026_xupt`，`core` 和 `chiplab` 以 Git
submodule 形式接入。主仓库只记录子仓库提交号，不包含子仓库提交本身。

涉及多个仓库的改动应按以下顺序发布：

1. 提交并推送 `core` 的实际修改。
2. 提交并推送 `chiplab` 的实际修改。
3. 在主仓库提交并推送对应的 submodule gitlink。

若先推主仓库，其他协作者可能无法获取尚未发布的 submodule commit。

## 开发线职责

| 工作内容 | 主仓库分支 | core 分支 | chiplab 分支 |
| --- | --- | --- | --- |
| NPU、摄像头、LCD、机械臂集成 | `feature/npu-linux-port` | 由主仓库固定已验证版本 | 对应 VisionArm/NPU 集成分支 |
| 自研 CPU 基础 Linux 启动 | `bringup/la32r-linux` | `feature/la32r-mmu` | `bringup/la32r-linux` |

CPU 修复继续提交到共享的 `core/feature/la32r-mmu`，不再为每次下板排查
建立额外 core 分支。主仓库和 chiplab 的 bring-up 分支负责固定可复现的
SoC、VIO、内核和构建组合。

## LA32R 当前组合

- core：`b897a7d`
- chiplab：`0ae86e2`（RTL/构建防护为 `a2531f4`）
- Vivado：2023.2
- CPU 时钟：33.333 MHz
- bitstream：
  `chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.bit`
- probes：
  `chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top.ltx`

bitstream SHA256：

```text
768e78be353186eac6699a245f7e9d96384cac5ca6c2122eaf2fb9c1ae43b5b3
```

该版本已完成 Vivado 综合、布局、布线和 bitgen。最终 WNS 为 0.162 ns，
WHS 为 0.057 ns，TNS/THS 和 routing error 均为 0。

## VIO 与生成文件规则

VIO 必须作为 Xilinx IP 由构建脚本显式创建或读取 XCI/XCIX，不允许把
`*_sim_netlist.v`、`*_sim_netlist.vhdl`、`*_stub.v` 或 `*_stub.vhdl`
加入 core filelist。

`build_la32r_linux.tcl` 执行两层检查：

1. 从 Vivado `sources_1` 移除历史上被直接加入的 VIO 生成 RTL。
2. core filelist 出现 VIO RTL 时立即终止构建。

Vivado runs、cache、日志、生成 IP 和 bitstream 不进入 Git。需要交付
bitstream 时，应同时记录 `.bit`、匹配的 `.ltx`、SHA256、三个仓库提交号
和时序摘要。

## 提交前检查

```bash
git status --short --branch
git submodule status
git -C core status --short --branch
git -C chiplab status --short --branch
```

submodule 状态中的大写 `M` 表示主仓库记录的 gitlink 改变，小写 `m`
表示子仓库目录中仍有未提交或未跟踪内容。禁止使用未经检查的
`git add -A`，避免把 Vivado 生成物或其他任务的修改混入提交。
