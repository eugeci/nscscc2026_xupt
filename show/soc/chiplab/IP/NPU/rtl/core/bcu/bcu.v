// -----------------------------------------------------------------------------
// Module      : bcu_v2
// Description : NPU 缓存控制单元 (支持 FC 展平伪装与嵌套循环修正)
// -----------------------------------------------------------------------------
module bcu (
    input  wire         clk,
    input  wire         rst_n,

    // Sequencer Control Interface
    input  wire         layer_start,
    output reg          layer_done,

    // Microcode ROM Configs
    input  wire         i_is_fc_mode,     // 1: FC Mode (Flattening), 0: Conv Mode
    input  wire [7:0]   i_cfg_width,      // 物理真实宽度
    input  wire [7:0]   i_cfg_height,     // 物理真实高度
    input  wire [1:0]   i_cfg_kernel,     // 00: 1x1, 10: 3x3
    input  wire         i_cfg_pool_en,    // 1: 2x2 pooling enable
    input  wire         i_cfg_padding_en, // 1: same padding
    input  wire [7:0]   i_cfg_cin_total,  // 物理通道总数

    // Cout 分组控制 (来自 sequencer)
    input  wire [3:0]   i_oc_group_idx,   // 当前输出分组索引

    // Cin 分组控制 (来自 sequencer, Step 14.1b)
    input  wire [5:0]   i_cin_group_idx,        // 当前输入分组索引 (6-bit 支持 ≤ 1024 cin)
    input  wire [4:0]   i_cin_block_size,       // 当前组有效 Cin 通道数 (1..16)
    input  wire         i_is_first_cin_group,   // 当前是 cin_group=0 (需发 is_first_cin)
    input  wire         i_is_last_cin_group,    // 当前是 cin_group=last (需发 is_last_cin 触发 PSUM 输出与回写)

    // Layer-0 packed preload read mode.
    // 默认关闭；仅 layer-0 input preload 使用 packed cross-bank layout:
    // linear = abs_cin * W * H + pixel, bank = linear[3:0], addr = linear >> 4.
    input  wire         i_is_layer0,
    input  wire         i_l0_packed_read_en,

    // SRAM Array Read Interface
    // 读地址 15b：layer-0 读 LBP 输入缓冲区需要覆盖 19200 个地址 (>14b)
    // 高 2 位仅在 layer-0 读 LBP buffer 时使用；fm_bank_array 只取低 13 位
    output wire [14:0]  o_sram_rd_addr,
    output wire         o_sram_rd_en,
    output wire [3:0]   o_sram_cin_idx,   // FM bank 选择 (低4位)
    output wire [7:0]   o_cin_idx_full,   // 完整 Cin 索引 (供 weight_buffer 页深度寻址)

    // SRAM Array Write Interface (NPU 回写地址, 13b 对应 fm_bank_array 深度 8K)
    output wire [12:0]  o_sram_wr_addr,

    // NPU Compute Engine Dataflow Interface
    input  wire         i_npu_in_ready,
    output wire         o_npu_in_valid,
    output wire         o_npu_is_first_cin,
    output wire         o_npu_is_last_cin,
    input  wire         i_npu_out_valid,
    // [Step 14.1m] conv_engine 实际输出坐标, 用于 SRAM 写地址精确寻址。
    //   原方案 r_wr_addr 单纯随 i_npu_out_valid 自增, 隐含假设 conv 按 SRAM 行优先序 emit。
    //   但 2×2+pad / 3×3+pad 数据阶段按输入扫描序 emit (列宽 = W_in), flush 阶段才补
    //   bottom row + right col。当下游有 pool 时 pool_reorder 把它整理成行优先, 当
    //   pool=False (C8 是网络中唯一这样的 padding 层) 就暴露错位 → SRAM 写到错误位置。
    input  wire [7:0]   i_conv_out_x,
    input  wire [7:0]   i_conv_out_y,

    // [Step 14.1k 方案A] 来自 conv_engine_top.o_pipeline_idle
    // 高表示计算流水已完全排空 (line_buffer_conv 不在 flush, PE/accumulator 无飞行 mac,
    // pool 不在 flush)。BCU 必须等到此信号高才能让 layer_done 拉起,
    // 否则 sequencer 会过早翻转 r_cin_group_idx → is_first_cin/is_last_cin 被错误广播
    // 给仍在 flush 的 line_buffer_conv emit, 导致 channel_accumulator 路由错乱。
    input  wire         i_pipeline_idle,

    output wire [31:0]  o_dbg0,
    output wire [31:0]  o_dbg1,
    output wire [31:0]  o_dbg2,
    output wire [31:0]  o_dbg3
);

    // FSM States
    localparam ST_IDLE       = 3'd0;
    localparam ST_CALC       = 3'd1;
    localparam ST_READ       = 3'd2;
    localparam ST_WAIT_WRITE = 3'd3;
    localparam ST_DRAIN      = 3'd4;   // Step 14.1d: cin 间排空 (3x3+pad)
    localparam ST_CFG_PLANE  = 3'd5;
    localparam ST_CFG_OFFSET = 3'd6;

    reg [2:0]  state;
    reg [15:0] r_img_pixels;        // 物理图像总像素 (W * H)
    reg [23:0] r_total_reads;       // 本层总读取次数 (W * H * Cin)
    reg [15:0] r_expected_writes;   // 终态需要被回写的最少次数
    reg [7:0]  r_final_w;
    reg [7:0]  r_final_h;
    reg [15:0] r_plane_pixels;
    reg [15:0] r_oc_g_offset;
    reg [22:0] r_group_rd_base;
    reg [31:0] r_packed_cin_base;

    reg [23:0] r_global_cnt;        // 全局读取计数器
    reg [15:0] r_pixel_cnt;         // 外层循环：像素空间坐标
    reg [7:0]  r_cin_idx;           // 内层循环：通道深度坐标

    // Step 14.1d: cin 间排空计数器 (3x3+pad 与 2x2+pad 均启用)
    // [Step 14.1k] 把 2×2+pad (kernel==2'b01) 也纳入 drain 路径:
    //   line_buffer_conv 2×2+pad flush_cnt = W+H+1, 加 flush_done_pulse + accumulator
    //   2~3 拍延迟 ≈ W+H+4。w_drain_total = W+H+8 仍有余量。
    //   原 14.1d 只覆盖 3×3+pad, 导致 2×2+pad 非末 cin_group 时 BCU 一进 ST_WAIT_WRITE 就立刻
    //   layer_done → sequencer 翻 r_cin_group_idx → is_first_cin/is_last_cin 静态广播
    //   在 line_buffer_conv 还在 flush 时翻转 → channel_accumulator 拿错 first/last 标志
    //   → 边界 9 个 emit 落入错误的累加分支。这是 L7 PE-PSUM 卡 46% 的核心根因。
    reg [8:0]  r_drain_cnt;
    wire       w_drain_needed = i_cfg_padding_en &&
                                ((i_cfg_kernel == 2'b10) || (i_cfg_kernel == 2'b01));
    // line_buffer_conv 3x3+pad flush 期需要 W+H-1 个 emit + flush_cnt(W+H+5) 倒计 + FIFO clear
    // pulse, 取 W+H+8 留余量 (2x2+pad 实际只需 W+H+4, 共用此余量上限即可)
    wire [8:0] w_drain_total = {1'b0, i_cfg_width} + {1'b0, i_cfg_height} + 9'd8;
    
    reg [15:0] r_write_cnt;
    reg [12:0] r_wr_addr;
    wire       w_read_fire = (state == ST_READ) && i_npu_in_ready;

    // 组合逻辑预计算输出尺寸
    // [Step 14.1j] 增加 2x2 (i_cfg_kernel == 2'b01) 分支:
    //   - 2x2 + pad : conv 输出 = (W+1) x (H+1)（C8 的实际行为, 与 conv_engine_top.conv_out_w 一致）
    //   - 2x2 valid : conv 输出 = (W-1) x (H-1)
    // 旧代码只有 1x1 和 3x3 两条分支, 2x2 走 default = i_cfg_width, 在 padding 路径
    // 误把 2x2+pad 的输出宽度算成 W (= cfg_width)。BCU 据此控制 w_final_w/h、cap_total
    // 与 r_wr_addr 的步进, 写回 PING/PONG 的位置全部偏掉一行/一列, 表现为
    // L7 (C8) PE-PSUM 仅 46% 命中、QUANT 79%、POOL-REORDER 274/384 与 PING 51%。
    wire [7:0] w_out_w = i_cfg_padding_en
                       ? (i_cfg_kernel == 2'b01 ? (i_cfg_width + 8'd1) : i_cfg_width)
                       : (i_cfg_kernel == 2'b10 ? (i_cfg_width > 2 ? i_cfg_width - 8'd2 : 8'd0)
                       : (i_cfg_kernel == 2'b01 ? (i_cfg_width > 1 ? i_cfg_width - 8'd1 : 8'd0)
                       : i_cfg_width));
    wire [7:0] w_out_h = i_cfg_padding_en
                       ? (i_cfg_kernel == 2'b01 ? (i_cfg_height + 8'd1) : i_cfg_height)
                       : (i_cfg_kernel == 2'b10 ? (i_cfg_height > 2 ? i_cfg_height - 8'd2 : 8'd0)
                       : (i_cfg_kernel == 2'b01 ? (i_cfg_height > 1 ? i_cfg_height - 8'd1 : 8'd0)
                       : i_cfg_height));
    wire [7:0] w_final_w = i_cfg_pool_en ? (w_out_w >> 1) : w_out_w;
    wire [7:0] w_final_h = i_cfg_pool_en ? (w_out_h >> 1) : w_out_h;

    // ==========================================
    // 1. 主控状态机与地址嵌套引擎
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            r_img_pixels <= 0; r_total_reads <= 0; r_expected_writes <= 0;
            r_final_w <= 0; r_final_h <= 0; r_plane_pixels <= 0;
            r_oc_g_offset <= 0; r_group_rd_base <= 0; r_packed_cin_base <= 0;
            r_global_cnt <= 0; r_pixel_cnt <= 0; r_cin_idx <= 0;
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    r_global_cnt <= 0;
                    r_pixel_cnt  <= 0;
                    r_cin_idx    <= 0;
                    r_drain_cnt  <= 0;
                    if (layer_start) state <= ST_CALC;
                end
                
                ST_CALC: begin
                    // Layer/group configuration is constant while BCU runs.  Split
                    // its address multipliers across setup cycles so they do not
                    // drive all 32 feature SRAM banks as a combinational tree.
                    r_img_pixels  <= i_cfg_width * i_cfg_height;
                    r_final_w     <= w_final_w;
                    r_final_h     <= w_final_h;
                    state         <= ST_CFG_PLANE;
                end

                ST_CFG_PLANE: begin
                    r_total_reads  <= r_img_pixels * {19'd0, i_cin_block_size};
                    r_plane_pixels <= r_final_w * r_final_h;
                    state          <= ST_CFG_OFFSET;
                end

                ST_CFG_OFFSET: begin
                    r_expected_writes <= i_is_last_cin_group ?
                                         (i_is_fc_mode ? 16'd1 : r_plane_pixels) :
                                         16'd0;
                    r_oc_g_offset   <= i_oc_group_idx * r_plane_pixels;
                    r_group_rd_base <= i_cin_group_idx * r_img_pixels;
                    r_packed_cin_base <=
                        {22'd0, i_cin_group_idx, 4'b0} * {16'd0, r_img_pixels};
                    state <= ST_READ;
                end
                
                ST_READ: begin
                    if (!i_npu_in_ready) begin
                        state <= ST_READ;
                    end else if (r_global_cnt == r_total_reads - 1) begin
                        // 末像素末 cin: 进入 WAIT_WRITE (line_buffer flush 在此期间完成,
                        // is_last_cin 保持触发 channel_accumulator 输出边界像素)
                        state <= ST_WAIT_WRITE;
                    end else if (r_pixel_cnt == r_img_pixels - 1 && w_drain_needed) begin
                        // Step 14.1d: 当前 cin 末像素 + 3x3+pad 模式 → 进入 DRAIN, 让
                        // line_buffer_conv 完成 flush + FIFO clear, 才能开始下一 cin。
                        // (非 3x3+pad 模式直接走 else 分支无缝衔接, 与原行为一致)
                        // 注意: r_cin_idx 保持当前 cin (=N), 不可在此 +1 — 否则 drain
                        // 期间 r_is_last_d1 = (r_cin_idx==block_size-1) 会过早升高,
                        // 导致中间 cin 的 flush 边界 win_valid 被错误标 is_last_cin,
                        // channel_accumulator 在 PSUM 未累完所有 cin 前提前 emit。
                        r_global_cnt <= r_global_cnt + 1;
                        r_pixel_cnt  <= 0;
                        r_drain_cnt  <= w_drain_total;
                        state        <= ST_DRAIN;
                    end else begin
                        r_global_cnt <= r_global_cnt + 1;
                        // Conv 输入顺序要求：外层扫 Cin (仅本组内 0..cin_block_size-1)，内层扫像素（行优先）
                        if (r_pixel_cnt == r_img_pixels - 1) begin
                            r_pixel_cnt <= 0;
                            r_cin_idx   <= r_cin_idx + 1;
                            r_packed_cin_base <= r_packed_cin_base + r_img_pixels;
                        end else begin
                            r_pixel_cnt <= r_pixel_cnt + 1;
                        end
                    end
                end

                ST_DRAIN: begin
                    // Step 14.1d: 空闲 W+H+8 周期, o_sram_rd_en=0 → o_npu_in_valid=0,
                    // line_buffer_conv 3x3+pad 触发 flush_done_pulse + FIFO clear,
                    // 同时 emit 当前 cin 的 W+H-1 个边界 win_valid 累加到 PSUM。
                    // drain 结束时再 +1 r_cin_idx, 准备下一 cin 的读取。
                    if (r_drain_cnt == 0) begin
                        r_cin_idx <= r_cin_idx + 1;
                        r_packed_cin_base <= r_packed_cin_base + r_img_pixels;
                        state     <= ST_READ;
                    end else begin
                        r_drain_cnt <= r_drain_cnt - 1'b1;
                    end
                end

                ST_WAIT_WRITE: begin
                    // [Step 14.1k 方案A] 双条件: 写回 quota 满 + 计算流水真正排空
                    // (1) r_write_cnt >= r_expected_writes
                    //       - 末 cin_group 必须等回写计数到 final_w*final_h
                    //       - 非末 cin_group: r_expected_writes=0, 此条件总是真
                    // (2) i_pipeline_idle = 1
                    //       - 关键修复: 防止非末 cin_group 立刻 layer_done 导致 sequencer
                    //         过早翻 r_cin_group_idx, 让 line_buffer_conv 仍在 flush 的
                    //         那 9 (2x2+pad) / W+H-1 (3x3+pad) 拍 emit 被错误标 is_last_cin
                    if (r_write_cnt >= r_expected_writes && i_pipeline_idle) begin
                        layer_done <= 1'b1;
                        state <= ST_IDLE;
                    end
`ifdef BCU_DEBUG
                    if ($time % 50000 == 0)
                        $display("[%0t] BCU ST_WAIT_WRITE r_write_cnt=%0d expected=%0d", $time, r_write_cnt, r_expected_writes);
`endif
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    // ==========================================
    // 2. 独立异步写出累加器
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_write_cnt <= 0;
            r_wr_addr   <= 0;
        end else if (state == ST_IDLE) begin
            r_write_cnt <= 0;
            r_wr_addr   <= 0;
        end else if (state == ST_CALC) begin
            // [Step 14.1m] r_wr_addr 不再做累加; 改由组合逻辑根据 conv 实际 (out_y, out_x) 计算。
            // 这里仅复位 r_write_cnt; 保留 r_wr_addr 寄存器以维持端口规整, 但无人读取。
            r_wr_addr   <= 13'd0;
            r_write_cnt <= 0;
        end else if (i_npu_out_valid) begin
            r_write_cnt <= r_write_cnt + 1;
        end
    end

    // [Step 14.1m] 组合写地址生成: oc_group_offset + out_y*W_out + out_x。
    //   - Conv 模式: BCU 读完整图后, conv_engine_top 按其内部 emit 顺序产出 out_valid + (out_x, out_y);
    //     SRAM 期望按行优先存储 (oy*W_out + ox), 故必须用实际 (out_x, out_y) 而非 emit 序号。
    //   - FC 模式  : 每组 1 个输出, 直接写到 i_oc_group_idx 位置。
    //   - oc_group_offset = oc_g * W_final * H_final (与原 r_wr_addr 复位值一致)。
    wire [15:0] w_xy_offset      = i_conv_out_y * r_final_w + i_conv_out_x;
    wire [15:0] w_conv_wr_addr16 = r_oc_g_offset + w_xy_offset;
    wire [12:0] w_conv_wr_addr   = w_conv_wr_addr16[12:0];

    // ==========================================
    // 3. 时序安全对齐与 FC 欺骗输出 (Data Aligning)
    // Step 14.1b: is_first_cin / is_last_cin 需跳跨 cin_group 边界
    //   只有 cin_group=0 才能发 is_first_cin (初始化 PSUM)
    //   只有 cin_group=last 才能发 is_last_cin (触发输出)
    //   中间 cin_group 均为 0，仅累加 PSUM
    // ==========================================
    reg r_rd_en_d1, r_is_first_d1, r_is_last_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_rd_en_d1    <= 1'b0;
            r_is_first_d1 <= 1'b0;
            r_is_last_d1  <= 1'b0;
        end else begin
            r_rd_en_d1 <= w_read_fire;
            
            if (i_is_fc_mode) begin
                // 【FC 欺骗逻辑】：本组首拍受 cin_group=0 门控，本组末拍受 cin_group=last 门控
                r_is_first_d1 <= i_is_first_cin_group && (r_global_cnt == 0);
                r_is_last_d1  <= i_is_last_cin_group  && (r_global_cnt == r_total_reads - 1);
            end else begin
                // 标准卷积模式：本组内 cin_idx=0 受 cin_group=0 门控，本组末 cin_idx 受 cin_group=last 门控
                r_is_first_d1 <= i_is_first_cin_group && (r_cin_idx == 0);
                r_is_last_d1  <= i_is_last_cin_group  && (r_cin_idx == {3'd0, i_cin_block_size} - 1);
            end
        end
    end

    // Direct memory assignments
    // 默认 group/lane layout:
    //   addr = cin_group_idx * (W*H) + pixel
    //   bank = local_cin_idx[3:0]
    //
    // Layer-0 packed preload layout:
    //   abs_cin = cin_group_idx * 16 + local_cin_idx
    //   linear  = abs_cin * (W*H) + pixel
    //   addr    = linear >> 4
    //   bank    = linear[3:0]
    wire        w_packed_rd_mode = i_is_layer0 && i_l0_packed_read_en;
    wire [22:0] w_group_rd_addr = r_group_rd_base + {7'd0, r_pixel_cnt};
    wire [31:0] w_packed_linear = r_packed_cin_base + {16'd0, r_pixel_cnt};

    assign o_sram_rd_addr = w_packed_rd_mode ? w_packed_linear[18:4]
                                             : w_group_rd_addr[14:0];
    assign o_sram_rd_en   = w_read_fire;
    assign o_sram_cin_idx  = w_packed_rd_mode ? w_packed_linear[3:0]
                                              : r_cin_idx[3:0]; // 自动取余映射到 16 个 Bank (本组内)
    assign o_cin_idx_full  = r_cin_idx;       // 本组内 Cin 索引 (0..15)。weight_buffer 页深度寻址仅用本组许划
    // [Step 14.1m] FC 仍按 oc_group_idx 顺序写; Conv 改为坐标精确寻址。
    assign o_sram_wr_addr = i_is_fc_mode ? {9'd0, i_oc_group_idx} : w_conv_wr_addr;

    // NPU delayed pipeline assignments
    assign o_npu_in_valid     = r_rd_en_d1;
    assign o_npu_is_first_cin = r_is_first_d1;
    assign o_npu_is_last_cin  = r_is_last_d1;

    assign o_dbg0 = {13'd0, i_pipeline_idle, i_npu_in_ready,
                     r_is_last_d1, r_is_first_d1, r_rd_en_d1,
                     layer_done, state, r_cin_idx};
    assign o_dbg1 = {8'd0, r_global_cnt};
    assign o_dbg2 = {8'd0, r_total_reads};
    assign o_dbg3 = {r_write_cnt, r_expected_writes};

endmodule
