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
- selectable Stage-3 and Stage-4 initramfs smoke programs;
- native `libxnpu`, package inspection, inference and manifest regression tools;
- a no-trace Chiplab Verilator boot path for the pinned OpenLA500 baseline.

## Build

The build script uses `CROSS_COMPILE` when supplied. Otherwise it uses the
LA32R GNU toolchain distributed under `chiplab/toolchains`.

```sh
./linux/npu/build.sh
```

This keeps the Stage-3 HEX-backed smoke as the default. Build the Stage-4
binary-package path with:

```sh
NPU_INIT=stage4 ./linux/npu/build.sh
```

The Stage-4 initramfs contains the checked-in FaceNet `.xnpu` and binary
fixture. Set `NPU_INCLUDE_TOOLS=1` as well to include `xnpu-inspect`,
`xnpu-run` and `xnpu-regress`; the minimal cycle-accurate boot omits the three
duplicate static executables to save RAM and simulation time.

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

The Stage-4 package run validates the package on the LA32 target, loads its
binary descriptor and parameter sections, and prints:

```text
package=facenet_bbox model_id=65537 abi=2 layers=10 input=19200 parameters=84392 sha256=af466fe36f009520c6f0a8bfbf3d50884344b785b326d74e2904d5eb278c4199
driver_abi=2 hardware_abi=2 caps=0x0000003f
bytes=16 checksum=0x685184b3 bbox=58,132,81,104,137 perf_cycle=734915
XNPU_STAGE4_PASS
```

After printing the marker, `/init` sleeps forever so the kernel does not panic
from an init-process exit.  End the Verilator process after capturing the
marker; the resulting termination status is not an inference failure.

## OpenLA500 RTL simulation

First prepare the repository's pinned OpenLA500 baseline:

```sh
./baselines/openla500/prepare.sh
```

Build the desired kernel, then compile the no-waveform DMA Verilator model
once:

```sh
NPU_INIT=stage4 ./linux/npu/build.sh

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

## Model packages and native userspace

The format is specified in
[`chiplab/IP/NPU/models/XNPU_FORMAT.md`](../../chiplab/IP/NPU/models/XNPU_FORMAT.md).
Four deterministic packages and standalone fixtures are checked in under
`chiplab/IP/NPU/models/{packages,fixtures/bin}`. Rebuild and validate them:

```sh
python3 chiplab/IP/NPU/scripts/xnpu_pack.py
python3 chiplab/IP/NPU/scripts/test_xnpu_package.py -v
```

Python is a reference build-time tool only. The target consumes the committed
binary packages through the dependency-free C library:

```sh
make -C linux/npu/userspace \
  PACKAGES_DIR="$PWD/chiplab/IP/NPU/models/packages" all test

xnpu-inspect facenet_lbp_v1.xnpu
xnpu-run --expect-checksum 0x685184b3 \
  --expect-bbox 58,132,81,104,137 \
  facenet_lbp_v1.xnpu facenet_seed42.bin
xnpu-regress regression.tsv
```

See [`userspace/README.md`](userspace/README.md) for the library lifecycle,
cross-build command and regression manifest.

Stage 4 provides the deployment package and runtime, but does not claim the
Stage-5 four-model RTL loop or the future native `xnpu-cc` compiler backend.
