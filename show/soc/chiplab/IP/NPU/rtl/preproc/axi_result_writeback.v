// -----------------------------------------------------------------------------
// axi_result_writeback
// -----------------------------------------------------------------------------
// Captures the final-layer 128-bit tensor stream and writes it to system memory
// as 32-bit AXI single-beat stores. The stream has no ready/backpressure signal,
// so this module uses a small FIFO and reports overflow through o_error.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "npu_math_defs.vh"

module axi_result_writeback #(
    parameter FIFO_DEPTH = 64
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         i_start,
    input  wire         i_enable,
    input  wire [31:0]  i_base_addr,
    input  wire [31:0]  i_max_bytes,
    input  wire         i_stream_valid,
    input  wire [127:0] i_stream_data,
    input  wire         i_inference_done,

    output reg          o_busy,
    output reg          o_done,
    output reg          o_error,
    output reg  [31:0]  o_write_bytes,
    output reg  [31:0]  o_checksum,
    output reg  [31:0]  o_last_addr,

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

    localparam FIFO_AW = `NPU_CLOG2(FIFO_DEPTH);
    localparam [FIFO_AW:0] FIFO_DEPTH_COUNT = FIFO_DEPTH;
    localparam [FIFO_AW-1:0] FIFO_LAST_PTR = FIFO_DEPTH - 1;

    localparam [1:0] W_IDLE = 2'd0;
    localparam [1:0] W_AW   = 2'd1;
    localparam [1:0] W_DATA = 2'd2;
    localparam [1:0] W_RESP = 2'd3;

    reg [127:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] fifo_wr_ptr;
    reg [FIFO_AW-1:0] fifo_rd_ptr;
    reg [FIFO_AW:0]   fifo_count;

    reg        r_active;
    reg        r_inference_done_seen;
    reg [31:0] r_seen_bytes;
    reg        r_cur_valid;
    reg [127:0] r_cur_data;
    reg [1:0]  r_word_idx;
    reg [1:0]  r_w_state;

    wire fifo_full  = (fifo_count == FIFO_DEPTH_COUNT);
    wire fifo_empty = (fifo_count == {FIFO_AW+1{1'b0}});
    wire capture_allowed = r_active && (r_seen_bytes < i_max_bytes);
    wire fifo_push = i_stream_valid && capture_allowed && !fifo_full;
    wire fifo_overflow = i_stream_valid && capture_allowed && fifo_full;
    wire load_cur = r_active && !r_cur_valid && !fifo_empty;
    wire fifo_pop = load_cur;

    wire [127:0] fifo_dout = fifo_mem[fifo_rd_ptr];
    reg [31:0] cur_word_r;
    wire [31:0] bytes_remaining =
        (o_write_bytes < i_max_bytes) ? (i_max_bytes - o_write_bytes) : 32'd0;
    wire [2:0] beat_byte_count =
        (bytes_remaining >= 32'd4) ? 3'd4 : bytes_remaining[2:0];
    reg [3:0] cur_wstrb_r;
    wire [3:0] cur_wstrb = cur_wstrb_r;
    wire [31:0] cur_word = cur_word_r;
    wire [31:0] cur_mask = {{8{cur_wstrb[3]}}, {8{cur_wstrb[2]}},
                            {8{cur_wstrb[1]}}, {8{cur_wstrb[0]}}};
    wire [31:0] cur_masked_word = cur_word & cur_mask;

    always @(*) begin
        case (r_word_idx)
            2'd0: cur_word_r = r_cur_data[31:0];
            2'd1: cur_word_r = r_cur_data[63:32];
            2'd2: cur_word_r = r_cur_data[95:64];
            default: cur_word_r = r_cur_data[127:96];
        endcase
    end

    always @(*) begin
        case (beat_byte_count)
            3'd1: cur_wstrb_r = 4'b0001;
            3'd2: cur_wstrb_r = 4'b0011;
            3'd3: cur_wstrb_r = 4'b0111;
            default: cur_wstrb_r = 4'b1111;
        endcase
    end

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire  = m_axi_wvalid && m_axi_wready;
    wire b_fire  = m_axi_bvalid && m_axi_bready;

    assign m_axi_awid    = 4'd0;
    assign m_axi_awaddr  = i_base_addr + o_write_bytes;
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awvalid = r_active && r_cur_valid &&
                            (bytes_remaining != 32'd0) &&
                            (r_w_state == W_AW);
    assign m_axi_wid     = 4'd0;
    assign m_axi_wdata   = cur_word;
    assign m_axi_wstrb   = cur_wstrb;
    assign m_axi_wlast   = 1'b1;
    assign m_axi_wvalid  = r_active && r_cur_valid &&
                            (bytes_remaining != 32'd0) &&
                            (r_w_state == W_DATA);
    assign m_axi_bready  = (r_w_state == W_RESP);

    wire _unused_bid = ^m_axi_bid;

    always @(posedge clk) begin
        if (fifo_push)
            fifo_mem[fifo_wr_ptr] <= i_stream_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= {FIFO_AW{1'b0}};
            fifo_rd_ptr <= {FIFO_AW{1'b0}};
            fifo_count  <= {FIFO_AW+1{1'b0}};
        end else if (i_start) begin
            fifo_wr_ptr <= {FIFO_AW{1'b0}};
            fifo_rd_ptr <= {FIFO_AW{1'b0}};
            fifo_count  <= {FIFO_AW+1{1'b0}};
        end else begin
            case ({fifo_push, fifo_pop})
                2'b10: begin
                    fifo_wr_ptr <= (fifo_wr_ptr == FIFO_LAST_PTR) ?
                                   {FIFO_AW{1'b0}} : fifo_wr_ptr + 1'b1;
                    fifo_count  <= fifo_count + 1'b1;
                end
                2'b01: begin
                    fifo_rd_ptr <= (fifo_rd_ptr == FIFO_LAST_PTR) ?
                                   {FIFO_AW{1'b0}} : fifo_rd_ptr + 1'b1;
                    fifo_count  <= fifo_count - 1'b1;
                end
                2'b11: begin
                    fifo_wr_ptr <= (fifo_wr_ptr == FIFO_LAST_PTR) ?
                                   {FIFO_AW{1'b0}} : fifo_wr_ptr + 1'b1;
                    fifo_rd_ptr <= (fifo_rd_ptr == FIFO_LAST_PTR) ?
                                   {FIFO_AW{1'b0}} : fifo_rd_ptr + 1'b1;
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_active <= 1'b0;
            r_inference_done_seen <= 1'b0;
            r_seen_bytes <= 32'd0;
            r_cur_valid <= 1'b0;
            r_cur_data <= 128'd0;
            r_word_idx <= 2'd0;
            r_w_state <= W_IDLE;
            o_busy <= 1'b0;
            o_done <= 1'b0;
            o_error <= 1'b0;
            o_write_bytes <= 32'd0;
            o_checksum <= 32'd0;
            o_last_addr <= 32'd0;
        end else if (i_start) begin
            r_active <= i_enable && (i_max_bytes != 32'd0);
            r_inference_done_seen <= 1'b0;
            r_seen_bytes <= 32'd0;
            r_cur_valid <= 1'b0;
            r_cur_data <= 128'd0;
            r_word_idx <= 2'd0;
            r_w_state <= W_IDLE;
            o_busy <= i_enable && (i_max_bytes != 32'd0);
            o_done <= 1'b0;
            o_error <= 1'b0;
            o_write_bytes <= 32'd0;
            o_checksum <= 32'd0;
            o_last_addr <= 32'd0;
        end else begin
            if (fifo_push) begin
                if (r_seen_bytes <= 32'hfffffff0)
                    r_seen_bytes <= r_seen_bytes + 32'd16;
                else
                    r_seen_bytes <= 32'hffffffff;
            end

            if (fifo_overflow)
                o_error <= 1'b1;

            if (i_inference_done && r_active)
                r_inference_done_seen <= 1'b1;

            if (load_cur) begin
                r_cur_valid <= 1'b1;
                r_cur_data  <= fifo_dout;
                r_word_idx  <= 2'd0;
                r_w_state   <= W_AW;
            end

            case (r_w_state)
                W_IDLE: begin
                    if (r_cur_valid && (bytes_remaining != 32'd0))
                        r_w_state <= W_AW;
                end
                W_AW: begin
                    if (aw_fire) begin
                        o_last_addr <= m_axi_awaddr;
                        r_w_state <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (w_fire)
                        r_w_state <= W_RESP;
                end
                W_RESP: begin
                    if (b_fire) begin
                        if (m_axi_bresp != 2'b00)
                            o_error <= 1'b1;
                        o_write_bytes <= o_write_bytes + {29'd0, beat_byte_count};
                        o_checksum <= o_checksum ^ cur_masked_word;
                        if ((r_word_idx == 2'd3) ||
                            ((o_write_bytes + {29'd0, beat_byte_count}) >= i_max_bytes)) begin
                            r_cur_valid <= 1'b0;
                            r_word_idx  <= 2'd0;
                            r_w_state   <= W_IDLE;
                        end else begin
                            r_word_idx <= r_word_idx + 2'd1;
                            r_w_state  <= W_AW;
                        end
                    end
                end
                default: r_w_state <= W_IDLE;
            endcase

            if (r_active && r_inference_done_seen && fifo_empty &&
                !r_cur_valid && (r_w_state == W_IDLE)) begin
                r_active <= 1'b0;
                o_busy   <= 1'b0;
                o_done   <= 1'b1;
            end else if (r_active) begin
                o_busy <= 1'b1;
            end
        end
    end

endmodule
