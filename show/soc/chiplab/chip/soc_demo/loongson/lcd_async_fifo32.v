`timescale 1ns / 1ps

// Small dual-clock FIFO used between the DDR AXI clock and the LCD clock.
// Storage is 32 bits wide because each DDR beat contains two RGB565 pixels.
module lcd_async_fifo32 #(
    parameter integer ADDR_BITS = 9
)(
    input  wire        wr_clk,
    input  wire        wr_resetn,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        wr_full,

    input  wire        rd_clk,
    input  wire        rd_resetn,
    input  wire        rd_en,
    output reg  [31:0] rd_data,
    output reg         rd_valid,
    output wire        rd_empty
);

localparam integer PTR_BITS = ADDR_BITS + 1;

(* ram_style = "block" *) reg [31:0] memory [0:(1 << ADDR_BITS)-1];

reg [PTR_BITS-1:0] wr_bin;
reg [PTR_BITS-1:0] wr_gray;
reg [PTR_BITS-1:0] rd_bin;
reg [PTR_BITS-1:0] rd_gray;
reg                wr_full_reg;

(* ASYNC_REG = "TRUE" *) reg [PTR_BITS-1:0] rd_gray_wr_meta;
(* ASYNC_REG = "TRUE" *) reg [PTR_BITS-1:0] rd_gray_wr_sync;
(* ASYNC_REG = "TRUE" *) reg [PTR_BITS-1:0] wr_gray_rd_meta;
(* ASYNC_REG = "TRUE" *) reg [PTR_BITS-1:0] wr_gray_rd_sync;

wire wr_push = wr_en && !wr_full;
wire rd_pop  = rd_en && !rd_empty;

wire [PTR_BITS-1:0] wr_bin_next  = wr_bin + wr_push;
wire [PTR_BITS-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
wire [PTR_BITS-1:0] rd_bin_next  = rd_bin + rd_pop;
wire [PTR_BITS-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

// Full when the next write pointer equals the read pointer with both wrap
// bits inverted. PTR_BITS is at least three for every supported instance.
wire [PTR_BITS-1:0] rd_gray_full_compare =
    {~rd_gray_wr_sync[PTR_BITS-1:PTR_BITS-2],
      rd_gray_wr_sync[PTR_BITS-3:0]};

assign wr_full  = wr_full_reg;
assign rd_empty = (rd_gray == wr_gray_rd_sync);

always @(posedge wr_clk or negedge wr_resetn) begin
    if (!wr_resetn) begin
        wr_bin          <= {PTR_BITS{1'b0}};
        wr_gray         <= {PTR_BITS{1'b0}};
        wr_full_reg     <= 1'b0;
        rd_gray_wr_meta <= {PTR_BITS{1'b0}};
        rd_gray_wr_sync <= {PTR_BITS{1'b0}};
    end else begin
        rd_gray_wr_meta <= rd_gray;
        rd_gray_wr_sync <= rd_gray_wr_meta;
        wr_full_reg     <= (wr_gray_next == rd_gray_full_compare);
        if (wr_push) begin
            memory[wr_bin[ADDR_BITS-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
        end
    end
end

always @(posedge rd_clk or negedge rd_resetn) begin
    if (!rd_resetn) begin
        rd_bin          <= {PTR_BITS{1'b0}};
        rd_gray         <= {PTR_BITS{1'b0}};
        wr_gray_rd_meta <= {PTR_BITS{1'b0}};
        wr_gray_rd_sync <= {PTR_BITS{1'b0}};
        rd_valid        <= 1'b0;
    end else begin
        wr_gray_rd_meta <= wr_gray;
        wr_gray_rd_sync <= wr_gray_rd_meta;
        rd_valid        <= rd_pop;
        if (rd_pop) begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
        end
    end
end

// Keep the memory read outside the asynchronous-reset process so Vivado can
// infer a true dual-clock block RAM instead of a large LUT/FF mux tree.
always @(posedge rd_clk) begin
    if (rd_pop)
        rd_data <= memory[rd_bin[ADDR_BITS-1:0]];
end

endmodule
