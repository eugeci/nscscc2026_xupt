# XUPT NPU Linux integration

This directory contains a reproducible Linux 5.14 integration for the NPU in
the Chiplab SoC.  It targets the official `la32r-Linux` `la32r-new-world`
baseline at commit `4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e`.

The integration provides:

- a device-tree node at physical address `0x1f100000`, CPU HWIRQ 2;
- a platform/misc driver exposed as `/dev/xupt-npu`;
- a stable userspace UAPI for reset, descriptor loading, start and wait/result;
- a built-in initramfs whose `/init` runs an end-to-end NPU smoke test.
- a no-trace Chiplab Verilator boot path for the pinned OpenLA500 baseline.

## Build

The build script uses `CROSS_COMPILE` when supplied. Otherwise it uses the
LA32R GNU toolchain distributed under `chiplab/toolchains`.

```sh
./linux/npu/build.sh
```

The resulting kernel is:

```text
linux/npu/.work/build/vmlinux
```

The smoke test prints `NPU_LINUX_PASS` after the descriptor, frame, interrupt
and bounding-box paths have all completed successfully.

## OpenLA500 RTL simulation

First prepare the repository's pinned OpenLA500 baseline:

```sh
./baselines/openla500/prepare.sh
```

Build the kernel, then compile the no-waveform Verilator model once:

```sh
./linux/npu/build.sh

cd chiplab/sims/verilator/run_prog
CHIPLAB_HOME="$PWD/../../.." make compile \
  RUN_SOFTWARE=linux_npu TRACE_COMP=n SIMU_TRACE=n \
  RUN_FUNC=n RUN_C=y OUTPUT_UART_INFO=y DEAD_CLOCK_EN=n \
  DUMP_VCD=n DUMP_FST=n ISA=OPENLA \
  MYCPU_SRC="$PWD/../../../../baselines/openla500/.work/openla500-src"
```

For each kernel or initramfs change, regenerate the ROM and run:

```sh
CHIPLAB_HOME="$PWD/../../.." make clean_soft soft \
  RUN_SOFTWARE=linux_npu TRACE_COMP=n SIMU_TRACE=n \
  RUN_FUNC=n RUN_C=y OUTPUT_UART_INFO=y DEAD_CLOCK_EN=n \
  DUMP_VCD=n DUMP_FST=n ISA=OPENLA \
  MYCPU_SRC="$PWD/../../../../baselines/openla500/.work/openla500-src"

CHIPLAB_HOME="$PWD/../../.." make run \
  RUN_SOFTWARE=linux_npu TRACE_COMP=n SIMU_TRACE=n \
  RUN_FUNC=n RUN_C=y OUTPUT_UART_INFO=y DEAD_CLOCK_EN=n \
  DUMP_VCD=n DUMP_FST=n ISA=OPENLA \
  MYCPU_SRC="$PWD/../../../../baselines/openla500/.work/openla500-src" \
  TIME_LIMIT=1000000000 BUS_DELAY=n
```

The validation device tree advertises 16 MiB of RAM to keep cycle-accurate
boot practical. This does not change the FPGA SoC's 128 MiB DDR layout.

## Userspace ABI

The frame is written as exactly 19,200 grayscale bytes to `/dev/xupt-npu`.
The remaining operations use the ioctls in
`kernel/include/uapi/linux/xupt_npu.h`:

1. `XUPT_NPU_IOC_RESET`
2. `XUPT_NPU_IOC_LOAD_DESCRIPTORS`
3. `write(fd, frame, XUPT_NPU_FRAME_BYTES)`
4. `XUPT_NPU_IOC_RUN`
5. `XUPT_NPU_IOC_WAIT`

Only one process can open the device at a time.  The driver intentionally does
not expose `mmap`; all MMIO validation and serialization remain in the kernel.
