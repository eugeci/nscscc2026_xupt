// ----------------------------------------------------------------------------
// npu_top_with_dma  (Path B M3 集成顶层)
// ----------------------------------------------------------------------------
//
// 目的：把 npu_core_top 与 weight_rom_dma 打包为一个完整自包含模块。
//       外部只需喂 LBP 像素流 + 读 bbox 输出；权重/偏置由内部 ROM 自供。
//
// 设计文档: docs/weight_rom_dma_设计_PathB.md §4, §7
//
// 端口 (对比 npu_core_top)：
//   保留: clk / rst_n / LBP 输入三件套 / bbox 输出 / o_kernel_size (snoop)
//   删除: weight_in_* / bias_in_* / update_*_en  (由 weight_rom_dma 内部提供)
//   删除: o_dma_* / i_dma_*  (DMA 握手环路内部封闭)
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef NPU_PARAMS_HEX
  `define NPU_PARAMS_HEX "params/npu_params.hex"
`endif

module npu_top_with_dma #(
    parameter PARAMS_HEX = `NPU_PARAMS_HEX,
    parameter ROM_DEPTH  = 21098
)(
    input  wire         clk,
    input  wire         rst_n,

    // External LBP sensor
    input  wire         i_frame_valid,
    input  wire         i_lbp_valid,
    input  wire [7:0]   i_lbp_pixel,

    // Final result output
    output wire         o_result_stream_valid,
    output wire [127:0] o_result_stream_data,
    output wire         o_inference_done,
    output wire         o_bbox_valid,
    output wire [39:0]  o_bbox_data,

    // Debug/snoop (可选接 SignalTap / cocotb)
    output wire         o_dma_req_snoop,
    output wire         o_dma_done_snoop,
    output wire [15:0]  o_dma_base_addr_snoop,
    output wire [15:0]  o_dma_length_snoop
);

    // -------- sequencer→DMA 控制 --------
    wire         w_dma_req;
    wire [15:0]  w_dma_base_addr;
    wire [15:0]  w_bias_base_addr;
    wire [15:0]  w_dma_length;
    wire         w_dma_ack;
    wire         w_dma_done;
    wire [1:0]   w_kernel_size;

    // -------- DMA→buffers 数据面 --------
    wire [143:0] w_weight_in_data;
    wire         w_weight_in_valid;
    wire [9:0]   w_weight_in_addr;
    wire         w_update_weights_en;

    wire [31:0]  w_bias_in_data;
    wire         w_bias_in_valid;
    wire [4:0]   w_bias_in_addr;
    wire         w_update_bias_en;
    wire         w_pool_reorder_error;

    assign o_dma_req_snoop       = w_dma_req;
    assign o_dma_done_snoop      = w_dma_done;
    assign o_dma_base_addr_snoop = w_dma_base_addr;
    assign o_dma_length_snoop    = w_dma_length;

    // -------- npu_core_top --------
    npu_core_top u_core (
        .clk               (clk),
        .rst_n             (rst_n),

        .i_frame_valid     (i_frame_valid),
        .i_lbp_valid       (i_lbp_valid),
        .i_lbp_pixel       (i_lbp_pixel),
        .i_l0_input_preload_en(1'b0),
        .i_l0_input_packed_en (1'b0),
        .i_preload_wr_en      (1'b0),
        .i_preload_target     (1'b0),
        .i_preload_wr_addr    (13'd0),
        .i_preload_wr_mask    (16'd0),
        .i_preload_wr_data    (128'd0),
        .i_skip_lbp_load      (1'b0),

        .i_desc_we         (1'b0),
        .i_desc_layer      (5'd0),
        .i_desc_word       (3'd0),
        .i_desc_wdata      (32'd0),
        .i_layer_count     (5'd0),

        .o_dma_req         (w_dma_req),
        .o_dma_base_addr   (w_dma_base_addr),
        .o_bias_base_addr  (w_bias_base_addr),
        .o_dma_length      (w_dma_length),
        .i_dma_ack         (w_dma_ack),
        .i_dma_done        (w_dma_done),

        .weight_in_data    (w_weight_in_data),
        .weight_in_valid   (w_weight_in_valid),
        .weight_in_addr    (w_weight_in_addr),
        .update_weights_en (w_update_weights_en),

        .bias_in_data      (w_bias_in_data),
        .bias_in_valid     (w_bias_in_valid),
        .bias_in_addr      (w_bias_in_addr),
        .update_bias_en    (w_update_bias_en),

        .i_pool_scratch_base_addr(32'd0),
        .o_pool_reorder_error(w_pool_reorder_error),
        .o_pool_reorder_dbg0(),
        .o_pool_reorder_dbg1(),
        .o_pool_reorder_dbg2(),
        .o_pool_reorder_dbg3(),
        .o_pool_reorder_dbg4(),
        .o_pool_reorder_dbg5(),
        .o_pool_reorder_dbg6(),
        .o_pool_reorder_dbg7(),
        .o_pool_reorder_dbg8(),
        .o_pool_reorder_dbg9(),
        .o_pool_reorder_dbg10(),
        .o_pool_reorder_dbg11(),
        .o_pool_reorder_dbg12(),
        .o_pool_reorder_dbg13(),
        .o_pool_reorder_dbg14(),
        .o_pool_reorder_dbg15(),
        .o_pool_reorder_dbg16(),
        .o_pool_reorder_dbg17(),
        .o_pool_reorder_dbg18(),
        .i_layer_dbg_sel(7'd0),
        .o_layer_dbg0(),
        .o_layer_dbg1(),
        .o_layer_dbg2(),
        .o_layer_dbg3(),
        .o_layer_dbg4(),
        .o_layer_dbg5(),
        .o_layer_dbg6(),
        .o_layer_dbg7(),
        .m_axi_arid         (),
        .m_axi_araddr       (),
        .m_axi_arlen        (),
        .m_axi_arsize       (),
        .m_axi_arburst      (),
        .m_axi_arlock       (),
        .m_axi_arcache      (),
        .m_axi_arprot       (),
        .m_axi_arvalid      (),
        .m_axi_arready      (1'b0),
        .m_axi_rid          (4'd0),
        .m_axi_rdata        (32'd0),
        .m_axi_rresp        (2'b00),
        .m_axi_rlast        (1'b0),
        .m_axi_rvalid       (1'b0),
        .m_axi_rready       (),
        .m_axi_awid         (),
        .m_axi_awaddr       (),
        .m_axi_awlen        (),
        .m_axi_awsize       (),
        .m_axi_awburst      (),
        .m_axi_awlock       (),
        .m_axi_awcache      (),
        .m_axi_awprot       (),
        .m_axi_awvalid      (),
        .m_axi_awready      (1'b0),
        .m_axi_wid          (),
        .m_axi_wdata        (),
        .m_axi_wstrb        (),
        .m_axi_wlast        (),
        .m_axi_wvalid       (),
        .m_axi_wready       (1'b0),
        .m_axi_bid          (4'd0),
        .m_axi_bresp        (2'b00),
        .m_axi_bvalid       (1'b0),
        .m_axi_bready       (),

        .o_kernel_size     (w_kernel_size),

        .o_result_stream_valid(o_result_stream_valid),
        .o_result_stream_data(o_result_stream_data),
        .o_inference_done  (o_inference_done),
        .o_bbox_valid      (o_bbox_valid),
        .o_bbox_data       (o_bbox_data)
    );

    // -------- weight_rom_dma --------
    weight_rom_dma #(
        .PARAMS_HEX (PARAMS_HEX),
        .ROM_DEPTH  (ROM_DEPTH),
        .ADDR_W     (16)
    ) u_dma (
        .clk                  (clk),
        .rst_n                (rst_n),

        .i_dma_req            (w_dma_req),
        .i_dma_base_addr      (w_dma_base_addr),
        .i_bias_base_addr     (w_bias_base_addr),
        .i_dma_length         (w_dma_length),
        .i_kernel_size        (w_kernel_size),
        .o_dma_ack            (w_dma_ack),
        .o_dma_done           (w_dma_done),

        .o_weight_data        (w_weight_in_data),
        .o_weight_valid       (w_weight_in_valid),
        .o_weight_addr        (w_weight_in_addr),
        .o_update_weights_en  (w_update_weights_en),

        .o_bias_data          (w_bias_in_data),
        .o_bias_valid         (w_bias_in_valid),
        .o_bias_addr          (w_bias_in_addr),
        .o_update_bias_en     (w_update_bias_en)
    );

endmodule
