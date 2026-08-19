// -----------------------------------------------------------------------------
// npu_top_with_axi_dma
// -----------------------------------------------------------------------------
// npu_core_top + AXI parameter DMA. This variant removes the on-chip parameter
// ROM from the data path and reads the packed parameter image from system memory.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module npu_top_with_axi_dma #(
    parameter USE_POOL_REORDER_AXI = 1'b1,
    parameter POOL_AXI_BURST_BEATS = 4,
    // The target FPGA has ample DSP48 capacity.  Keeping every output lane in
    // DSPs avoids the long 8x8 LUT-multiplier paths on lanes 9..15.
    parameter DSP_MAC_LANES = 16,
    // Production SoC default: omit the large per-layer trace bank.  Set to 1
    // in a diagnostic RTL testbench when historical layer counters are needed.
    parameter ENABLE_LAYER_DEBUG = 1'b0
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         i_frame_valid,
    input  wire         i_lbp_valid,
    input  wire [7:0]   i_lbp_pixel,
    input  wire         i_l0_input_preload_en,
    input  wire         i_l0_input_packed_en,
    input  wire         i_preload_wr_en,
    input  wire         i_preload_target,
    input  wire [12:0]  i_preload_wr_addr,
    input  wire [15:0]  i_preload_wr_mask,
    input  wire [127:0] i_preload_wr_data,
    input  wire         i_skip_lbp_load,
    input  wire [31:0]  i_param_base_addr,
    input  wire [31:0]  i_pool_scratch_base_addr,
    input  wire         i_result_enable,
    input  wire         i_result_start,
    input  wire [31:0]  i_result_base_addr,
    input  wire [31:0]  i_result_max_bytes,

    // Descriptor configuration ports
    input  wire         i_desc_we,
    input  wire [4:0]   i_desc_layer,
    input  wire [2:0]   i_desc_word,
    input  wire [31:0]  i_desc_wdata,
    input  wire [4:0]   i_layer_count,

    output wire         o_result_stream_valid,
    output wire [127:0] o_result_stream_data,
    output wire         o_inference_done,
    output wire         o_result_busy,
    output wire         o_result_done,
    output wire         o_result_error,
    output wire [31:0]  o_result_write_bytes,
    output wire [31:0]  o_result_checksum,
    output wire [31:0]  o_result_last_addr,
    output wire         o_bbox_valid,
    output wire [39:0]  o_bbox_data,

    output wire         o_dma_req_snoop,
    output wire         o_dma_done_snoop,
    output wire [15:0]  o_dma_base_addr_snoop,
    output wire [15:0]  o_dma_length_snoop,
    output wire         o_dma_error_snoop,
    output wire [31:0]  o_pool_reorder_dbg0,
    output wire [31:0]  o_pool_reorder_dbg1,
    output wire [31:0]  o_pool_reorder_dbg2,
    output wire [31:0]  o_pool_reorder_dbg3,
    output wire [31:0]  o_pool_reorder_dbg4,
    output wire [31:0]  o_pool_reorder_dbg5,
    output wire [31:0]  o_pool_reorder_dbg6,
    output wire [31:0]  o_pool_reorder_dbg7,
    output wire [31:0]  o_pool_reorder_dbg8,
    output wire [31:0]  o_pool_reorder_dbg9,
    output wire [31:0]  o_pool_reorder_dbg10,
    output wire [31:0]  o_pool_reorder_dbg11,
    output wire [31:0]  o_pool_reorder_dbg12,
    output wire [31:0]  o_pool_reorder_dbg13,
    output wire [31:0]  o_pool_reorder_dbg14,
    output wire [31:0]  o_pool_reorder_dbg15,
    output wire [31:0]  o_pool_reorder_dbg16,
    output wire [31:0]  o_pool_reorder_dbg17,
    output wire [31:0]  o_pool_reorder_dbg18,
    output wire [31:0]  o_param_dma_dbg0,
    output wire [31:0]  o_param_dma_dbg1,
    output wire [31:0]  o_param_dma_dbg2,
    output wire [31:0]  o_param_dma_dbg3,
    output wire [31:0]  o_param_dma_dbg4,
    output wire [31:0]  o_param_dma_dbg5,
    output wire [31:0]  o_param_dma_dbg6,
    output wire [31:0]  o_param_dma_dbg7,
    output wire [31:0]  o_param_dma_dbg8,
    output wire [31:0]  o_param_dma_dbg9,
    output wire [31:0]  o_param_dma_dbg10,
    output wire [31:0]  o_param_dma_dbg11,
    output wire [31:0]  o_param_dma_dbg12,
    output wire [31:0]  o_param_dma_dbg13,
    output wire [31:0]  o_param_dma_dbg14,
    output wire [31:0]  o_param_dma_dbg15,
    output wire [31:0]  o_param_dma_dbg16,
    output wire [31:0]  o_param_dma_dbg17,
    output wire [31:0]  o_param_dma_dbg18,

    input  wire [6:0]   i_layer_dbg_sel,
    output wire [31:0]  o_layer_dbg0,
    output wire [31:0]  o_layer_dbg1,
    output wire [31:0]  o_layer_dbg2,
    output wire [31:0]  o_layer_dbg3,
    output wire [31:0]  o_layer_dbg4,
    output wire [31:0]  o_layer_dbg5,
    output wire [31:0]  o_layer_dbg6,
    output wire [31:0]  o_layer_dbg7,

    output wire [3:0]   m_axi_arid,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [2:0]   m_axi_arprot,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,

    input  wire [3:0]   m_axi_rid,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    output wire [3:0]   m_axi_awid,
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [2:0]   m_axi_awprot,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [3:0]   m_axi_wid,
    output wire [31:0]  m_axi_wdata,
    output wire [3:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [3:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready
);

    wire         w_dma_req;
    wire [15:0]  w_dma_base_addr;
    wire [15:0]  w_bias_base_addr;
    wire [15:0]  w_dma_length;
    wire         w_dma_ack;
    wire         w_dma_done;
    wire         w_dma_error;
    wire [1:0]   w_kernel_size;

    wire [143:0] w_weight_in_data;
    wire         w_weight_in_valid;
    wire [9:0]   w_weight_in_addr;
    wire         w_update_weights_en;

    wire [31:0]  w_bias_in_data;
    wire         w_bias_in_valid;
    wire [4:0]   w_bias_in_addr;
    wire         w_update_bias_en;
    wire         w_pool_reorder_error;

    wire [3:0]   weight_axi_arid;
    wire [31:0]  weight_axi_araddr;
    wire [7:0]   weight_axi_arlen;
    wire [2:0]   weight_axi_arsize;
    wire [1:0]   weight_axi_arburst;
    wire         weight_axi_arlock;
    wire [3:0]   weight_axi_arcache;
    wire [2:0]   weight_axi_arprot;
    wire         weight_axi_arvalid;
    wire         weight_axi_arready;
    wire         weight_axi_rready;

    wire [3:0]   pool_axi_arid;
    wire [31:0]  pool_axi_araddr;
    wire [7:0]   pool_axi_arlen;
    wire [2:0]   pool_axi_arsize;
    wire [1:0]   pool_axi_arburst;
    wire         pool_axi_arlock;
    wire [3:0]   pool_axi_arcache;
    wire [2:0]   pool_axi_arprot;
    wire         pool_axi_arvalid;
    wire         pool_axi_arready;
    wire         pool_axi_rready;
    wire [3:0]   pool_axi_awid;
    wire [31:0]  pool_axi_awaddr;
    wire [7:0]   pool_axi_awlen;
    wire [2:0]   pool_axi_awsize;
    wire [1:0]   pool_axi_awburst;
    wire         pool_axi_awlock;
    wire [3:0]   pool_axi_awcache;
    wire [2:0]   pool_axi_awprot;
    wire         pool_axi_awvalid;
    wire         pool_axi_awready;
    wire [3:0]   pool_axi_wid;
    wire [31:0]  pool_axi_wdata;
    wire [3:0]   pool_axi_wstrb;
    wire         pool_axi_wlast;
    wire         pool_axi_wvalid;
    wire         pool_axi_wready;
    wire         pool_axi_bready;

    wire [3:0]   result_axi_awid;
    wire [31:0]  result_axi_awaddr;
    wire [7:0]   result_axi_awlen;
    wire [2:0]   result_axi_awsize;
    wire [1:0]   result_axi_awburst;
    wire         result_axi_awlock;
    wire [3:0]   result_axi_awcache;
    wire [2:0]   result_axi_awprot;
    wire         result_axi_awvalid;
    wire         result_axi_awready;
    wire [3:0]   result_axi_wid;
    wire [31:0]  result_axi_wdata;
    wire [3:0]   result_axi_wstrb;
    wire         result_axi_wlast;
    wire         result_axi_wvalid;
    wire         result_axi_wready;
    wire         result_axi_bready;
    reg          r_write_active;
    reg          r_write_owner;
    localparam WRITE_OWNER_POOL   = 1'b0;
    localparam WRITE_OWNER_RESULT = 1'b1;
    wire         write_sel_result = r_write_active &&
                                    (r_write_owner == WRITE_OWNER_RESULT);
    wire         write_sel_pool = r_write_active &&
                                  (r_write_owner == WRITE_OWNER_POOL);
    wire         write_grant_result = !r_write_active && result_axi_awvalid;
    wire         write_grant_pool = !r_write_active && !result_axi_awvalid &&
                                    pool_axi_awvalid;

    reg          r_ar_locked;
    reg          r_ar_owner;
    reg          r_read_owner;
    reg          r_read_outstanding;
    localparam READ_OWNER_WEIGHT = 1'b0;
    localparam READ_OWNER_POOL   = 1'b1;

    wire req_pool     = pool_axi_arvalid;
    wire req_weight   = weight_axi_arvalid;
    wire ar_sel_pool  = r_ar_locked ? (r_ar_owner == READ_OWNER_POOL) : req_pool;
    wire ar_sel_weight = r_ar_locked ? (r_ar_owner == READ_OWNER_WEIGHT) :
                         (!req_pool && req_weight);
    wire ar_sel_valid = ar_sel_pool ? pool_axi_arvalid :
                        ar_sel_weight ? weight_axi_arvalid : 1'b0;
    wire grant_pool   = !r_read_outstanding && ar_sel_pool;
    wire grant_weight = !r_read_outstanding && ar_sel_weight;
    wire read_ar_fire = m_axi_arvalid && m_axi_arready;
    wire read_r_fire  = m_axi_rvalid && m_axi_rready && m_axi_rlast;
    wire write_aw_fire = m_axi_awvalid && m_axi_awready;
    wire write_b_fire  = m_axi_bvalid && m_axi_bready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_ar_locked        <= 1'b0;
            r_ar_owner         <= READ_OWNER_WEIGHT;
            r_read_owner       <= READ_OWNER_WEIGHT;
            r_read_outstanding <= 1'b0;
        end else begin
            if (!r_read_outstanding) begin
                if (read_ar_fire) begin
                    r_ar_locked        <= 1'b0;
                    r_read_owner       <= ar_sel_pool ? READ_OWNER_POOL : READ_OWNER_WEIGHT;
                    r_read_outstanding <= 1'b1;
                end else if (!r_ar_locked && (req_pool || req_weight)) begin
                    r_ar_locked <= 1'b1;
                    r_ar_owner  <= req_pool ? READ_OWNER_POOL : READ_OWNER_WEIGHT;
                end
            end else if (r_read_outstanding && read_r_fire) begin
                r_ar_locked        <= 1'b0;
                r_read_outstanding <= 1'b0;
            end
        end
    end

    wire sel_pool = (r_read_owner == READ_OWNER_POOL);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_write_active <= 1'b0;
            r_write_owner  <= WRITE_OWNER_POOL;
        end else begin
            if (!r_write_active) begin
                if (write_aw_fire) begin
                    r_write_active <= 1'b1;
                    r_write_owner  <= write_grant_result ?
                                      WRITE_OWNER_RESULT : WRITE_OWNER_POOL;
                end
            end else if (write_b_fire) begin
                r_write_active <= 1'b0;
            end
        end
    end

    assign m_axi_arid    = grant_pool ? pool_axi_arid    : weight_axi_arid;
    assign m_axi_araddr  = grant_pool ? pool_axi_araddr  : weight_axi_araddr;
    assign m_axi_arlen   = grant_pool ? pool_axi_arlen   : weight_axi_arlen;
    assign m_axi_arsize  = grant_pool ? pool_axi_arsize  : weight_axi_arsize;
    assign m_axi_arburst = grant_pool ? pool_axi_arburst : weight_axi_arburst;
    assign m_axi_arlock  = grant_pool ? pool_axi_arlock  : weight_axi_arlock;
    assign m_axi_arcache = grant_pool ? pool_axi_arcache : weight_axi_arcache;
    assign m_axi_arprot  = grant_pool ? pool_axi_arprot  : weight_axi_arprot;
    assign m_axi_arvalid = !r_read_outstanding && ar_sel_valid;
    assign weight_axi_arready = grant_weight && m_axi_arready;
    assign pool_axi_arready   = grant_pool && m_axi_arready;
    assign m_axi_rready       = sel_pool ? pool_axi_rready : weight_axi_rready;

    assign m_axi_awid    = write_grant_result ? result_axi_awid    : pool_axi_awid;
    assign m_axi_awaddr  = write_grant_result ? result_axi_awaddr  : pool_axi_awaddr;
    assign m_axi_awlen   = write_grant_result ? result_axi_awlen   : pool_axi_awlen;
    assign m_axi_awsize  = write_grant_result ? result_axi_awsize  : pool_axi_awsize;
    assign m_axi_awburst = write_grant_result ? result_axi_awburst : pool_axi_awburst;
    assign m_axi_awlock  = write_grant_result ? result_axi_awlock  : pool_axi_awlock;
    assign m_axi_awcache = write_grant_result ? result_axi_awcache : pool_axi_awcache;
    assign m_axi_awprot  = write_grant_result ? result_axi_awprot  : pool_axi_awprot;
    assign m_axi_awvalid = write_grant_result ? result_axi_awvalid :
                           write_grant_pool ? pool_axi_awvalid : 1'b0;
    assign result_axi_awready = write_grant_result && m_axi_awready;
    assign pool_axi_awready   = write_grant_pool && m_axi_awready;

    assign m_axi_wid     = write_sel_result ? result_axi_wid     : pool_axi_wid;
    assign m_axi_wdata   = write_sel_result ? result_axi_wdata   : pool_axi_wdata;
    assign m_axi_wstrb   = write_sel_result ? result_axi_wstrb   : pool_axi_wstrb;
    assign m_axi_wlast   = write_sel_result ? result_axi_wlast   : pool_axi_wlast;
    assign m_axi_wvalid  = write_sel_result ? result_axi_wvalid  :
                           write_sel_pool ? pool_axi_wvalid : 1'b0;
    assign result_axi_wready = write_sel_result && m_axi_wready;
    assign pool_axi_wready   = write_sel_pool && m_axi_wready;
    assign m_axi_bready  = write_sel_result ? result_axi_bready :
                           write_sel_pool ? pool_axi_bready : 1'b0;

    assign o_dma_req_snoop       = w_dma_req;
    assign o_dma_done_snoop      = w_dma_done;
    assign o_dma_base_addr_snoop = w_dma_base_addr;
    assign o_dma_length_snoop    = w_dma_length;
    assign o_dma_error_snoop     = w_dma_error || w_pool_reorder_error;

    npu_core_top #(
        .USE_DESC_RAM  (1'b1),
        .DSP_MAC_LANES(DSP_MAC_LANES),
        .USE_POOL_REORDER_AXI(USE_POOL_REORDER_AXI),
        .POOL_AXI_BURST_BEATS(POOL_AXI_BURST_BEATS),
        .ENABLE_LAYER_DEBUG(ENABLE_LAYER_DEBUG)
    ) u_core (
        .clk               (clk),
        .rst_n             (rst_n),

        .i_frame_valid     (i_frame_valid),
        .i_lbp_valid       (i_lbp_valid),
        .i_lbp_pixel       (i_lbp_pixel),
        .i_l0_input_preload_en(i_l0_input_preload_en),
        .i_l0_input_packed_en (i_l0_input_packed_en),
        .i_preload_wr_en      (i_preload_wr_en),
        .i_preload_target     (i_preload_target),
        .i_preload_wr_addr    (i_preload_wr_addr),
        .i_preload_wr_mask    (i_preload_wr_mask),
        .i_preload_wr_data    (i_preload_wr_data),
        .i_skip_lbp_load      (i_skip_lbp_load),

        .i_desc_we         (i_desc_we),
        .i_desc_layer      (i_desc_layer),
        .i_desc_word       (i_desc_word),
        .i_desc_wdata      (i_desc_wdata),
        .i_layer_count     (i_layer_count),

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

        .i_pool_scratch_base_addr(i_pool_scratch_base_addr),
        .o_pool_reorder_error(w_pool_reorder_error),
        .o_pool_reorder_dbg0(o_pool_reorder_dbg0),
        .o_pool_reorder_dbg1(o_pool_reorder_dbg1),
        .o_pool_reorder_dbg2(o_pool_reorder_dbg2),
        .o_pool_reorder_dbg3(o_pool_reorder_dbg3),
        .o_pool_reorder_dbg4(o_pool_reorder_dbg4),
        .o_pool_reorder_dbg5(o_pool_reorder_dbg5),
        .o_pool_reorder_dbg6(o_pool_reorder_dbg6),
        .o_pool_reorder_dbg7(o_pool_reorder_dbg7),
        .o_pool_reorder_dbg8(o_pool_reorder_dbg8),
        .o_pool_reorder_dbg9(o_pool_reorder_dbg9),
        .o_pool_reorder_dbg10(o_pool_reorder_dbg10),
        .o_pool_reorder_dbg11(o_pool_reorder_dbg11),
        .o_pool_reorder_dbg12(o_pool_reorder_dbg12),
        .o_pool_reorder_dbg13(o_pool_reorder_dbg13),
        .o_pool_reorder_dbg14(o_pool_reorder_dbg14),
        .o_pool_reorder_dbg15(o_pool_reorder_dbg15),
        .o_pool_reorder_dbg16(o_pool_reorder_dbg16),
        .o_pool_reorder_dbg17(o_pool_reorder_dbg17),
        .o_pool_reorder_dbg18(o_pool_reorder_dbg18),
        .i_layer_dbg_sel(i_layer_dbg_sel),
        .o_layer_dbg0(o_layer_dbg0),
        .o_layer_dbg1(o_layer_dbg1),
        .o_layer_dbg2(o_layer_dbg2),
        .o_layer_dbg3(o_layer_dbg3),
        .o_layer_dbg4(o_layer_dbg4),
        .o_layer_dbg5(o_layer_dbg5),
        .o_layer_dbg6(o_layer_dbg6),
        .o_layer_dbg7(o_layer_dbg7),
        .m_axi_arid         (pool_axi_arid),
        .m_axi_araddr       (pool_axi_araddr),
        .m_axi_arlen        (pool_axi_arlen),
        .m_axi_arsize       (pool_axi_arsize),
        .m_axi_arburst      (pool_axi_arburst),
        .m_axi_arlock       (pool_axi_arlock),
        .m_axi_arcache      (pool_axi_arcache),
        .m_axi_arprot       (pool_axi_arprot),
        .m_axi_arvalid      (pool_axi_arvalid),
        .m_axi_arready      (pool_axi_arready),
        .m_axi_rid          (m_axi_rid),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid && sel_pool),
        .m_axi_rready       (pool_axi_rready),
        .m_axi_awid         (pool_axi_awid),
        .m_axi_awaddr       (pool_axi_awaddr),
        .m_axi_awlen        (pool_axi_awlen),
        .m_axi_awsize       (pool_axi_awsize),
        .m_axi_awburst      (pool_axi_awburst),
        .m_axi_awlock       (pool_axi_awlock),
        .m_axi_awcache      (pool_axi_awcache),
        .m_axi_awprot       (pool_axi_awprot),
        .m_axi_awvalid      (pool_axi_awvalid),
        .m_axi_awready      (pool_axi_awready),
        .m_axi_wid          (pool_axi_wid),
        .m_axi_wdata        (pool_axi_wdata),
        .m_axi_wstrb        (pool_axi_wstrb),
        .m_axi_wlast        (pool_axi_wlast),
        .m_axi_wvalid       (pool_axi_wvalid),
        .m_axi_wready       (pool_axi_wready),
        .m_axi_bid          (m_axi_bid),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid && write_sel_pool),
        .m_axi_bready       (pool_axi_bready),

        .o_kernel_size     (w_kernel_size),

        .o_result_stream_valid(o_result_stream_valid),
        .o_result_stream_data(o_result_stream_data),
        .o_inference_done  (o_inference_done),
        .o_bbox_valid      (o_bbox_valid),
        .o_bbox_data       (o_bbox_data)
    );

    axi_result_writeback u_result_writeback (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_start          (i_result_start),
        .i_enable         (i_result_enable),
        .i_base_addr      (i_result_base_addr),
        .i_max_bytes      (i_result_max_bytes),
        .i_stream_valid   (o_result_stream_valid),
        .i_stream_data    (o_result_stream_data),
        .i_inference_done (o_inference_done),
        .o_busy           (o_result_busy),
        .o_done           (o_result_done),
        .o_error          (o_result_error),
        .o_write_bytes    (o_result_write_bytes),
        .o_checksum       (o_result_checksum),
        .o_last_addr      (o_result_last_addr),
        .m_axi_awid       (result_axi_awid),
        .m_axi_awaddr     (result_axi_awaddr),
        .m_axi_awlen      (result_axi_awlen),
        .m_axi_awsize     (result_axi_awsize),
        .m_axi_awburst    (result_axi_awburst),
        .m_axi_awlock     (result_axi_awlock),
        .m_axi_awcache    (result_axi_awcache),
        .m_axi_awprot     (result_axi_awprot),
        .m_axi_awvalid    (result_axi_awvalid),
        .m_axi_awready    (result_axi_awready),
        .m_axi_wid        (result_axi_wid),
        .m_axi_wdata      (result_axi_wdata),
        .m_axi_wstrb      (result_axi_wstrb),
        .m_axi_wlast      (result_axi_wlast),
        .m_axi_wvalid     (result_axi_wvalid),
        .m_axi_wready     (result_axi_wready),
        .m_axi_bid        (m_axi_bid),
        .m_axi_bresp      (m_axi_bresp),
        .m_axi_bvalid     (m_axi_bvalid && write_sel_result),
        .m_axi_bready     (result_axi_bready)
    );

    axi_weight_dma #(
        .ADDR_W (16)
    ) u_dma (
        .clk                  (clk),
        .rst_n                (rst_n),

        .i_dma_req            (w_dma_req),
        .i_dma_base_addr      (w_dma_base_addr),
        .i_bias_base_addr     (w_bias_base_addr),
        .i_dma_length         (w_dma_length),
        .i_kernel_size        (w_kernel_size),
        .i_param_base_addr    (i_param_base_addr),
        .o_dma_ack            (w_dma_ack),
        .o_dma_done           (w_dma_done),
        .o_dma_error          (w_dma_error),

        .o_weight_data        (w_weight_in_data),
        .o_weight_valid       (w_weight_in_valid),
        .o_weight_addr        (w_weight_in_addr),
        .o_update_weights_en  (w_update_weights_en),

        .o_bias_data          (w_bias_in_data),
        .o_bias_valid         (w_bias_in_valid),
        .o_bias_addr          (w_bias_in_addr),
        .o_update_bias_en     (w_update_bias_en),

        .m_axi_arid           (weight_axi_arid),
        .m_axi_araddr         (weight_axi_araddr),
        .m_axi_arlen          (weight_axi_arlen),
        .m_axi_arsize         (weight_axi_arsize),
        .m_axi_arburst        (weight_axi_arburst),
        .m_axi_arlock         (weight_axi_arlock),
        .m_axi_arcache        (weight_axi_arcache),
        .m_axi_arprot         (weight_axi_arprot),
        .m_axi_arvalid        (weight_axi_arvalid),
        .m_axi_arready        (weight_axi_arready),
        .m_axi_rid            (m_axi_rid),
        .m_axi_rdata          (m_axi_rdata),
        .m_axi_rresp          (m_axi_rresp),
        .m_axi_rlast          (m_axi_rlast),
        .m_axi_rvalid         (m_axi_rvalid && !sel_pool),
        .m_axi_rready         (weight_axi_rready),

        .o_dbg0               (o_param_dma_dbg0),
        .o_dbg1               (o_param_dma_dbg1),
        .o_dbg2               (o_param_dma_dbg2),
        .o_dbg3               (o_param_dma_dbg3),
        .o_dbg4               (o_param_dma_dbg4),
        .o_dbg5               (o_param_dma_dbg5),
        .o_dbg6               (o_param_dma_dbg6),
        .o_dbg7               (o_param_dma_dbg7),
        .o_dbg8               (o_param_dma_dbg8),
        .o_dbg9               (o_param_dma_dbg9),
        .o_dbg10              (o_param_dma_dbg10),
        .o_dbg11              (o_param_dma_dbg11),
        .o_dbg12              (o_param_dma_dbg12),
        .o_dbg13              (o_param_dma_dbg13),
        .o_dbg14              (o_param_dma_dbg14),
        .o_dbg15              (o_param_dma_dbg15),
        .o_dbg16              (o_param_dma_dbg16),
        .o_dbg17              (o_param_dma_dbg17),
        .o_dbg18              (o_param_dma_dbg18)
    );

endmodule
