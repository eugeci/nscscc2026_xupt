`timescale 1ns / 1ps

// Read one 800x480 RGB565 frame from DDR using aligned 64-beat AXI bursts.
// The frame is 768000 bytes = 192000 32-bit words = exactly 3000 bursts.
module lcd_axi_frame_reader #(
    parameter integer WORD_COUNT  = 192000,
    parameter integer BURST_WORDS = 64
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire [31:0] frame_addr,

    output reg         busy,
    output reg         done,
    output reg         error,

    output reg  [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arcache,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,

    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output wire        fifo_wr_en,
    output wire [31:0] fifo_wr_data,
    input  wire        fifo_full
);

localparam [1:0] ST_IDLE  = 2'd0,
                 ST_ADDR  = 2'd1,
                 ST_DATA  = 2'd2;

reg [1:0]  state;
reg [31:0] words_remaining;

assign m_axi_arlen   = BURST_WORDS - 1;
assign m_axi_arsize  = 3'd2;
assign m_axi_arburst = 2'b01;
assign m_axi_arprot  = 3'b000;
assign m_axi_arcache = 4'b0011;

assign m_axi_rready = (state == ST_DATA) && !fifo_full;
assign fifo_wr_en    = m_axi_rvalid && m_axi_rready;
assign fifo_wr_data  = m_axi_rdata;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state           <= ST_IDLE;
        words_remaining <= 32'd0;
        m_axi_araddr    <= 32'd0;
        m_axi_arvalid   <= 1'b0;
        busy            <= 1'b0;
        done            <= 1'b0;
        error           <= 1'b0;
    end else begin
        done <= 1'b0;

        case (state)
            ST_IDLE: begin
                m_axi_arvalid <= 1'b0;
                busy          <= 1'b0;
                if (start) begin
                    m_axi_araddr    <= frame_addr;
                    words_remaining <= WORD_COUNT;
                    m_axi_arvalid   <= 1'b1;
                    busy            <= 1'b1;
                    error           <= 1'b0;
                    state           <= ST_ADDR;
                end
            end

            ST_ADDR: begin
                busy <= 1'b1;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    state         <= ST_DATA;
                end
            end

            ST_DATA: begin
                busy <= 1'b1;
                if (m_axi_rvalid && m_axi_rready) begin
                    if (m_axi_rresp != 2'b00)
                        error <= 1'b1;
                    words_remaining <= words_remaining - 32'd1;

                    if (words_remaining == 32'd1) begin
                        if (!m_axi_rlast)
                            error <= 1'b1;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end else if (m_axi_rlast) begin
                        m_axi_araddr  <= m_axi_araddr + BURST_WORDS * 4;
                        m_axi_arvalid <= 1'b1;
                        state         <= ST_ADDR;
                    end
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
