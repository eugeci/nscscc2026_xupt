// ----------------------------------------------------------------------------
// weight_rom_dma  (Path B B1 — Blocked INT8 ROM + 在线 144-bit 装配)
// ----------------------------------------------------------------------------
//
// 设计文档：docs/weight_rom_dma_设计_PathB.md (v1.1, 2026-05-04)
//
// 责任：
//   1. 持有片内权重/偏置 ROM (32-bit × ROM_DEPTH word, $readmemh PARAMS_HEX)
//   2. 响应 npu_sequencer 的 i_dma_req，按 base/length 顺序读出字节流
//   3. 在线把字节流装配成 144-bit 双通道 weight 条目，按 weight_buffer
//      协议 (valid + addr + update_weights_en 末沿) 写入
//   4. 紧接着读出 16 个 INT32 偏置字，按 bias_buffer 协议写入
//   5. 拉高 o_dma_done 一拍，回到 IDLE
//
// 寻址：全链路字单位 (32-bit word) — 详见设计文档 §3.6 (RPT-3 决议)。
//
// 字节装配顺序 (与 face/quant_int8.py:_build_weight_block 严格对齐)：
//   for ic_local in 0..15:
//     for oc_pair in {0,2,4,6,8,10,12,14}:
//       even ch 的 K² 字节 (与 repack_*_for_npu 一致)
//       odd  ch 的 K² 字节
//
// kernel_size 编码 (与 sequencer 一致): 00=1×1, 01=2×2, 10=3×3
//
// 时序模型 (steady state)：
//   ROM 同步读 1-cycle 延迟。每 ROM 字按 4 字节消费 = 4 cycles/word。
//   字节级状态机驱动 r_word_buf / r_byte_in_word，并并行预取下一字。
//
// 偏置块：每 oc_g 固定 16 word INT32，DMA 顺序读 16 拍。
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef NPU_PARAMS_HEX
  `define NPU_PARAMS_HEX "params/npu_params.hex"
`endif

