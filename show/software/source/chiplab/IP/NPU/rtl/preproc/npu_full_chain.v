// ----------------------------------------------------------------------------
// npu_full_chain  (P3 集成顶层 — RGB → preproc → NPU → bbox)
// ----------------------------------------------------------------------------
//
// 目的：把 npu_preproc (RGB888→Y→4:1 resize→LBP) 与 npu_top_with_dma (NPU+DMA)
//       合并为一个完整的"传感器到 bbox"自包含模块。
//
//       RGB888 像流 → rgb2y → img_downsampler → lbp_extractor → npu_top_with_dma
//                                                                     │
//                                                                     ▼
//                                                                  o_bbox
//
//       端口：
//         保留: clk / rst_n / vip_* (RGB 输入) / o_bbox_* / 调试 snoop
//
//       与 npu_top_with_dma 的接线: i_frame_valid / i_lbp_valid / i_lbp_pixel
//       由 npu_preproc 内部 19200 计数器 + LBP extractor 直接驱动。
//
// 测试: npu_ip/sim/Makefile.full_chain + test_full_chain.py
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef NPU_PARAMS_HEX
  `define NPU_PARAMS_HEX "params/npu_params.hex"
`endif

module npu_full_chain #(
    parameter SRC_W      = 640,
    parameter SRC_H      = 480,
    parameter DST_W      = 160,
    parameter DST_H      = 120,
    parameter PARAMS_HEX = `NPU_PARAMS_HEX,
    parameter ROM_DEPTH  = 21098
)(
    input  wire         clk,
    input  wire         rst_n,

    // VIP 上游: RGB888 像流 (与 npu_preproc 端口同名)
    input  wire         vip_vsync,      // 高电平 idle, 高→低 表示帧起始
    input  wire         vip_pix_valid,
    input  wire [7:0]   vip_r,
    input  wire [7:0]   vip_g,
    input  wire [7:0]   vip_b,

    // bbox 输出 (与 npu_top_with_dma 一致)
    output wire         o_bbox_valid,
    output wire [39:0]  o_bbox_data,

    // 调试 snoop: 来自 npu_preproc
    output wire         o_lbp_valid_snoop,
    output wire [7:0]   o_lbp_pixel_snoop,
    output wire         o_frame_valid_snoop,

    // 调试 snoop: 来自 npu_top_with_dma (DMA 状态)
    output wire         o_dma_req_snoop,
    output wire         o_dma_done_snoop,
    output wire [15:0]  o_dma_base_addr_snoop,
    output wire [15:0]  o_dma_length_snoop
);

    // -------- preproc → NPU 接线 --------
    wire        w_frame_valid;
    wire        w_lbp_valid;
    wire [7:0]  w_lbp_pixel;
    wire [7:0]  w_lbp_x_unused;
    wire [7:0]  w_lbp_y_unused;

    assign o_lbp_valid_snoop   = w_lbp_valid;
    assign o_lbp_pixel_snoop   = w_lbp_pixel;
    assign o_frame_valid_snoop = w_frame_valid;

    // -------- 1. preproc (rgb2y + ds + lbp) --------
    npu_preproc #(
        .SRC_W (SRC_W),
        .SRC_H (SRC_H),
        .DST_W (DST_W),
        .DST_H (DST_H)
    ) u_preproc (
        .clk            (clk),
        .rst_n          (rst_n),

        .vip_vsync      (vip_vsync),
        .vip_pix_valid  (vip_pix_valid),
        .vip_r          (vip_r),
        .vip_g          (vip_g),
        .vip_b          (vip_b),

        .o_frame_valid  (w_frame_valid),
        .o_lbp_valid    (w_lbp_valid),
        .o_lbp_pixel    (w_lbp_pixel),
        .o_lbp_x        (w_lbp_x_unused),
        .o_lbp_y        (w_lbp_y_unused)
    );

    // -------- 2. NPU + 内置 DMA --------
    npu_top_with_dma #(
        .PARAMS_HEX (PARAMS_HEX),
        .ROM_DEPTH  (ROM_DEPTH)
    ) u_npu (
        .clk                   (clk),
        .rst_n                 (rst_n),

        .i_frame_valid         (w_frame_valid),
        .i_lbp_valid           (w_lbp_valid),
        .i_lbp_pixel           (w_lbp_pixel),

        .o_bbox_valid          (o_bbox_valid),
        .o_bbox_data           (o_bbox_data),

        .o_dma_req_snoop       (o_dma_req_snoop),
        .o_dma_done_snoop      (o_dma_done_snoop),
        .o_dma_base_addr_snoop (o_dma_base_addr_snoop),
        .o_dma_length_snoop    (o_dma_length_snoop)
    );

endmodule
