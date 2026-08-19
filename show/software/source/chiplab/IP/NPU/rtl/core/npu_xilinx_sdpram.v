// -----------------------------------------------------------------------------
// Module      : npu_xilinx_sdpram
// Description : Simple dual-port RAM wrapper used to force Xilinx block RAM
//               mapping in Vivado while keeping a simulator-friendly fallback.
//
// Port A: write-only. Port B: read-only, one-cycle synchronous read.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "npu_math_defs.vh"

module npu_xilinx_sdpram #(
    parameter DATA_WIDTH       = 32,
    parameter ADDR_WIDTH       = 10,
    parameter MEMORY_DEPTH     = 1024,
    parameter BYTE_WRITE_WIDTH = DATA_WIDTH,
    parameter READ_LATENCY     = 1
) (
    input  wire                                      clk,
    input  wire                                      wr_en,
    input  wire [(DATA_WIDTH/BYTE_WRITE_WIDTH)-1:0] wr_strb,
    input  wire [ADDR_WIDTH-1:0]                    wr_addr,
    input  wire [DATA_WIDTH-1:0]                    wr_data,
    input  wire                                      rd_en,
    input  wire [ADDR_WIDTH-1:0]                    rd_addr,
    output wire [DATA_WIDTH-1:0]                    rd_data
);

    localparam WRITE_STROBES = DATA_WIDTH / BYTE_WRITE_WIDTH;

