# OpenLA500 Chiplab performance baseline

This directory builds and runs an OpenLA500 baseline without changing the
existing self-designed CPU project.

## Fixed inputs

- Chiplab platform: the current `chiplab/chip/soc_demo/nscscc-team` platform.
- CPU: OpenLA500 commit `aa3bde1f3e720e71c2c78d6b81930d797b810149`.
- Software image: the current
  `chiplab/software/examples/nscscc_perf/obj/allbench/inst_data.bin`.
- CPU clock: Chiplab's default OpenLA500 setting, nominally 33 MHz. The
  historical PLL configuration actually generates 32.72727 MHz
  (`100 MHz * 18 / 55`).
- Test count: all 20 Chiplab performance tests.

The selected OpenLA500 revision is the exact revision previously pinned by
Chiplab commit `ac3e7a1`. The upstream core is fetched into the ignored
`.work/` directory, so it does not replace `chiplab/IP/myCPU`.

The independent project also extracts the historical 33 MHz `clk_pll.xci`
from that Chiplab commit. It does not consume or modify the current 125 MHz
PLL used by the self-designed CPU project. A future 125 MHz OpenLA500 run may
be useful as a separate same-frequency experiment, but it is not the default
OpenLA500 baseline recorded here.

## IPC measurement

OpenLA500 already produces a one-cycle `commit_inst` pulse for every normally
retired instruction. The baseline patch adds a measurement counter that:

1. Starts on the first CPU AXI read of the Chiplab timer at physical address
   `0x1faf_e000`.
2. Stops on the next timer read.
3. Accumulates multiple start/stop intervals for `stringsearch`.
4. Resets on every VIO CPU reset.

The instruction count is exposed through the existing 32-bit VIO input that
normally displays `num_data`. CPU cycles continue to come from the benchmark's
`rdcntvl.w` delta in `CONFREG_CR0`.

The counter is in the CPU clock domain while VIO runs from the board's 100 MHz
clock. A two-register synchronizer samples the stopped counter, and only the
first stage is declared as a false-path CDC endpoint. JTAG reads the second
stage after test completion, so the reported multi-bit value has already been
stable for millions of VIO clocks.

```text
IPC = measured retired instructions / measured CPU cycles
test_time_ms = measured SoC timer cycles / 100000
cpu_cycle_time_ms = measured CPU cycles / 32727.272727
```

The timer-read window includes a few instructions around the two software
counter calls, while the `rdcntvl.w` interval is slightly narrower. The error
is negligible for these multi-million-cycle tests, but the raw instruction and
cycle counts are both retained in the CSV.

`test_time_ms` is the baseline runtime used for comparison because the SoC
timer remains at an exact 100 MHz. `cpu_cycle_time_ms` is retained as a
cross-check using the PLL's actual 32.72727 MHz output. The test software's
printed time uses its nominal 33 MHz constant and can therefore differ by
about 0.83% from the hardware-timer result.

## Commands

Prepare the pinned source and generated SoC overlay:

```bash
./baselines/openla500/prepare.sh
```

Create and build the independent Vivado project:

```bash
./baselines/openla500/build.sh
```

`build.sh` defaults to `/home/eugeci/Xilinx/Vivado/2023.2/bin/vivado`. Override
it with `VIVADO=/path/to/vivado` when needed.

Program the board and load the existing allbench image into DDR:

```bash
vivado -mode batch -source baselines/openla500/program_and_load.tcl
```

Run all tests and produce the baseline CSV:

```bash
vivado -mode batch -source baselines/openla500/run_all_perf_jtag.tcl
```

The generated Vivado project is:

```text
chiplab/fpga/nscscc-team/run_vivado/project_openla500/openla500.xpr
```

The result is saved as:

```text
baselines/openla500/openla500_perf_results.csv
```
