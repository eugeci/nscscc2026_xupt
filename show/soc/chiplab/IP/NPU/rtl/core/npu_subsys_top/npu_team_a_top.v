// -----------------------------------------------------------------------------
// Module      : npu_team_a_top
// Description : Team A 集成顶层 (GCU + BCU + PING/PONG BRAM + Dummy NPU)
// -----------------------------------------------------------------------------
module npu_team_a_top (
    input  wire         clk,
    input  wire         rst_n,

    // SoC Interface
    input  wire [31:0]  cfg_wdata,
    input  wire [31:0]  cfg_addr,
    input  wire         cfg_wen,
    output wire [31:0]  cfg_rdata,
    output wire         irq_layer_done
);

    // 内部连线声明
    wire [7:0]  w_cfg_width, w_cfg_height, w_cfg_cin_total;
    wire [1:0]  w_cfg_kernel;
    wire        w_cfg_pool_en, w_cfg_padding_en;
    wire        w_layer_start, w_layer_done, w_pingpong_sel;

    wire [14:0] w_bcu_rd_addr;
    wire [12:0] w_bcu_wr_addr;
    wire        w_bcu_rd_en;
    wire [3:0]  w_bcu_cin_idx;
    wire        w_npu_in_valid, w_npu_out_valid;

    wire [7:0]  w_ping_read_data, w_pong_read_data;
    wire [127:0] w_npu_out_bus;

    // ==========================================
    // 1. GCU 实例化
    // ==========================================
    gcu gcu_inst (
        .clk(clk), .rst_n(rst_n),
        .cfg_wdata(cfg_wdata), .cfg_addr(cfg_addr), .cfg_wen(cfg_wen),
        .cfg_rdata(cfg_rdata), .irq_layer_done(irq_layer_done),
        .cfg_width(w_cfg_width), .cfg_height(w_cfg_height),
        .cfg_kernel(w_cfg_kernel), .cfg_pool_en(w_cfg_pool_en),
        .cfg_padding_en(w_cfg_padding_en), .cfg_shift_bits(), 
        .cfg_cin_total(w_cfg_cin_total),
        .layer_start(w_layer_start), .layer_done(w_layer_done),
        .pingpong_sel(w_pingpong_sel)
    );

    // ==========================================
    // 2. BCU 实例化
    // ==========================================
    bcu bcu_inst (
        .clk(clk), .rst_n(rst_n),
        .layer_start(w_layer_start), .layer_done(w_layer_done),
        .i_is_fc_mode(1'b0),
        .i_cfg_width(w_cfg_width), .i_cfg_height(w_cfg_height),
        .i_cfg_kernel(w_cfg_kernel), .i_cfg_pool_en(w_cfg_pool_en),
        .i_cfg_padding_en(w_cfg_padding_en), .i_cfg_cin_total(w_cfg_cin_total),
        .i_oc_group_idx(4'd0),
        .i_cin_group_idx(6'd0),
        .i_cin_block_size(w_cfg_cin_total[4:0]),
        .i_is_first_cin_group(1'b1),
        .i_is_last_cin_group(1'b1),
        .i_is_layer0(1'b0),
        .i_l0_packed_read_en(1'b0),
        .o_sram_rd_addr(w_bcu_rd_addr), .o_sram_rd_en(w_bcu_rd_en),
        .o_sram_cin_idx(w_bcu_cin_idx), .o_cin_idx_full(), .o_sram_wr_addr(w_bcu_wr_addr),
        .i_npu_in_ready(1'b1),
        .o_npu_in_valid(w_npu_in_valid), .o_npu_is_first_cin(), .o_npu_is_last_cin(),
        .i_npu_out_valid(w_npu_out_valid),
        .i_conv_out_x(8'd0),
        .i_conv_out_y(8'd0),
        .i_pipeline_idle(1'b1),
        .o_dbg0(),
        .o_dbg1(),
        .o_dbg2(),
        .o_dbg3()
    );

    // ==========================================
    // 3. Ping-Pong 数据流路由网格 (Crossbar)
    // ==========================================
    // sel=0: 读PING, 写PONG; sel=1: 读PONG, 写PING
    wire w_ping_rd_en = w_bcu_rd_en & (~w_pingpong_sel);
    wire w_pong_rd_en = w_bcu_rd_en & (w_pingpong_sel);
    
    wire w_ping_wr_en = w_npu_out_valid & (w_pingpong_sel);
    wire w_pong_wr_en = w_npu_out_valid & (~w_pingpong_sel);

    // 送入 NPU 的像素通过 MUX 选择
    wire [7:0] w_npu_pixel_in = w_pingpong_sel ? w_pong_read_data : w_ping_read_data;

    // ==========================================
    // 4. FM Bank Array (PING)
    // ==========================================
    fm_bank_array ping_array (
        .clk(clk),
        .i_write_bus(w_npu_out_bus), .i_write_en(w_ping_wr_en), .i_write_mask(16'hffff), .i_write_addr(w_bcu_wr_addr),
        .i_read_cin_idx(w_bcu_cin_idx), .i_read_en(w_ping_rd_en), .i_read_addr(w_bcu_rd_addr[12:0]),
        .o_read_data(w_ping_read_data)
    );

    // ==========================================
    // 5. FM Bank Array (PONG)
    // ==========================================
    fm_bank_array pong_array (
        .clk(clk),
        .i_write_bus(w_npu_out_bus), .i_write_en(w_pong_wr_en), .i_write_mask(16'hffff), .i_write_addr(w_bcu_wr_addr),
        .i_read_cin_idx(w_bcu_cin_idx), .i_read_en(w_pong_rd_en), .i_read_addr(w_bcu_rd_addr[12:0]),
        .o_read_data(w_pong_read_data)
    );

    // ==========================================
    // 6. Dummy NPU 实例化
    // ==========================================
    dummy_npu #(
        .PIPELINE_DEPTH(5) // 模拟5拍延时
    ) npu_engine (
        .clk(clk), .rst_n(rst_n),
        .pixel_in_data(w_npu_pixel_in), .pixel_in_valid(w_npu_in_valid),
        .out_pixel_bus(w_npu_out_bus), .out_valid(w_npu_out_valid)
    );

endmodule
