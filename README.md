# nscscc2026_xupt

## 仓库内容说明与文档索引
- 本项目所需的文档与设计规范均应位于`/docs`文件夹下,当前该文件夹存放了loongarch32r的isa文档说明;
- `/core`文件夹下放置了处理器核心的RTL代码，为独立submodule,在另一仓库进行开发与维护;
- 文件夹`/chiplab`是本次nscscc指定的chiplab版本，用于进行功能和性能测试;
- 我们fork了chiplab，修改了适配于自己环境的运行脚本，按照赛方要求，**未修改fpga相关综合实现参数**;

## 环境搭建

### 1. 克隆仓库

```bash
git clone --recurse-submodules <仓库地址>
```

### 2. 设置 CHIPLAB_HOME

```bash
export CHIPLAB_HOME=$(pwd)/chiplab
# 建议写入 ~/.bashrc，避免每次手动设置
echo "export CHIPLAB_HOME=$(pwd)/chiplab" >> ~/.bashrc
```

### 3. 链接 CPU 设计到 chiplab

在仓库根目录执行：
```bash
ln -sf ../../core/02_Design chiplab/IP/myCPU
```

> 或进入 chiplab 目录执行：`ln -sf ../core/02_Design IP/myCPU`，两种写法等价。

### 4. 下载外部工具链

- **NEMU**（difftest 参考核）：从 [la32r-nemu releases](https://gitee.com/wwt_panache/la32r-nemu/releases) 下载 `la32r-nemu-interpreter-so`，放入 `chiplab/toolchains/nemu/`
- **QEMU**：从 [la32r-QEMU releases](https://gitee.com/loongson-edu/la32r-QEMU/releases/tag/v0.0.2) 下载 `la32r-QEMU-x86_64-ubuntu-22.04.tar`，解压到 `chiplab/toolchains/qemu/`，并创建符号链接：
  ```bash
  cd chiplab/toolchains/qemu
  ln -s qemu-system-loongarch32 qemu-system-loongson32
  ```
- **GCC 交叉编译器**：[la32r-toolchains](https://gitee.com/loongson-edu/la32r-toolchains/releases)，解压后将 `bin/` 加入 `PATH`

### 5. 配置并运行仿真

```bash
cd chiplab/sims/verilator/run_prog
./configure.sh --run func/func_lab3 --threads N   # N 根据内存调整，建议 1~4
make
```

## 系统功能说明
尚未补充完整描述