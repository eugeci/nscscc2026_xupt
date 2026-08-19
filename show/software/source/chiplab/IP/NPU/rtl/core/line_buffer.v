// ============================================================================
// File Name   : line_buffer.v
// Description : 动态多模式行缓冲引擎 (支持 1x1, 2x2, 3x3)
//               核心优化：利用门控信号动态关闭 FIFO，实现功耗与资源的极致节省
// ============================================================================

module line_buffer #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 256
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire [7:0]             cfg_width,
    input  wire [7:0]             cfg_height,
    input  wire [1:0]             kernel_size, // 00: 1x1, 01: 2x2, 10: 3x3
    input  wire                   padding_en,

    input  wire [DATA_WIDTH-1:0]  data_in,
    input  wire                   data_in_valid,

    output wire [DATA_WIDTH*9-1:0] win_out_flat,
    output wire                   win_valid,
    output wire [7:0]             out_x,
    output wire [7:0]             out_y
);
    // 模式参数定义
    localparam MODE_1X1 = 2'b00;
    localparam MODE_2X2 = 2'b01;
    localparam MODE_3X3 = 2'b10;

    reg [7:0] in_x, in_y;
    reg [8:0] flush_cnt;

    wire is_eof = (in_x == cfg_width - 1) && (in_y == cfg_height - 1) && data_in_valid;

    // --------------------------------------------------------------
    // 1. 动态 Flush 计数器
    // --------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flush_cnt <= 0;
        else if (is_eof) begin
            if (kernel_size == MODE_1X1)
                flush_cnt <= 1; // 1x1 仅需 1 拍把最后一点推出
            else
                flush_cnt <= cfg_width + 5; // 2x2/3x3 需要排空 FIFO
        end else if (flush_cnt > 0)
            flush_cnt <= flush_cnt - 1;
    end

    wire internal_valid = data_in_valid || (flush_cnt > 0);
    wire [DATA_WIDTH-1:0] internal_data = data_in_valid ? data_in : {DATA_WIDTH{1'b0}};

    // 输入坐标计数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_x <= 0; in_y <= 0;
        end else if (flush_cnt == 1) begin
            in_x <= 0; in_y <= 0; // 帧复位
        end else if (internal_valid) begin
            if (in_x == cfg_width - 1) begin
                in_x <= 0; in_y <= in_y + 1;
            end else begin
                in_x <= in_x + 1;
            end
        end
    end

    // --------------------------------------------------------------
    // 2. 动态 FIFO 使能 (极致省电优化)
    // --------------------------------------------------------------
    wire fifo1_en = (kernel_size == MODE_2X2) || (kernel_size == MODE_3X3);
    wire fifo2_en = (kernel_size == MODE_3X3);

    wire fifo1_wr_en = internal_valid && fifo1_en;
    wire fifo1_rd_en = internal_valid && (in_y > 0 || flush_cnt > 0) && fifo1_en;

    // 【修复点】：将输出 wire 的声明提前到被调用之前！
    wire [DATA_WIDTH-1:0] fifo1_dout, fifo2_dout;
    wire fifo1_empty, fifo2_empty;

    wire fifo2_wr_en = fifo1_rd_en && !fifo1_empty && fifo2_en;
    wire fifo2_rd_en = internal_valid && (in_y > 1 || flush_cnt > 0) && fifo2_en;

// --------------------------------------------------------------
    // 【新增】：FIFO 自主清空信号
    // 当 flush_cnt 倒数到 1 时，意味着本帧/本通道最后一点数据已经推出
    // 此时拉高 clr，在下一拍将 FIFO 内堆积的无效数据瞬间清零
    // --------------------------------------------------------------
    wire fifo_clr = (flush_cnt == 1);

    sync_fifo_npu_module #(.DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_fifo_row1 (
        .clk(clk), .rst_n(rst_n), .clr(fifo_clr),  // 接入 clr 信号
        .wr_en(fifo1_wr_en), .din(internal_data),
        .rd_en(fifo1_rd_en), .dout(fifo1_dout), .empty(fifo1_empty), .full()
    );

    sync_fifo_npu_module #(.DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_fifo_row0 (
        .clk(clk), .rst_n(rst_n), .clr(fifo_clr),  // 接入 clr 信号
        .wr_en(fifo2_wr_en), .din(fifo1_dout),
        .rd_en(fifo2_rd_en), .dout(fifo2_dout), .empty(fifo2_empty), .full()
    );

    // --------------------------------------------------------------
    // 3. 多模式数据投递机制
    // --------------------------------------------------------------
    reg [DATA_WIDTH-1:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p00<=0; p01<=0; p02<=0; p10<=0; p11<=0; p12<=0; p20<=0; p21<=0; p22<=0;
        end else if (internal_valid) begin
            if (kernel_size == MODE_1X1) begin
                // 【核心优化】1x1 模式：跳过所有 FIFO，直接送达中心点，其余强制休眠
                p11 <= internal_data;
                p00 <= 0; p01 <= 0; p02 <= 0;
                p10 <= 0; p12 <= 0;
                p20 <= 0; p21 <= 0; p22 <= 0;
            end else begin
                // 2x2 & 3x3 模式：标准的流水线移位
                p00 <= p01; p01 <= p02;
                p02 <= (fifo2_rd_en && !fifo2_empty && fifo2_en) ? fifo2_dout : {DATA_WIDTH{1'b0}};

                p10 <= p11; p11 <= p12;
                p12 <= (fifo1_rd_en && !fifo1_empty && fifo1_en) ? fifo1_dout : {DATA_WIDTH{1'b0}};

                p20 <= p21; p21 <= p22;
                p22 <= internal_data;
            end
        end
    end

    // --------------------------------------------------------------
    // 4. 坐标引擎对齐
    // --------------------------------------------------------------
    reg signed [8:0] cx, cy_raw;
    reg valid_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cx <= 0; cy_raw <= 0; valid_d1 <= 0;
        end else if (internal_valid) begin
            if (kernel_size == MODE_1X1) begin
                // 【修复点】：1x1 模式数据直达中心，无需减 1 延迟
                cx     <= $signed({1'b0, in_x});
                cy_raw <= $signed({1'b0, in_y}); 
            end else begin
                // 2x2 & 3x3 模式：中心点具有 1 个像素的物理延迟
                cx     <= (in_x == 0) ? $signed({1'b0, cfg_width}) - 1 : $signed({1'b0, in_x}) - 1;
                cy_raw <= (in_x == 0) ? $signed({1'b0, in_y}) - 1 : $signed({1'b0, in_y});
            end
            valid_d1 <= 1;
        end else begin
            valid_d1 <= 0;
        end
    end

    wire signed [8:0] cy = (kernel_size == MODE_1X1) ? cy_raw : cy_raw - 1;
    
    // 边界与零填充处理
    wire is_left   = (cx == 0);
    wire is_right  = (cx == $signed({1'b0, cfg_width}) - 1);
    wire is_top    = (cy == 0);
    wire is_bottom = (cy == $signed({1'b0, cfg_height}) - 1);

    wire [DATA_WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7, w8;
    assign w4 = p11;   // 永恒的物理中心

    assign w0 = (padding_en && (is_left || is_top))    ? {DATA_WIDTH{1'b0}} : p00;
    assign w1 = (padding_en && is_top)                 ? {DATA_WIDTH{1'b0}} : p01;
    assign w2 = (padding_en && (is_right || is_top))   ? {DATA_WIDTH{1'b0}} : p02;
    assign w3 = (padding_en && is_left)                ? {DATA_WIDTH{1'b0}} : p10;
    assign w5 = (padding_en && is_right)               ? {DATA_WIDTH{1'b0}} : p12;
    assign w6 = (padding_en && (is_left || is_bottom)) ? {DATA_WIDTH{1'b0}} : p20;
    assign w7 = (padding_en && is_bottom)              ? {DATA_WIDTH{1'b0}} : p21;
    assign w8 = (padding_en && (is_right || is_bottom))? {DATA_WIDTH{1'b0}} : p22;

    assign win_out_flat = {w8, w7, w6, w5, w4, w3, w2, w1, w0};

    // --------------------------------------------------------------
    // 5. 最终步长控制
    // --------------------------------------------------------------
    wire center_valid = valid_d1 && (cy >= 0) && (cx >= 0) && (cy < $signed({1'b0, cfg_height})) && (cx < $signed({1'b0, cfg_width}));
    reg  final_valid;

    always @(*) begin
        if (kernel_size == MODE_2X2)      // 2x2: 强行过滤坐标，实现 Stride = 2
            final_valid = center_valid && (cx[0] == 1'b0) && (cy[0] == 1'b0);
        else                              // 1x1 & 3x3: 步长 1
            final_valid = center_valid;
    end

    assign win_valid = final_valid;
    assign out_x     = cx;
    assign out_y     = cy;

endmodule