`ifdef NPU_USE_XPM_BRAM
    localparam USE_18K_BRAM    = (DATA_WIDTH <= 8);
    localparam RAM_WIDTH       = (DATA_WIDTH <= 8) ? 8 : 32;
    localparam RAM_ADDR_WIDTH  = USE_18K_BRAM      ? 11 :
                                 (RAM_WIDTH <= 9)  ? 12 :
                                 (RAM_WIDTH <= 18) ? 11 :
                                 (RAM_WIDTH <= 36) ? 10 : 9;
    localparam RAM_DEPTH       = (1 << RAM_ADDR_WIDTH);
    localparam RAM_WE_WIDTH    = (RAM_WIDTH <= 9)  ? 1 :
                                 (RAM_WIDTH <= 18) ? 2 :
                                 (RAM_WIDTH <= 36) ? 4 : 8;
    localparam RAM_BYTES       = RAM_WE_WIDTH;
    localparam WIDTH_BANKS     = (DATA_WIDTH + RAM_WIDTH - 1) / RAM_WIDTH;
    localparam DEPTH_BANKS     = (MEMORY_DEPTH + RAM_DEPTH - 1) / RAM_DEPTH;
    localparam DEPTH_SEL_WIDTH = (DEPTH_BANKS <= 1) ? 1 : `NPU_CLOG2(DEPTH_BANKS);
    localparam PADDED_WIDTH    = WIDTH_BANKS * RAM_WIDTH;

    wire [ADDR_WIDTH+RAM_ADDR_WIDTH-1:0] wr_addr_ext = {{RAM_ADDR_WIDTH{1'b0}}, wr_addr};
    wire [ADDR_WIDTH+RAM_ADDR_WIDTH-1:0] rd_addr_ext = {{RAM_ADDR_WIDTH{1'b0}}, rd_addr};
    wire [RAM_ADDR_WIDTH-1:0] wr_bank_addr = wr_addr_ext[RAM_ADDR_WIDTH-1:0];
    wire [RAM_ADDR_WIDTH-1:0] rd_bank_addr = rd_addr_ext[RAM_ADDR_WIDTH-1:0];

    wire [ADDR_WIDTH+RAM_ADDR_WIDTH+DEPTH_SEL_WIDTH-1:0] wr_depth_ext =
        {{(RAM_ADDR_WIDTH+DEPTH_SEL_WIDTH){1'b0}}, wr_addr};
    wire [ADDR_WIDTH+RAM_ADDR_WIDTH+DEPTH_SEL_WIDTH-1:0] rd_depth_ext =
        {{(RAM_ADDR_WIDTH+DEPTH_SEL_WIDTH){1'b0}}, rd_addr};
    wire [DEPTH_SEL_WIDTH-1:0] wr_depth_sel =
        wr_depth_ext[RAM_ADDR_WIDTH +: DEPTH_SEL_WIDTH];
    wire [DEPTH_SEL_WIDTH-1:0] rd_depth_sel =
        rd_depth_ext[RAM_ADDR_WIDTH +: DEPTH_SEL_WIDTH];

    reg [DEPTH_SEL_WIDTH-1:0] rd_depth_sel_d1;
    always @(posedge clk) begin
        if (rd_en) begin
            rd_depth_sel_d1 <= rd_depth_sel;
        end
    end

    wire [PADDED_WIDTH-1:0] wr_data_padded;
    generate
        if (PADDED_WIDTH == DATA_WIDTH) begin : gen_no_data_pad
            assign wr_data_padded = wr_data;
        end else begin : gen_data_pad
            assign wr_data_padded = {{(PADDED_WIDTH-DATA_WIDTH){1'b0}}, wr_data};
        end
    endgenerate

    wire [WIDTH_BANKS*DEPTH_BANKS*RAM_WIDTH-1:0] bank_rdata_flat;

    genvar wb;
    genvar db;
    generate
        for (wb = 0; wb < WIDTH_BANKS; wb = wb + 1) begin : gen_width_bank
            for (db = 0; db < DEPTH_BANKS; db = db + 1) begin : gen_depth_bank
                localparam integer BANK_RDATA_LSB = ((wb * DEPTH_BANKS) + db) * RAM_WIDTH;
                localparam [DEPTH_SEL_WIDTH-1:0] BANK_SEL = db;

                wire bank_wren = wr_en && (wr_depth_sel == BANK_SEL);
                wire bank_rden = rd_en && (rd_depth_sel == BANK_SEL);
                wire [RAM_WE_WIDTH-1:0] macro_we_raw;
                wire [RAM_WE_WIDTH-1:0] macro_we = {RAM_WE_WIDTH{bank_wren}} & macro_we_raw;
                wire [RAM_WIDTH-1:0] macro_rdata;

                if (BYTE_WRITE_WIDTH == 8) begin : gen_byte_we
                    assign macro_we_raw =
                        wr_strb[(wb*RAM_BYTES) +: RAM_BYTES];
                end else begin : gen_word_we
                    assign macro_we_raw = {RAM_WE_WIDTH{wr_strb[0]}};
                end

                if (USE_18K_BRAM) begin : gen_ramb18
                    BRAM_SDP_MACRO #(
                        .BRAM_SIZE ("18Kb"),
                        .DEVICE    ("7SERIES"),
                        .DO_REG    (0),
                        .READ_WIDTH(RAM_WIDTH),
                        .WRITE_MODE("READ_FIRST"),
                        .WRITE_WIDTH(RAM_WIDTH)
                    ) u_bram (
                        .DO    (macro_rdata),
                        .DI    (wr_data_padded[(wb*RAM_WIDTH) +: RAM_WIDTH]),
                        .RDADDR(rd_bank_addr),
                        .RDCLK (clk),
                        .RDEN  (bank_rden),
                        .REGCE (1'b1),
                        .RST   (1'b0),
                        .WE    (macro_we),
                        .WRADDR(wr_bank_addr),
                        .WRCLK (clk),
                        .WREN  (bank_wren)
                    );
                end else begin : gen_ramb36
                    BRAM_SDP_MACRO #(
                        .BRAM_SIZE ("36Kb"),
                        .DEVICE    ("7SERIES"),
                        .DO_REG    (0),
                        .READ_WIDTH(RAM_WIDTH),
                        .WRITE_MODE("READ_FIRST"),
                        .WRITE_WIDTH(RAM_WIDTH)
                    ) u_bram (
                        .DO    (macro_rdata),
                        .DI    (wr_data_padded[(wb*RAM_WIDTH) +: RAM_WIDTH]),
                        .RDADDR(rd_bank_addr),
                        .RDCLK (clk),
                        .RDEN  (bank_rden),
                        .REGCE (1'b1),
                        .RST   (1'b0),
                        .WE    (macro_we),
                        .WRADDR(wr_bank_addr),
                        .WRCLK (clk),
                        .WREN  (bank_wren)
                    );
                end

                assign bank_rdata_flat[BANK_RDATA_LSB +: RAM_WIDTH] = macro_rdata;
            end
        end
    endgenerate

    reg [PADDED_WIDTH-1:0] rd_data_mux;
    integer mux_w;
    always @(*) begin
        rd_data_mux = {PADDED_WIDTH{1'b0}};
        for (mux_w = 0; mux_w < WIDTH_BANKS; mux_w = mux_w + 1) begin
            rd_data_mux[(mux_w*RAM_WIDTH) +: RAM_WIDTH] =
                bank_rdata_flat[(((mux_w*DEPTH_BANKS) + rd_depth_sel_d1) * RAM_WIDTH) +: RAM_WIDTH];
        end
    end

    assign rd_data = rd_data_mux[DATA_WIDTH-1:0];
`else
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:MEMORY_DEPTH-1];
    reg [DATA_WIDTH-1:0] rd_data_r;
    integer byte_i;

    always @(posedge clk) begin
        if (wr_en) begin
            for (byte_i = 0; byte_i < WRITE_STROBES; byte_i = byte_i + 1) begin
                if (wr_strb[byte_i]) begin
                    mem[wr_addr][byte_i*BYTE_WRITE_WIDTH +: BYTE_WRITE_WIDTH]
                        <= wr_data[byte_i*BYTE_WRITE_WIDTH +: BYTE_WRITE_WIDTH];
                end
            end
        end

        if (rd_en) begin
            rd_data_r <= mem[rd_addr];
        end
    end

    assign rd_data = rd_data_r;
`endif

endmodule
