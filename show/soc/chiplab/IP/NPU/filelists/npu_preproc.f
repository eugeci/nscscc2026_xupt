# RGB888 -> Y -> downsample -> LBP preprocessing chain.
# Use from npu_ip root.
rtl/preproc/rgb2y.v
rtl/core/sync_fifo_npu_module.v
rtl/core/line_buffer.v
rtl/core/img_downsampler.v
rtl/core/lbp_extractor.v
rtl/preproc/npu_preproc.v
