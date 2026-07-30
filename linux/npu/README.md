# XUPT NPU Linux integration

This directory contains a reproducible Linux 5.14 integration for the NPU in
the Chiplab SoC.  It targets the official `la32r-Linux` `la32r-new-world`
baseline at commit `4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e`.

The integration provides:

- a device-tree node at physical address `0x1f100000`, CPU HWIRQ 2;
- a platform/misc driver exposed as `/dev/xupt-npu`;
- ABI-v1 compatibility for the fixed ROM/MMIO FaceNet path;
- ABI v2 for capability discovery, one active DMA model, generic input and
  result tensors;
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

The smoke test first queries hardware capabilities.  A default ROM build runs
the ABI-v1 descriptor/frame/bbox regression.  A DMA build loads the checked-in
FaceNet descriptor and 84,392-byte parameter image through ABI v2, executes
the canonical frame and checks the 16-byte result, checksum and bbox.  Both
paths print `NPU_LINUX_PASS` on success.

The Stage-3 OpenLA500 DMA golden run is:

```text
npu abi=2 hw_abi=2 caps=0x0000003f frame=160x120 bytes=19200 max_layers=32 irq=1
dma status=0x4b00000a result_status=0x00000002 bytes=16 checksum=0x685184b3 shape=1x1x5 bbox=58,132,81,104,137 perf_cycle=734915
NPU_LINUX_PASS
```

After printing the marker, `/init` sleeps forever so the kernel does not panic
from an init-process exit.  End the Verilator process after capturing the
marker; the resulting termination status is not an inference failure.

## OpenLA500 RTL simulation

First prepare the repository's pinned OpenLA500 baseline:

```sh
./baselines/openla500/prepare.sh
```

Build the kernel, then compile the no-waveform DMA Verilator model once:

```sh
./linux/npu/build.sh

cd chiplab/sims/verilator/run_prog
CHIPLAB_HOME="$PWD/../../.." make compile \
  RUN_SOFTWARE=linux_npu TRACE_COMP=n SIMU_TRACE=n \
  RUN_FUNC=n RUN_C=y OUTPUT_UART_INFO=y DEAD_CLOCK_EN=n \
  DUMP_VCD=n DUMP_FST=n ISA=OPENLA NPU_AXI_DMA=1 \
  MYCPU_SRC="$PWD/../../../../baselines/openla500/.work/openla500-src"
```

For each kernel or initramfs change, regenerate the ROM and run:

```sh
CHIPLAB_HOME="$PWD/../../.." make clean_soft soft \
  RUN_SOFTWARE=linux_npu TRACE_COMP=n SIMU_TRACE=n \
  RUN_FUNC=n RUN_C=y OUTPUT_UART_INFO=y DEAD_CLOCK_EN=n \
  DUMP_VCD=n DUMP_FST=n ISA=OPENLA NPU_AXI_DMA=1 \
  MYCPU_SRC="$PWD/../../../../baselines/openla500/.work/openla500-src"

CHIPLAB_HOME="$PWD/../../.." make run \
  RUN_SOFTWARE=linux_npu TRACE_COMP=n SIMU_TRACE=n \
  RUN_FUNC=n RUN_C=y OUTPUT_UART_INFO=y DEAD_CLOCK_EN=n \
  DUMP_VCD=n DUMP_FST=n ISA=OPENLA NPU_AXI_DMA=1 \
  MYCPU_SRC="$PWD/../../../../baselines/openla500/.work/openla500-src" \
  TIME_LIMIT=1000000000 BUS_DELAY=n
```

Omit `NPU_AXI_DMA=1` to compile and run the retained ROM/MMIO regression.
Changing this setting requires rerunning the Verilator compile step because it
changes the elaborated NPU implementation.

The migrated core's full-hierarchy VCD is disabled by default because a Linux
boot otherwise produces multi-gigabyte traces independently of Chiplab's
normal waveform options.  Set `NPU_CORE_VCD=1` only for a deliberately short
NPU debug run.

The validation device tree advertises 16 MiB of RAM to keep cycle-accurate
boot practical. This does not change the FPGA SoC's 128 MiB DDR layout.

## Userspace ABI

ABI v2 uses this lifecycle:

1. `XUPT_NPU_IOC_QUERY_CAPS`
2. `XUPT_NPU_IOC_LOAD_MODEL`
3. `XUPT_NPU_IOC_LOAD_INPUT`
4. `XUPT_NPU_IOC_RUN`
5. `XUPT_NPU_IOC_WAIT_V2`
6. `read()` the generic result payload

`LOAD_MODEL` atomically copies model metadata, `layer_count * 8` descriptor
words and the parameter image into kernel-owned state.  Parameter, scratch and
result buffers use the DMA API; userspace cannot pass a physical address.
Only one process can open the device at a time and the driver intentionally
does not expose `mmap`.

The old `RESET -> LOAD_DESCRIPTORS -> write(frame) -> RUN -> WAIT` sequence
remains available for ROM/MMIO regression.  Structure definitions, limits,
state transitions and error recovery are specified in
[`UAPI.md`](UAPI.md).

Stage 3 stops at this segmented model UAPI and its FaceNet end-to-end test.
The `*.xnpu` package parser, model catalog CLI and native target-side compiler
are intentionally deferred to Stage 4.
