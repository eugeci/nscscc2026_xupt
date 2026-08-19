// -----------------------------------------------------------------------------
// pool_reorder_buffer
// -----------------------------------------------------------------------------
// Reorders quantized convolution output into raster order before 2x2 pooling.
// The BRAM backend preserves the original on-chip behavior. The AXI backend
// stores entries in external scratch memory as 128-bit records. The AXI backend
// can either transfer each record as one 4-beat burst or as four single-beat
// transactions for board-level AXI path isolation.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "npu_math_defs.vh"

module pool_reorder_buffer #(
    parameter BUS_WIDTH     = 128,
    parameter ADDR_WIDTH    = 15,
    parameter MEMORY_DEPTH  = 19200,
    parameter USE_AXI       = 1'b0,
    parameter AXI_BURST_BEATS = 4,
    parameter FIFO_DEPTH    = 512,
    parameter FIFO_MARGIN   = 320
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       i_clear,
    input  wire                       i_enable,
    input  wire [7:0]                 i_width,
    input  wire [7:0]                 i_height,
    input  wire [31:0]                i_scratch_base_addr,

    input  wire                       i_in_valid,
    input  wire [BUS_WIDTH-1:0]       i_in_data,
    input  wire [7:0]                 i_in_x,
    input  wire [7:0]                 i_in_y,
    output wire                       o_input_ready,

    output reg  [BUS_WIDTH-1:0]       o_out_data,
    output reg                        o_out_valid,
    output wire                       o_busy,
    output reg                        o_error,

    output wire [31:0]                o_dbg0,
    output wire [31:0]                o_dbg1,
    output wire [31:0]                o_dbg2,
    output wire [31:0]                o_dbg3,
    output wire [31:0]                o_dbg4,
    output wire [31:0]                o_dbg5,
    output wire [31:0]                o_dbg6,
    output wire [31:0]                o_dbg7,
    output wire [31:0]                o_dbg8,
    output wire [31:0]                o_dbg9,
    output wire [31:0]                o_dbg10,
    output wire [31:0]                o_dbg11,
    output wire [31:0]                o_dbg12,
    output wire [31:0]                o_dbg13,
    output wire [31:0]                o_dbg14,
    output wire [31:0]                o_dbg15,
    output wire [31:0]                o_dbg16,
    output wire [31:0]                o_dbg17,
    output wire [31:0]                o_dbg18,

    output wire [3:0]                 m_axi_arid,
    output wire [31:0]                m_axi_araddr,
    output wire [7:0]                 m_axi_arlen,
    output wire [2:0]                 m_axi_arsize,
    output wire [1:0]                 m_axi_arburst,
    output wire                       m_axi_arlock,
    output wire [3:0]                 m_axi_arcache,
    output wire [2:0]                 m_axi_arprot,
    output wire                       m_axi_arvalid,
    input  wire                       m_axi_arready,
    input  wire [3:0]                 m_axi_rid,
    input  wire [31:0]                m_axi_rdata,
    input  wire [1:0]                 m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output wire                       m_axi_rready,

    output wire [3:0]                 m_axi_awid,
    output wire [31:0]                m_axi_awaddr,
    output wire [7:0]                 m_axi_awlen,
    output wire [2:0]                 m_axi_awsize,
    output wire [1:0]                 m_axi_awburst,
    output wire                       m_axi_awlock,
    output wire [3:0]                 m_axi_awcache,
    output wire [2:0]                 m_axi_awprot,
    output wire                       m_axi_awvalid,
    input  wire                       m_axi_awready,
    output wire [3:0]                 m_axi_wid,
    output wire [31:0]                m_axi_wdata,
    output wire [3:0]                 m_axi_wstrb,
    output wire                       m_axi_wlast,
    output wire                       m_axi_wvalid,
    input  wire                       m_axi_wready,
    input  wire [3:0]                 m_axi_bid,
    input  wire [1:0]                 m_axi_bresp,
    input  wire                       m_axi_bvalid,
    output wire                       m_axi_bready
);

    localparam FIFO_AW    = `NPU_CLOG2(FIFO_DEPTH);
    localparam ENTRY_W    = ADDR_WIDTH + BUS_WIDTH;
    localparam RD_IDLE    = 2'd0;
    localparam RD_WAIT    = 2'd1;
    localparam R_IDLE     = 2'd0;
    localparam R_AR       = 2'd1;
    localparam R_DATA     = 2'd2;
    localparam W_IDLE     = 2'd0;
    localparam W_AW       = 2'd1;
    localparam W_DATA     = 2'd2;
    localparam W_RESP     = 2'd3;
    localparam [FIFO_AW:0]   FIFO_DEPTH_COUNT       = FIFO_DEPTH;
    localparam [FIFO_AW:0]   FIFO_ALMOST_FULL_COUNT = FIFO_DEPTH - FIFO_MARGIN;
    localparam [FIFO_AW-1:0] FIFO_LAST_PTR          = FIFO_DEPTH - 1;

    wire [15:0] w_cap_total = ({8'd0, i_width}) * ({8'd0, i_height});
    wire [15:0] w_cap_addr_full = ({8'd0, i_in_y} * {8'd0, i_width}) + {8'd0, i_in_x};

    reg [15:0] r_cap_cnt;
    reg        r_replay_active;
    reg [7:0]  r_replay_x;
    reg [7:0]  r_replay_y;
    reg        r_rd_pending;

    wire [15:0] w_replay_addr_full =
        ({8'd0, r_replay_y} * {8'd0, i_width}) + {8'd0, r_replay_x};
    wire w_replay_last = r_replay_active &&
                         (r_replay_x == i_width - 8'd1) &&
                         (r_replay_y == i_height - 8'd1);

    wire                       be_wr_ready;
    wire                       be_wr_almost_full;
    wire                       be_wr_valid;
    wire [ADDR_WIDTH-1:0]      be_wr_addr;
    wire [BUS_WIDTH-1:0]       be_wr_data;
    wire                       be_rd_ready;
    wire                       be_rd_req;
    wire [ADDR_WIDTH-1:0]      be_rd_addr;
    wire [BUS_WIDTH-1:0]       be_rd_data;
    wire                       be_rd_valid;
    wire                       be_busy;
    wire                       be_error;
    wire [15:0]                be_fifo_level;

    assign o_input_ready = !i_enable || (!r_replay_active && !be_wr_almost_full);
    assign be_wr_valid   = i_enable && i_in_valid && !r_replay_active && be_wr_ready;
    assign be_wr_addr    = w_cap_addr_full[ADDR_WIDTH-1:0];
    assign be_wr_data    = i_in_data;

    wire w_cap_fire = be_wr_valid;
    wire w_cap_last = w_cap_fire && (r_cap_cnt + 16'd1 == w_cap_total);

    assign be_rd_req  = r_replay_active && !r_rd_pending && be_rd_ready;
    assign be_rd_addr = w_replay_addr_full[ADDR_WIDTH-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_cap_cnt       <= 16'd0;
            r_replay_active <= 1'b0;
            r_replay_x      <= 8'd0;
            r_replay_y      <= 8'd0;
            r_rd_pending    <= 1'b0;
            o_out_data      <= {BUS_WIDTH{1'b0}};
            o_out_valid     <= 1'b0;
            o_error         <= 1'b0;
        end else begin
            o_out_valid <= 1'b0;

            if (i_clear || !i_enable) begin
                r_cap_cnt       <= 16'd0;
                r_replay_active <= 1'b0;
                r_replay_x      <= 8'd0;
                r_replay_y      <= 8'd0;
                r_rd_pending    <= 1'b0;
                o_error         <= 1'b0;
            end else begin
                if (i_in_valid && !r_replay_active && !be_wr_ready)
                    o_error <= 1'b1;
                if (be_error)
                    o_error <= 1'b1;

                if (w_cap_fire)
                    r_cap_cnt <= r_cap_cnt + 16'd1;

                if (w_cap_last) begin
                    r_replay_active <= 1'b1;
                    r_replay_x      <= 8'd0;
                    r_replay_y      <= 8'd0;
                end

                if (be_rd_req)
                    r_rd_pending <= 1'b1;

                if (be_rd_valid) begin
                    r_rd_pending <= 1'b0;
                    o_out_data   <= be_rd_data;
                    o_out_valid  <= 1'b1;

                    if (w_replay_last) begin
                        r_replay_active <= 1'b0;
                        r_replay_x      <= 8'd0;
                        r_replay_y      <= 8'd0;
                        r_cap_cnt       <= 16'd0;
                    end else if (r_replay_x == i_width - 8'd1) begin
                        r_replay_x <= 8'd0;
                        r_replay_y <= r_replay_y + 8'd1;
                    end else begin
                        r_replay_x <= r_replay_x + 8'd1;
                    end
                end
            end
        end
    end

    assign o_busy = i_enable && ((r_cap_cnt != 16'd0) ||
                                 r_replay_active ||
                                 r_rd_pending ||
                                 be_busy);

    wire dbg_input_enabled = i_enable && i_in_valid;
    wire dbg_input_blocked = dbg_input_enabled && !o_input_ready;
    wire dbg_input_dropped = dbg_input_enabled && (!be_wr_ready || r_replay_active);

    reg [31:0] dbg_in_valid_count;
    reg [31:0] dbg_wr_accept_count;
    reg [31:0] dbg_replay_out_count;
    reg [31:0] dbg_blocked_count;
    reg [31:0] dbg_dropped_count;
    reg [15:0] dbg_capture_sessions;
    reg [15:0] dbg_replay_sessions;
    reg [15:0] dbg_fifo_max;
    reg [15:0] dbg_last_cap_total;
    reg [15:0] dbg_first_drop_cap_cnt;
    reg [7:0]  dbg_first_drop_width;
    reg [7:0]  dbg_first_drop_height;
    reg [7:0]  dbg_first_drop_x;
    reg [7:0]  dbg_first_drop_y;
    reg        dbg_first_drop_seen;
    reg [31:0] dbg_cap_live_xor;
    reg [31:0] dbg_replay_live_xor;
    reg [31:0] dbg_last_cap_xor;
    reg [31:0] dbg_last_replay_xor;
    reg [7:0]  dbg_last_cap_width;
    reg [7:0]  dbg_last_cap_height;
    reg [15:0] dbg_last_cap_first_addr;
    reg [15:0] dbg_last_cap_last_addr;
    reg [15:0] dbg_last_replay_first_addr;
    reg [15:0] dbg_last_replay_last_addr;
    reg [31:0] dbg_last_cap_first_data_xor;
    reg [31:0] dbg_last_cap_last_data_xor;
    reg [31:0] dbg_last_replay_first_data_xor;
    reg [31:0] dbg_last_replay_last_data_xor;

    wire [31:0] dbg_cap_data_xor =
        be_wr_data[31:0] ^ be_wr_data[63:32] ^
        be_wr_data[95:64] ^ be_wr_data[127:96];
    wire [31:0] dbg_replay_data_xor =
        be_rd_data[31:0] ^ be_rd_data[63:32] ^
        be_rd_data[95:64] ^ be_rd_data[127:96];
    wire [31:0] dbg_cap_sample_xor =
        {16'd0, be_wr_addr} ^ dbg_cap_data_xor;
    wire [31:0] dbg_replay_sample_xor =
        {16'd0, be_rd_addr} ^ dbg_replay_data_xor;
    wire [31:0] dbg_cap_next_xor =
        (r_cap_cnt == 16'd0) ? dbg_cap_sample_xor :
                               (dbg_cap_live_xor ^ dbg_cap_sample_xor);
    wire dbg_replay_first =
        be_rd_valid && (r_replay_x == 8'd0) && (r_replay_y == 8'd0);
    wire [31:0] dbg_replay_next_xor =
        dbg_replay_first ? dbg_replay_sample_xor :
                           (dbg_replay_live_xor ^ dbg_replay_sample_xor);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_in_valid_count     <= 32'd0;
            dbg_wr_accept_count    <= 32'd0;
            dbg_replay_out_count   <= 32'd0;
            dbg_blocked_count      <= 32'd0;
            dbg_dropped_count      <= 32'd0;
            dbg_capture_sessions   <= 16'd0;
            dbg_replay_sessions    <= 16'd0;
            dbg_fifo_max           <= 16'd0;
            dbg_last_cap_total     <= 16'd0;
            dbg_first_drop_cap_cnt <= 16'd0;
            dbg_first_drop_width   <= 8'd0;
            dbg_first_drop_height  <= 8'd0;
            dbg_first_drop_x       <= 8'd0;
            dbg_first_drop_y       <= 8'd0;
            dbg_first_drop_seen    <= 1'b0;
            dbg_cap_live_xor       <= 32'd0;
            dbg_replay_live_xor    <= 32'd0;
            dbg_last_cap_xor       <= 32'd0;
            dbg_last_replay_xor    <= 32'd0;
            dbg_last_cap_width     <= 8'd0;
            dbg_last_cap_height    <= 8'd0;
            dbg_last_cap_first_addr <= 16'd0;
            dbg_last_cap_last_addr <= 16'd0;
            dbg_last_replay_first_addr <= 16'd0;
            dbg_last_replay_last_addr <= 16'd0;
            dbg_last_cap_first_data_xor <= 32'd0;
            dbg_last_cap_last_data_xor <= 32'd0;
            dbg_last_replay_first_data_xor <= 32'd0;
            dbg_last_replay_last_data_xor <= 32'd0;
        end else begin
            if (dbg_input_enabled && dbg_in_valid_count != 32'hffffffff)
                dbg_in_valid_count <= dbg_in_valid_count + 32'd1;
            if (w_cap_fire && dbg_wr_accept_count != 32'hffffffff)
                dbg_wr_accept_count <= dbg_wr_accept_count + 32'd1;
            if (be_rd_valid && dbg_replay_out_count != 32'hffffffff)
                dbg_replay_out_count <= dbg_replay_out_count + 32'd1;
            if (dbg_input_blocked && dbg_blocked_count != 32'hffffffff)
                dbg_blocked_count <= dbg_blocked_count + 32'd1;
            if (dbg_input_dropped && dbg_dropped_count != 32'hffffffff)
                dbg_dropped_count <= dbg_dropped_count + 32'd1;

            if (w_cap_fire && r_cap_cnt == 16'd0 &&
                dbg_capture_sessions != 16'hffff)
                dbg_capture_sessions <= dbg_capture_sessions + 16'd1;
            if (w_cap_last && dbg_replay_sessions != 16'hffff)
                dbg_replay_sessions <= dbg_replay_sessions + 16'd1;
            if (w_cap_last)
                dbg_last_cap_total <= w_cap_total;
            if (be_fifo_level > dbg_fifo_max)
                dbg_fifo_max <= be_fifo_level;

            if (w_cap_fire) begin
                dbg_cap_live_xor <= dbg_cap_next_xor;
                dbg_last_cap_last_addr <= {1'b0, be_wr_addr};
                dbg_last_cap_last_data_xor <= dbg_cap_data_xor;
                if (r_cap_cnt == 16'd0) begin
                    dbg_last_cap_first_addr <= {1'b0, be_wr_addr};
                    dbg_last_cap_first_data_xor <= dbg_cap_data_xor;
                end
            end

            if (w_cap_last) begin
                dbg_last_cap_xor    <= dbg_cap_next_xor;
                dbg_last_cap_width  <= i_width;
                dbg_last_cap_height <= i_height;
            end

            if (be_rd_valid) begin
                dbg_replay_live_xor <= dbg_replay_next_xor;
                dbg_last_replay_last_addr <= {1'b0, be_rd_addr};
                dbg_last_replay_last_data_xor <= dbg_replay_data_xor;
                if (dbg_replay_first) begin
                    dbg_last_replay_first_addr <= {1'b0, be_rd_addr};
                    dbg_last_replay_first_data_xor <= dbg_replay_data_xor;
                end
            end

            if (be_rd_valid && w_replay_last)
                dbg_last_replay_xor <= dbg_replay_next_xor;

            if (dbg_input_dropped && !dbg_first_drop_seen) begin
                dbg_first_drop_seen    <= 1'b1;
                dbg_first_drop_cap_cnt <= r_cap_cnt;
                dbg_first_drop_width   <= i_width;
                dbg_first_drop_height  <= i_height;
                dbg_first_drop_x       <= i_in_x;
                dbg_first_drop_y       <= i_in_y;
            end
        end
    end

    assign o_dbg0 = {dbg_capture_sessions, dbg_replay_sessions};
    assign o_dbg1 = dbg_in_valid_count;
    assign o_dbg2 = dbg_wr_accept_count;
    assign o_dbg3 = dbg_replay_out_count;
    assign o_dbg4 = dbg_blocked_count;
    assign o_dbg5 = dbg_dropped_count;
    assign o_dbg6 = {dbg_fifo_max, be_fifo_level};
    assign o_dbg7 = {dbg_first_drop_width, dbg_first_drop_height,
                     dbg_first_drop_x, dbg_first_drop_y};
    assign o_dbg8 = {dbg_first_drop_cap_cnt, dbg_last_cap_total};
    assign o_dbg9 = {20'd0, dbg_first_drop_seen, o_error, be_error,
                     r_replay_active, r_rd_pending, o_input_ready,
                     be_wr_ready, be_wr_almost_full, i_enable,
                     i_in_valid, be_wr_valid};
    assign o_dbg10 = dbg_last_cap_xor;
    assign o_dbg11 = dbg_last_replay_xor;
    assign o_dbg12 = {dbg_last_cap_width, dbg_last_cap_height,
                      dbg_last_cap_total};
    assign o_dbg13 = {dbg_last_cap_first_addr, dbg_last_cap_last_addr};
    assign o_dbg14 = {dbg_last_replay_first_addr,
                      dbg_last_replay_last_addr};
    assign o_dbg15 = dbg_last_cap_first_data_xor;
    assign o_dbg16 = dbg_last_cap_last_data_xor;
    assign o_dbg17 = dbg_last_replay_first_data_xor;
    assign o_dbg18 = dbg_last_replay_last_data_xor;

    generate
        if (USE_AXI) begin : gen_axi_backend
            reg [ENTRY_W-1:0] wr_fifo [0:FIFO_DEPTH-1];
            reg [FIFO_AW-1:0] fifo_wr_ptr;
            reg [FIFO_AW-1:0] fifo_rd_ptr;
            reg [FIFO_AW:0]   fifo_count;

            reg [1:0]         w_state;
            reg [ADDR_WIDTH-1:0] w_addr;
            reg [BUS_WIDTH-1:0]  w_data_buf;
            reg [1:0]         w_word_idx;
            reg               w_error_reg;

            reg [1:0]         r_state;
            reg [ADDR_WIDTH-1:0] r_addr;
            reg [BUS_WIDTH-1:0]  r_data_buf;
            reg [1:0]         r_word_idx;
            reg               r_valid_reg;
            reg [BUS_WIDTH-1:0] r_data_out;
            reg               r_error_reg;

            wire fifo_full  = (fifo_count == FIFO_DEPTH_COUNT);
            wire fifo_empty = (fifo_count == {FIFO_AW+1{1'b0}});
            wire fifo_push  = be_wr_valid && !fifo_full;
            wire fifo_pop   = (w_state == W_IDLE) && !fifo_empty;

            wire [ENTRY_W-1:0] fifo_dout = wr_fifo[fifo_rd_ptr];

            assign be_wr_ready       = !fifo_full;
            assign be_wr_almost_full = (fifo_count >= FIFO_ALMOST_FULL_COUNT);
            assign be_fifo_level     = fifo_count;

            always @(posedge clk) begin
                if (fifo_push)
                    wr_fifo[fifo_wr_ptr] <= {be_wr_addr, be_wr_data};
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    fifo_wr_ptr <= {FIFO_AW{1'b0}};
                    fifo_rd_ptr <= {FIFO_AW{1'b0}};
                    fifo_count  <= {FIFO_AW+1{1'b0}};
                end else if (i_clear || !i_enable) begin
                    fifo_wr_ptr <= {FIFO_AW{1'b0}};
                    fifo_rd_ptr <= {FIFO_AW{1'b0}};
                    fifo_count  <= {FIFO_AW+1{1'b0}};
                end else begin
                    case ({fifo_push, fifo_pop})
                        2'b10: begin
                            fifo_wr_ptr <= (fifo_wr_ptr == FIFO_LAST_PTR) ? {FIFO_AW{1'b0}} : fifo_wr_ptr + 1'b1;
                            fifo_count  <= fifo_count + 1'b1;
                        end
                        2'b01: begin
                            fifo_rd_ptr <= (fifo_rd_ptr == FIFO_LAST_PTR) ? {FIFO_AW{1'b0}} : fifo_rd_ptr + 1'b1;
                            fifo_count  <= fifo_count - 1'b1;
                        end
                        2'b11: begin
                            fifo_wr_ptr <= (fifo_wr_ptr == FIFO_LAST_PTR) ? {FIFO_AW{1'b0}} : fifo_wr_ptr + 1'b1;
                            fifo_rd_ptr <= (fifo_rd_ptr == FIFO_LAST_PTR) ? {FIFO_AW{1'b0}} : fifo_rd_ptr + 1'b1;
                        end
                        default: ;
                    endcase
                end
            end

            localparam AXI_SINGLE_BEAT = (AXI_BURST_BEATS == 1);

            wire [31:0] w_entry_byte_offset =
                {{(32-ADDR_WIDTH-4){1'b0}}, w_addr, 4'b0000};
            wire [31:0] w_word_byte_offset =
                AXI_SINGLE_BEAT ? {28'd0, w_word_idx, 2'b00} : 32'd0;
            wire [31:0] w_cur_word_data = w_data_buf[w_word_idx*32 +: 32];
            wire w_aw_fire = m_axi_awvalid && m_axi_awready;
            wire w_w_fire  = m_axi_wvalid && m_axi_wready;
            wire w_b_fire  = m_axi_bvalid && m_axi_bready;

            assign m_axi_awid    = 4'd0;
            assign m_axi_awaddr  = i_scratch_base_addr + w_entry_byte_offset +
                                    w_word_byte_offset;
            assign m_axi_awlen   = AXI_SINGLE_BEAT ? 8'd0 : 8'd3;
            assign m_axi_awsize  = 3'd2;
            assign m_axi_awburst = 2'b01;
            assign m_axi_awlock  = 1'b0;
            assign m_axi_awcache = 4'b0011;
            assign m_axi_awprot  = 3'b000;
            assign m_axi_awvalid = (w_state == W_AW);
            assign m_axi_wid     = 4'd0;
            assign m_axi_wdata   = w_cur_word_data;
            assign m_axi_wstrb   = 4'hf;
            assign m_axi_wlast   = AXI_SINGLE_BEAT ? 1'b1 : (w_word_idx == 2'd3);
            assign m_axi_wvalid  = (w_state == W_DATA);
            assign m_axi_bready  = (w_state == W_RESP);

            wire _unused_bid = ^m_axi_bid;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    w_state      <= W_IDLE;
                    w_addr       <= {ADDR_WIDTH{1'b0}};
                    w_data_buf   <= {BUS_WIDTH{1'b0}};
                    w_word_idx   <= 2'd0;
                    w_error_reg  <= 1'b0;
                end else if (i_clear || !i_enable) begin
                    w_state      <= W_IDLE;
                    w_word_idx   <= 2'd0;
                    w_error_reg  <= 1'b0;
                end else begin
                    case (w_state)
                        W_IDLE: begin
                            if (!fifo_empty) begin
                                w_addr       <= fifo_dout[ENTRY_W-1:BUS_WIDTH];
                                w_data_buf   <= fifo_dout[BUS_WIDTH-1:0];
                                w_word_idx   <= 2'd0;
                                w_state      <= W_AW;
                            end
                        end
                        W_AW: begin
                            if (w_aw_fire)
                                w_state <= W_DATA;
                        end
                        W_DATA: begin
                            if (w_w_fire) begin
                                if (AXI_SINGLE_BEAT) begin
                                    w_state <= W_RESP;
                                end else if (w_word_idx == 2'd3) begin
                                    w_state <= W_RESP;
                                end else begin
                                    w_word_idx <= w_word_idx + 2'd1;
                                end
                            end
                        end
                        W_RESP: begin
                            if (w_b_fire) begin
                                if (m_axi_bresp != 2'b00)
                                    w_error_reg <= 1'b1;
                                if (AXI_SINGLE_BEAT && (w_word_idx != 2'd3)) begin
                                    w_word_idx <= w_word_idx + 2'd1;
                                    w_state    <= W_AW;
                                end else begin
                                    w_state <= W_IDLE;
                                end
                            end
                        end
                        default: w_state <= W_IDLE;
                    endcase
                end
            end

            wire writes_idle = (w_state == W_IDLE) && fifo_empty;
            assign be_rd_ready = (r_state == R_IDLE) && writes_idle;

            wire [31:0] r_entry_byte_offset =
                {{(32-ADDR_WIDTH-4){1'b0}}, r_addr, 4'b0000};
            wire [31:0] r_word_byte_offset =
                AXI_SINGLE_BEAT ? {28'd0, r_word_idx, 2'b00} : 32'd0;
            wire r_ar_fire = m_axi_arvalid && m_axi_arready;
            wire r_r_fire  = m_axi_rvalid && m_axi_rready;

            assign m_axi_arid    = 4'd0;
            assign m_axi_araddr  = i_scratch_base_addr + r_entry_byte_offset +
                                    r_word_byte_offset;
            assign m_axi_arlen   = AXI_SINGLE_BEAT ? 8'd0 : 8'd3;
            assign m_axi_arsize  = 3'd2;
            assign m_axi_arburst = 2'b01;
            assign m_axi_arlock  = 1'b0;
            assign m_axi_arcache = 4'b0011;
            assign m_axi_arprot  = 3'b000;
            assign m_axi_arvalid = (r_state == R_AR);
            assign m_axi_rready  = (r_state == R_DATA);

            wire _unused_rid = ^m_axi_rid;

            assign be_rd_data  = r_data_out;
            assign be_rd_valid = r_valid_reg;
            assign be_busy     = !writes_idle || (r_state != R_IDLE);
            assign be_error    = w_error_reg || r_error_reg;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    r_state     <= R_IDLE;
                    r_addr      <= {ADDR_WIDTH{1'b0}};
                    r_data_buf  <= {BUS_WIDTH{1'b0}};
                    r_data_out  <= {BUS_WIDTH{1'b0}};
                    r_word_idx  <= 2'd0;
                    r_valid_reg <= 1'b0;
                    r_error_reg <= 1'b0;
                end else if (i_clear || !i_enable) begin
                    r_state     <= R_IDLE;
                    r_word_idx  <= 2'd0;
                    r_valid_reg <= 1'b0;
                    r_error_reg <= 1'b0;
                end else begin
                    r_valid_reg <= 1'b0;
                    case (r_state)
                        R_IDLE: begin
                            if (be_rd_req) begin
                                r_addr     <= be_rd_addr;
                                r_word_idx <= 2'd0;
                                r_data_buf <= {BUS_WIDTH{1'b0}};
                                r_state    <= R_AR;
                            end
                        end
                        R_AR: begin
                            if (r_ar_fire)
                                r_state <= R_DATA;
                        end
                        R_DATA: begin
                            if (r_r_fire) begin
                                if (m_axi_rresp != 2'b00 ||
                                    (AXI_SINGLE_BEAT && !m_axi_rlast) ||
                                    (!AXI_SINGLE_BEAT &&
                                     ((m_axi_rlast && (r_word_idx != 2'd3)) ||
                                      (!m_axi_rlast && (r_word_idx == 2'd3)))))
                                    r_error_reg <= 1'b1;
                                r_data_buf[r_word_idx*32 +: 32] <= m_axi_rdata;
                                if (r_word_idx == 2'd3) begin
                                    r_data_out <= {m_axi_rdata, r_data_buf[95:0]};
                                    r_valid_reg <= 1'b1;
                                    r_state <= R_IDLE;
                                end else if (AXI_SINGLE_BEAT) begin
                                    r_word_idx <= r_word_idx + 2'd1;
                                    r_state <= R_AR;
                                end else begin
                                    r_word_idx <= r_word_idx + 2'd1;
                                end
                            end
                        end
                        default: r_state <= R_IDLE;
                    endcase
                end
            end

`ifdef NPU_POOL_REORDER_TRACE
            reg trace_replay_active_d1;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    trace_replay_active_d1 <= 1'b0;
                end else begin
                    if (w_cap_fire && r_cap_cnt == 16'd0) begin
                        $display("[POOL_REORDER] t=%0t capture_start size=%0dx%0d total=%0d use_axi=%0d base=%08h",
                                 $time, i_width, i_height, w_cap_total, USE_AXI, i_scratch_base_addr);
                    end
                    if (w_cap_last) begin
                        $display("[POOL_REORDER] t=%0t capture_done total=%0d busy=%0b",
                                 $time, w_cap_total, be_busy);
                    end
                    if (r_replay_active && !trace_replay_active_d1) begin
                        $display("[POOL_REORDER] t=%0t replay_start total=%0d",
                                 $time, w_cap_total);
                    end
                    if (be_rd_valid && w_replay_last) begin
                        $display("[POOL_REORDER] t=%0t replay_done total=%0d error=%0b",
                                 $time, w_cap_total, o_error);
                    end
                    if (be_error) begin
                        $display("[POOL_REORDER] t=%0t backend_error", $time);
                    end
                    trace_replay_active_d1 <= r_replay_active;
                end
            end
`endif
        end else begin : gen_bram_backend
`ifdef NPU_USE_XPM_BRAM
            wire [BUS_WIDTH-1:0] bram_rdata;
`else
            (* ram_style = "block" *) reg [BUS_WIDTH-1:0] bram_mem [0:MEMORY_DEPTH-1];
            reg [BUS_WIDTH-1:0] bram_rdata;
`endif
            reg bram_rd_valid;

            assign be_wr_ready       = 1'b1;
            assign be_wr_almost_full = 1'b0;
            assign be_rd_ready       = 1'b1;
            assign be_rd_data        = bram_rdata;
            assign be_rd_valid       = bram_rd_valid;
            assign be_busy           = 1'b0;
            assign be_error          = 1'b0;
            assign be_fifo_level     = 16'd0;

`ifdef NPU_USE_XPM_BRAM
            npu_xilinx_sdpram #(
                .DATA_WIDTH  (BUS_WIDTH),
                .ADDR_WIDTH  (ADDR_WIDTH),
                .MEMORY_DEPTH(MEMORY_DEPTH)
            ) u_pool_reorder_bram (
                .clk     (clk),
                .wr_en   (be_wr_valid),
                .wr_strb (1'b1),
                .wr_addr (be_wr_addr),
                .wr_data (be_wr_data),
                .rd_en   (be_rd_req),
                .rd_addr (be_rd_addr),
                .rd_data (bram_rdata)
            );
`else
            always @(posedge clk) begin
                if (be_wr_valid)
                    bram_mem[be_wr_addr] <= be_wr_data;
                if (be_rd_req)
                    bram_rdata <= bram_mem[be_rd_addr];
            end
`endif

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    bram_rd_valid <= 1'b0;
                else
                    bram_rd_valid <= be_rd_req;
            end

            assign m_axi_arid    = 4'd0;
            assign m_axi_araddr  = 32'd0;
            assign m_axi_arlen   = 8'd0;
            assign m_axi_arsize  = 3'd0;
            assign m_axi_arburst = 2'd0;
            assign m_axi_arlock  = 1'b0;
            assign m_axi_arcache = 4'd0;
            assign m_axi_arprot  = 3'd0;
            assign m_axi_arvalid = 1'b0;
            assign m_axi_rready  = 1'b1;
            assign m_axi_awid    = 4'd0;
            assign m_axi_awaddr  = 32'd0;
            assign m_axi_awlen   = 8'd0;
            assign m_axi_awsize  = 3'd0;
            assign m_axi_awburst = 2'd0;
            assign m_axi_awlock  = 1'b0;
            assign m_axi_awcache = 4'd0;
            assign m_axi_awprot  = 3'd0;
            assign m_axi_awvalid = 1'b0;
            assign m_axi_wid     = 4'd0;
            assign m_axi_wdata   = 32'd0;
            assign m_axi_wstrb   = 4'd0;
            assign m_axi_wlast   = 1'b0;
            assign m_axi_wvalid  = 1'b0;
            assign m_axi_bready  = 1'b1;

            wire _unused_axi_inputs = m_axi_arready ^ m_axi_rid[0] ^
                                      m_axi_rdata[0] ^ m_axi_rresp[0] ^
                                      m_axi_rlast ^ m_axi_rvalid ^
                                      m_axi_awready ^ m_axi_wready ^
                                      m_axi_bid[0] ^ m_axi_bresp[0] ^
                                      m_axi_bvalid;
        end
    endgenerate

endmodule
