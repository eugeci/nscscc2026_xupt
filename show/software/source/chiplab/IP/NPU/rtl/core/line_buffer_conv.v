// ============================================================================
// File Name   : line_buffer_conv.v
// Description : [极简正确版] 适配 Space-First，100% 消除 1x1 坐标越界死锁
// ============================================================================
module line_buffer_conv #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 512
) (
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             i_clr,
    input  wire [7:0]                       cfg_width,
    input  wire [7:0]                       cfg_height,
    input  wire [1:0]                       kernel_size,
    input  wire                             padding_en,
    input  wire                             is_last_cin, // 顶层保留，内部忽略

    input  wire [DATA_WIDTH-1:0]            data_in,
    input  wire                             data_in_valid,

    output wire [DATA_WIDTH*9-1:0]          win_out_flat,
    output wire                             win_valid,
    output wire [7:0]                       out_x,
    output wire [7:0]                       out_y,

    // [Step 14.1k 方案A] 模块繁忙标志: 高表示内部仍可能在未来若干拍发出 win_valid
    // 包括: (1) flush_cnt 未清 (2) valid_d1 未消化 (3) 2x2+pad / 3x3+pad 双阶段 emit 未完成
    // 用于上游 BCU 等到本模块真正排空再切换 cin_group / 翻转 is_first_cin/is_last_cin
    output wire                             o_busy
);

    localparam MODE_1X1 = 2'b00;
    localparam MODE_2X2 = 2'b01;
    localparam MODE_3X3 = 2'b10;
    wire mode_2x2_pad_scan = (kernel_size == MODE_2X2) && padding_en;
    wire mode_3x3_pad_scan = (kernel_size == MODE_3X3) && padding_en;

    // ------------------------------------------------------------------------
    // 1. 输入扫描坐标 (纯净版)
    // ------------------------------------------------------------------------
    reg [7:0] in_x, in_y;
    reg [8:0] flush_cnt;

    // 是否到了当前通道的图尾？
    wire is_frame_end = (in_x == cfg_width - 1) && (in_y == cfg_height - 1) && data_in_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_cnt <= 0;
        end else if (i_clr) begin
            flush_cnt <= 0;
        end else if (is_frame_end) begin
            // 1x1/2x2(no-pad) 不需要排空
            // 2x2+pad 需要补齐 (W+1)*(H+1)-W*H = W+H+1 个输出周期
            // Valid convolution finishes on the last real pixel. Padding modes
            // keep a flush phase to emit the synthetic bottom/right boundary.
            flush_cnt <= (kernel_size == MODE_1X1) ? 9'd0 :
                         ((kernel_size == MODE_2X2 && !padding_en)) ? 9'd0 :
                         ((kernel_size == MODE_3X3 && !padding_en)) ? 9'd0 :
                         ((kernel_size == MODE_2X2 &&  padding_en)) ? ({1'b0, cfg_width} + {1'b0, cfg_height} + 9'd1) :
                         ((kernel_size == MODE_3X3 &&  padding_en)) ? ({1'b0, cfg_width} + {1'b0, cfg_height} + 9'd5) :
                                                                       9'd0;
        end else if (flush_cnt > 0) begin
            flush_cnt <= flush_cnt - 1'b1;
        end
    end

    wire internal_valid = data_in_valid || (flush_cnt > 0);
    wire [DATA_WIDTH-1:0] internal_data = data_in_valid ? data_in : {DATA_WIDTH{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_x <= 0; in_y <= 0;
        end else if (i_clr) begin
            in_x <= 0; in_y <= 0;
        end else if (internal_valid) begin
            // [Step 14.1c] 3×3+pad 与 2×2+pad 一致: flush 阶段冻结 in_x/in_y, 避免
            // 下一 cin 馈 (0,0) 输入时内部坐标仍在滑动 → cin 累加 psum 地址错位.
            if ((mode_2x2_pad_scan || mode_3x3_pad_scan) && !data_in_valid) begin
                in_x <= in_x;
                in_y <= in_y;
            end else
            // 【核心修复】：到了图尾直接清零，绝对不能再让 y 加 1 了！
            if (in_x == cfg_width - 1 && in_y == cfg_height - 1) begin
                in_x <= 0;
                in_y <= 0;
            end else if (in_x == cfg_width - 1) begin
                in_x <= 0;
                in_y <= in_y + 1'b1;
            end else begin
                in_x <= in_x + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 2. FIFO 与移位寄存器 (保持不变)
    // ------------------------------------------------------------------------
    wire fifo1_en = (kernel_size == MODE_2X2) || (kernel_size == MODE_3X3);
    wire fifo2_en = (kernel_size == MODE_3X3) || (kernel_size == MODE_2X2 && padding_en);

    wire fifo1_wr_en = internal_valid && fifo1_en;
    wire fifo1_rd_en = internal_valid && (in_y > 0 || flush_cnt > 0) && fifo1_en;
    wire [DATA_WIDTH-1:0] fifo1_dout, fifo2_dout;
    wire fifo1_empty, fifo2_empty;

    wire fifo2_wr_en = fifo1_rd_en && !fifo1_empty && fifo2_en;
    wire fifo2_rd_en = internal_valid && (in_y > 1 || flush_cnt > 0) && fifo2_en;

    // FIFO 清空时序：
    // - 无 padding 的模式：frame_end 当拍可直接清空
    // - 需要 flush 的 padding 模式：必须等 flush 完成后再清空
    wire no_flush_mode = (kernel_size == MODE_1X1) || !padding_en;
    reg  flush_active_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flush_active_d <= 1'b0;
        else if (i_clr)
            flush_active_d <= 1'b0;
        else
            flush_active_d <= (flush_cnt > 0);
    end
    wire flush_done_pulse = flush_active_d && (flush_cnt == 0) && !data_in_valid;
    wire fifo_clr = i_clr || (is_frame_end && no_flush_mode) || flush_done_pulse;

    sync_fifo_npu_module #(.DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_fifo_row1 (
        .clk(clk), .rst_n(rst_n), .clr(fifo_clr),
        .wr_en(fifo1_wr_en), .din(internal_data), .rd_en(fifo1_rd_en), .dout(fifo1_dout), .empty(fifo1_empty), .full()
    );

    sync_fifo_npu_module #(.DATA_WIDTH(DATA_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_fifo_row0 (
        .clk(clk), .rst_n(rst_n), .clr(fifo_clr),
        .wr_en(fifo2_wr_en), .din(fifo1_dout), .rd_en(fifo2_rd_en), .dout(fifo2_dout), .empty(fifo2_empty), .full()
    );

    reg [DATA_WIDTH-1:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;
    // [Step 14.1c 策略 A] 4 组边界 cache, 用于 3×3+pad flush 期 9 像素窗口重建。
    // - right_col_cache       : input(W-1, k) — 已有 (2×2+pad 复用)
    // - bottom_row_cache      : input(k, H-1) — Step A 新增
    // - second_right_col_cache: input(W-2, k) — Step C 新增, 供 right col emit 的 p10/p00/p20
    // - second_bottom_row_cache: input(k, H-2) — Step C 新增, 供 bottom row emit 的 p01/p00/p02
    // 每组 256×8b ≈ 256B, 4 组合计 1KB (1 个 M4K 即可容纳)。
    // 【综合友好】4 组 cache 用 LUT-RAM (distributed) 实现, 避免 for-loop 异步清零导致
    // 国产 EDA 将其展开成大片寄存器 + LUT 选择器。首次使用必然在数据期写入之后,
    // 上电初值无关紧要。
    (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] right_col_cache         [0:255];
    (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] bottom_row_cache        [0:255];
    (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] second_right_col_cache  [0:255];
    (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] second_bottom_row_cache [0:255];

    // cache 写口: 纯同步, 无复位 (LUT-RAM 无法异步清空)
    always @(posedge clk) begin
        if (internal_valid && data_in_valid) begin
            if (in_x == cfg_width - 1)
                right_col_cache[in_y] <= internal_data;
            if (in_y == cfg_height - 1)
                bottom_row_cache[in_x] <= internal_data;
            // 注意: cfg_width<2 / cfg_height<2 时 W-2/H-2 下溢, 但 3×3+pad 实际不会发生
            //       (FaceNet 最小 3×3+pad 输入 ≥ 3×3); 边界情况由 8b 算术自然包容。
            if (in_x == cfg_width  - 8'd2)
                second_right_col_cache[in_y]  <= internal_data;
            if (in_y == cfg_height - 8'd2)
                second_bottom_row_cache[in_x] <= internal_data;
        end
    end

    // p00..p22 滑窗寄存器: 保留异步复位 (少量 FF, 与 RAM 分离)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {p00, p01, p02, p10, p11, p12, p20, p21, p22} <= 0;
        end else if (i_clr) begin
            {p00, p01, p02, p10, p11, p12, p20, p21, p22} <= 0;
        end else if (internal_valid) begin
            if (kernel_size == MODE_1X1) begin
                p11 <= internal_data;
            end else begin
                p00 <= p01; p01 <= p02; p02 <= (fifo2_rd_en && !fifo2_empty) ? fifo2_dout : 0;
                p10 <= p11; p11 <= p12; p12 <= (fifo1_rd_en && !fifo1_empty) ? fifo1_dout : 0;
                p20 <= p21; p21 <= p22; p22 <= internal_data;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 3. 坐标投影与输出判定
    // ------------------------------------------------------------------------
    reg [7:0] out_x_reg, out_y_reg;
    reg       valid_d1;
    reg       data_valid_d1;
    reg       data_in_valid_d;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_x_reg <= 0; out_y_reg <= 0; valid_d1 <= 0; data_valid_d1 <= 0; data_in_valid_d <= 0;
        end else if (i_clr) begin
            out_x_reg <= 0; out_y_reg <= 0; valid_d1 <= 0; data_valid_d1 <= 0; data_in_valid_d <= 0;
        end else begin
            valid_d1 <= internal_valid;
            data_valid_d1 <= data_in_valid;
            data_in_valid_d <= data_in_valid;
            if (internal_valid) begin
                out_x_reg <= in_x;
                out_y_reg <= in_y;
            end
        end
    end

    wire signed [8:0] cx = (kernel_size == MODE_1X1) ? {1'b0, out_x_reg} :
                           ((out_x_reg == 0) ? $signed({1'b0, cfg_width}) - 1 : $signed({1'b0, out_x_reg}) - 1);
    wire signed [8:0] cy = (kernel_size == MODE_1X1) ? {1'b0, out_y_reg} :
                           ((out_y_reg == 0) ? $signed({1'b0, cfg_height}) - 1 : $signed({1'b0, out_y_reg}) - 1);

    // 2×2 坐标：无 padding 时偏移-1
    wire [7:0] out_x_2x2_nopad = out_x_reg - 8'd1;
    wire [7:0] out_y_2x2_nopad = out_y_reg - 8'd1;
    wire valid_bounds_2x2_nopad = out_x_reg > 0 && out_y_reg > 0;

    wire mode_2x2_pad = mode_2x2_pad_scan;

    // 2x2+padding 的 flush 阶段坐标计数：
    // 先输出底边界行 (x=0..W-1, y=H)，再输出右边界列 (x=W, y=0..H)
    reg [8:0] flush_emit_2x2p;
    wire frame_start_2x2p = mode_2x2_pad && data_in_valid && !data_in_valid_d;
    wire flush_emit_fire_2x2p = mode_2x2_pad && valid_d1 && !data_valid_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_emit_2x2p <= 9'd0;
        end else if (i_clr) begin
            flush_emit_2x2p <= 9'd0;
        end else if (frame_start_2x2p) begin
            flush_emit_2x2p <= 9'd0;
        end else if (flush_emit_fire_2x2p) begin
            flush_emit_2x2p <= flush_emit_2x2p + 1'b1;
        end
    end

    wire [8:0] flush_need_2x2p = {1'b0, cfg_width} + {1'b0, cfg_height} + 9'd1;
    wire flush_emit_valid_2x2p = (flush_emit_2x2p < flush_need_2x2p);

    wire [8:0] out_y_2x2p_flush_calc = flush_emit_2x2p - {1'b0, cfg_width};
    wire [7:0] out_x_2x2p_flush = (flush_emit_2x2p < {1'b0, cfg_width}) ?
                                  flush_emit_2x2p[7:0] :
                                  cfg_width;
    wire [7:0] out_y_2x2p_flush = (flush_emit_2x2p < {1'b0, cfg_width}) ?
                                  cfg_height :
                                  out_y_2x2p_flush_calc[7:0];

    wire [7:0] out_x_2x2p_eff = data_valid_d1 ? out_x_reg : out_x_2x2p_flush;
    wire [7:0] out_y_2x2p_eff = data_valid_d1 ? out_y_reg : out_y_2x2p_flush;

    // 2×2+padding 专用边界标志：基于最终输出坐标 (0..W, 0..H)
    wire is_left_2x2p   = (out_x_2x2p_eff == 0);
    wire is_right_2x2p  = (out_x_2x2p_eff == cfg_width);
    wire is_top_2x2p    = (out_y_2x2p_eff == 0);
    wire is_bottom_2x2p = (out_y_2x2p_eff == cfg_height);

    // ------------------------------------------------------------------------
    // [Step 14.1c] 3×3 + padding 双阶段坐标 (镜像 2×2+pad 设计)
    // ------------------------------------------------------------------------
    // 输出域 W×H, 数据阶段只 emit 内部 (W-1)×(H-1) (out_x_reg≥1 && out_y_reg≥1),
    // flush 阶段补齐 W+H-1 个边界点: 先 bottom row (W 个), 再 right col 除角 (H-1 个)。
    wire mode_3x3_pad = (kernel_size == MODE_3X3) && padding_en;

    reg [8:0] flush_emit_3x3p;
    wire frame_start_3x3p     = mode_3x3_pad && data_in_valid && !data_in_valid_d;
    wire flush_emit_fire_3x3p = mode_3x3_pad && valid_d1 && !data_valid_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_emit_3x3p <= 9'd0;
        end else if (i_clr) begin
            flush_emit_3x3p <= 9'd0;
        end else if (frame_start_3x3p) begin
            flush_emit_3x3p <= 9'd0;
        end else if (flush_emit_fire_3x3p) begin
            flush_emit_3x3p <= flush_emit_3x3p + 1'b1;
        end
    end

    // flush 总需求: W (bottom row 含右下角) + (H-1) (right col 除右下角) = W+H-1
    wire [8:0] flush_need_3x3p = {1'b0, cfg_width} + {1'b0, cfg_height} - 9'd1;
    wire flush_emit_valid_3x3p = (flush_emit_3x3p < flush_need_3x3p);

    // flush 坐标:
    //   emit_idx 0..W-1   → ox=emit_idx,   oy=H-1   (bottom row, W 个)
    //   emit_idx W..W+H-2 → ox=W-1,        oy=emit_idx-W (right col oy=0..H-2, H-1 个)
    wire [8:0] out_y_3x3p_rc_calc = flush_emit_3x3p - {1'b0, cfg_width};
    wire [7:0] out_x_3x3p_flush = (flush_emit_3x3p < {1'b0, cfg_width}) ?
                                  flush_emit_3x3p[7:0] :
                                  (cfg_width - 8'd1);
    wire [7:0] out_y_3x3p_flush = (flush_emit_3x3p < {1'b0, cfg_width}) ?
                                  (cfg_height - 8'd1) :
                                  out_y_3x3p_rc_calc[7:0];

    // 数据阶段: 仅 out_x_reg≥1 && out_y_reg≥1 emit, 输出坐标 (out_x_reg-1, out_y_reg-1)
    wire [7:0] out_x_3x3p_data = out_x_reg - 8'd1;
    wire [7:0] out_y_3x3p_data = out_y_reg - 8'd1;
    wire data_phase_emit_valid_3x3p = (out_x_reg >= 8'd1) && (out_y_reg >= 8'd1);

    // 最终输出坐标: data 阶段 vs flush 阶段
    wire [7:0] out_x_3x3p_eff = data_valid_d1 ? out_x_3x3p_data : out_x_3x3p_flush;
    wire [7:0] out_y_3x3p_eff = data_valid_d1 ? out_y_3x3p_data : out_y_3x3p_flush;

    // 3×3+pad 边界标志 (基于最终输出坐标 0..W-1 × 0..H-1)
    wire is_left_3x3p   = (out_x_3x3p_eff == 8'd0);
    wire is_right_3x3p  = (out_x_3x3p_eff == cfg_width  - 8'd1);
    wire is_top_3x3p    = (out_y_3x3p_eff == 8'd0);
    wire is_bottom_3x3p = (out_y_3x3p_eff == cfg_height - 8'd1);

    // ------------------------------------------------------------------------
    // [Step 14.1c · Step C.2] flush 期 3×3+pad 9 像素窗口装配 (cache-built)
    // ------------------------------------------------------------------------
    // 现有移位寄存器在 flush 期顺序错位 (fifo 输出 row H-1 / 0-pad), 与 emit 顺序
    // (bottom row → right col) 不同步, 故必须用 cache 显式重建 p*。
    //
    // 标准 3×3 窗口布局 (output (ox, oy) 中心, 行优先):
    //   p00 p01 p02     (oy-1 行)
    //   p10 p11 p12     (oy   行: p11 = 中心)
    //   p20 p21 p22     (oy+1 行)
    wire flush_phase_3x3p   = mode_3x3_pad && !data_valid_d1;
    wire flush_is_br_3x3p   = flush_phase_3x3p && (flush_emit_3x3p <  {1'b0, cfg_width});  // bottom row
    wire flush_is_rc_3x3p   = flush_phase_3x3p && (flush_emit_3x3p >= {1'b0, cfg_width}) &&
                                                  (flush_emit_3x3p <  flush_need_3x3p);    // right col

    // bottom row emit: ox 索引
    wire [7:0] flush_br_ox     = flush_emit_3x3p[7:0];
    wire       flush_br_has_l  = (flush_br_ox != 8'd0);                  // p*0 列可用
    wire       flush_br_has_r  = (flush_br_ox != cfg_width - 8'd1);      // p*2 列可用
    wire [7:0] flush_br_ox_m1  = flush_br_ox - 8'd1;
    wire [7:0] flush_br_ox_p1  = flush_br_ox + 8'd1;

    // right col emit: oy 索引
    wire [7:0] flush_rc_oy     = out_y_3x3p_rc_calc[7:0];                 // = emit_idx - W
    wire       flush_rc_has_t  = (flush_rc_oy != 8'd0);                   // p0* 行可用
    wire       flush_rc_has_b  = (flush_rc_oy != cfg_height - 8'd1);      // p2* 行可用 (实际恒为真, 保险检查)
    wire [7:0] flush_rc_oy_m1  = flush_rc_oy - 8'd1;
    wire [7:0] flush_rc_oy_p1  = flush_rc_oy + 8'd1;

    // 9 像素重建 — bottom row 模式: p2* 全 0 (bottom pad), p11 行用 bottom_row_cache, p0* 行用 second_bottom_row
    wire [DATA_WIDTH-1:0] fp00, fp01, fp02, fp10, fp11, fp12, fp20, fp21, fp22;
    assign fp22 = {DATA_WIDTH{1'b0}};
    assign fp21 = flush_is_rc_3x3p ? (flush_rc_has_b ? right_col_cache       [flush_rc_oy_p1] : {DATA_WIDTH{1'b0}}) :
                                     {DATA_WIDTH{1'b0}};   // br: bottom pad
    assign fp20 = flush_is_rc_3x3p ? (flush_rc_has_b ? second_right_col_cache[flush_rc_oy_p1] : {DATA_WIDTH{1'b0}}) :
                                     {DATA_WIDTH{1'b0}};   // br: bottom pad
    assign fp12 = flush_is_br_3x3p ? (flush_br_has_r ? bottom_row_cache       [flush_br_ox_p1] : {DATA_WIDTH{1'b0}}) :
                                     {DATA_WIDTH{1'b0}};   // rc: right pad
    assign fp11 = flush_is_br_3x3p ? bottom_row_cache       [flush_br_ox] :
                  flush_is_rc_3x3p ? right_col_cache        [flush_rc_oy] :
                                     {DATA_WIDTH{1'b0}};
    assign fp10 = flush_is_br_3x3p ? (flush_br_has_l ? bottom_row_cache       [flush_br_ox_m1] : {DATA_WIDTH{1'b0}}) :
                  flush_is_rc_3x3p ? second_right_col_cache[flush_rc_oy] :
                                     {DATA_WIDTH{1'b0}};
    assign fp02 = flush_is_br_3x3p ? (flush_br_has_r ? second_bottom_row_cache[flush_br_ox_p1] : {DATA_WIDTH{1'b0}}) :
                                     {DATA_WIDTH{1'b0}};   // rc: right pad
    assign fp01 = flush_is_br_3x3p ? second_bottom_row_cache[flush_br_ox] :
                  flush_is_rc_3x3p ? (flush_rc_has_t ? right_col_cache        [flush_rc_oy_m1] : {DATA_WIDTH{1'b0}}) :
                                     {DATA_WIDTH{1'b0}};
    assign fp00 = flush_is_br_3x3p ? (flush_br_has_l ? second_bottom_row_cache[flush_br_ox_m1] : {DATA_WIDTH{1'b0}}) :
                  flush_is_rc_3x3p ? (flush_rc_has_t ? second_right_col_cache[flush_rc_oy_m1] : {DATA_WIDTH{1'b0}}) :
                                     {DATA_WIDTH{1'b0}};

    // ------------------------------------------------------------------------
    // 3×3 边界标志（基于回绕坐标 cx/cy）— 现有 3×3 no-pad 路径仍使用
    // ------------------------------------------------------------------------
    wire is_left   = (cx == 0);
    wire is_right  = (cx == $signed({1'b0, cfg_width}) - 1);
    wire is_top    = (cy == 0);
    wire is_bottom = (cy == $signed({1'b0, cfg_height}) - 1);

    wire [DATA_WIDTH-1:0] w0, w1, w2, w3, w4, w5, w6, w7, w8;
    assign w4 = p11;
    assign w0 = (padding_en && (is_left || is_top))    ? 0 : p00;
    assign w1 = (padding_en && is_top)                 ? 0 : p01;
    assign w2 = (padding_en && (is_right || is_top))   ? 0 : p02;
    assign w3 = (padding_en && is_left)                ? 0 : p10;
    assign w5 = (padding_en && is_right)               ? 0 : p12;
    assign w6 = (padding_en && (is_left || is_bottom)) ? 0 : p20;
    assign w7 = (padding_en && is_bottom)              ? 0 : p21;
    assign w8 = (padding_en && (is_right || is_bottom))? 0 : p22;

    wire valid_bounds = padding_en ? 1'b1 :
                        (kernel_size == MODE_1X1) ? 1'b1 :
                        (kernel_size == MODE_2X2) ? valid_bounds_2x2_nopad :
                        !(is_left || is_right || is_top || is_bottom);

    // 2×2 padding 专用窗口：
    // - 常规位置基于 p11/p12/p21/p22
    // - 右边界列(x=W) flush 阶段改用 right_col_cache
    // - [Step 14.1k 阶段2] 底边界行(y=H) flush 阶段改用 bottom_row_cache, 否则
    //   p11/p12 在 flush 期已被 internal_data=0 推进 / 错位, 导致 PE-PSUM 在 bottom row
    //   (oy=3 for C8) 计算出错。bottom_row_cache 在数据期由 `in_y == cfg_height-1` 写入,
    //   保存最后一行 H-1 的输入像素 in[H-1, *]。
    //   bottom-right 角点 (ox=W, oy=H) 仍走 right_col 分支处理 (right_col_top/bot 已在 oy==H 时返 0)。
    wire [DATA_WIDTH-1:0] w2x2_00, w2x2_01, w2x2_10, w2x2_11;
    wire right_col_flush_2x2p   = mode_2x2_pad && !data_valid_d1 && is_right_2x2p;
    wire bottom_row_flush_2x2p  = mode_2x2_pad && !data_valid_d1 && is_bottom_2x2p && !is_right_2x2p;
    wire [7:0] y_prev_2x2p = out_y_2x2p_eff - 8'd1;
    wire [7:0] x_prev_2x2p = out_x_2x2p_eff - 8'd1;
    wire [DATA_WIDTH-1:0] right_col_top = (out_y_2x2p_eff == 0) ? {DATA_WIDTH{1'b0}} : right_col_cache[y_prev_2x2p];
    wire [DATA_WIDTH-1:0] right_col_bot = (out_y_2x2p_eff == cfg_height) ? {DATA_WIDTH{1'b0}} : right_col_cache[out_y_2x2p_eff];
    // bottom row flush emit: 输出坐标 (ox, oy=H), 卷积窗口 (oy-1, ox-1)..(oy, ox).
    //   w_00 = in[H-1, ox-1] = bottom_row_cache[ox-1] (ox==0 时左 pad → 0)
    //   w_01 = in[H-1, ox  ] = bottom_row_cache[ox]
    //   w_10 / w_11 由 is_bottom_2x2p 掩码自然 0 (bottom pad)
    wire [DATA_WIDTH-1:0] bottom_row_left  = (out_x_2x2p_eff == 0) ? {DATA_WIDTH{1'b0}} : bottom_row_cache[x_prev_2x2p];
    wire [DATA_WIDTH-1:0] bottom_row_right = bottom_row_cache[out_x_2x2p_eff];
    wire [DATA_WIDTH-1:0] p2x2_top_left  = right_col_flush_2x2p   ? right_col_top    :
                                           bottom_row_flush_2x2p  ? bottom_row_left  :
                                                                    p11;
    wire [DATA_WIDTH-1:0] p2x2_top_right = bottom_row_flush_2x2p  ? bottom_row_right : p12;
    wire [DATA_WIDTH-1:0] p2x2_bot_left  = right_col_flush_2x2p   ? right_col_bot    : p21;
    assign w2x2_00 = (padding_en && (is_top_2x2p || is_left_2x2p))     ? {DATA_WIDTH{1'b0}} : p2x2_top_left;
    assign w2x2_01 = (padding_en && (is_top_2x2p || is_right_2x2p))    ? {DATA_WIDTH{1'b0}} : p2x2_top_right;
    assign w2x2_10 = (padding_en && (is_bottom_2x2p || is_left_2x2p))  ? {DATA_WIDTH{1'b0}} : p2x2_bot_left;
    assign w2x2_11 = (padding_en && (is_bottom_2x2p || is_right_2x2p)) ? {DATA_WIDTH{1'b0}} : p22;

    // [Step 14.1c · Step C.3] 3×3+pad 的窗口序列：
    //   - data 阶段: 复用现有 w0..w8 (is_left/right/top/bottom 与 is_*_3x3p 在数据阶段恖同)
    //   - flush 阶段: 全部使用 fp00..fp22 (已含 padding=0)
    wire [DATA_WIDTH*9-1:0] win_3x3p_data  = {w8, w7, w6, w5, w4, w3, w2, w1, w0};
    wire [DATA_WIDTH*9-1:0] win_3x3p_flush = {fp22, fp21, fp20, fp12, fp11, fp10, fp02, fp01, fp00};

    reg [DATA_WIDTH*9-1:0] final_win;
    always @(*) begin
        if (kernel_size == MODE_1X1)
            final_win = {32'd0, w4, 32'd0};
        else if (kernel_size == MODE_2X2)
            final_win = {8'd0, 8'd0, 8'd0, 8'd0, w2x2_11, w2x2_10, 8'd0, w2x2_01, w2x2_00};
        else if (mode_3x3_pad)
            final_win = flush_phase_3x3p ? win_3x3p_flush : win_3x3p_data;
        else
            final_win = {w8, w7, w6, w5, w4, w3, w2, w1, w0};
    end

    assign win_out_flat = final_win;

    wire win_gen_base = valid_d1 && (cy >= 0) && (cy < $signed({1'b0, cfg_height})) && valid_bounds;

    // 2×2 无 padding: 仅 out_x_reg>0 && out_y_reg>0 有效
    // 2×2+padding: data 阶段 + flush 阶段坐标分别映射到 (W+1)x(H+1)
    // 3×3+padding: data 阶段仅 out_x_reg>=1 && out_y_reg>=1 emit, flush 阶段补 W+H-1 边界 (Step 14.1c)
    // 3×3 no-pad / 1×1: 使用 cx/cy 回绕坐标判定
    assign win_valid = mode_3x3_pad ?
                       (valid_d1 && (data_valid_d1 ? data_phase_emit_valid_3x3p : flush_emit_valid_3x3p)) :
                       mode_2x2_pad ?
                       (valid_d1 && (data_valid_d1 || flush_emit_valid_2x2p)) :
                       (kernel_size == MODE_2X2) ?
                       (valid_d1 && valid_bounds_2x2_nopad) :
                       win_gen_base;

    assign out_x = mode_3x3_pad ? out_x_3x3p_eff :
                   mode_2x2_pad ? out_x_2x2p_eff :
                   (kernel_size == MODE_2X2) ? out_x_2x2_nopad :
                   ((padding_en || kernel_size == MODE_1X1) ? cx[7:0] : (cx[7:0] - 8'd1));
    assign out_y = mode_3x3_pad ? out_y_3x3p_eff :
                   mode_2x2_pad ? out_y_2x2p_eff :
                   (kernel_size == MODE_2X2) ? out_y_2x2_nopad :
                   ((padding_en || kernel_size == MODE_1X1) ? cy[7:0] : (cy[7:0] - 8'd1));

    // ------------------------------------------------------------------------
    // [Step 14.1k 方案A] o_busy: 模块仍有未发完的 win_valid 时拉高
    // 列表化所有可能的「未来还会产生 win_valid」状态来源:
    //   1) flush_cnt > 0          : 任意 mode 的 flush 期未完
    //   2) valid_d1                : 上一拍 internal_valid 还会再生一拍 win_valid
    //   3) data_valid_d1           : 数据期最后一拍后还有相位对齐 emit
    //   4) flush_active_d          : flush 已结束但 fifo_clr 脉冲还没发
    //   5) 2x2+pad 双阶段未走完: flush_emit_2x2p < flush_need_2x2p && mode 处于 padding flush
    //   6) 3x3+pad 双阶段未走完: flush_emit_3x3p < flush_need_3x3p && mode 处于 padding flush
    // 注意: 这里是过近似 (over-approximation) — 宁可多忙一拍也不能漏报
    wire busy_2x2p_phase = mode_2x2_pad_scan &&
                           ((flush_emit_2x2p < flush_need_2x2p) || data_valid_d1);
    wire busy_3x3p_phase = mode_3x3_pad_scan &&
                           ((flush_emit_3x3p < flush_need_3x3p) || data_valid_d1);
    assign o_busy = (flush_cnt > 0)
                  || valid_d1
                  || data_valid_d1
                  || flush_active_d
                  || busy_2x2p_phase
                  || busy_3x3p_phase;

endmodule
