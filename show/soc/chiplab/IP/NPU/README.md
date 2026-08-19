# Chiplab NPU integration

This directory contains the NPU RTL imported from
`la32r_xupt_soc_a735t/rtl/ip/npu_ip` commit
`b28772386f5b88a6face5e898282b6fb1e17a542`.
`README.upstream.md` records the original IP status and verification flow.

## Current integration

- AXI slave physical address: `0x1f100000`--`0x1f10ffff`
- CPU external interrupt input: `intrpt[0]`
- SoC top: `rtl/wrappers/npu_rom_mmio.v`
- RAM-side DMA arbiter: `rtl/wrappers/npu_axi_ram_arbiter.v`
- Parameters: `params/npu_params.hex`
- Microcode: `sim/microcode_face.hex`
- Descriptor image: `sim/npu_desc.hex`

The default build deliberately keeps `USE_AXI_DMA=0`: parameters and
microcode come from the verified ROM path, while frames and descriptors are
written through the AXI slave aperture.  Defining `NPU_AXI_DMA_ENABLE` selects
`USE_AXI_DMA=1` and connects the NPU master to RAM through a synthesizable
two-initiator arbiter.  Input 0 is the existing CPU/JTAG RAM path and input 1
is the NPU; the arbiter output connects only to SRAM/MIG, so the NPU cannot
initiate accesses to MMIO targets.

Both modes expose read-only hardware capability and ABI registers at offsets
`0x0158` and `0x015c`.  DMA mode reports parameter reads, packed preload,
descriptor RAM and result writeback; ROM mode reports descriptor RAM only.

## Build integration

`filelists/npu_soc_wrapper.f` is consumed by both:

- `sims/verilator/run_prog/Makefile`
- `fpga/nscscc-team/run_vivado/create_project.tcl`

The simulation Makefile supplies absolute paths for the three memory images.
The Vivado project script applies the equivalent Verilog macros and adds the
NPU include directory.  ROM/MMIO remains the default.  Use:

```sh
NPU_AXI_DMA=1 make ...
```

for Verilator, or export `NPU_AXI_DMA=1` before running
`fpga/nscscc-team/run_vivado/create_project.tcl`, to enable the DMA topology.
This switch does not regenerate or modify the Vivado AXI-crossbar XCI.

The Verilator flow defines `NO_VCD_DUMP` by default to suppress the migrated
core's independent full-hierarchy dump.  Set `NPU_CORE_VCD=1` for an explicit,
short internal-waveform run; `DUMP_VCD`/`DUMP_FST` continue to control the
normal Chiplab testbench trace.

The nscscc-team FPGA AXI crossbar keeps its historical module name
`axi_crossbar_2x3`, but its configuration now has four master interfaces. M03
is the NPU window.

## Software

The migrated bare-metal API is under `software/bsp/{include,drivers}`. Build
the integration smoke program with:

```sh
make -C software/examples/npu_smoke
```

Bare-metal software uses the uncached direct-mapped address `0xbf100000`.
Linux must use the physical resource `0x1f100000` and map it with
`devm_platform_ioremap_resource()`; it must not reuse the bare-metal virtual
address.

## AXI DMA software contract

The Linux driver allocates parameter, scratch and result memory with
`dma_alloc_coherent()`, enforces a 32-bit DMA mask and writes only DMA API
addresses to hardware.  Userspace supplies copied model sections and never a
physical address.  See `linux/npu/UAPI.md` for the ABI-v2 lifecycle and bounds.

Stage-4 deployment packages are under `models/packages/`; their stable binary
layout is documented in `models/XNPU_FORMAT.md`. `scripts/xnpu_pack.py`
converts the checked-in descriptor/parameter HEX into little-endian sections.
The target-side `libxnpu` validates the package and supplies those sections to
the Linux UAPI, so Linux does not parse HEX and does not require Python.

The arbiter intentionally allows one outstanding read burst and one
outstanding write burst, independently, with round-robin selection at burst
boundaries.  The simulation AXI3-style 4-bit length/2-bit lock signals and the
FPGA AXI4 8-bit length/1-bit lock signals are adapted at their respective SoC
tops.
