# Filelists

These filelists are relative to the `npu_ip/` root and are intended for SoC
projects, Vivado project import, and standalone lint/compile checks.

| File | Top-level intent |
| --- | --- |
| `npu_core.f` | `npu_core_top`: core NPU with external weight/bias loading interface |
| `npu_with_rom_dma.f` | `npu_top_with_dma`: current bit-true NPU wrapper with on-chip parameter ROM DMA |
| `npu_preproc.f` | `npu_preproc`: RGB888 to LBP preprocessing chain |
| `npu_full_chain.f` | `npu_full_chain`: RGB888 input to bbox output verification wrapper |

Usage example:

```bash
cd npu_ip
iverilog -g2012 -s npu_top_with_dma \
  -DMICROCODE_FILE=\"sim/microcode_face.hex\" \
  -DNPU_PARAMS_HEX=\"params/npu_params.hex\" \
  -f filelists/npu_with_rom_dma.f
```

Notes:

- Wrapper filelists use nested `-f npu_core.f` style includes. Invoke them as
  `-f filelists/<name>.f` from the `npu_ip/` root.
- `rtl/core/npu_subsys_top/` is not included. It is legacy/experimental glue.
- `rtl/core/npu_params_define.v` is not included. Current parameter loading uses
  `params/npu_params.hex` through `weight_rom_dma` or an external DMA wrapper.
- For the future Xilinx SoC path, use `npu_core.f` as the stable compute core
  boundary and add the AXI wrapper in `rtl/wrappers/`.
