# Current bit-true NPU wrapper: npu_core_top + on-chip parameter ROM DMA.
# Use from npu_ip root.
-f npu_core.f
rtl/preproc/weight_rom_dma.v
rtl/preproc/npu_top_with_dma.v
