// ============================================================================
// File Name   : line_buffer_pool.v
// Description : 池化专用行缓冲（固定 2x2 窗口，Stride = 2，单 FIFO 优化）
//               参数化通道数，适配 8/16/32 通道并行计算
// ============================================================================

module line_buffer_pool #(
    parameter NUM_CHANNELS = 16,                     // 并行通道数（默认 16）
    parameter FIFO_DEPTH   = 512                     // FIFO 深度（可独立调整）
) (
    input  wire                                 clk,
    input  wire                                 rst_n,

    // [Step 14.1i] 同步层间清零脉冲。在 conv_engine_top 检测到 cfg_pool_en
    // 上升沿（前一层不池化、本层池化）时拉高一拍，强制把 in_x/in_y/flush_cnt/
    // cy/cx/valid_d1/p00..p11 全部归零，并清空内部行 FIFO。
    // 修复 14.1g 残留问题：上一层 (e.g. C5 池化层) flush 还在进行 (~22~42 cyc)
    // 时，sequencer 已经把 r_pc 推到下一层，cfg_width/cfg_height 切到新值
    // 后，line_buffer_pool 的 in_x/in_y 在新 wrap 点下继续累加，
    // 偶发把 in_y 拖到 14/28 等异常值，导致下一池化层 (C7/C8) max_pool 输出
    // 落到 oy=14..17 而非 0..2，POOL-OUT 命中率从 100% 跌到 0%。
    input  wire                                 i_clr,

    // 配置接口
    input  wire [7:0]                           cfg_width,
    input  wire [7:0]                           cfg_height,

    // 图像数据输入（位宽 = NUM_CHANNELS * 8）
    input  wire [NUM_CHANNELS*8-1:0]            data_in,
    input  wire                                 data_in_valid,

    // 2x2 窗口输出（{p11, p10, p01, p00}，位宽 = NUM_CHANNELS * 32）
    output wire [NUM_CHANNELS*32-1:0]           pool_win_flat,
    output wire                                 win_valid,
    output wire [7:0]                           out_x,
    output wire [7:0]                           out_y
);

    // ------------------------------------------------------------------------
    // 局部参数：数据总线宽度 = 通道数 × 8
    // ------------------------------------------------------------------------
    localparam DATA_WIDTH = NUM_CHANNELS * 8;

    // ------------------------------------------------------------------------
    // 内部信号与寄存器
    // ------------------------------------------------------------------------
    reg  [7:0] in_x, in_y;
    reg  [8:0] flush_cnt;

    wire is_eof = (in_x == cfg_width - 1) && (in_y == cfg_height - 1) && data_in_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flush_cnt <= 9'd0;
        else if (i_clr)
            flush_cnt <= 9'd0;
        else if (is_eof)
            flush_cnt <= {1'b0, cfg_width} + 9'd2;
        else if (flush_cnt > 0)
            flush_cnt <= flush_cnt - 1'b1;
    end

    wire internal_valid = data_in_valid || (flush_cnt > 0);
    wire [DATA_WIDTH-1:0] internal_data = data_in_valid ? data_in : {DATA_WIDTH{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_x <= 8'd0;
            in_y <= 8'd0;
        end else if (i_clr) begin
            in_x <= 8'd0;
            in_y <= 8'd0;
        end else if (flush_cnt == 1) begin
            in_x <= 8'd0;
            in_y <= 8'd0;
        end else if (internal_valid) begin
            if (in_x == cfg_width - 1) begin
                in_x <= 8'd0;
                in_y <= in_y + 1'b1;
            end else begin
                in_x <= in_x + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 单行 FIFO 缓存（深度 FIFO_DEPTH，宽度 DATA_WIDTH）
    // ------------------------------------------------------------------------
    wire fifo_rd_en = internal_valid && (in_y > 0 || flush_cnt > 0);
    wire [DATA_WIDTH-1:0] fifo_dout;
    wire fifo_empty;
    wire fifo_clr = (flush_cnt == 1) || i_clr;

    sync_fifo_npu_module #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fifo_pool (
        .clk   (clk),
        .rst_n (rst_n),
        .clr   (fifo_clr),
        .wr_en (internal_valid),
        .din   (internal_data),
        .rd_en (fifo_rd_en),
        .dout  (fifo_dout),
        .empty (fifo_empty),
        .full  ()
    );

    // ------------------------------------------------------------------------
    // 2x2 移位寄存器阵列（宽度 DATA_WIDTH）
    // ------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] p00, p01, p10, p11;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {p00, p01, p10, p11} <= 0;
        end else if (i_clr) begin
            {p00, p01, p10, p11} <= 0;
        end else if (internal_valid) begin
            p00 <= p01;
            p01 <= (!fifo_empty) ? fifo_dout : {DATA_WIDTH{1'b0}};
            p10 <= p11;
            p11 <= internal_data;
        end
    end

    // ------------------------------------------------------------------------
    // 步长与坐标控制（硬件实现 Stride = 2）
    // ------------------------------------------------------------------------
    reg       valid_d1;
    reg [7:0] cx, cy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_d1 <= 1'b0;
            cx       <= 8'd0;
            cy       <= 8'd0;
        end else if (i_clr) begin
            valid_d1 <= 1'b0;
            cx       <= 8'd0;
            cy       <= 8'd0;
        end else if (internal_valid) begin
            // [Step 14.1g] 只在 *真实数据* 输入时发出 stride=2 采样脉冲。
            // 之前用 internal_valid 门控会让 flush_cnt>0 阶段的虚假递增
            // (in_x/in_y 越过 W-1/H-1 后还在跑) 也产生 valid_d1 脉冲, 这些
            // 脉冲会被 max_pool_2x2 视作真实输出, 通过 BCU 写入下一层的
            // PING/PONG, 严重损坏 layer 边界后下一层的 stride 对齐与
            // 数值正确性。data_in_valid 门控保证最后一个真实窗口 (在 is_eof
            // 当拍 in_x=W-1, in_y=H-1) 仍能正常 emit, 只屏蔽 flush 期的伪边沿。
            valid_d1 <= data_in_valid && (in_x[0] == 1'b1) && (in_y[0] == 1'b1);
            cx       <= in_x;
            cy       <= in_y;
        end else begin
            valid_d1 <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // 输出拼接与连接
    // ------------------------------------------------------------------------
    assign pool_win_flat = {p11, p10, p01, p00};
    assign win_valid     = valid_d1;
    assign out_x         = cx;
    assign out_y         = cy;

endmodule