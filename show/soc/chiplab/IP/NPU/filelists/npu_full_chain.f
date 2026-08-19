# Full RGB888-to-bbox verification chain.
# Use from npu_ip root.
-f npu_core.f
rtl/core/img_downsampler.v
rtl/core/lbp_extractor.v
rtl/preproc/rgb2y.v
rtl/preproc/npu_preproc.v
rtl/preproc/weight_rom_dma.v
rtl/preproc/npu_top_with_dma.v
rtl/preproc/npu_full_chain.v
