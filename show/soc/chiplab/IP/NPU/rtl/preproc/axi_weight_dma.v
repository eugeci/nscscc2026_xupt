// -----------------------------------------------------------------------------
// axi_weight_dma
// -----------------------------------------------------------------------------
// Replaces the on-chip parameter ROM data source with AXI single-beat reads while
// keeping the same sequencer-facing and buffer-facing protocol as weight_rom_dma.
// The sequencer still supplies 32-bit word offsets; i_param_base_addr supplies
// the physical byte base address of the parameter image in system memory.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module axi_weight_dma #(
    parameter ADDR_W = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  i_dma_req,
    input  wire [ADDR_W-1:0]     i_dma_base_addr,
    input  wire [ADDR_W-1:0]     i_bias_base_addr,
    input  wire [15:0]           i_dma_length,
    input  wire [1:0]            i_kernel_size,
    input  wire [31:0]           i_param_base_addr,
    output reg                   o_dma_ack,
    output reg                   o_dma_done,
    output reg                   o_dma_error,

    output reg  [143:0]          o_weight_data,
    output reg                   o_weight_valid,
    output reg  [9:0]            o_weight_addr,
    output reg                   o_update_weights_en,

    output reg  [31:0]           o_bias_data,
    output reg                   o_bias_valid,
    output reg  [4:0]            o_bias_addr,
    output reg                   o_update_bias_en,

    output wire [3:0]            m_axi_arid,
    output wire [31:0]           m_axi_araddr,
    output wire [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output wire                  m_axi_arlock,
    output wire [3:0]            m_axi_arcache,
    output wire [2:0]            m_axi_arprot,
    output wire                  m_axi_arvalid,
    input  wire                  m_axi_arready,

    input  wire [3:0]            m_axi_rid,
    input  wire [31:0]           m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready,

    output wire [31:0]           o_dbg0,
    output wire [31:0]           o_dbg1,
    output wire [31:0]           o_dbg2,
    output wire [31:0]           o_dbg3,
    output wire [31:0]           o_dbg4,
    output wire [31:0]           o_dbg5,
    output wire [31:0]           o_dbg6,
    output wire [31:0]           o_dbg7,
    output wire [31:0]           o_dbg8,
    output wire [31:0]           o_dbg9,
    output wire [31:0]           o_dbg10,
    output wire [31:0]           o_dbg11,
    output wire [31:0]           o_dbg12,
    output wire [31:0]           o_dbg13,
    output wire [31:0]           o_dbg14,
    output wire [31:0]           o_dbg15,
    output wire [31:0]           o_dbg16,
    output wire [31:0]           o_dbg17,
    output wire [31:0]           o_dbg18
);

    localparam ST_IDLE      = 4'd0;
    localparam ST_ACK       = 4'd1;
    localparam ST_W_AR      = 4'd2;
    localparam ST_W_R       = 4'd3;
    localparam ST_W_CONSUME = 4'd4;
    localparam ST_W_DRAIN   = 4'd5;
    localparam ST_W_COMMIT  = 4'd6;
    localparam ST_B_AR      = 4'd7;
    localparam ST_B_R       = 4'd8;
    localparam ST_B_COMMIT  = 4'd9;
    localparam ST_DONE      = 4'd10;

    reg [3:0] state, next_state;

    reg [31:0] r_axi_addr;
    reg [31:0] r_word_buf;
    reg [1:0]  r_byte_in_word;
    reg [15:0] r_words_left;
    reg [4:0]  r_bias_cnt;
    reg [3:0]  r_k2_locked;

    reg [4:0]  r_cin_local;
    reg [3:0]  r_oc_pair;
    reg        r_half;
    reg [3:0]  r_byte_in_half;
    reg [71:0] r_even_buf;
    reg [71:0] r_odd_buf;

    reg [15:0] r_dbg_req_count;
    reg [15:0] r_dbg_done_count;
    reg [15:0] r_dbg_last_dma_base_addr;
    reg [15:0] r_dbg_last_bias_base_addr;
    reg [15:0] r_dbg_last_dma_length;
    reg [1:0]  r_dbg_last_kernel_size;
    reg [15:0] r_dbg_last_weight_words;
    reg [15:0] r_dbg_last_bias_words;
    reg [31:0] r_dbg_weight_r_xor_total;
    reg [31:0] r_dbg_bias_r_xor_total;
    reg [31:0] r_dbg_weight_r_xor_last;
    reg [31:0] r_dbg_bias_r_xor_last;
    reg [31:0] r_dbg_weight_emit_xor_last;
    reg [31:0] r_dbg_bias_emit_xor_last;
    reg [31:0] r_dbg_weight_first_data;
    reg [31:0] r_dbg_weight_last_data;
    reg [31:0] r_dbg_bias_first_data;
    reg [31:0] r_dbg_bias_last_data;
    reg [31:0] r_dbg_weight_first_addr;
    reg [31:0] r_dbg_weight_last_addr;
    reg [31:0] r_dbg_bias_first_addr;
    reg [31:0] r_dbg_bias_last_addr;
    reg        r_dbg_weight_seen;
    reg        r_dbg_bias_seen;

    wire [31:0] w_weight_start_addr =
        i_param_base_addr + ({{(32-ADDR_W){1'b0}}, i_dma_base_addr} << 2);
    wire [31:0] w_bias_start_addr =
        i_param_base_addr + ({{(32-ADDR_W){1'b0}}, i_bias_base_addr} << 2);

    wire [7:0] w_cur_byte = r_word_buf[r_byte_in_word*8 +: 8];

    wire w_ar_fire         = m_axi_arvalid && m_axi_arready;
    wire w_r_fire          = m_axi_rvalid && m_axi_rready;
    wire w_word_byte_done  = (r_byte_in_word == 2'd3);
    wire w_more_words      = (r_words_left > 16'd0);
    wire w_pair_last_byte  = (r_half == 1'b1) &&
                             (r_byte_in_half == r_k2_locked - 4'd1);

    assign m_axi_arid    = 4'd0;
    assign m_axi_araddr  = r_axi_addr;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'd2;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arvalid = (state == ST_W_AR) || (state == ST_B_AR);
    assign m_axi_rready  = (state == ST_W_R)  || (state == ST_B_R);

    wire _unused_rid = ^m_axi_rid;

    reg [3:0] w_k2_decode;
    wire [31:0] w_weight_emit_fold =
        o_weight_data[31:0] ^ o_weight_data[63:32] ^
        o_weight_data[95:64] ^ o_weight_data[127:96] ^
        {16'd0, o_weight_data[143:128]};

    always @(*) begin
        case (i_kernel_size)
            2'b00:   w_k2_decode = 4'd1;
            2'b01:   w_k2_decode = 4'd4;
            2'b10:   w_k2_decode = 4'd9;
            default: w_k2_decode = 4'd1;
        endcase
    end

    assign o_dbg0  = {r_dbg_req_count, r_dbg_done_count};
    assign o_dbg1  = {r_dbg_last_dma_base_addr, r_dbg_last_dma_length};
    assign o_dbg2  = {r_dbg_last_bias_base_addr, 14'd0, r_dbg_last_kernel_size};
    assign o_dbg3  = {r_dbg_last_weight_words, r_dbg_last_bias_words};
    assign o_dbg4  = r_dbg_weight_r_xor_total;
    assign o_dbg5  = r_dbg_bias_r_xor_total;
    assign o_dbg6  = r_dbg_weight_r_xor_last;
    assign o_dbg7  = r_dbg_bias_r_xor_last;
    assign o_dbg8  = r_dbg_weight_emit_xor_last;
    assign o_dbg9  = r_dbg_bias_emit_xor_last;
    assign o_dbg10 = r_dbg_weight_first_data;
    assign o_dbg11 = r_dbg_weight_last_data;
    assign o_dbg12 = r_dbg_bias_first_data;
    assign o_dbg13 = r_dbg_bias_last_data;
    assign o_dbg14 = r_dbg_weight_first_addr;
    assign o_dbg15 = r_dbg_weight_last_addr;
    assign o_dbg16 = r_dbg_bias_first_addr;
    assign o_dbg17 = r_dbg_bias_last_addr;
    assign o_dbg18 = {12'd0, state, r_bias_cnt, r_words_left, o_dma_error};

    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE:      if (i_dma_req)                       next_state = ST_ACK;
            ST_ACK:       if (r_words_left == 16'd0)           next_state = ST_W_DRAIN;
                          else                                 next_state = ST_W_AR;
            ST_W_AR:      if (w_ar_fire)                       next_state = ST_W_R;
            ST_W_R:       if (w_r_fire)                        next_state = ST_W_CONSUME;
            ST_W_CONSUME: if (w_word_byte_done) begin
                              if (w_more_words)                next_state = ST_W_AR;
                              else                             next_state = ST_W_DRAIN;
                          end
            ST_W_DRAIN:                                        next_state = ST_W_COMMIT;
            ST_W_COMMIT:                                       next_state = ST_B_AR;
            ST_B_AR:      if (w_ar_fire)                       next_state = ST_B_R;
            ST_B_R:       if (w_r_fire) begin
                              if (r_bias_cnt == 5'd15)         next_state = ST_B_COMMIT;
                              else                             next_state = ST_B_AR;
                          end
            ST_B_COMMIT:                                       next_state = ST_DONE;
            ST_DONE:                                           next_state = ST_IDLE;
            default:                                           next_state = ST_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= next_state;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_axi_addr     <= 32'd0;
            r_word_buf     <= 32'd0;
            r_byte_in_word <= 2'd0;
            r_words_left   <= 16'd0;
            r_bias_cnt     <= 5'd0;
            r_k2_locked    <= 4'd1;
            o_dma_error    <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (i_dma_req) begin
                        r_axi_addr   <= w_weight_start_addr;
                        r_words_left <= i_dma_length;
                        r_k2_locked  <= w_k2_decode;
                        o_dma_error  <= 1'b0;
                    end
                end
                ST_W_R: begin
                    if (w_r_fire) begin
                        r_word_buf     <= m_axi_rdata;
                        r_byte_in_word <= 2'd0;
                        r_axi_addr     <= r_axi_addr + 32'd4;
                        if (r_words_left != 16'd0)
                            r_words_left <= r_words_left - 16'd1;
                        if (m_axi_rresp != 2'b00 || !m_axi_rlast)
                            o_dma_error <= 1'b1;
                    end
                end
                ST_W_CONSUME: begin
                    if (!w_word_byte_done)
                        r_byte_in_word <= r_byte_in_word + 2'd1;
                end
                ST_W_COMMIT: begin
                    r_axi_addr <= w_bias_start_addr;
                    r_bias_cnt <= 5'd0;
                end
                ST_B_R: begin
                    if (w_r_fire) begin
                        if (r_bias_cnt != 5'd15)
                            r_axi_addr <= r_axi_addr + 32'd4;
                        r_bias_cnt <= r_bias_cnt + 5'd1;
                        if (m_axi_rresp != 2'b00 || !m_axi_rlast)
                            o_dma_error <= 1'b1;
                    end
                end
                default: ;
            endcase
        end
    end

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
            if (r_half == 1'b0)
                r_even_buf[r_byte_in_half*8 +: 8] <= w_cur_byte;
            else
                r_odd_buf [r_byte_in_half*8 +: 8] <= w_cur_byte;

            if (r_byte_in_half == r_k2_locked - 4'd1) begin
                r_byte_in_half <= 4'd0;
                if (r_half == 1'b0) begin
                    r_half <= 1'b1;
                end else begin
                    r_half     <= 1'b0;
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

    wire [71:0] w_odd_final = r_odd_buf | ({64'd0, w_cur_byte} << (r_byte_in_half * 8));
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_dma_ack <= 1'b0;
        else        o_dma_ack <= (state == ST_ACK);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_dma_done <= 1'b0;
        else        o_dma_done <= (state == ST_DONE);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_update_weights_en <= 1'b0;
        else begin
            if (state == ST_IDLE && i_dma_req)
                o_update_weights_en <= 1'b1;
            else if (state == ST_W_COMMIT)
                o_update_weights_en <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_bias_data  <= 32'd0;
            o_bias_valid <= 1'b0;
            o_bias_addr  <= 5'd0;
        end else begin
            o_bias_valid <= 1'b0;
            if (state == ST_B_R && w_r_fire) begin
                o_bias_data  <= m_axi_rdata;
                o_bias_valid <= 1'b1;
                o_bias_addr  <= r_bias_cnt;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_dbg_req_count           <= 16'd0;
            r_dbg_done_count          <= 16'd0;
            r_dbg_last_dma_base_addr  <= 16'd0;
            r_dbg_last_bias_base_addr <= 16'd0;
            r_dbg_last_dma_length     <= 16'd0;
            r_dbg_last_kernel_size    <= 2'd0;
            r_dbg_last_weight_words   <= 16'd0;
            r_dbg_last_bias_words     <= 16'd0;
            r_dbg_weight_r_xor_total  <= 32'd0;
            r_dbg_bias_r_xor_total    <= 32'd0;
            r_dbg_weight_r_xor_last   <= 32'd0;
            r_dbg_bias_r_xor_last     <= 32'd0;
            r_dbg_weight_emit_xor_last <= 32'd0;
            r_dbg_bias_emit_xor_last  <= 32'd0;
            r_dbg_weight_first_data   <= 32'd0;
            r_dbg_weight_last_data    <= 32'd0;
            r_dbg_bias_first_data     <= 32'd0;
            r_dbg_bias_last_data      <= 32'd0;
            r_dbg_weight_first_addr   <= 32'd0;
            r_dbg_weight_last_addr    <= 32'd0;
            r_dbg_bias_first_addr     <= 32'd0;
            r_dbg_bias_last_addr      <= 32'd0;
            r_dbg_weight_seen         <= 1'b0;
            r_dbg_bias_seen           <= 1'b0;
        end else begin
            if (state == ST_IDLE && i_dma_req) begin
                if (r_dbg_req_count != 16'hffff)
                    r_dbg_req_count <= r_dbg_req_count + 16'd1;
                r_dbg_last_dma_base_addr  <= i_dma_base_addr;
                r_dbg_last_bias_base_addr <= i_bias_base_addr;
                r_dbg_last_dma_length     <= i_dma_length;
                r_dbg_last_kernel_size    <= i_kernel_size;
                r_dbg_last_weight_words   <= 16'd0;
                r_dbg_last_bias_words     <= 16'd0;
                r_dbg_weight_r_xor_last   <= 32'd0;
                r_dbg_bias_r_xor_last     <= 32'd0;
                r_dbg_weight_emit_xor_last <= 32'd0;
                r_dbg_bias_emit_xor_last  <= 32'd0;
                r_dbg_weight_first_data   <= 32'd0;
                r_dbg_weight_last_data    <= 32'd0;
                r_dbg_bias_first_data     <= 32'd0;
                r_dbg_bias_last_data      <= 32'd0;
                r_dbg_weight_first_addr   <= w_weight_start_addr;
                r_dbg_weight_last_addr    <= w_weight_start_addr;
                r_dbg_bias_first_addr     <= w_bias_start_addr;
                r_dbg_bias_last_addr      <= w_bias_start_addr;
                r_dbg_weight_seen         <= 1'b0;
                r_dbg_bias_seen           <= 1'b0;
            end

            if (state == ST_W_R && w_r_fire) begin
                if (!r_dbg_weight_seen) begin
                    r_dbg_weight_first_data <= m_axi_rdata;
                    r_dbg_weight_first_addr <= r_axi_addr;
                    r_dbg_weight_seen       <= 1'b1;
                end
                r_dbg_weight_last_data   <= m_axi_rdata;
                r_dbg_weight_last_addr   <= r_axi_addr;
                r_dbg_weight_r_xor_last  <= r_dbg_weight_r_xor_last ^ m_axi_rdata;
                r_dbg_weight_r_xor_total <= r_dbg_weight_r_xor_total ^ m_axi_rdata;
                if (r_dbg_last_weight_words != 16'hffff)
                    r_dbg_last_weight_words <= r_dbg_last_weight_words + 16'd1;
            end

            if (state == ST_B_R && w_r_fire) begin
                if (!r_dbg_bias_seen) begin
                    r_dbg_bias_first_data <= m_axi_rdata;
                    r_dbg_bias_first_addr <= r_axi_addr;
                    r_dbg_bias_seen       <= 1'b1;
                end
                r_dbg_bias_last_data   <= m_axi_rdata;
                r_dbg_bias_last_addr   <= r_axi_addr;
                r_dbg_bias_r_xor_last  <= r_dbg_bias_r_xor_last ^ m_axi_rdata;
                r_dbg_bias_r_xor_total <= r_dbg_bias_r_xor_total ^ m_axi_rdata;
                if (r_dbg_last_bias_words != 16'hffff)
                    r_dbg_last_bias_words <= r_dbg_last_bias_words + 16'd1;
            end

            if (o_weight_valid) begin
                r_dbg_weight_emit_xor_last <=
                    r_dbg_weight_emit_xor_last ^ w_weight_emit_fold;
            end

            if (o_bias_valid) begin
                r_dbg_bias_emit_xor_last <= r_dbg_bias_emit_xor_last ^ o_bias_data;
            end

            if (state == ST_DONE && r_dbg_done_count != 16'hffff) begin
                r_dbg_done_count <= r_dbg_done_count + 16'd1;
            end
        end
    end

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