module weight_rom_dma #(
    parameter PARAMS_HEX = `NPU_PARAMS_HEX,
    parameter ROM_DEPTH  = 21098,
    parameter ADDR_W     = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // -------- sequencer 控制 (字单位, RPT-3) --------
    input  wire                  i_dma_req,
    input  wire [ADDR_W-1:0]     i_dma_base_addr,
    input  wire [ADDR_W-1:0]     i_bias_base_addr,
    input  wire [15:0]           i_dma_length,
    input  wire [1:0]            i_kernel_size,
    output reg                   o_dma_ack,
    output reg                   o_dma_done,

    // -------- weight_buffer 写入 --------
    output reg  [143:0]          o_weight_data,
    output reg                   o_weight_valid,
    output reg  [9:0]            o_weight_addr,
    output reg                   o_update_weights_en,

    // -------- bias_buffer 写入 --------
    output reg  [31:0]           o_bias_data,
    output reg                   o_bias_valid,
    output reg  [4:0]            o_bias_addr,
    output reg                   o_update_bias_en
);

    // ------------------------------------------------------------------
    // ROM 例化 (通用 BRAM 推断, 适配 eHiChip6 / Synplify 内核)
    //   - syn_ramstyle = "block_ram"  : Synplify (eLinx/Pango/同创/复旦微)
    //   - ram_style    = "block"      : Vivado / 安路 TD
    //   - ramstyle     = "no_rw_check": Quartus (不指定 M4K/M9K，让工具自选)
    //   注意: 不再写死 "M9K" — eHiChip6 不支持，警告会触发 fallback 到次优策略。
    // ------------------------------------------------------------------
    (* syn_ramstyle = "block_ram", ram_style = "block", ramstyle = "no_rw_check" *)
    reg [31:0] rom [0:ROM_DEPTH-1];

    initial begin
        $readmemh(PARAMS_HEX, rom);
    end

    reg  [ADDR_W-1:0]  r_rom_addr;
    reg  [31:0]        r_rom_q;          // 1-cycle latency sync read
    always @(posedge clk) r_rom_q <= rom[r_rom_addr];

    // ------------------------------------------------------------------
    // K² 解码 + 锁存
    // ------------------------------------------------------------------
    reg [3:0] r_k2_locked;                // 1, 4, 或 9
    reg [3:0] w_k2_decode;

    always @(*) begin
        case (i_kernel_size)
            2'b00:   w_k2_decode = 4'd1;
            2'b01:   w_k2_decode = 4'd4;
            2'b10:   w_k2_decode = 4'd9;
            default: w_k2_decode = 4'd1;
        endcase
    end

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam ST_IDLE      = 4'd0;
    localparam ST_ACK       = 4'd1;
    localparam ST_W_WAIT1   = 4'd2;       // ROM 1-cycle latency 等待
    localparam ST_W_LATCH   = 4'd3;       // 把 r_rom_q 装入 r_word_buf, 启动消费
    localparam ST_W_CONSUME = 4'd4;       // 4 cycles/word 字节消费循环
    localparam ST_W_DRAIN   = 4'd5;       // 等装配器 emit pipeline 流空 (1 cycle)
    localparam ST_W_COMMIT  = 4'd6;       // 拉低 update_weights_en
    localparam ST_B_WAIT1   = 4'd7;       // 后接 B_CONSUME，无需额外 LATCH
    localparam ST_B_CONSUME = 4'd8;       // 16 words, 1 cycle/word
    localparam ST_B_COMMIT  = 4'd9;
    localparam ST_DONE      = 4'd10;

    reg [3:0] state, next_state;

    // ------------------------------------------------------------------
    // 计数器与缓冲
    // ------------------------------------------------------------------
    reg [31:0] r_word_buf;                // 当前正被字节消费的 ROM 字
    reg [1:0]  r_byte_in_word;            // 0..3
    reg [15:0] r_words_left;              // weight 字数倒计
    reg [4:0]  r_bias_cnt;                // 0..15

    // 装配器
    reg [4:0]  r_cin_local;               // 0..15
    reg [3:0]  r_oc_pair;                 // 0,2,4,6,8,10,12,14
    reg        r_half;                    // 0=even, 1=odd
    reg [3:0]  r_byte_in_half;            // 0..K²-1

    reg [71:0] r_even_buf;
    reg [71:0] r_odd_buf;

    wire [7:0] w_cur_byte = r_word_buf[r_byte_in_word*8 +: 8];

    // ------------------------------------------------------------------
    // FSM 转移
    // ------------------------------------------------------------------
    wire w_word_byte_done   = (r_byte_in_word == 2'd3);
    wire w_more_words       = (r_words_left  >  16'd0);   // 还需 latch 下一字 (W_LATCH 已减 1，剩余 == 待 latch 数)
    wire w_pair_last_byte   = (r_half == 1'b1) && (r_byte_in_half == r_k2_locked - 4'd1);

    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE:      if (i_dma_req)                      next_state = ST_ACK;
            ST_ACK:                                           next_state = ST_W_WAIT1;
            ST_W_WAIT1:                                       next_state = ST_W_LATCH;
            ST_W_LATCH:                                       next_state = ST_W_CONSUME;
            ST_W_CONSUME: if (w_word_byte_done && !w_more_words) next_state = ST_W_DRAIN;
            ST_W_DRAIN:                                       next_state = ST_W_COMMIT;
            ST_W_COMMIT:                                      next_state = ST_B_WAIT1;
            ST_B_WAIT1:                                       next_state = ST_B_CONSUME;
            ST_B_CONSUME: if (r_bias_cnt == 5'd15)            next_state = ST_B_COMMIT;
            ST_B_COMMIT:                                      next_state = ST_DONE;
            ST_DONE:                                          next_state = ST_IDLE;
            default:                                          next_state = ST_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= next_state;
    end

    // ------------------------------------------------------------------
    // ROM addr / 字 buf / 字节计数
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_rom_addr     <= {ADDR_W{1'b0}};
            r_word_buf     <= 32'd0;
            r_byte_in_word <= 2'd0;
            r_words_left   <= 16'd0;
            r_bias_cnt     <= 5'd0;
            r_k2_locked    <= 4'd1;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (i_dma_req) begin
                        r_rom_addr   <= i_dma_base_addr;
                        r_words_left <= i_dma_length;
                        r_k2_locked  <= w_k2_decode;
                    end
                end
                ST_ACK: begin
                    // rom_addr 在 IDLE 已设；本拍 NBA r_rom_q<=rom[base]
                    // 不动 rom_addr，等 W_WAIT1 一并预取下一字
                end
                ST_W_WAIT1: begin
                    // 本拍 r_rom_q 仍为 rom[base] (rom_addr 未变)
                    r_rom_addr <= r_rom_addr + 1'b1;   // 预取下一字 → r_rom_q 在 LATCH 出口有 rom[base+1]
                end
                ST_W_LATCH: begin
                    // pre: rom_addr=base+1, r_rom_q=rom[base]
                    // NBA: 装入首字，启动消费；rom_addr 不动 → 本拍末 r_rom_q=rom[base+1]
                    //      留给 byte=3 时 r_word_buf <= r_rom_q 切换下一字。
                    r_word_buf     <= r_rom_q;
                    r_byte_in_word <= 2'd0;
                    if (r_words_left != 16'd0) r_words_left <= r_words_left - 16'd1;
                end
                ST_W_CONSUME: begin
                    if (w_word_byte_done) begin
                        if (w_more_words) begin
                            r_word_buf     <= r_rom_q;     // 上拍预取的下一字
                            r_byte_in_word <= 2'd0;
                            r_rom_addr     <= r_rom_addr + 1'b1;
                            r_words_left   <= r_words_left - 16'd1;
                        end
                        // else: 进 W_DRAIN
                    end else begin
                        r_byte_in_word <= r_byte_in_word + 2'd1;
                    end
                end
                ST_W_COMMIT: begin
                    r_rom_addr <= i_bias_base_addr;
                    r_bias_cnt <= 5'd0;
                end
                ST_B_WAIT1: begin
                    // pre: rom_addr=bias_base. NBA: rom_addr<=bias_base+1; r_rom_q<=rom[bias_base]
                    // Post: rom_addr=bias_base+1, r_rom_q=rom[bias_base], state=B_CONSUME
                    r_rom_addr <= r_rom_addr + 1'b1;
                end
                ST_B_CONSUME: begin
                    // cycle k pre: rom_addr=bias_base+k+1, r_rom_q=rom[bias_base+k], bias_cnt=k
                    // 输出 data<=r_rom_q=rom[bias_base+k], addr<=k
                    // 预取下一字：只在 cnt<=14 时增 addr（cycle 15 不需再预取）
                    r_bias_cnt <= r_bias_cnt + 5'd1;
                    if (r_bias_cnt <= 5'd14)
                        r_rom_addr <= r_rom_addr + 1'b1;
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 装配器：在 W_CONSUME 每拍把 w_cur_byte 写入 even/odd 缓冲，并推进计数
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_cin_local    <= 5'd0;
            r_oc_pair      <= 4'd0;
            r_half         <= 1'b0;
            r_byte_in_half <= 4'd0;
            r_even_buf     <= 72'd0;
            r_odd_buf      <= 72'd0;
        end else if (state == ST_IDLE && i_dma_req) begin
            r_cin_local    <= 5'd0;
            r_oc_pair      <= 4'd0;
            r_half         <= 1'b0;
            r_byte_in_half <= 4'd0;
            r_even_buf     <= 72'd0;
            r_odd_buf      <= 72'd0;
        end else if (state == ST_W_CONSUME) begin
            // 写入字节
            if (r_half == 1'b0)
                r_even_buf[r_byte_in_half*8 +: 8] <= w_cur_byte;
            else
                r_odd_buf [r_byte_in_half*8 +: 8] <= w_cur_byte;

            // 推进
            if (r_byte_in_half == r_k2_locked - 4'd1) begin
                r_byte_in_half <= 4'd0;
                if (r_half == 1'b0) begin
                    r_half <= 1'b1;
                end else begin
                    r_half <= 1'b0;
                    // 清 buf 给下一对 (新对从 even 开始累积)
                    r_even_buf <= 72'd0;
                    r_odd_buf  <= 72'd0;
                    if (r_oc_pair == 4'd14) begin
                        r_oc_pair   <= 4'd0;
                        r_cin_local <= r_cin_local + 5'd1;
                    end else begin
                        r_oc_pair   <= r_oc_pair + 4'd2;
                    end
                end
            end else begin
                r_byte_in_half <= r_byte_in_half + 4'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 144-bit emit pipeline：在 pair_last_byte 那拍把 (r_odd_buf | byte_at_pos)
    //   组合拼成最终 odd_word，与 r_even_buf (本拍已是完整) 一起锁存到 pending。
    //   下一拍从 pending 输出到 o_weight_*。
    // ------------------------------------------------------------------
    wire [71:0] w_odd_final = r_odd_buf | ({64'd0, w_cur_byte} << (r_byte_in_half * 8));
    // weight_in_addr = cin_local*16 + oc_pair (oc_pair LSB 恒 0)
    wire [9:0]  w_pair_addr = {2'd0, r_cin_local[3:0], r_oc_pair[3:0]};

    reg [143:0] r_pending_data;
    reg         r_pending_valid;
    reg [9:0]   r_pending_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_pending_data  <= 144'd0;
            r_pending_valid <= 1'b0;
            r_pending_addr  <= 10'd0;
        end else begin
            r_pending_valid <= 1'b0;
            if (state == ST_W_CONSUME && w_pair_last_byte) begin
                r_pending_data  <= {w_odd_final, r_even_buf};
                r_pending_valid <= 1'b1;
                r_pending_addr  <= w_pair_addr;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_weight_data  <= 144'd0;
            o_weight_valid <= 1'b0;
            o_weight_addr  <= 10'd0;
        end else begin
            o_weight_data  <= r_pending_data;
            o_weight_valid <= r_pending_valid;
            o_weight_addr  <= r_pending_addr;
        end
    end

    // ------------------------------------------------------------------
    // o_dma_ack / o_dma_done 单拍脉冲
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_dma_ack <= 1'b0;
        else        o_dma_ack <= (state == ST_ACK);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_dma_done <= 1'b0;
        else        o_dma_done <= (state == ST_DONE);
    end

    // ------------------------------------------------------------------
    // update_weights_en：req 起拉高，W_COMMIT 拉低 (产生末沿 → page commit)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_update_weights_en <= 1'b0;
        else begin
            if (state == ST_IDLE && i_dma_req)
                o_update_weights_en <= 1'b1;
            else if (state == ST_W_COMMIT)
                o_update_weights_en <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // bias 路径：B_CONSUME 每拍输出 r_rom_q
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_bias_data  <= 32'd0;
            o_bias_valid <= 1'b0;
            o_bias_addr  <= 5'd0;
        end else begin
            o_bias_valid <= (state == ST_B_CONSUME);
            o_bias_data  <= r_rom_q;
            o_bias_addr  <= r_bias_cnt;
        end
    end

    // ------------------------------------------------------------------
    // update_bias_en：W_COMMIT 起拉高，B_COMMIT 拉低末沿
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_update_bias_en <= 1'b0;
        else begin
            if (state == ST_W_COMMIT)
                o_update_bias_en <= 1'b1;
            else if (state == ST_B_COMMIT)
                o_update_bias_en <= 1'b0;
        end
    end

endmodule
