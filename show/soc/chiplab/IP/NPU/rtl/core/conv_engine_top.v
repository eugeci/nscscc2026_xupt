// ============================================================================
// File Name   : conv_engine_top.v
// Description : 适配空间优先数据流，集成 HardSigmoid 与 144b 加载
// ============================================================================
`include "npu_math_defs.vh"

module conv_engine_top #(
    parameter PIXEL_W   = 8,
    parameter WEIGHT_W  = 8,
    parameter ACC_WIDTH = 24,
    parameter NUM_CHANNELS = 16,
    parameter DSP_MAC_LANES = 9,
    parameter USE_POOL_REORDER_AXI = 1'b0,
    parameter POOL_AXI_BURST_BEATS = 4,
    // Current FaceNet max reorder surface is layer-0 160x120 = 19200 pixels.
    // Increase this parameter if a future microcode topology needs a larger
    // padded-conv + pool reorder surface.
    parameter POOL_REORDER_DEPTH = 19200
)(
    // 【硬性参数约束】ACC_WIDTH >= 32
    // 偏置加法级 bias_i = bias_bus[ch*32 +: ACC_WIDTH]，ACC_WIDTH < 32 时偏置高位被静默截断。
    // npu_core_top 实例化时已设 ACC_WIDTH=32；任何独立使用必须保证 ACC_WIDTH >= 32。
/*     initial if (ACC_WIDTH < 32)
        $warning("[conv_engine_top] ACC_WIDTH=%0d < 32: bias high bits will be silently truncated!", ACC_WIDTH); */

    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   layer_start_clr,

    // 配置接口
    input  wire [7:0]             cfg_width,
    input  wire [7:0]             cfg_height,
    input  wire [1:0]             kernel_size,   
    input  wire                   padding_en,
    input  wire [3:0]             shift_bits,
    input  wire [1:0]             cfg_activation_type, // [新增] 0:ReLU, 1:HardSig
    input  wire                   cfg_pool_en,   
 
    // 数据流控制 (来自 BCU)
    input  wire                   is_first_cin,
    input  wire                   is_last_cin,
    
    // 权重加载接口 (升级为 144-bit 双通道加载 + 全页深度)
    input  wire [143:0]           weight_in_data,
    input  wire                   weight_in_valid,
    input  wire [9:0]             weight_in_addr,   // flat 写入地址，每拍 2 条目
    input  wire                   update_weights_en,

    // 当前 Cin 索引（供 weight_buffer 按页深度读出对应权重）
    input  wire [7:0]             i_current_cin,

    // 偏置加载接口（分组页：每页 16 路 INT32）
    input  wire [31:0]            bias_in_data,
    input  wire                   bias_in_valid,
    input  wire [4:0]             bias_in_addr,
    input  wire                   update_bias_en,
    
    input  wire [7:0]             pixel_in_data,
    input  wire                   pixel_in_valid,
    output wire                   pixel_in_ready,

    // 当前 Cout 组有效 lane 数 (1..NUM_CHANNELS); 末组若 < NUM_CHANNELS，
    // 高位 lane 在 out_pixel_bus 上强制为 0 (硬件契约: 不依赖外部 DMA 灌零)。
    input  wire [4:0]             i_oc_block_size,

    output wire [NUM_CHANNELS*8-1:0] out_pixel_bus,
    output wire                   out_valid,
    output wire [7:0]             out_x,
    output wire [7:0]             out_y,

    // [Step 14.1k 方案A] 流水排空标志: 高表示 conv_engine_top 内部全部子模块
    // 都不再有「飞行中」的 valid 像素, 也没有未来会自发产生 valid 的内部状态
    // (line_buffer_conv flush / PE pipeline / channel_accumulator commit / pool flush 等)
    // BCU/sequencer 应等到此信号高时才能切换 cin_group 或翻转 is_first_cin/is_last_cin
    output wire                   o_pipeline_idle,

    // Intermediate pipeline debug: XOR-folded checksums (per-cycle, accumulated externally)
    output wire [31:0]            o_dbg_pe_fold,       // pe_sum_bus on pe_valid
    output wire [31:0]            o_dbg_bias_fold,      // bias_sum_bus on bias_valid
    output wire [31:0]            o_dbg_quant_fold,     // quant_out_bus on quant_valid
    output wire [31:0]            o_dbg_wt_fold,        // weight bus XOR
    output wire [7:0]             o_dbg_valid_flags,    // pipeline valid snapshot

    input  wire [31:0]            i_pool_scratch_base_addr,
    output wire                   o_pool_reorder_error,
    output wire [31:0]            o_pool_reorder_dbg0,
    output wire [31:0]            o_pool_reorder_dbg1,
    output wire [31:0]            o_pool_reorder_dbg2,
    output wire [31:0]            o_pool_reorder_dbg3,
    output wire [31:0]            o_pool_reorder_dbg4,
    output wire [31:0]            o_pool_reorder_dbg5,
    output wire [31:0]            o_pool_reorder_dbg6,
    output wire [31:0]            o_pool_reorder_dbg7,
    output wire [31:0]            o_pool_reorder_dbg8,
    output wire [31:0]            o_pool_reorder_dbg9,
    output wire [31:0]            o_pool_reorder_dbg10,
    output wire [31:0]            o_pool_reorder_dbg11,
    output wire [31:0]            o_pool_reorder_dbg12,
    output wire [31:0]            o_pool_reorder_dbg13,
    output wire [31:0]            o_pool_reorder_dbg14,
    output wire [31:0]            o_pool_reorder_dbg15,
    output wire [31:0]            o_pool_reorder_dbg16,
    output wire [31:0]            o_pool_reorder_dbg17,
    output wire [31:0]            o_pool_reorder_dbg18,

    output wire [3:0]             m_axi_arid,
    output wire [31:0]            m_axi_araddr,
    output wire [7:0]             m_axi_arlen,
    output wire [2:0]             m_axi_arsize,
    output wire [1:0]             m_axi_arburst,
    output wire                   m_axi_arlock,
    output wire [3:0]             m_axi_arcache,
    output wire [2:0]             m_axi_arprot,
    output wire                   m_axi_arvalid,
    input  wire                   m_axi_arready,
    input  wire [3:0]             m_axi_rid,
    input  wire [31:0]            m_axi_rdata,
    input  wire [1:0]             m_axi_rresp,
    input  wire                   m_axi_rlast,
    input  wire                   m_axi_rvalid,
    output wire                   m_axi_rready,

    output wire [3:0]             m_axi_awid,
    output wire [31:0]            m_axi_awaddr,
    output wire [7:0]             m_axi_awlen,
    output wire [2:0]             m_axi_awsize,
    output wire [1:0]             m_axi_awburst,
    output wire                   m_axi_awlock,
    output wire [3:0]             m_axi_awcache,
    output wire [2:0]             m_axi_awprot,
    output wire                   m_axi_awvalid,
    input  wire                   m_axi_awready,
    output wire [3:0]             m_axi_wid,
    output wire [31:0]            m_axi_wdata,
    output wire [3:0]             m_axi_wstrb,
    output wire                   m_axi_wlast,
    output wire                   m_axi_wvalid,
    input  wire                   m_axi_wready,
    input  wire [3:0]             m_axi_bid,
    input  wire [1:0]             m_axi_bresp,
    input  wire                   m_axi_bvalid,
    output wire                   m_axi_bready
);

    // 内部总线
    localparam BUS_WIDTH = NUM_CHANNELS * 8;
    localparam SUM_WIDTH = ACC_WIDTH * NUM_CHANNELS;
    localparam MODE_1X1 = 2'b00;
    localparam MODE_2X2 = 2'b01;
    localparam MODE_3X3 = 2'b10;

    localparam POOL_REORDER_AW = `NPU_CLOG2(POOL_REORDER_DEPTH);

    wire [PIXEL_W*9-1:0]   lb_win_flat;
    wire                   lb_win_valid;
    wire [7:0]             lb_x, lb_y;
    wire [NUM_CHANNELS*72-1:0]  wb_weights_bus;

    // Timing boundary between the line-buffer/cache reconstruction network and
    // the 16 DSP MAC lanes.  Window, weights and control are captured together,
    // preserving one-result-per-cycle throughput while adding one fixed cycle.
    reg [PIXEL_W*9-1:0]        pe_win_flat_reg;
    reg                         pe_win_valid_reg;
    reg [7:0]                   pe_x_reg;
    reg [7:0]                   pe_y_reg;
    reg [NUM_CHANNELS*72-1:0]  pe_weights_bus_reg;
    reg                         pe_first_cin_reg;
    reg                         pe_last_cin_reg;
    
    wire [SUM_WIDTH-1:0]   pe_sum_bus;
    wire [NUM_CHANNELS-1:0] pe_valid_bus;
    wire [NUM_CHANNELS*8-1:0] pe_x_bus, pe_y_bus;
    wire [NUM_CHANNELS*32-1:0]  bias_bus;

    wire [SUM_WIDTH-1:0]   bias_sum_bus;
    wire                   bias_valid;
    wire [7:0]             bias_x, bias_y;

    wire [SUM_WIDTH-1:0]   act_out_bus;
    wire                   act_valid;
    wire [7:0]             act_x, act_y;

    wire [BUS_WIDTH-1:0]   quant_out_bus;
    wire                   quant_valid;
    wire [7:0]             quant_x, quant_y;

    wire [NUM_CHANNELS*32-1:0] pool_win_flat;
    wire                        pool_win_valid;
    wire [7:0]                  pool_win_x, pool_win_y;
    wire [BUS_WIDTH-1:0]        pool_p00_bus;
    wire [BUS_WIDTH-1:0]        pool_p01_bus;
    wire [BUS_WIDTH-1:0]        pool_p10_bus;
    wire [BUS_WIDTH-1:0]        pool_p11_bus;
    wire [BUS_WIDTH-1:0]        pool_out_bus;
    wire                        pool_out_valid;
    wire [7:0]                  pool_out_x, pool_out_y;
    wire [BUS_WIDTH-1:0]        lb_pool_data_in;
    wire                        lb_pool_data_valid;
    wire [BUS_WIDTH-1:0]        pool_reorder_rdata;
    wire                        pool_reorder_rvalid;
    wire                        pool_reorder_input_ready;
    wire                        pool_reorder_busy;

    reg [7:0] conv_out_w, conv_out_h;
    always @(*) begin
        case (kernel_size)
            MODE_1X1: begin
                conv_out_w = cfg_width;
                conv_out_h = cfg_height;
            end
            MODE_2X2: begin
                conv_out_w = padding_en ? (cfg_width + 8'd1) : (cfg_width - 8'd1);
                conv_out_h = padding_en ? (cfg_height + 8'd1) : (cfg_height - 8'd1);
            end
            default: begin
                conv_out_w = padding_en ? cfg_width : (cfg_width - 8'd2);
                conv_out_h = padding_en ? cfg_height : (cfg_height - 8'd2);
            end
        endcase
    end

    // --- 1. 权重 Buffer (144b适配 + 全页深度 SRAM) ---
    // [Step 14.1l] i_current_cin 1 拍延迟用于对齐 line_buffer 数据路径
    //   conv_engine_top 内部数据路径: pixel_in_data -> line_buffer p11 (1 拍) -> mac_tree
    //   故权重路径也需延迟 1 拍, 使 mac_tree 看到的 (data, weight) 对齐到同一 cin。
    //
    //   集成路径 (npu_core_top): BCU r_cin_idx -> SRAM (1 拍) -> conv_engine_top.pixel_in_data
    //   故 npu_core_top 还需在 BCU 输出 o_cin_idx_full 与 conv_engine_top.i_current_cin 之间
    //   再加 1 拍寄存器, 使总延迟达到 2 拍 (匹配 SRAM + line_buffer 的总数据延迟)。
    //
    // [Step 15.3] weight_buffer 已重构为内部同步读, 自带 1 拍延迟。原本此处的
    //   r_current_cin_d1 寄存器现已凗余, 直接将 i_current_cin 直连给 weight_buffer。
    //   所有 npu_core_top / 平台测试的外部约定不变 (1 拍延迟由 weight_buffer 内部承担)。
    weight_buffer #(
        .NUM_CHANNELS(NUM_CHANNELS), .MAX_CIN(32)
    ) u_weight_buf (
        .clk(clk), .rst_n(rst_n),
        .kernel_size(kernel_size),
        .weight_in_data(weight_in_data), .weight_in_valid(weight_in_valid),
        .weight_in_addr(weight_in_addr), .update_weights_en(update_weights_en),
        .i_current_cin(i_current_cin), .weights_bus_out(wb_weights_bus)
    );

    // --- 2. Line Buffer (保持原样，无需冻结逻辑) ---
    wire lbc_busy;
    line_buffer_conv #(
        .DATA_WIDTH(PIXEL_W)
    ) u_lb_conv (
        .clk(clk), .rst_n(rst_n),
        .i_clr(layer_start_clr),
        .is_last_cin(is_last_cin), // 传递给 line_buffer_conv 用于 EOF 判断
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .kernel_size(kernel_size), .padding_en(padding_en),
        .data_in(pixel_in_data), .data_in_valid(pixel_in_valid),
        .win_out_flat(lb_win_flat), .win_valid(lb_win_valid),
        .out_x(lb_x), .out_y(lb_y),
        .o_busy(lbc_busy)
    );

    // --- 2.5 Bias Buffer (分组双缓冲) ---
    bias_buffer #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_bias_buf (
        .clk(clk), .rst_n(rst_n),
        .bias_in_data(bias_in_data), .bias_in_valid(bias_in_valid),
        .bias_in_addr(bias_in_addr), .update_bias_en(update_bias_en),
        .bias_bus_out(bias_bus)
    );

    // 【核心修复】：控制信号相位对齐
    // 理由：line_buffer_conv 对数据流产生了一拍延迟，控制流必须同步对齐
    // ========================================================================
    reg is_first_cin_reg, is_last_cin_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_first_cin_reg <= 1'b0;
            is_last_cin_reg  <= 1'b0;
        end else if (layer_start_clr) begin
            is_first_cin_reg <= 1'b0;
            is_last_cin_reg  <= 1'b0;
        end else begin
            is_first_cin_reg <= is_first_cin;
            is_last_cin_reg  <= is_last_cin;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_win_flat_reg   <= {PIXEL_W*9{1'b0}};
            pe_win_valid_reg  <= 1'b0;
            pe_x_reg          <= 8'd0;
            pe_y_reg          <= 8'd0;
            pe_weights_bus_reg <= {NUM_CHANNELS*72{1'b0}};
            pe_first_cin_reg  <= 1'b0;
            pe_last_cin_reg   <= 1'b0;
        end else if (layer_start_clr) begin
            pe_win_valid_reg <= 1'b0;
            pe_first_cin_reg <= 1'b0;
            pe_last_cin_reg  <= 1'b0;
        end else begin
            pe_win_flat_reg    <= lb_win_flat;
            pe_win_valid_reg   <= lb_win_valid;
            pe_x_reg           <= lb_x;
            pe_y_reg           <= lb_y;
            pe_weights_bus_reg <= wb_weights_bus;
            pe_first_cin_reg   <= is_first_cin_reg;
            pe_last_cin_reg    <= is_last_cin_reg;
        end
    end

    // --- 3. PE Array (计算底座) ---
    pe_array #(
        .ACC_WIDTH(ACC_WIDTH), .NUM_CHANNELS(NUM_CHANNELS),
        .DSP_MAC_LANES(DSP_MAC_LANES)
    ) u_pe_array (
        .clk(clk), .rst_n(rst_n),
        .win_data_flat(pe_win_flat_reg), .win_valid(pe_win_valid_reg),
        .win_x(pe_x_reg), .win_y(pe_y_reg),
        .weights_bus(pe_weights_bus_reg), .cfg_width(conv_out_w),
        .is_first_cin(pe_first_cin_reg), .is_last_cin(pe_last_cin_reg),
        .out_sum_bus(pe_sum_bus), .out_valid_bus(pe_valid_bus),
        .out_x_bus(pe_x_bus), .out_y_bus(pe_y_bus)
    );

    // --- 4. Bias阶段（ConvAcc + Bias） ---
    genvar i_bias;
    generate
        for (i_bias = 0; i_bias < NUM_CHANNELS; i_bias = i_bias + 1) begin : GEN_BIAS_ADD
            wire signed [ACC_WIDTH-1:0] pe_sum_i;
            wire signed [ACC_WIDTH-1:0] bias_i;
            wire signed [ACC_WIDTH-1:0] sum_i;
            assign pe_sum_i = pe_sum_bus[i_bias*ACC_WIDTH +: ACC_WIDTH];
            assign bias_i   = bias_bus[i_bias*32 +: ACC_WIDTH];
            assign sum_i    = pe_sum_i + bias_i;
            assign bias_sum_bus[i_bias*ACC_WIDTH +: ACC_WIDTH] = sum_i;
        end
    endgenerate

    assign bias_valid   = pe_valid_bus[0];
    assign bias_x       = pe_x_bus[7:0];
    assign bias_y       = pe_y_bus[7:0];

    // --- 5. 激活层 (多模式适配) ---
    activation_core #(
        .ACC_WIDTH(ACC_WIDTH), .NUM_CHANNELS(NUM_CHANNELS)
    ) u_act (
        .clk(clk), .rst_n(rst_n),
        .cfg_activation_type(cfg_activation_type),
        .in_sum_bus(bias_sum_bus), .in_valid(bias_valid),
        .in_x(bias_x), .in_y(bias_y),
        .act_out_bus(act_out_bus), .act_valid(act_valid),
        .act_x(act_x), .act_y(act_y)
    );

    // --- 6. 量化层 (下溢防卫) ---
    quantize #(
        .ACC_WIDTH(ACC_WIDTH), .NUM_CHANNELS(NUM_CHANNELS)
    ) u_quant (
        .clk(clk), .rst_n(rst_n),
        .act_out_bus(act_out_bus), .act_valid(act_valid),
        .act_x(act_x), .act_y(act_y), .shift_bits(shift_bits),
        .out_pixel_bus(quant_out_bus), .out_valid(quant_valid),
        .out_x(quant_x), .out_y(quant_y)
    );

    // 2x2+padding / 3x3+padding 时，quant 输出顺序不是标准 raster（边界在 flush 末尾输出）。
    // 池化 line_buffer 需要 raster 输入，因此这里按 (x,y) 捕获后再按 raster 重放。
    // Step 14.1d: 扩展到 3x3+pad — FaceNet C4 (cin=16 cout=24 3x3+pad+pool) 必需。
    wire mode_2x2_pad = (kernel_size == MODE_2X2) && padding_en;
    wire mode_3x3_pad_pool = (kernel_size == MODE_3X3) && padding_en;
    wire pool_reorder_en = cfg_pool_en && (mode_2x2_pad || mode_3x3_pad_pool);
    pool_reorder_buffer #(
        .BUS_WIDTH    (BUS_WIDTH),
        .ADDR_WIDTH   (POOL_REORDER_AW),
        .MEMORY_DEPTH (POOL_REORDER_DEPTH),
        .USE_AXI      (USE_POOL_REORDER_AXI),
        .AXI_BURST_BEATS(POOL_AXI_BURST_BEATS)
    ) u_pool_reorder (
        .clk                 (clk),
        .rst_n               (rst_n),
        .i_clear             (layer_start_clr || !cfg_pool_en),
        .i_enable            (pool_reorder_en),
        .i_width             (conv_out_w),
        .i_height            (conv_out_h),
        .i_scratch_base_addr (i_pool_scratch_base_addr),
        .i_in_valid          (quant_valid),
        .i_in_data           (quant_out_bus),
        .i_in_x              (quant_x),
        .i_in_y              (quant_y),
        .o_input_ready       (pool_reorder_input_ready),
        .o_out_data          (pool_reorder_rdata),
        .o_out_valid         (pool_reorder_rvalid),
        .o_busy              (pool_reorder_busy),
        .o_error             (o_pool_reorder_error),
        .o_dbg0              (o_pool_reorder_dbg0),
        .o_dbg1              (o_pool_reorder_dbg1),
        .o_dbg2              (o_pool_reorder_dbg2),
        .o_dbg3              (o_pool_reorder_dbg3),
        .o_dbg4              (o_pool_reorder_dbg4),
        .o_dbg5              (o_pool_reorder_dbg5),
        .o_dbg6              (o_pool_reorder_dbg6),
        .o_dbg7              (o_pool_reorder_dbg7),
        .o_dbg8              (o_pool_reorder_dbg8),
        .o_dbg9              (o_pool_reorder_dbg9),
        .o_dbg10             (o_pool_reorder_dbg10),
        .o_dbg11             (o_pool_reorder_dbg11),
        .o_dbg12             (o_pool_reorder_dbg12),
        .o_dbg13             (o_pool_reorder_dbg13),
        .o_dbg14             (o_pool_reorder_dbg14),
        .o_dbg15             (o_pool_reorder_dbg15),
        .o_dbg16             (o_pool_reorder_dbg16),
        .o_dbg17             (o_pool_reorder_dbg17),
        .o_dbg18             (o_pool_reorder_dbg18),
        .m_axi_arid          (m_axi_arid),
        .m_axi_araddr        (m_axi_araddr),
        .m_axi_arlen         (m_axi_arlen),
        .m_axi_arsize        (m_axi_arsize),
        .m_axi_arburst       (m_axi_arburst),
        .m_axi_arlock        (m_axi_arlock),
        .m_axi_arcache       (m_axi_arcache),
        .m_axi_arprot        (m_axi_arprot),
        .m_axi_arvalid       (m_axi_arvalid),
        .m_axi_arready       (m_axi_arready),
        .m_axi_rid           (m_axi_rid),
        .m_axi_rdata         (m_axi_rdata),
        .m_axi_rresp         (m_axi_rresp),
        .m_axi_rlast         (m_axi_rlast),
        .m_axi_rvalid        (m_axi_rvalid),
        .m_axi_rready        (m_axi_rready),
        .m_axi_awid          (m_axi_awid),
        .m_axi_awaddr        (m_axi_awaddr),
        .m_axi_awlen         (m_axi_awlen),
        .m_axi_awsize        (m_axi_awsize),
        .m_axi_awburst       (m_axi_awburst),
        .m_axi_awlock        (m_axi_awlock),
        .m_axi_awcache       (m_axi_awcache),
        .m_axi_awprot        (m_axi_awprot),
        .m_axi_awvalid       (m_axi_awvalid),
        .m_axi_awready       (m_axi_awready),
        .m_axi_wid           (m_axi_wid),
        .m_axi_wdata         (m_axi_wdata),
        .m_axi_wstrb         (m_axi_wstrb),
        .m_axi_wlast         (m_axi_wlast),
        .m_axi_wvalid        (m_axi_wvalid),
        .m_axi_wready        (m_axi_wready),
        .m_axi_bid           (m_axi_bid),
        .m_axi_bresp         (m_axi_bresp),
        .m_axi_bvalid        (m_axi_bvalid),
        .m_axi_bready        (m_axi_bready)
    );

    assign pixel_in_ready = (!pool_reorder_en) || pool_reorder_input_ready;
    assign lb_pool_data_in = pool_reorder_en ? pool_reorder_rdata : quant_out_bus;
    // [Step 14.1i] Gate line_buffer_pool's input valid by cfg_pool_en so that
    // layers WITHOUT pool (e.g. L5 = C6, 1×1 no-pool) do NOT advance the
    // pool line buffer's in_x/in_y counters. Previously quant_valid pulses
    // were forwarded unconditionally; line_buffer_pool tracked them, but its
    // is_eof condition depends on cfg_width/cfg_height matching exactly, and
    // any cfg transition mid-stream (e.g. cin_g boundary, layer change with
    // overlapping flush) would skip is_eof and leave in_y latched at a high
    // value. By the next pool-enabled layer (L6 = C7), in_y carried over to
    // ~28-35, making max_pool emit at out_y=14..17 instead of 0..2.
    // Gating on cfg_pool_en keeps the pool buffer fully inert during no-pool
    // layers (downstream MUX in line 315 already discards its output anyway),
    // so state stays at the post-flush (0,0) reset of the prior pool layer.
    assign lb_pool_data_valid = cfg_pool_en
                              ? (pool_reorder_en ? pool_reorder_rvalid : quant_valid)
                              : 1'b0;

    // 每次 BCU 计算启动时清空 pool transient 状态。旧逻辑只在 cfg_pool_en
    // 上升沿清空；L0/L1 连续 pool 层不会触发该边沿，真实 FPGA 上容易把上一组
    // 尾部状态带入下一组。这里不清 PING/PONG/PSUM，只清 line buffer/reorder 状态。
    reg cfg_pool_en_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cfg_pool_en_d1 <= 1'b0;
        else        cfg_pool_en_d1 <= cfg_pool_en;
    end
    wire lbp_clr = layer_start_clr || (cfg_pool_en && !cfg_pool_en_d1);

    // --- 7. 可选池化尾部 (Quant -> Pool) ---
    line_buffer_pool #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_lb_pool (
        .clk(clk), .rst_n(rst_n),
        .i_clr(lbp_clr),
        .cfg_width(conv_out_w), .cfg_height(conv_out_h),
        .data_in(lb_pool_data_in), .data_in_valid(lb_pool_data_valid),
        .pool_win_flat(pool_win_flat), .win_valid(pool_win_valid),
        .out_x(pool_win_x), .out_y(pool_win_y)
    );

    assign pool_p00_bus = pool_win_flat[BUS_WIDTH*1-1:BUS_WIDTH*0];
    assign pool_p01_bus = pool_win_flat[BUS_WIDTH*2-1:BUS_WIDTH*1];
    assign pool_p10_bus = pool_win_flat[BUS_WIDTH*3-1:BUS_WIDTH*2];
    assign pool_p11_bus = pool_win_flat[BUS_WIDTH*4-1:BUS_WIDTH*3];

    max_pool #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_max_pool (
        .clk(clk), .rst_n(rst_n),
        .in_p00_bus(pool_p00_bus), .in_p01_bus(pool_p01_bus),
        .in_p10_bus(pool_p10_bus), .in_p11_bus(pool_p11_bus),
        .in_valid(pool_win_valid), .in_x(pool_win_x), .in_y(pool_win_y),
        .out_pixel_bus(pool_out_bus), .out_valid(pool_out_valid),
        .out_x(pool_out_x), .out_y(pool_out_y)
    );

    // --- 8. 末组 lane 掩码 (Cout 分组末组有效 lane 不足 NUM_CHANNELS 时, 高位 lane 强制 0) ---
    wire [BUS_WIDTH-1:0] w_out_pre_mask;
    assign w_out_pre_mask = cfg_pool_en ? pool_out_bus : quant_out_bus;

    genvar i_mask;
    generate
        for (i_mask = 0; i_mask < NUM_CHANNELS; i_mask = i_mask + 1) begin : GEN_LANE_MASK
            assign out_pixel_bus[i_mask*8 +: 8] =
                ({1'b0, i_mask[3:0]} < i_oc_block_size)
                    ? w_out_pre_mask[i_mask*8 +: 8]
                    : 8'd0;
        end
    endgenerate

    assign out_valid     = cfg_pool_en ? pool_out_valid : quant_valid;
    assign out_x         = cfg_pool_en ? pool_out_x : quant_x;
    assign out_y         = cfg_pool_en ? pool_out_y : quant_y;

    // ============================================================================
    // [Step 14.1k 方案A] o_pipeline_idle 合成
    //   组成 = (line_buffer_conv 已 idle) AND (PE→act→quant→pool 后段 N 拍内无 valid)
    //   后段流水深度估算 (Step 14.1k 阶段1):
    //     - line-buffer/PE timing boundary + mac_tree_3x3: ~4 拍
    //     - channel_accumulator: 2 拍 (ram_rdata 1 拍 + commit 1 拍)
    //     - bias/activation/quant: 各 1 拍组合或单级
    //     - line_buffer_pool flush: max(W,H)+ 拍 (cfg_pool_en 时)
    //   保守取上限 16 拍 -> drain shift register: 一旦观察到任何「后段 valid」或
    //   lbc_busy=1 / pixel_in_valid=1, 就把 drain_cnt 重置为 16; 否则每拍 -1。
    //   drain_cnt==0 且 lbc_busy==0 -> idle。
    //   注: cfg_pool_en=0 (L7 等无 pool 层) drain 余量绰绰有余 (实际只需 ~6 拍)。
    // ============================================================================
    reg [4:0] r_post_drain_cnt;  // 5-bit, max 31
    wire any_downstream_valid = lb_win_valid          // line-buffer 输出
                              || pe_win_valid_reg      // PE timing-boundary 输出
                              || (|pe_valid_bus)       // PE 输出 / accumulator final
                              || act_valid             // activation 输出
                              || quant_valid           // quant 输出
                              || pool_reorder_busy
                              || pool_reorder_rvalid
                              || pool_win_valid        // pool 输入
                              || pool_out_valid;       // pool 输出
    wire pipeline_active = lbc_busy || pixel_in_valid || any_downstream_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  r_post_drain_cnt <= 5'd0;
        else if (layer_start_clr)    r_post_drain_cnt <= 5'd0;
        else if (pipeline_active)    r_post_drain_cnt <= 5'd16;
        else if (r_post_drain_cnt > 0) r_post_drain_cnt <= r_post_drain_cnt - 1'b1;
    end
    assign o_pipeline_idle = (r_post_drain_cnt == 5'd0) && !pipeline_active;

    // ---- Intermediate pipeline debug ----
    wire [31:0] w_dbg_pe_fold_raw;
    wire [31:0] w_dbg_bias_fold_raw;
    wire [31:0] w_dbg_quant_fold_raw;
    wire [31:0] w_dbg_wt_fold_raw;

    npu_xor_fold #(
        .IN_WIDTH (SUM_WIDTH),
        .OUT_WIDTH(32)
    ) u_dbg_pe_fold (
        .i_data(pe_sum_bus),
        .o_fold(w_dbg_pe_fold_raw)
    );

    npu_xor_fold #(
        .IN_WIDTH (SUM_WIDTH),
        .OUT_WIDTH(32)
    ) u_dbg_bias_fold (
        .i_data(bias_sum_bus),
        .o_fold(w_dbg_bias_fold_raw)
    );

    npu_xor_fold #(
        .IN_WIDTH (BUS_WIDTH),
        .OUT_WIDTH(32)
    ) u_dbg_quant_fold (
        .i_data(quant_out_bus),
        .o_fold(w_dbg_quant_fold_raw)
    );

    npu_xor_fold #(
        .IN_WIDTH (NUM_CHANNELS*72),
        .OUT_WIDTH(32)
    ) u_dbg_wt_fold (
        .i_data(wb_weights_bus),
        .o_fold(w_dbg_wt_fold_raw)
    );

    // Per-cycle checksums: valid-gated, externally accumulated per layer
    assign o_dbg_pe_fold    = (|pe_valid_bus) ? w_dbg_pe_fold_raw    : 32'd0;
    assign o_dbg_bias_fold   = bias_valid     ? w_dbg_bias_fold_raw  : 32'd0;
    assign o_dbg_quant_fold  = quant_valid    ? w_dbg_quant_fold_raw : 32'd0;
    reg pixel_in_valid_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pixel_in_valid_d1 <= 1'b0;
        else        pixel_in_valid_d1 <= pixel_in_valid;
    end
    assign o_dbg_wt_fold     = pixel_in_valid_d1 ? w_dbg_wt_fold_raw : 32'd0;
    assign o_dbg_valid_flags = {o_pipeline_idle,
                                out_valid,
                                quant_valid,
                                bias_valid,
                                (|pe_valid_bus),
                                lb_win_valid,
                                pixel_in_valid_d1,
                                pixel_in_valid};

endmodule
