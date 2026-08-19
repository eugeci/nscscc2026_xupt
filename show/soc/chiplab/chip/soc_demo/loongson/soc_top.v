/*------------------------------------------------------------------------------
--------------------------------------------------------------------------------
Copyright (c) 2016, Loongson Technology Corporation Limited.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this 
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, 
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of Loongson Technology Corporation Limited nor the names of 
its contributors may be used to endorse or promote products derived from this 
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
DISCLAIMED. IN NO EVENT SHALL LOONGSON TECHNOLOGY CORPORATION LIMITED BE LIABLE
TO ANY PARTY FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------
------------------------------------------------------------------------------*/

`include "config.h"

// Preserve both level interrupts and short source-clock-domain interrupt
// events while crossing into the independently clocked CPU. A plain two-flop
// synchronizer is sufficient for UART/SPI/MAC/NPU levels, but it can entirely
// miss DMA (and some NAND completion) pulses that are shorter than one CPU
// period. The source-domain rising edge toggles a bit; the synchronized toggle
// produces one full destination-clock pulse, while the parallel level path
// retains normal level-sensitive interrupt behavior.
module peripheral_irq_cdc #(
    parameter integer WIDTH = 1
) (
    input  wire             src_clk,
    input  wire             dst_clk,
    input  wire             resetn,
    input  wire [WIDTH-1:0] irq_src,
    output wire [WIDTH-1:0] irq_dst
);
    reg [WIDTH-1:0] irq_src_d;
    reg [WIDTH-1:0] event_toggle_src;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [WIDTH-1:0] level_meta_dst;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [WIDTH-1:0] level_sync_dst;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [WIDTH-1:0] event_meta_dst;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [WIDTH-1:0] event_sync_dst;
    reg [WIDTH-1:0] event_seen_dst;

    always @(posedge src_clk or negedge resetn) begin
        if (!resetn) begin
            irq_src_d       <= {WIDTH{1'b0}};
            event_toggle_src <= {WIDTH{1'b0}};
        end else begin
            irq_src_d <= irq_src;
            event_toggle_src <= event_toggle_src
                              ^ (irq_src & ~irq_src_d);
        end
    end

    always @(posedge dst_clk or negedge resetn) begin
        if (!resetn) begin
            level_meta_dst <= {WIDTH{1'b0}};
            level_sync_dst <= {WIDTH{1'b0}};
            event_meta_dst <= {WIDTH{1'b0}};
            event_sync_dst <= {WIDTH{1'b0}};
            event_seen_dst <= {WIDTH{1'b0}};
        end else begin
            level_meta_dst <= irq_src;
            level_sync_dst <= level_meta_dst;
            event_meta_dst <= event_toggle_src;
            event_sync_dst <= event_meta_dst;
            event_seen_dst <= event_sync_dst;
        end
    end

    assign irq_dst = level_sync_dst | (event_sync_dst ^ event_seen_dst);
endmodule

module soc_top(
    input         resetn, 
    input         clk,

    //------gpio----------------
    output [15:0] led,
    output [1 :0] led_rg0,
    output [1 :0] led_rg1,
    output [7 :0] num_csn,
    output [6 :0] num_a_g,
    input  [7 :0] switch, 
    output [3 :0] btn_key_col,
    input  [3 :0] btn_key_row,
    input  [1 :0] btn_step,

    //------DDR3 interface------
    inout  [15:0] ddr3_dq,
    output [12:0] ddr3_addr,
    output [2 :0] ddr3_ba,
    output        ddr3_ras_n,
    output        ddr3_cas_n,
    output        ddr3_we_n,
    output        ddr3_odt,
    output        ddr3_reset_n,
    output        ddr3_cke,
    output [1:0]  ddr3_dm,
    inout  [1:0]  ddr3_dqs_p,
    inout  [1:0]  ddr3_dqs_n,
    output        ddr3_ck_p,
    output        ddr3_ck_n,

    //------mac controller-------
    //TX
    input         mtxclk_0,     
    output        mtxen_0,      
    output [3:0]  mtxd_0,       
    output        mtxerr_0,
    //RX
    input         mrxclk_0,      
    input         mrxdv_0,     
    input  [3:0]  mrxd_0,        
    input         mrxerr_0,
    input         mcoll_0,
    input         mcrs_0,
    // MIIM
    output        mdc_0,
    inout         mdio_0,
    
    output        phy_rstn,
 
    //------EJTAG-------
    input         EJTAG_TRST,
    input         EJTAG_TCK,
    input         EJTAG_TDI,
    input         EJTAG_TMS,
    output        EJTAG_TDO,

    //------uart-------
    inout         UART_RX,
    inout         UART_TX,

    //------debug-uart------
    input         UART_RX2,
    output        UART_TX2,

    //------nand-------
    output        NAND_CLE ,
    output        NAND_ALE ,
    input         NAND_RDY ,
    inout [7:0]   NAND_DATA,
    output        NAND_RD  ,
    output        NAND_CE  ,  //low active
    output        NAND_WR  ,  
       
    //------spi flash-------
    output        SPI_CLK,
    output        SPI_CS,
    inout         SPI_MISO,
    inout         SPI_MOSI,

    //------VGA output-------
    output [3:0]  vga_r,
    output [3:0]  vga_g,
    output [3:0]  vga_b,
    output        vga_hsync,
    output        vga_vsync,

    //------OV5640 camera------
    input  [7:0]  cam_d,
    input         cam_pclk,
    input         cam_vsync,
    input         cam_href,
    inout         cam_scl,
    inout         cam_sda,
    output        cam_rst_n,
    output        cam_pwdn,

    //------ALIENTEK 4.3-inch NT35510 LCD------
    output [15:0] LCD_DB,
    output        LCD_CS_N,
    output        LCD_RS,
    output        LCD_WR_N,
    output        LCD_RD_N,
    output        LCD_RST_N,
    output        LCD_BL,

    //------mechanical arm UART------
    output        ARM_UART_TX
);

// The selected MMU core has no EJTAG slave.  Drive the unused board output
// deterministically instead of leaving a top-level pin floating.
assign EJTAG_TDO = 1'b0;
wire        aclk;
wire        aresetn;
wire        cpu_clk;
wire        uncore_clk;

// Keep the camera powered up, then release its active-low reset after about
// 10 ms (the board input clock is 100 MHz).
reg  [19:0] cam_reset_count;
reg         cam_reset_release;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        cam_reset_count   <= 20'd0;
        cam_reset_release <= 1'b0;
    end
    else if (!cam_reset_release) begin
        if (&cam_reset_count)
            cam_reset_release <= 1'b1;
        else
            cam_reset_count <= cam_reset_count + 20'd1;
    end
end

assign cam_pwdn = 1'b0;
assign cam_rst_n = cam_reset_release;

// LCD_STAGE2_DDR_NT35510
// The complete LCD engine is instantiated beside the camera VDMA so its DDR
// reader can safely share the existing S04 read port.  SW18/SW19 remain the
// hardware recovery-pattern selector when Linux software_mode is zero.

// Read the OV5640 ID, then configure stable DVP 320x240 RGB565.  The camera
// stream is scaled to the 640x480 DDR/VGA frame format downstream. Failed ID
// reads and register writes are retried automatically.
wire       sccb_busy;
wire       sccb_done;
wire       sccb_ack_error;
wire [7:0] sccb_read_data;
reg        sccb_start;
reg        sccb_write;
reg [15:0] sccb_reg_addr;
reg [7:0]  sccb_write_data;
reg [21:0] sccb_wait_count;
reg [3:0]  sccb_state;
reg [7:0]  cam_id_high;
reg [7:0]  cam_id_low;
reg        cam_id_high_ack;
reg        cam_id_low_ack;
reg        cam_id_ack_ok;
reg        cam_id_ok;
reg [8:0]  cam_init_index;
reg        cam_init_done;
reg        cam_init_error;

wire [23:0] cam_init_value;
wire        cam_init_valid;
wire        cam_init_last;
wire        cam_init_delay_5ms;

localparam [3:0] CAM_ID_WAIT         = 4'd0,
                 CAM_ID_START_HIGH   = 4'd1,
                 CAM_ID_WAIT_HIGH    = 4'd2,
                 CAM_ID_START_LOW    = 4'd3,
                 CAM_ID_WAIT_LOW     = 4'd4,
                 CAM_ID_CHECK        = 4'd5,
                 CAM_ID_RETRY_WAIT   = 4'd6,
                 CAM_INIT_START      = 4'd7,
                 CAM_INIT_WAIT       = 4'd8,
                 CAM_INIT_DELAY      = 4'd9,
                 CAM_INIT_RETRY_WAIT = 4'd10,
                 CAM_INIT_HOLD       = 4'd11;

ov5640_init_rom u_ov5640_init_rom (
    .index     (cam_init_index),
    .test_pattern_enable(1'b0),
    .value     (cam_init_value),
    .valid     (cam_init_valid),
    .last      (cam_init_last),
    .delay_5ms (cam_init_delay_5ms)
);

ov5640_sccb_master #(
    .CLK_HZ  (100000000),
    .SCCB_HZ (100000)
) u_ov5640_sccb_master (
    .clk       (clk),
    .resetn    (cam_reset_release),
    .start     (sccb_start),
    .write     (sccb_write),
    .reg_addr  (sccb_reg_addr),
    .write_data(sccb_write_data),
    .read_data (sccb_read_data),
    .busy      (sccb_busy),
    .done      (sccb_done),
    .ack_error (sccb_ack_error),
    .scl       (cam_scl),
    .sda       (cam_sda)
);

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        sccb_start         <= 1'b0;
        sccb_write         <= 1'b0;
        sccb_reg_addr      <= 16'd0;
        sccb_write_data    <= 8'd0;
        sccb_wait_count    <= 22'd0;
        sccb_state         <= CAM_ID_WAIT;
        cam_id_high        <= 8'd0;
        cam_id_low         <= 8'd0;
        cam_id_high_ack    <= 1'b0;
        cam_id_low_ack     <= 1'b0;
        cam_id_ack_ok      <= 1'b0;
        cam_id_ok          <= 1'b0;
        cam_init_index     <= 9'd0;
        cam_init_done      <= 1'b0;
        cam_init_error     <= 1'b0;
    end
    else if (!cam_reset_release) begin
        sccb_start         <= 1'b0;
        sccb_write         <= 1'b0;
        sccb_reg_addr      <= 16'd0;
        sccb_write_data    <= 8'd0;
        sccb_wait_count    <= 22'd0;
        sccb_state         <= CAM_ID_WAIT;
        cam_id_high        <= 8'd0;
        cam_id_low         <= 8'd0;
        cam_id_high_ack    <= 1'b0;
        cam_id_low_ack     <= 1'b0;
        cam_id_ack_ok      <= 1'b0;
        cam_id_ok          <= 1'b0;
        cam_init_index     <= 9'd0;
        cam_init_done      <= 1'b0;
        cam_init_error     <= 1'b0;
    end
    else begin
        sccb_start <= 1'b0;
        case (sccb_state)
            CAM_ID_WAIT: begin
                if (sccb_wait_count == 22'd2000000) begin
                    sccb_wait_count <= 22'd0;
                    sccb_state <= CAM_ID_START_HIGH;
                end
                else
                    sccb_wait_count <= sccb_wait_count + 22'd1;
            end

            CAM_ID_START_HIGH: begin
                if (!sccb_busy) begin
                    sccb_write <= 1'b0;
                    sccb_reg_addr <= 16'h300a;
                    sccb_start <= 1'b1;
                    sccb_state <= CAM_ID_WAIT_HIGH;
                end
            end

            CAM_ID_WAIT_HIGH: begin
                if (sccb_done) begin
                    cam_id_high <= sccb_read_data;
                    cam_id_high_ack <= ~sccb_ack_error;
                    sccb_state <= CAM_ID_START_LOW;
                end
            end

            CAM_ID_START_LOW: begin
                if (!sccb_busy) begin
                    sccb_write <= 1'b0;
                    sccb_reg_addr <= 16'h300b;
                    sccb_start <= 1'b1;
                    sccb_state <= CAM_ID_WAIT_LOW;
                end
            end

            CAM_ID_WAIT_LOW: begin
                if (sccb_done) begin
                    cam_id_low <= sccb_read_data;
                    cam_id_low_ack <= ~sccb_ack_error;
                    sccb_state <= CAM_ID_CHECK;
                end
            end

            CAM_ID_CHECK: begin
                cam_id_ack_ok <= cam_id_high_ack & cam_id_low_ack;
                if (cam_id_high_ack && cam_id_low_ack &&
                    (cam_id_high == 8'h56) && (cam_id_low == 8'h40)) begin
                    cam_id_ok <= 1'b1;
                    cam_init_index <= 9'd0;
                    sccb_state <= CAM_INIT_START;
                end
                else begin
                    sccb_wait_count <= 22'd0;
                    sccb_state <= CAM_ID_RETRY_WAIT;
                end
            end

            CAM_ID_RETRY_WAIT: begin
                if (sccb_wait_count == 22'd1000000) begin
                    sccb_wait_count <= 22'd0;
                    sccb_state <= CAM_ID_START_HIGH;
                end
                else
                    sccb_wait_count <= sccb_wait_count + 22'd1;
            end

            CAM_INIT_START: begin
                if (!sccb_busy && cam_init_valid) begin
                    sccb_write <= 1'b1;
                    sccb_reg_addr <= cam_init_value[23:8];
                    sccb_write_data <= cam_init_value[7:0];
                    sccb_start <= 1'b1;
                    sccb_state <= CAM_INIT_WAIT;
                end
            end

            CAM_INIT_WAIT: begin
                if (sccb_done) begin
                    if (sccb_ack_error) begin
                        cam_init_error <= 1'b1;
                        sccb_wait_count <= 22'd0;
                        sccb_state <= CAM_INIT_RETRY_WAIT;
                    end
                    else if (cam_init_last) begin
                        cam_init_done <= 1'b1;
                        sccb_state <= CAM_INIT_HOLD;
                    end
                    else begin
                        cam_init_index <= cam_init_index + 9'd1;
                        if (cam_init_delay_5ms) begin
                            sccb_wait_count <= 22'd0;
                            sccb_state <= CAM_INIT_DELAY;
                        end
                        else
                            sccb_state <= CAM_INIT_START;
                    end
                end
            end

            CAM_INIT_DELAY: begin
                if (sccb_wait_count == 22'd500000) begin
                    sccb_wait_count <= 22'd0;
                    sccb_state <= CAM_INIT_START;
                end
                else
                    sccb_wait_count <= sccb_wait_count + 22'd1;
            end

            CAM_INIT_RETRY_WAIT: begin
                if (sccb_wait_count == 22'd100000) begin
                    sccb_wait_count <= 22'd0;
                    sccb_state <= CAM_INIT_START;
                end
                else
                    sccb_wait_count <= sccb_wait_count + 22'd1;
            end

            default: sccb_state <= CAM_INIT_HOLD;
        endcase
    end
end

// Camera-link activity indicators latch after each signal has been observed.
reg [23:0] cam_pclk_count;
reg        cam_pclk_seen;
reg        cam_vsync_seen;
reg        cam_href_seen;

always @(posedge cam_pclk or negedge cam_reset_release) begin
    if (!cam_reset_release) begin
        cam_pclk_count <= 24'd0;
        cam_pclk_seen  <= 1'b0;
        cam_vsync_seen <= 1'b0;
        cam_href_seen  <= 1'b0;
    end
    else begin
        cam_pclk_count <= cam_pclk_count + 24'd1;
        cam_pclk_seen  <= 1'b1;
        cam_vsync_seen <= cam_vsync_seen | cam_vsync;
        cam_href_seen  <= cam_href_seen  | cam_href;
    end
end

wire [15:0] soc_led;
wire        cam_frame_ready;

wire [`LID         -1 :0] m0_awid;
wire [`Lawaddr     -1 :0] m0_awaddr;
wire [`Lawlen      -1 :0] m0_awlen;
wire [7:0]                 cpu_awlen;
wire [`Lawsize     -1 :0] m0_awsize;
wire [`Lawburst    -1 :0] m0_awburst;
wire [`Lawlock     -1 :0] m0_awlock;
wire [`Lawcache    -1 :0] m0_awcache;
wire [`Lawprot     -1 :0] m0_awprot;
wire                      m0_awvalid;
wire                      m0_awready;
wire [`LID         -1 :0] m0_wid;
wire [`Lwdata      -1 :0] m0_wdata;
wire [`Lwstrb      -1 :0] m0_wstrb;
wire                      m0_wlast;
wire                      m0_wvalid;
wire                      m0_wready;
wire [`LID         -1 :0] m0_bid;
wire [`Lbresp      -1 :0] m0_bresp;
wire                      m0_bvalid;
wire                      m0_bready;
wire [`LID         -1 :0] m0_arid;
wire [`Laraddr     -1 :0] m0_araddr;
wire [`Larlen      -1 :0] m0_arlen;
wire [7:0]                 cpu_arlen;
wire [`Larsize     -1 :0] m0_arsize;
wire [`Larburst    -1 :0] m0_arburst;
wire [`Larlock     -1 :0] m0_arlock;
wire [`Larcache    -1 :0] m0_arcache;
wire [`Larprot     -1 :0] m0_arprot;
wire                      m0_arvalid;
wire                      m0_arready;
wire [`LID         -1 :0] m0_rid;
wire [`Lrdata      -1 :0] m0_rdata;
wire [`Lrresp      -1 :0] m0_rresp;
wire                      m0_rlast;
wire                      m0_rvalid;
wire                      m0_rready;

// The repository core exposes AXI4's 8-bit LEN while this legacy SoC fabric
// is AXI3 and carries a 4-bit LEN.  Current core traffic is at most eight
// beats, so make the compatible narrowing explicit instead of relying on an
// implicit port-width truncation at the core boundary.
assign m0_awlen = cpu_awlen[`Lawlen-1:0];
assign m0_arlen = cpu_arlen[`Larlen-1:0];

wire [`LID         -1 :0] m0_async_awid;
wire [`Lawaddr     -1 :0] m0_async_awaddr;
wire [`Lawlen      -1 :0] m0_async_awlen;
wire [`Lawsize     -1 :0] m0_async_awsize;
wire [`Lawburst    -1 :0] m0_async_awburst;
wire [`Lawlock     -1 :0] m0_async_awlock;
wire [`Lawcache    -1 :0] m0_async_awcache;
wire [`Lawprot     -1 :0] m0_async_awprot;
wire                      m0_async_awvalid;
wire                      m0_async_awready;
wire [`LID         -1 :0] m0_async_wid;
wire [`Lwdata      -1 :0] m0_async_wdata;
wire [`Lwstrb      -1 :0] m0_async_wstrb;
wire                      m0_async_wlast;
wire                      m0_async_wvalid;
wire                      m0_async_wready;
wire [`LID         -1 :0] m0_async_bid;
wire [`Lbresp      -1 :0] m0_async_bresp;
wire                      m0_async_bvalid;
wire                      m0_async_bready;
wire [`LID         -1 :0] m0_async_arid;
wire [`Laraddr     -1 :0] m0_async_araddr;
wire [`Larlen      -1 :0] m0_async_arlen;
wire [`Larsize     -1 :0] m0_async_arsize;
wire [`Larburst    -1 :0] m0_async_arburst;
wire [`Larlock     -1 :0] m0_async_arlock;
wire [`Larcache    -1 :0] m0_async_arcache;
wire [`Larprot     -1 :0] m0_async_arprot;
wire                      m0_async_arvalid;
wire                      m0_async_arready;
wire [`LID         -1 :0] m0_async_rid;
wire [`Lrdata      -1 :0] m0_async_rdata;
wire [`Lrresp      -1 :0] m0_async_rresp;
wire                      m0_async_rlast;
wire                      m0_async_rvalid;
wire                      m0_async_rready;

// CPU path after the NPU MMIO window has been split out.  This remains the
// input of the original five-target SoC address decoder.
wire [3:0]  soc_awid;
wire [31:0] soc_awaddr;
wire [7:0]  soc_awlen;
wire [2:0]  soc_awsize;
wire [1:0]  soc_awburst;
wire        soc_awlock;
wire [3:0]  soc_awcache;
wire [2:0]  soc_awprot;
wire        soc_awvalid;
wire        soc_awready;
wire [3:0]  soc_wid;
wire [31:0] soc_wdata;
wire [3:0]  soc_wstrb;
wire        soc_wlast;
wire        soc_wvalid;
wire        soc_wready;
wire [3:0]  soc_bid;
wire [1:0]  soc_bresp;
wire        soc_bvalid;
wire        soc_bready;
wire [3:0]  soc_arid;
wire [31:0] soc_araddr;
wire [7:0]  soc_arlen;
wire [2:0]  soc_arsize;
wire [1:0]  soc_arburst;
wire        soc_arlock;
wire [3:0]  soc_arcache;
wire [2:0]  soc_arprot;
wire        soc_arvalid;
wire        soc_arready;
wire [3:0]  soc_rid;
wire [31:0] soc_rdata;
wire [1:0]  soc_rresp;
wire        soc_rlast;
wire        soc_rvalid;
wire        soc_rready;

// CPU-visible NPU slave at 0x1f100000..0x1f10ffff.
wire [3:0]  npu_awid;
wire [31:0] npu_awaddr;
wire [7:0]  npu_awlen;
wire [2:0]  npu_awsize;
wire [1:0]  npu_awburst;
wire        npu_awlock;
wire [3:0]  npu_awcache;
wire [2:0]  npu_awprot;
wire        npu_awvalid;
wire        npu_awready;
wire [31:0] npu_wdata;
wire [3:0]  npu_wstrb;
wire        npu_wlast;
wire        npu_wvalid;
wire        npu_wready;
wire [3:0]  npu_bid;
wire [1:0]  npu_bresp;
wire        npu_bvalid;
wire        npu_bready;
wire [3:0]  npu_arid;
wire [31:0] npu_araddr;
wire [7:0]  npu_arlen;
wire [2:0]  npu_arsize;
wire [1:0]  npu_arburst;
wire        npu_arlock;
wire [3:0]  npu_arcache;
wire [2:0]  npu_arprot;
wire        npu_arvalid;
wire        npu_arready;
wire [3:0]  npu_rid;
wire [31:0] npu_rdata;
wire [1:0]  npu_rresp;
wire        npu_rlast;
wire        npu_rvalid;
wire        npu_rready;
wire        npu_irq;

// NPU DMA master and its shared 32-bit CPU/DDR output.
wire [3:0]  npu_dma_awid;
wire [31:0] npu_dma_awaddr;
wire [7:0]  npu_dma_awlen;
wire [2:0]  npu_dma_awsize;
wire [1:0]  npu_dma_awburst;
wire        npu_dma_awlock;
wire [3:0]  npu_dma_awcache;
wire [2:0]  npu_dma_awprot;
wire        npu_dma_awvalid;
wire        npu_dma_awready;
wire [3:0]  npu_dma_wid;
wire [31:0] npu_dma_wdata;
wire [3:0]  npu_dma_wstrb;
wire        npu_dma_wlast;
wire        npu_dma_wvalid;
wire        npu_dma_wready;
wire [3:0]  npu_dma_bid;
wire [1:0]  npu_dma_bresp;
wire        npu_dma_bvalid;
wire        npu_dma_bready;
wire [3:0]  npu_dma_arid;
wire [31:0] npu_dma_araddr;
wire [7:0]  npu_dma_arlen;
wire [2:0]  npu_dma_arsize;
wire [1:0]  npu_dma_arburst;
wire        npu_dma_arlock;
wire [3:0]  npu_dma_arcache;
wire [2:0]  npu_dma_arprot;
wire        npu_dma_arvalid;
wire        npu_dma_arready;
wire [3:0]  npu_dma_rid;
wire [31:0] npu_dma_rdata;
wire [1:0]  npu_dma_rresp;
wire        npu_dma_rlast;
wire        npu_dma_rvalid;
wire        npu_dma_rready;

wire [3:0]  ddr_s0_awid;
wire [31:0] ddr_s0_awaddr;
wire [7:0]  ddr_s0_awlen;
wire [2:0]  ddr_s0_awsize;
wire [1:0]  ddr_s0_awburst;
wire        ddr_s0_awlock;
wire [3:0]  ddr_s0_awcache;
wire [2:0]  ddr_s0_awprot;
wire        ddr_s0_awvalid;
wire        ddr_s0_awready;
wire [3:0]  ddr_s0_wid;
wire [31:0] ddr_s0_wdata;
wire [3:0]  ddr_s0_wstrb;
wire        ddr_s0_wlast;
wire        ddr_s0_wvalid;
wire        ddr_s0_wready;
wire [3:0]  ddr_s0_bid;
wire [1:0]  ddr_s0_bresp;
wire        ddr_s0_bvalid;
wire        ddr_s0_bready;
wire [3:0]  ddr_s0_arid;
wire [31:0] ddr_s0_araddr;
wire [7:0]  ddr_s0_arlen;
wire [2:0]  ddr_s0_arsize;
wire [1:0]  ddr_s0_arburst;
wire        ddr_s0_arlock;
wire [3:0]  ddr_s0_arcache;
wire [2:0]  ddr_s0_arprot;
wire        ddr_s0_arvalid;
wire        ddr_s0_arready;
wire [3:0]  ddr_s0_rid;
wire [31:0] ddr_s0_rdata;
wire [1:0]  ddr_s0_rresp;
wire        ddr_s0_rlast;
wire        ddr_s0_rvalid;
wire        ddr_s0_rready;

wire [`LID         -1 :0] spi_s_awid;
wire [`Lawaddr     -1 :0] spi_s_awaddr;
wire [`Lawlen      -1 :0] spi_s_awlen;
wire [`Lawsize     -1 :0] spi_s_awsize;
wire [`Lawburst    -1 :0] spi_s_awburst;
wire [`Lawlock     -1 :0] spi_s_awlock;
wire [`Lawcache    -1 :0] spi_s_awcache;
wire [`Lawprot     -1 :0] spi_s_awprot;
wire                      spi_s_awvalid;
wire                      spi_s_awready;
wire [`LID         -1 :0] spi_s_wid;
wire [`Lwdata      -1 :0] spi_s_wdata;
wire [`Lwstrb      -1 :0] spi_s_wstrb;
wire                      spi_s_wlast;
wire                      spi_s_wvalid;
wire                      spi_s_wready;
wire [`LID         -1 :0] spi_s_bid;
wire [`Lbresp      -1 :0] spi_s_bresp;
wire                      spi_s_bvalid;
wire                      spi_s_bready;
wire [`LID         -1 :0] spi_s_arid;
wire [`Laraddr     -1 :0] spi_s_araddr;
wire [`Larlen      -1 :0] spi_s_arlen;
wire [`Larsize     -1 :0] spi_s_arsize;
wire [`Larburst    -1 :0] spi_s_arburst;
wire [`Larlock     -1 :0] spi_s_arlock;
wire [`Larcache    -1 :0] spi_s_arcache;
wire [`Larprot     -1 :0] spi_s_arprot;
wire                      spi_s_arvalid;
wire                      spi_s_arready;
wire [`LID         -1 :0] spi_s_rid;
wire [`Lrdata      -1 :0] spi_s_rdata;
wire [`Lrresp      -1 :0] spi_s_rresp;
wire                      spi_s_rlast;
wire                      spi_s_rvalid;
wire                      spi_s_rready;

wire [`LID         -1 :0] conf_s_awid;
wire [`Lawaddr     -1 :0] conf_s_awaddr;
wire [`Lawlen      -1 :0] conf_s_awlen;
wire [`Lawsize     -1 :0] conf_s_awsize;
wire [`Lawburst    -1 :0] conf_s_awburst;
wire [`Lawlock     -1 :0] conf_s_awlock;
wire [`Lawcache    -1 :0] conf_s_awcache;
wire [`Lawprot     -1 :0] conf_s_awprot;
wire                      conf_s_awvalid;
wire                      conf_s_awready;
wire [`LID         -1 :0] conf_s_wid;
wire [`Lwdata      -1 :0] conf_s_wdata;
wire [`Lwstrb      -1 :0] conf_s_wstrb;
wire                      conf_s_wlast;
wire                      conf_s_wvalid;
wire                      conf_s_wready;
wire [`LID         -1 :0] conf_s_bid;
wire [`Lbresp      -1 :0] conf_s_bresp;
wire                      conf_s_bvalid;
wire                      conf_s_bready;
wire [`LID         -1 :0] conf_s_arid;
wire [`Laraddr     -1 :0] conf_s_araddr;
wire [`Larlen      -1 :0] conf_s_arlen;
wire [`Larsize     -1 :0] conf_s_arsize;
wire [`Larburst    -1 :0] conf_s_arburst;
wire [`Larlock     -1 :0] conf_s_arlock;
wire [`Larcache    -1 :0] conf_s_arcache;
wire [`Larprot     -1 :0] conf_s_arprot;
wire                      conf_s_arvalid;
wire                      conf_s_arready;
wire [`LID         -1 :0] conf_s_rid;
wire [`Lrdata      -1 :0] conf_s_rdata;
wire [`Lrresp      -1 :0] conf_s_rresp;
wire                      conf_s_rlast;
wire                      conf_s_rvalid;
wire                      conf_s_rready;

wire [`LID         -1 :0] mac_s_awid;
wire [`Lawaddr     -1 :0] mac_s_awaddr;
wire [`Lawlen      -1 :0] mac_s_awlen;
wire [`Lawsize     -1 :0] mac_s_awsize;
wire [`Lawburst    -1 :0] mac_s_awburst;
wire [`Lawlock     -1 :0] mac_s_awlock;
wire [`Lawcache    -1 :0] mac_s_awcache;
wire [`Lawprot     -1 :0] mac_s_awprot;
wire                      mac_s_awvalid;
wire                      mac_s_awready;
wire [`LID         -1 :0] mac_s_wid;
wire [`Lwdata      -1 :0] mac_s_wdata;
wire [`Lwstrb      -1 :0] mac_s_wstrb;
wire                      mac_s_wlast;
wire                      mac_s_wvalid;
wire                      mac_s_wready;
wire [`LID         -1 :0] mac_s_bid;
wire [`Lbresp      -1 :0] mac_s_bresp;
wire                      mac_s_bvalid;
wire                      mac_s_bready;
wire [`LID         -1 :0] mac_s_arid;
wire [`Laraddr     -1 :0] mac_s_araddr;
wire [`Larlen      -1 :0] mac_s_arlen;
wire [`Larsize     -1 :0] mac_s_arsize;
wire [`Larburst    -1 :0] mac_s_arburst;
wire [`Larlock     -1 :0] mac_s_arlock;
wire [`Larcache    -1 :0] mac_s_arcache;
wire [`Larprot     -1 :0] mac_s_arprot;
wire                      mac_s_arvalid;
wire                      mac_s_arready;
wire [`LID         -1 :0] mac_s_rid;
wire [`Lrdata      -1 :0] mac_s_rdata;
wire [`Lrresp      -1 :0] mac_s_rresp;
wire                      mac_s_rlast;
wire                      mac_s_rvalid;
wire                      mac_s_rready;

wire [`LID         -1 :0] mac_m_awid;
wire [`Lawaddr     -1 :0] mac_m_awaddr;
wire [`Lawlen      -1 :0] mac_m_awlen;
wire [`Lawsize     -1 :0] mac_m_awsize;
wire [`Lawburst    -1 :0] mac_m_awburst;
wire [`Lawlock     -1 :0] mac_m_awlock;
wire [`Lawcache    -1 :0] mac_m_awcache;
wire [`Lawprot     -1 :0] mac_m_awprot;
wire                      mac_m_awvalid;
wire                      mac_m_awready;
wire [`LID         -1 :0] mac_m_wid;
wire [`Lwdata      -1 :0] mac_m_wdata;
wire [`Lwstrb      -1 :0] mac_m_wstrb;
wire                      mac_m_wlast;
wire                      mac_m_wvalid;
wire                      mac_m_wready;
wire [`LID         -1 :0] mac_m_bid;
wire [`Lbresp      -1 :0] mac_m_bresp;
wire                      mac_m_bvalid;
wire                      mac_m_bready;
wire [`LID         -1 :0] mac_m_arid;
wire [`Laraddr     -1 :0] mac_m_araddr;
wire [`Larlen      -1 :0] mac_m_arlen;
wire [`Larsize     -1 :0] mac_m_arsize;
wire [`Larburst    -1 :0] mac_m_arburst;
wire [`Larlock     -1 :0] mac_m_arlock;
wire [`Larcache    -1 :0] mac_m_arcache;
wire [`Larprot     -1 :0] mac_m_arprot;
wire                      mac_m_arvalid;
wire                      mac_m_arready;
wire [`LID         -1 :0] mac_m_rid;
wire [`Lrdata      -1 :0] mac_m_rdata;
wire [`Lrresp      -1 :0] mac_m_rresp;
wire                      mac_m_rlast;
wire                      mac_m_rvalid;
wire                      mac_m_rready;

wire [`LID         -1 :0] s0_awid;
wire [`Lawaddr     -1 :0] s0_awaddr;
wire [`Lawlen      -1 :0] s0_awlen;
wire [`Lawsize     -1 :0] s0_awsize;
wire [`Lawburst    -1 :0] s0_awburst;
wire [`Lawlock     -1 :0] s0_awlock;
wire [`Lawcache    -1 :0] s0_awcache;
wire [`Lawprot     -1 :0] s0_awprot;
wire                      s0_awvalid;
wire                      s0_awready;
wire [`LID         -1 :0] s0_wid;
wire [`Lwdata      -1 :0] s0_wdata;
wire [`Lwstrb      -1 :0] s0_wstrb;
wire                      s0_wlast;
wire                      s0_wvalid;
wire                      s0_wready;
wire [`LID         -1 :0] s0_bid;
wire [`Lbresp      -1 :0] s0_bresp;
wire                      s0_bvalid;
wire                      s0_bready;
wire [`LID         -1 :0] s0_arid;
wire [`Laraddr     -1 :0] s0_araddr;
wire [`Larlen      -1 :0] s0_arlen;
wire [`Larsize     -1 :0] s0_arsize;
wire [`Larburst    -1 :0] s0_arburst;
wire [`Larlock     -1 :0] s0_arlock;
wire [`Larcache    -1 :0] s0_arcache;
wire [`Larprot     -1 :0] s0_arprot;
wire                      s0_arvalid;
wire                      s0_arready;
wire [`LID         -1 :0] s0_rid;
wire [`Lrdata      -1 :0] s0_rdata;
wire [`Lrresp      -1 :0] s0_rresp;
wire                      s0_rlast;
wire                      s0_rvalid;
wire                      s0_rready;

wire [8            -1 :0] mig_awid;
wire [`Lawaddr     -1 :0] mig_awaddr;
wire [8            -1 :0] mig_awlen;
wire [`Lawsize     -1 :0] mig_awsize;
wire [`Lawburst    -1 :0] mig_awburst;
wire [`Lawlock     -1 :0] mig_awlock;
wire [`Lawcache    -1 :0] mig_awcache;
wire [`Lawprot     -1 :0] mig_awprot;
wire                      mig_awvalid;
wire                      mig_awready;
wire [8            -1 :0] mig_wid;
wire [`Lwdata      -1 :0] mig_wdata;
wire [`Lwstrb      -1 :0] mig_wstrb;
wire                      mig_wlast;
wire                      mig_wvalid;
wire                      mig_wready;
wire [8            -1 :0] mig_bid;
wire [`Lbresp      -1 :0] mig_bresp;
wire                      mig_bvalid;
wire                      mig_bready;
wire [8            -1 :0] mig_arid;
wire [`Laraddr     -1 :0] mig_araddr;
wire [8            -1 :0] mig_arlen;
wire [`Larsize     -1 :0] mig_arsize;
wire [`Larburst    -1 :0] mig_arburst;
wire [`Larlock     -1 :0] mig_arlock;
wire [`Larcache    -1 :0] mig_arcache;
wire [`Larprot     -1 :0] mig_arprot;
wire                      mig_arvalid;
wire                      mig_arready;
wire [8            -1 :0] mig_rid;
wire [`Lrdata      -1 :0] mig_rdata;
wire [`Lrresp      -1 :0] mig_rresp;
wire                      mig_rlast;
wire                      mig_rvalid;
wire                      mig_rready;

// Camera AXI VDMA masters.  During the first DDR bring-up stage only S2MM is
// started; the existing BRAM VGA path below remains the visible output.
wire [31:0] cam_s2mm_awaddr;
wire [7:0]  cam_s2mm_awlen;
wire [2:0]  cam_s2mm_awsize;
wire [1:0]  cam_s2mm_awburst;
wire [2:0]  cam_s2mm_awprot;
wire [3:0]  cam_s2mm_awcache;
wire        cam_s2mm_awvalid;
wire        cam_s2mm_awready;
wire [31:0] cam_s2mm_wdata;
wire [3:0]  cam_s2mm_wstrb;
wire        cam_s2mm_wlast;
wire        cam_s2mm_wvalid;
wire        cam_s2mm_wready;
wire [1:0]  cam_s2mm_bresp;
wire        cam_s2mm_bvalid;
wire        cam_s2mm_bready;

wire [31:0] cam_mm2s_araddr;
wire [7:0]  cam_mm2s_arlen;
wire [2:0]  cam_mm2s_arsize;
wire [1:0]  cam_mm2s_arburst;
wire [2:0]  cam_mm2s_arprot;
wire [3:0]  cam_mm2s_arcache;
wire        cam_mm2s_arvalid;
wire        cam_mm2s_arready;
wire [31:0] cam_mm2s_rdata;
wire [1:0]  cam_mm2s_rresp;
wire        cam_mm2s_rlast;
wire        cam_mm2s_rvalid;
wire        cam_mm2s_rready;

// LCD one-shot DDR reader.  It shares the camera MM2S slot only after the
// camera reader has been disabled and all accepted camera bursts are drained.
wire [31:0] lcd_mm2s_araddr;
wire [7:0]  lcd_mm2s_arlen;
wire [2:0]  lcd_mm2s_arsize;
wire [1:0]  lcd_mm2s_arburst;
wire [2:0]  lcd_mm2s_arprot;
wire [3:0]  lcd_mm2s_arcache;
wire        lcd_mm2s_arvalid;
wire        lcd_mm2s_arready;
wire [31:0] lcd_mm2s_rdata;
wire [1:0]  lcd_mm2s_rresp;
wire        lcd_mm2s_rlast;
wire        lcd_mm2s_rvalid;
wire        lcd_mm2s_rready;

wire [31:0] s04_araddr;
wire [7:0]  s04_arlen;
wire [2:0]  s04_arsize;
wire [1:0]  s04_arburst;
wire [2:0]  s04_arprot;
wire [3:0]  s04_arcache;
wire        s04_arvalid;
wire        s04_arready;
wire [31:0] s04_rdata;
wire [1:0]  s04_rresp;
wire        s04_rlast;
wire        s04_rvalid;
wire        s04_rready;

wire        lcd_fifo_wr_en;
wire [31:0] lcd_fifo_wr_data;
wire        lcd_fifo_full;
wire        lcd_fifo_rd_en;
wire [31:0] lcd_fifo_rd_data;
wire        lcd_fifo_rd_valid;
wire        lcd_fifo_empty;

wire [15:0] cam_video_tdata;
wire [1:0]  cam_video_tkeep;
wire        cam_video_tuser;
wire        cam_video_tlast;
wire        cam_video_tvalid;
wire        cam_video_tready;
wire        cam_vdma_init_done;
wire        cam_vdma_init_error;
wire        cam_vdma_fifo_full;
wire        cam_vdma_fifo_overflow;
wire        cam_vdma_frame_seen;
wire [3:0]  cam_vdma_debug_state;
wire [3:0]  cam_vdma_debug_index;
wire [31:0] cam_vdma_mm2s_status;
wire [31:0] cam_vdma_s2mm_status;
wire        cam_vdma_status_valid;
wire        cam_ddr_stream_seen;
wire        cam_ddr_frame_started;
wire        cam_ddr_underflow;

// CPU-visible camera register block is implemented inside CONFREG.  All
// asynchronous camera/VDMA indicators are sampled into aclk before CONFREG
// exposes them to software.
wire [31:0] camera_control;
reg  [31:0] camera_status_aclk;
reg  [31:0] camera_frame_count_aclk;
reg  [31:0] camera_s2mm_status_meta;
reg  [31:0] camera_s2mm_status_aclk;
reg  [31:0] camera_mm2s_status_meta;
reg  [31:0] camera_mm2s_status_aclk;
reg         camera_frame_toggle_cpu;
(* ASYNC_REG = "TRUE" *) reg [2:0] camera_frame_toggle_sync;
(* ASYNC_REG = "TRUE" *) reg [31:0] camera_status_meta;

wire [31:0] lcd_control;
wire [31:0] lcd_frame_addr;
reg  [31:0] lcd_status_meta;
reg  [31:0] lcd_status_aclk;

wire [`LID         -1 :0] dma0_awid       ;
wire [`Lawaddr     -1 :0] dma0_awaddr     ;
wire [`Lawlen      -1 :0] dma0_awlen      ;
wire [`Lawsize     -1 :0] dma0_awsize     ;
wire [`Lawburst    -1 :0] dma0_awburst    ;
wire [`Lawlock     -1 :0] dma0_awlock     ;
wire [`Lawcache    -1 :0] dma0_awcache    ;
wire [`Lawprot     -1 :0] dma0_awprot     ;
wire                      dma0_awvalid    ;
wire                      dma0_awready    ;
wire [`LID         -1 :0] dma0_wid        ;
wire [64           -1 :0] dma0_wdata      ;
wire [8            -1 :0] dma0_wstrb      ;
wire                      dma0_wlast      ;
wire                      dma0_wvalid     ;
wire                      dma0_wready     ;
wire [`LID         -1 :0] dma0_bid        ;
wire [`Lbresp      -1 :0] dma0_bresp      ;
wire                      dma0_bvalid     ;
wire                      dma0_bready     ;
wire [`LID         -1 :0] dma0_arid       ;
wire [`Laraddr     -1 :0] dma0_araddr     ;
wire [`Larlen      -1 :0] dma0_arlen      ;
wire [`Larsize     -1 :0] dma0_arsize     ;
wire [`Larburst    -1 :0] dma0_arburst    ;
wire [`Larlock     -1 :0] dma0_arlock     ;
wire [`Larcache    -1 :0] dma0_arcache    ;
wire [`Larprot     -1 :0] dma0_arprot     ;
wire                      dma0_arvalid    ;
wire                      dma0_arready    ;
wire [`LID         -1 :0] dma0_rid        ;
wire [64           -1 :0] dma0_rdata      ;
wire [`Lrresp      -1 :0] dma0_rresp      ;
wire                      dma0_rlast      ;
wire                      dma0_rvalid     ;
wire                      dma0_rready     ;

wire [`LID         -1 :0] apb_s_awid;
wire [`Lawaddr     -1 :0] apb_s_awaddr;
wire [`Lawlen      -1 :0] apb_s_awlen;
wire [`Lawsize     -1 :0] apb_s_awsize;
wire [`Lawburst    -1 :0] apb_s_awburst;
wire [`Lawlock     -1 :0] apb_s_awlock;
wire [`Lawcache    -1 :0] apb_s_awcache;
wire [`Lawprot     -1 :0] apb_s_awprot;
wire                      apb_s_awvalid;
wire                      apb_s_awready;
wire [`LID         -1 :0] apb_s_wid;
wire [`Lwdata      -1 :0] apb_s_wdata;
wire [`Lwstrb      -1 :0] apb_s_wstrb;
wire                      apb_s_wlast;
wire                      apb_s_wvalid;
wire                      apb_s_wready;
wire [`LID         -1 :0] apb_s_bid;
wire [`Lbresp      -1 :0] apb_s_bresp;
wire                      apb_s_bvalid;
wire                      apb_s_bready;
wire [`LID         -1 :0] apb_s_arid;
wire [`Laraddr     -1 :0] apb_s_araddr;
wire [`Larlen      -1 :0] apb_s_arlen;
wire [`Larsize     -1 :0] apb_s_arsize;
wire [`Larburst    -1 :0] apb_s_arburst;
wire [`Larlock     -1 :0] apb_s_arlock;
wire [`Larcache    -1 :0] apb_s_arcache;
wire [`Larprot     -1 :0] apb_s_arprot;
wire                      apb_s_arvalid;
wire                      apb_s_arready;
wire [`LID         -1 :0] apb_s_rid;
wire [`Lrdata      -1 :0] apb_s_rdata;
wire [`Lrresp      -1 :0] apb_s_rresp;
wire                      apb_s_rlast;
wire                      apb_s_rvalid;
wire                      apb_s_rready;

wire          apb_ready_dma0;
wire          apb_start_dma0;
wire          apb_rw_dma0;
wire          apb_psel_dma0;
wire          apb_penable_dma0;
wire[31:0]    apb_addr_dma0;
wire[31:0]    apb_wdata_dma0;
wire[31:0]    apb_rdata_dma0;

wire         dma_int;
wire         dma_ack;
wire         dma_req;

wire                      dma0_gnt;
wire[31:0]                order_addr_in;
wire                      write_dma_end;
wire                      finish_read_order;

//spi
wire [3:0]spi_csn_o ;
wire [3:0]spi_csn_en;
wire spi_sck_o ;
wire spi_sdo_i ;
wire spi_sdo_o ;
wire spi_sdo_en;
wire spi_sdi_i ;
wire spi_sdi_o ;
wire spi_sdi_en;
wire spi_inta_o;
assign     SPI_CLK = spi_sck_o;
assign     SPI_CS  = ~spi_csn_en[0] & spi_csn_o[0];
assign     SPI_MOSI = spi_sdo_en ? 1'bz : spi_sdo_o ;
assign     SPI_MISO = spi_sdi_en ? 1'bz : spi_sdi_o ;
assign     spi_sdo_i = SPI_MOSI;
assign     spi_sdi_i = SPI_MISO;

// confreg 
wire   [31:0] cr00,cr01,cr02,cr03,cr04,cr05,cr06,cr07;

//mac
wire md_i_0;      // MII data input (from I/O cell)
wire md_o_0;      // MII data output (to I/O cell)
wire md_oe_0;     // MII data output enable (to I/O cell)
IOBUF mac_mdio(.IO(mdio_0),.I(md_o_0),.T(~md_oe_0),.O(md_i_0));
assign phy_rstn = aresetn;

//nand
wire       nand_cle   ;
wire       nand_ale   ;
wire [3:0] nand_rdy   ;
wire [3:0] nand_ce    ;
wire       nand_rd    ;
wire       nand_wr    ;
wire       nand_dat_oe;
wire [7:0] nand_dat_i ;
wire [7:0] nand_dat_o ;
wire       nand_int   ;
assign     NAND_CLE = nand_cle;
assign     NAND_ALE = nand_ale;
assign     nand_rdy = {3'd0,NAND_RDY};
assign     NAND_RD  = nand_rd;
assign     NAND_CE  = nand_ce[0];  //low active
assign     NAND_WR  = nand_wr;  
generate
    genvar i;
    for(i=0;i<8;i=i+1)
    begin: nand_data_loop
        IOBUF nand_data(.IO(NAND_DATA[i]),.I(nand_dat_o[i]),.T(nand_dat_oe),.O(nand_dat_i[i]));
    end
endgenerate

//uart
wire UART_CTS,   UART_RTS;
wire UART_DTR,   UART_DSR;
wire UART_RI,    UART_DCD;
assign UART_CTS = 1'b0;
assign UART_DSR = 1'b0;
assign UART_RI  = 1'b0;
assign UART_DCD = 1'b0;
wire uart0_int   ;
wire uart0_txd_o ;
wire uart0_txd_i ;
wire uart0_txd_oe;
wire uart0_rxd_o ;
wire uart0_rxd_i ;
wire uart0_rxd_oe;
wire uart0_rts_o ;
wire uart0_cts_i ;
wire uart0_dsr_i ;
wire uart0_dcd_i ;
wire uart0_dtr_o ;
wire uart0_ri_i  ;
assign     UART_RX     = uart0_rxd_oe ? 1'bz : uart0_rxd_o ;
assign     UART_TX     = uart0_txd_oe ? 1'bz : uart0_txd_o ;
assign     UART_RTS    = uart0_rts_o ;
assign     UART_DTR    = uart0_dtr_o ;
assign     uart0_txd_i = UART_TX;
assign     uart0_rxd_i = UART_RX;
assign     uart0_cts_i = UART_CTS;
assign     uart0_dcd_i = UART_DCD;
assign     uart0_dsr_i = UART_DSR;
assign     uart0_ri_i  = UART_RI ;

//interrupt
wire mac_int;
wire [5:0] int_out;
wire [5:0] int_n_i;
wire [5:0] int_async = {npu_irq,dma_int,nand_int,spi_inta_o,uart0_int,mac_int};

peripheral_irq_cdc #(.WIDTH(6)) u_peripheral_irq_cdc (
    .src_clk (aclk),
    .dst_clk (cpu_clk),
    .resetn  (resetn),
    .irq_src (int_async),
    .irq_dst (int_out)
);

assign int_n_i = ~int_out;

reg cpu_aresetn_1;
reg cpu_aresetn_2;

wire cpu_aresetn;

always @(posedge cpu_clk or negedge resetn) begin
    if (!resetn) begin
        cpu_aresetn_1 <= 1'b0;
        cpu_aresetn_2 <= 1'b0;
    end else begin
        cpu_aresetn_1 <= aresetn;
        cpu_aresetn_2 <= cpu_aresetn_1;
    end
end

assign cpu_aresetn = cpu_aresetn_2;

//debug signals
wire [31:0] debug_wb_pc;
wire [3 :0] debug_wb_rf_wen;
wire [4 :0] debug_wb_rf_wnum;
wire [31:0] debug_wb_rf_wdata;
wire        ws_valid;
wire [31:0] debug_wb_inst;
wire        debug0_wb_mem_read;
wire        debug0_wb_mem_write;
wire [31:0] debug0_wb_mem_addr;
wire [31:0] debug0_wb_store_data;
wire        debug1_wb_mem_read;
wire        debug1_wb_mem_write;
wire [31:0] debug1_wb_mem_addr;
wire [31:0] debug1_wb_store_data;
wire [3:0]  debug1_wb_rf_wen_raw;
wire [4:0]  debug1_wb_rf_wnum_raw;
wire [31:0] debug1_wb_rf_wdata_raw;
wire        debug_ertn;
wire        debug_fetch_valid;
wire [31:0] debug_fetch_vaddr;
wire [31:0] debug_fetch_paddr;
wire [31:0] debug_crmd;
wire [31:0] debug_badv;
wire [31:0] debug_dmw0;
wire [31:0] debug_dmw1;
wire        debug_exception_valid;
wire [5:0]  debug_exception_cause;
wire [31:0] debug_exception_pc;
wire [31:0] debug_exception_inst;
wire [31:0] debug_gpr4;
wire [31:0] debug_gpr5;
wire [31:0] debug_gpr6;
wire [31:0] debug_gpr7;
wire [31:0] debug_gpr8;
wire [31:0] debug_eentry;
wire [31:0] debug_tlbrentry;
reg  [15:0] linux_debug_status;
reg  [31:0] linux_last_fetch_vaddr;
reg  [31:0] linux_last_wb_pc;
reg         linux_first_exception_valid;
reg  [5:0]  linux_first_exception_cause;
reg  [31:0] linux_first_exception_pc;
reg  [31:0] linux_first_exception_inst;
reg  [31:0] linux_kernel_arg0;
reg  [31:0] linux_kernel_arg1;
reg  [31:0] linux_kernel_arg2;
reg  [31:0] linux_kernel_arg3;
reg  [31:0] pmon_context_ptr;
reg  [31:0] pmon_context_arg0;
reg  [31:0] pmon_context_arg1;
reg  [31:0] pmon_context_arg2;
reg  [31:0] pmon_context_arg3;
reg  [3:0]  pmon_fixed_store_seen;
reg  [3:0]  pmon_fixed_load_seen;
reg  [31:0] pmon_fixed_store_arg0;
reg  [31:0] pmon_fixed_store_arg1;
reg  [31:0] pmon_fixed_store_arg2;
reg  [31:0] pmon_fixed_store_arg3;
reg  [31:0] pmon_fixed_load_arg0;
reg  [31:0] pmon_fixed_load_arg1;
reg  [31:0] pmon_fixed_load_arg2;
reg  [31:0] pmon_fixed_load_arg3;
reg  [31:0] pmon_fixed_load_dest;
reg  [15:0] pmon_fixed_store_addr_hi;
reg  [15:0] pmon_fixed_load_addr_hi;
reg         pmon_restore_seen;
reg  [31:0] pmon_restore_gpr4;
reg  [31:0] pmon_restore_gpr5;
reg  [31:0] pmon_restore_gpr6;
reg  [31:0] pmon_restore_gpr7;
reg  [3:0]  pmon_axi_aw_seen;
reg  [7:0]  pmon_axi_w_seen;
reg  [3:0]  pmon_axi_ar_seen;
reg  [3:0]  pmon_axi_r_seen;
reg  [2:0]  pmon_axi_write_beat;
reg  [1:0]  pmon_axi_read_index;
reg         pmon_axi_aw_pending;
reg         pmon_axi_ar_pending;
reg  [7:0]  pmon_axi_aw_len;
reg  [1:0]  pmon_axi_aw_burst;
reg  [7:0]  pmon_axi_wlast_seen;
reg         pmon_axi_b_seen;
reg  [1:0]  pmon_axi_bresp;
reg  [31:0] pmon_axi_aw_addr0;
reg  [31:0] pmon_axi_aw_addr1;
reg  [31:0] pmon_axi_aw_addr2;
reg  [31:0] pmon_axi_aw_addr3;
reg  [31:0] pmon_axi_w_data0;
reg  [31:0] pmon_axi_w_data1;
reg  [31:0] pmon_axi_w_data2;
reg  [31:0] pmon_axi_w_data3;
reg  [31:0] pmon_axi_w_data4;
reg  [31:0] pmon_axi_w_data5;
reg  [31:0] pmon_axi_w_data6;
reg  [31:0] pmon_axi_w_data7;
reg  [31:0] pmon_axi_ar_addr0;
reg  [31:0] pmon_axi_ar_addr1;
reg  [31:0] pmon_axi_ar_addr2;
reg  [31:0] pmon_axi_ar_addr3;
reg  [31:0] pmon_axi_r_data0;
reg  [31:0] pmon_axi_r_data1;
reg  [31:0] pmon_axi_r_data2;
reg  [31:0] pmon_axi_r_data3;
wire [31:0] linux_debug_snapshot =
    {9'd0, linux_first_exception_valid,
     linux_first_exception_cause, linux_debug_status};
wire [31:0] pmon_fixed_access =
    {23'd0, pmon_restore_seen,
     pmon_fixed_store_seen, pmon_fixed_load_seen};
wire [31:0] pmon_axi_access =
    {12'd0, pmon_axi_r_seen, pmon_axi_ar_seen,
     pmon_axi_w_seen, pmon_axi_aw_seen};
wire [31:0] pmon_axi_write_meta =
    {11'd0, pmon_axi_bresp, pmon_axi_b_seen,
     pmon_axi_wlast_seen, pmon_axi_aw_burst, pmon_axi_aw_len};
wire pmon_go_tuple = debug_gpr5 == 32'd2
                   && debug_gpr6 == 32'ha4f0_0000
                   && debug_gpr7 == 32'ha4f0_0040
                   && debug_gpr8 == 32'd0
                   && debug_gpr4 != 32'd0;
// Arm before the helper resolves r4.  Requiring the nonzero context pointer
// can miss early W beats when AXI accepts data before its independent AW.
wire pmon_axi_arm_tuple = debug_gpr5 == 32'd2
                        && debug_gpr6 == 32'ha4f0_0000
                        && debug_gpr7 == 32'ha4f0_0040
                        && debug_gpr8 == 32'd0;
wire pmon_axi_trace_active = linux_debug_status[13] | pmon_axi_arm_tuple;
wire pmon_axi_aw_visible_fixed = pmon_axi_trace_active
                               && !pmon_axi_b_seen
                               && m0_awvalid
                               && m0_awid[3:0] == 4'd2
                               && (m0_awaddr == 32'h070d_0b60
                                   || m0_awaddr == 32'h070d_0b64
                                   || m0_awaddr == 32'h070d_0b68
                                   || m0_awaddr == 32'h070d_0b6c);
wire [1:0] pmon_axi_aw_visible_index =
    m0_awaddr == 32'h070d_0b60 ? 2'd0 :
    m0_awaddr == 32'h070d_0b64 ? 2'd1 :
    m0_awaddr == 32'h070d_0b68 ? 2'd2 : 2'd3;
wire pmon_axi_aw_fixed_fire = pmon_axi_aw_visible_fixed && m0_awready;
wire pmon_axi_w_fire = pmon_axi_trace_active
                     && m0_wvalid && m0_wready
                     && m0_wid[3:0] == 4'd2;
wire pmon_axi_w_has_index = pmon_axi_w_fire
                          && (pmon_axi_aw_visible_fixed
                              || pmon_axi_aw_pending);
wire [2:0] pmon_axi_w_capture_beat = pmon_axi_aw_pending
                                  ? pmon_axi_write_beat : 3'd0;
wire pmon_axi_ar_fixed_fire = pmon_axi_trace_active
                            && m0_arvalid && m0_arready
                            && m0_arid[3:0] == 4'd1
                            && (m0_araddr == 32'h070d_0b60
                                || m0_araddr == 32'h070d_0b64
                                || m0_araddr == 32'h070d_0b68
                                || m0_araddr == 32'h070d_0b6c);
wire [1:0] pmon_axi_ar_fire_index =
    m0_araddr == 32'h070d_0b60 ? 2'd0 :
    m0_araddr == 32'h070d_0b64 ? 2'd1 :
    m0_araddr == 32'h070d_0b68 ? 2'd2 : 2'd3;
wire        break_point;
wire        infor_flag;
wire [ 4:0] reg_num;
wire [31:0] rf_rdata;

//uart_ram signals
wire [3 :0] uart_arid   ;
wire [31:0] uart_araddr ;
wire [7 :0] uart_arlen  ;
wire [2 :0] uart_arsize ;
wire [1 :0] uart_arburst;
wire [1 :0] uart_arlock ;
wire [3 :0] uart_arcache;
wire [2 :0] uart_arprot ;
wire        uart_arvalid;
wire        uart_arready;
wire [3 :0] uart_rid    ;
wire [31:0] uart_rdata  ;
wire [1 :0] uart_rresp  ;
wire        uart_rlast  ;
wire        uart_rvalid ;
wire        uart_rready ;

wire        infom_flag;
wire [31:0] start_addr;
wire        mem_flag;
wire [ 7:0] mem_rdata;

//axi_2x1 signals
wire [`LID         -1 :0] m1_arid;
wire [`Laraddr     -1 :0] m1_araddr;
wire [`Larlen      -1 :0] m1_arlen;
wire [`Larsize     -1 :0] m1_arsize;
wire [`Larburst    -1 :0] m1_arburst;
wire [`Larlock     -1 :0] m1_arlock;
wire [`Larcache    -1 :0] m1_arcache;
wire [`Larprot     -1 :0] m1_arprot;
wire                      m1_arvalid;
wire                      m1_arready;
wire [`LID         -1 :0] m1_rid;
wire [`Lrdata      -1 :0] m1_rdata;
wire [`Lrresp      -1 :0] m1_rresp;
wire                      m1_rlast;
wire                      m1_rvalid;
wire                      m1_rready;

// axi_2x1_mux has one-bit IDs on each source and a five-bit ID on its
// downstream side (only bits [1:0] carry information in this configuration).
// Keep the conversions explicit so the mux's source tag survives the RAM
// round trip and returned client IDs are deterministically zero-extended.
wire                      mux_s0_rid;
wire                      mux_s1_rid;
wire [4:0]                mux_m_arid;
wire [7:0]                mux_m_arlen;
wire                      mux_m_arlock;

assign m0_rid      = {{(`LID-1){1'b0}}, mux_s0_rid};
assign uart_rid    = {3'b0, mux_s1_rid};
assign m1_arid     = mux_m_arid[`LID-1:0];
assign m1_arlen    = mux_m_arlen[`Larlen-1:0];
assign m1_arlock   = {{(`Larlock-1){1'b0}}, mux_m_arlock};

debug_top u_debug_top(
    .sys_clk              (cpu_clk          ),
    .sys_rst_n            (resetn           ),
    .uart_rxd             (UART_RX2         ),
    .debug_wb_pc          (debug_wb_pc      ),
    .debug_wb_rf_wnum     (debug_wb_rf_wnum ),
    .debug_wb_rf_wdata    (debug_wb_rf_wdata),
    .ws_valid             (ws_valid         ),
    .break_point          (break_point      ),
    .infor_flag           (infor_flag       ),
    .reg_num              (reg_num          ),
    .rf_rdata             (rf_rdata         ),
    .infom_flag           (infom_flag       ),
    .start_addr           (start_addr       ),
    .mem_flag             (mem_flag         ),
    .mem_rdata            (mem_rdata        ),
    .uart_txd             (UART_TX2         )

);


debug_sram u_debug_sram(
    .clk       (cpu_clk        ),
    .aresetn   (resetn         ),   

    .arid      (uart_arid      ),
    .araddr    (uart_araddr    ),
    .arlen     (uart_arlen     ),
    .arsize    (uart_arsize    ),
    .arburst   (uart_arburst   ),
    .arlock    (uart_arlock    ),
    .arcache   (uart_arcache   ),
    .arprot    (uart_arprot    ),
    .arvalid   (uart_arvalid   ),
    .arready   (uart_arready   ),
                
    .rid       (uart_rid       ),
    .rdata     (uart_rdata     ),
    .rresp     (uart_rresp     ),
    .rlast     (uart_rlast     ),
    .rvalid    (uart_rvalid    ),
    .rready    (uart_rready    ),

    .break_point(              ),
    .cpu_rready (              ),  
    .rvalid_r   (              ),
    .rid_r      (              ),
    .rdata_r    (              ),
    .rlast_r    (              ),
    .flag       (              ),

    .infom_flag(infom_flag    ),
    .start_addr(start_addr    ),
    .mem_flag  (mem_flag      ),
    .mem_rdata (mem_rdata     ) 

);

// cpu
core_top cpu_mid(
  .aclk             (cpu_clk),
  .intrpt           ({2'b0, int_out}),
  //.nmi              (1'b1),

  .aresetn          (cpu_aresetn  ),
  .arid         (m0_arid[3:0] ),
  .araddr       (m0_araddr    ),
  .arlen        (cpu_arlen    ),
  .arsize       (m0_arsize    ),
  .arburst      (m0_arburst   ),
  .arlock       (m0_arlock    ),
  .arcache      (m0_arcache   ),
  .arprot       (m0_arprot    ),
  .arvalid      (m0_arvalid   ),
  .arready      (m0_arready   ),
  .rid          (m0_rid[3:0]  ),
  .rdata        (m0_rdata     ),
  .rresp        (m0_rresp     ),
  .rlast        (m0_rlast     ),
  .rvalid       (m0_rvalid    ),
  .rready       (m0_rready    ),
  .awid         (m0_awid[3:0] ),
  .awaddr       (m0_awaddr    ),
  .awlen        (cpu_awlen    ),
  .awsize       (m0_awsize    ),
  .awburst      (m0_awburst   ),
  .awlock       (m0_awlock    ),
  .awcache      (m0_awcache   ),
  .awprot       (m0_awprot    ),
  .awvalid      (m0_awvalid   ),
  .awready      (m0_awready   ),
  .wid          (m0_wid[3:0]  ),
  .wdata        (m0_wdata     ),
  .wstrb        (m0_wstrb     ),
  .wlast        (m0_wlast     ),
  .wvalid       (m0_wvalid    ),
  .wready       (m0_wready    ),
  .bid          (m0_bid[3:0]  ),
  .bresp        (m0_bresp     ),
  .bvalid       (m0_bvalid    ),
  .bready       (m0_bready    ),

  .ws_valid     (ws_valid     ),
  .break_point  (break_point  ),
  .infor_flag   (infor_flag   ),
  .reg_num      (reg_num      ),
  .rf_rdata     (rf_rdata     ),

  .debug0_wb_pc        (debug_wb_pc      ),
  .debug0_wb_rf_wen    (debug_wb_rf_wen  ),
  .debug0_wb_rf_wnum   (debug_wb_rf_wnum ),
  .debug0_wb_rf_wdata  (debug_wb_rf_wdata),
  .debug0_wb_inst      (debug_wb_inst),
  .debug0_wb_mem_read  (debug0_wb_mem_read),
  .debug0_wb_mem_write (debug0_wb_mem_write),
  .debug0_wb_mem_addr  (debug0_wb_mem_addr),
  .debug0_wb_store_data(debug0_wb_store_data),
  .debug1_wb_mem_read  (debug1_wb_mem_read),
  .debug1_wb_mem_write (debug1_wb_mem_write),
  .debug1_wb_mem_addr  (debug1_wb_mem_addr),
  .debug1_wb_store_data(debug1_wb_store_data),
  .debug1_wb_rf_wen_raw(debug1_wb_rf_wen_raw),
  .debug1_wb_rf_wnum_raw(debug1_wb_rf_wnum_raw),
  .debug1_wb_rf_wdata_raw(debug1_wb_rf_wdata_raw),
  .debug_fetch_valid   (debug_fetch_valid),
  .debug_fetch_vaddr   (debug_fetch_vaddr),
  .debug_fetch_paddr   (debug_fetch_paddr),
  .debug_crmd          (debug_crmd),
  .debug_badv          (debug_badv),
  .debug_dmw0          (debug_dmw0),
  .debug_dmw1          (debug_dmw1),
  .debug_exception_valid(debug_exception_valid),
  .debug_exception_cause(debug_exception_cause),
  .debug_exception_pc  (debug_exception_pc),
  .debug_exception_inst(debug_exception_inst),
  .debug_ertn           (debug_ertn),
  .debug_gpr4          (debug_gpr4),
  .debug_gpr5          (debug_gpr5),
  .debug_gpr6          (debug_gpr6),
  .debug_gpr7          (debug_gpr7),
  .debug_gpr8          (debug_gpr8),
  .debug_eentry        (debug_eentry),
  .debug_tlbrentry     (debug_tlbrentry)
);

always @(posedge cpu_clk) begin
  if (!cpu_aresetn) begin
    linux_debug_status <= 16'd0;
    linux_last_fetch_vaddr <= 32'd0;
    linux_last_wb_pc <= 32'd0;
    linux_first_exception_valid <= 1'b0;
    linux_first_exception_cause <= 6'd0;
    linux_first_exception_pc <= 32'd0;
    linux_first_exception_inst <= 32'd0;
    linux_kernel_arg0 <= 32'd0;
    linux_kernel_arg1 <= 32'd0;
    linux_kernel_arg2 <= 32'd0;
    linux_kernel_arg3 <= 32'd0;
    pmon_context_ptr <= 32'd0;
    pmon_context_arg0 <= 32'd0;
    pmon_context_arg1 <= 32'd0;
    pmon_context_arg2 <= 32'd0;
    pmon_context_arg3 <= 32'd0;
    pmon_fixed_store_seen <= 4'd0;
    pmon_fixed_load_seen <= 4'd0;
    pmon_fixed_store_arg0 <= 32'd0;
    pmon_fixed_store_arg1 <= 32'd0;
    pmon_fixed_store_arg2 <= 32'd0;
    pmon_fixed_store_arg3 <= 32'd0;
    pmon_fixed_load_arg0 <= 32'd0;
    pmon_fixed_load_arg1 <= 32'd0;
    pmon_fixed_load_arg2 <= 32'd0;
    pmon_fixed_load_arg3 <= 32'd0;
    pmon_fixed_load_dest <= 32'd0;
    pmon_fixed_store_addr_hi <= 16'd0;
    pmon_fixed_load_addr_hi <= 16'd0;
    pmon_restore_seen <= 1'b0;
    pmon_restore_gpr4 <= 32'd0;
    pmon_restore_gpr5 <= 32'd0;
    pmon_restore_gpr6 <= 32'd0;
    pmon_restore_gpr7 <= 32'd0;
    pmon_axi_aw_seen <= 4'd0;
    pmon_axi_w_seen <= 8'd0;
    pmon_axi_ar_seen <= 4'd0;
    pmon_axi_r_seen <= 4'd0;
    pmon_axi_write_beat <= 3'd0;
    pmon_axi_read_index <= 2'd0;
    pmon_axi_aw_pending <= 1'b0;
    pmon_axi_ar_pending <= 1'b0;
    pmon_axi_aw_len <= 8'd0;
    pmon_axi_aw_burst <= 2'd0;
    pmon_axi_wlast_seen <= 8'd0;
    pmon_axi_b_seen <= 1'b0;
    pmon_axi_bresp <= 2'd0;
    pmon_axi_aw_addr0 <= 32'd0;
    pmon_axi_aw_addr1 <= 32'd0;
    pmon_axi_aw_addr2 <= 32'd0;
    pmon_axi_aw_addr3 <= 32'd0;
    pmon_axi_w_data0 <= 32'd0;
    pmon_axi_w_data1 <= 32'd0;
    pmon_axi_w_data2 <= 32'd0;
    pmon_axi_w_data3 <= 32'd0;
    pmon_axi_w_data4 <= 32'd0;
    pmon_axi_w_data5 <= 32'd0;
    pmon_axi_w_data6 <= 32'd0;
    pmon_axi_w_data7 <= 32'd0;
    pmon_axi_ar_addr0 <= 32'd0;
    pmon_axi_ar_addr1 <= 32'd0;
    pmon_axi_ar_addr2 <= 32'd0;
    pmon_axi_ar_addr3 <= 32'd0;
    pmon_axi_r_data0 <= 32'd0;
    pmon_axi_r_data1 <= 32'd0;
    pmon_axi_r_data2 <= 32'd0;
    pmon_axi_r_data3 <= 32'd0;
  end else begin
    linux_debug_status[0] <= linux_debug_status[0] | ws_valid;
    linux_debug_status[1] <= linux_debug_status[1] | debug_exception_valid;
    linux_debug_status[2] <= linux_debug_status[2] | debug_fetch_valid;
    linux_debug_status[3] <= linux_debug_status[3]
                           | (debug_fetch_valid && debug_fetch_vaddr[31]);
    linux_debug_status[4] <= linux_debug_status[4]
                           | (debug_fetch_valid && debug_fetch_paddr[31]);
    linux_debug_status[5] <= linux_debug_status[5] | (debug_dmw0 != 32'd0);
    linux_debug_status[6] <= linux_debug_status[6] | (debug_dmw1 != 32'd0);
    linux_debug_status[7] <= linux_debug_status[7] | debug_crmd[4];
    linux_debug_status[8] <= linux_debug_status[8] | debug_crmd[3];
    linux_debug_status[9] <= linux_debug_status[9]
                           | (ws_valid && debug_wb_pc[31]);
    linux_debug_status[10] <= linux_debug_status[10]
                            | (ws_valid && debug_wb_pc == 32'ha07b_06e0);
    linux_debug_status[11] <= linux_debug_status[11]
                            | (ws_valid && debug_wb_pc == 32'ha09c_077c);
    linux_debug_status[12] <= linux_debug_status[12]
                            | (debug_exception_valid
                               && debug_exception_pc[31]);
    linux_debug_status[15:13] <= linux_debug_status[15:13];
    if (debug_fetch_valid)
      linux_last_fetch_vaddr <= debug_fetch_vaddr;
    if (ws_valid || debug_exception_valid)
      linux_last_wb_pc <= debug_exception_valid
                        ? debug_exception_pc : debug_wb_pc;
    if (debug_exception_valid && !linux_first_exception_valid) begin
      linux_first_exception_valid <= 1'b1;
      linux_first_exception_cause <= debug_exception_cause;
      linux_first_exception_pc <= debug_exception_pc;
      linux_first_exception_inst <= debug_exception_inst;
    end
    // The released PMON stores the go arguments through a current-context
    // helper.  Its runtime commit PC can use a different alias from the linked
    // 0x07053f10..0x07053f1c address, so match the distinctive argument tuple
    // after the helper has resolved its nonzero context pointer instead.
    if (ws_valid && pmon_go_tuple
        && !linux_debug_status[13]) begin
      linux_debug_status[13] <= 1'b1;
      linux_debug_status[14] <= linux_debug_status[14]
                              | (debug_gpr4 == 32'h070d_0b50);
      linux_debug_status[15] <= linux_debug_status[15]
                              | (debug_gpr4 != 32'h070d_0b50);
      pmon_context_ptr <= debug_gpr4;
      pmon_context_arg0 <= debug_gpr5;
      pmon_context_arg1 <= debug_gpr6;
      pmon_context_arg2 <= debug_gpr7;
      pmon_context_arg3 <= debug_gpr8;
    end
    // Sample after the fourth entry-store has committed.  This separates a
    // genuine PMON-to-kernel argument loss from a too-early observation at
    // the first redirected instruction.
    if (ws_valid && debug_wb_pc == 32'ha07b_0718) begin
      linux_kernel_arg0 <= debug_gpr4;
      linux_kernel_arg1 <= debug_gpr5;
      linux_kernel_arg2 <= debug_gpr6;
      linux_kernel_arg3 <= debug_gpr7;
    end
    // The PMON exception return restores Linux r4-r7 from the fixed frame at
    // 0x070d0b50.  Observe both retire slots so adjacent loads/stores issued
    // together cannot hide whether that frame was populated or read stale.
    if (linux_debug_status[13] && debug0_wb_mem_write) begin
      case (debug0_wb_mem_addr[27:0])
        28'h70d0b60: if (!pmon_fixed_store_seen[0]) begin
          pmon_fixed_store_seen[0] <= 1'b1;
          pmon_fixed_store_arg0 <= debug0_wb_store_data;
          pmon_fixed_store_addr_hi[3:0] <= debug0_wb_mem_addr[31:28];
        end
        28'h70d0b64: if (!pmon_fixed_store_seen[1]) begin
          pmon_fixed_store_seen[1] <= 1'b1;
          pmon_fixed_store_arg1 <= debug0_wb_store_data;
          pmon_fixed_store_addr_hi[7:4] <= debug0_wb_mem_addr[31:28];
        end
        28'h70d0b68: if (!pmon_fixed_store_seen[2]) begin
          pmon_fixed_store_seen[2] <= 1'b1;
          pmon_fixed_store_arg2 <= debug0_wb_store_data;
          pmon_fixed_store_addr_hi[11:8] <= debug0_wb_mem_addr[31:28];
        end
        28'h70d0b6c: if (!pmon_fixed_store_seen[3]) begin
          pmon_fixed_store_seen[3] <= 1'b1;
          pmon_fixed_store_arg3 <= debug0_wb_store_data;
          pmon_fixed_store_addr_hi[15:12] <= debug0_wb_mem_addr[31:28];
        end
      endcase
    end
    if (linux_debug_status[13] && debug1_wb_mem_write) begin
      case (debug1_wb_mem_addr[27:0])
        28'h70d0b60: if (!pmon_fixed_store_seen[0]) begin
          pmon_fixed_store_seen[0] <= 1'b1;
          pmon_fixed_store_arg0 <= debug1_wb_store_data;
          pmon_fixed_store_addr_hi[3:0] <= debug1_wb_mem_addr[31:28];
        end
        28'h70d0b64: if (!pmon_fixed_store_seen[1]) begin
          pmon_fixed_store_seen[1] <= 1'b1;
          pmon_fixed_store_arg1 <= debug1_wb_store_data;
          pmon_fixed_store_addr_hi[7:4] <= debug1_wb_mem_addr[31:28];
        end
        28'h70d0b68: if (!pmon_fixed_store_seen[2]) begin
          pmon_fixed_store_seen[2] <= 1'b1;
          pmon_fixed_store_arg2 <= debug1_wb_store_data;
          pmon_fixed_store_addr_hi[11:8] <= debug1_wb_mem_addr[31:28];
        end
        28'h70d0b6c: if (!pmon_fixed_store_seen[3]) begin
          pmon_fixed_store_seen[3] <= 1'b1;
          pmon_fixed_store_arg3 <= debug1_wb_store_data;
          pmon_fixed_store_addr_hi[15:12] <= debug1_wb_mem_addr[31:28];
        end
      endcase
    end
    if (linux_debug_status[13] && debug0_wb_mem_read) begin
      case (debug0_wb_mem_addr[27:0])
        28'h70d0b60: if (!pmon_fixed_load_seen[0]) begin
          pmon_fixed_load_seen[0] <= 1'b1;
          pmon_fixed_load_arg0 <= debug_wb_rf_wdata;
          pmon_fixed_load_addr_hi[3:0] <= debug0_wb_mem_addr[31:28];
          pmon_fixed_load_dest[7:0] <=
              {2'd0, |debug_wb_rf_wen, debug_wb_rf_wnum};
        end
        28'h70d0b64: if (!pmon_fixed_load_seen[1]) begin
          pmon_fixed_load_seen[1] <= 1'b1;
          pmon_fixed_load_arg1 <= debug_wb_rf_wdata;
          pmon_fixed_load_addr_hi[7:4] <= debug0_wb_mem_addr[31:28];
          pmon_fixed_load_dest[15:8] <=
              {2'd0, |debug_wb_rf_wen, debug_wb_rf_wnum};
        end
        28'h70d0b68: if (!pmon_fixed_load_seen[2]) begin
          pmon_fixed_load_seen[2] <= 1'b1;
          pmon_fixed_load_arg2 <= debug_wb_rf_wdata;
          pmon_fixed_load_addr_hi[11:8] <= debug0_wb_mem_addr[31:28];
          pmon_fixed_load_dest[23:16] <=
              {2'd0, |debug_wb_rf_wen, debug_wb_rf_wnum};
        end
        28'h70d0b6c: if (!pmon_fixed_load_seen[3]) begin
          pmon_fixed_load_seen[3] <= 1'b1;
          pmon_fixed_load_arg3 <= debug_wb_rf_wdata;
          pmon_fixed_load_addr_hi[15:12] <= debug0_wb_mem_addr[31:28];
          pmon_fixed_load_dest[31:24] <=
              {2'd0, |debug_wb_rf_wen, debug_wb_rf_wnum};
        end
      endcase
    end
    if (linux_debug_status[13] && debug1_wb_mem_read) begin
      case (debug1_wb_mem_addr[27:0])
        28'h70d0b60: if (!pmon_fixed_load_seen[0]) begin
          pmon_fixed_load_seen[0] <= 1'b1;
          pmon_fixed_load_arg0 <= debug1_wb_rf_wdata_raw;
          pmon_fixed_load_addr_hi[3:0] <= debug1_wb_mem_addr[31:28];
          pmon_fixed_load_dest[7:0] <=
              {2'd0, |debug1_wb_rf_wen_raw, debug1_wb_rf_wnum_raw};
        end
        28'h70d0b64: if (!pmon_fixed_load_seen[1]) begin
          pmon_fixed_load_seen[1] <= 1'b1;
          pmon_fixed_load_arg1 <= debug1_wb_rf_wdata_raw;
          pmon_fixed_load_addr_hi[7:4] <= debug1_wb_mem_addr[31:28];
          pmon_fixed_load_dest[15:8] <=
              {2'd0, |debug1_wb_rf_wen_raw, debug1_wb_rf_wnum_raw};
        end
        28'h70d0b68: if (!pmon_fixed_load_seen[2]) begin
          pmon_fixed_load_seen[2] <= 1'b1;
          pmon_fixed_load_arg2 <= debug1_wb_rf_wdata_raw;
          pmon_fixed_load_addr_hi[11:8] <= debug1_wb_mem_addr[31:28];
          pmon_fixed_load_dest[23:16] <=
              {2'd0, |debug1_wb_rf_wen_raw, debug1_wb_rf_wnum_raw};
        end
        28'h70d0b6c: if (!pmon_fixed_load_seen[3]) begin
          pmon_fixed_load_seen[3] <= 1'b1;
          pmon_fixed_load_arg3 <= debug1_wb_rf_wdata_raw;
          pmon_fixed_load_addr_hi[15:12] <= debug1_wb_mem_addr[31:28];
          pmon_fixed_load_dest[31:24] <=
              {2'd0, |debug1_wb_rf_wen_raw, debug1_wb_rf_wnum_raw};
        end
      endcase
    end
    if (linux_debug_status[13] && debug_ertn && !pmon_restore_seen) begin
      pmon_restore_seen <= 1'b1;
      pmon_restore_gpr4 <= debug_gpr4;
      pmon_restore_gpr5 <= debug_gpr5;
      pmon_restore_gpr6 <= debug_gpr6;
      pmon_restore_gpr7 <= debug_gpr7;
    end
    // Capture one complete AXI write transaction.  The fixed PMON words share
    // a 32-byte line, so a dirty eviction is one AW plus eight W beats rather
    // than four single-beat writes.  AW and W remain independent: the visible
    // held AW address identifies even W-first traffic, while the beat counter
    // runs until WLAST and the B response closes the transaction.
    if (pmon_axi_aw_fixed_fire) begin
      case (pmon_axi_aw_visible_index)
        2'd0: begin pmon_axi_aw_seen[0] <= 1'b1;
          pmon_axi_aw_addr0 <= m0_awaddr; end
        2'd1: begin pmon_axi_aw_seen[1] <= 1'b1;
          pmon_axi_aw_addr1 <= m0_awaddr; end
        2'd2: begin pmon_axi_aw_seen[2] <= 1'b1;
          pmon_axi_aw_addr2 <= m0_awaddr; end
        2'd3: begin pmon_axi_aw_seen[3] <= 1'b1;
          pmon_axi_aw_addr3 <= m0_awaddr; end
      endcase
      pmon_axi_aw_len <= m0_awlen;
      pmon_axi_aw_burst <= m0_awburst;
      if (!(|pmon_axi_wlast_seen)) begin
        pmon_axi_aw_pending <= 1'b1;
        if (!(|pmon_axi_w_seen))
          pmon_axi_write_beat <= 3'd0;
      end
    end
    if (pmon_axi_w_has_index) begin
      pmon_axi_w_seen[pmon_axi_w_capture_beat] <= 1'b1;
      pmon_axi_wlast_seen[pmon_axi_w_capture_beat] <= m0_wlast;
      pmon_axi_aw_pending <= !m0_wlast;
      if (!m0_wlast)
        pmon_axi_write_beat <= pmon_axi_w_capture_beat + 1'b1;
      case (pmon_axi_w_capture_beat)
        3'd0: pmon_axi_w_data0 <= m0_wdata;
        3'd1: pmon_axi_w_data1 <= m0_wdata;
        3'd2: pmon_axi_w_data2 <= m0_wdata;
        3'd3: pmon_axi_w_data3 <= m0_wdata;
        3'd4: pmon_axi_w_data4 <= m0_wdata;
        3'd5: pmon_axi_w_data5 <= m0_wdata;
        3'd6: pmon_axi_w_data6 <= m0_wdata;
        3'd7: pmon_axi_w_data7 <= m0_wdata;
      endcase
    end
    if (m0_bvalid && m0_bready && m0_bid[3:0] == 4'd2
        && (|pmon_axi_aw_seen) && !pmon_axi_b_seen) begin
      pmon_axi_b_seen <= 1'b1;
      pmon_axi_bresp <= m0_bresp;
      pmon_axi_aw_pending <= 1'b0;
    end
    if (pmon_axi_ar_fixed_fire) begin
      case (pmon_axi_ar_fire_index)
        2'd0: begin pmon_axi_ar_seen[0] <= 1'b1;
          pmon_axi_ar_addr0 <= m0_araddr; end
        2'd1: begin pmon_axi_ar_seen[1] <= 1'b1;
          pmon_axi_ar_addr1 <= m0_araddr; end
        2'd2: begin pmon_axi_ar_seen[2] <= 1'b1;
          pmon_axi_ar_addr2 <= m0_araddr; end
        2'd3: begin pmon_axi_ar_seen[3] <= 1'b1;
          pmon_axi_ar_addr3 <= m0_araddr; end
      endcase
      pmon_axi_read_index <= pmon_axi_ar_fire_index;
      pmon_axi_ar_pending <= 1'b1;
    end
    if (pmon_axi_trace_active && m0_rvalid && m0_rready
        && m0_rid[3:0] == 4'd1
        && pmon_axi_ar_pending
        && !pmon_axi_r_seen[pmon_axi_read_index]) begin
      pmon_axi_r_seen[pmon_axi_read_index] <= 1'b1;
      pmon_axi_ar_pending <= 1'b0;
      case (pmon_axi_read_index)
        2'd0: pmon_axi_r_data0 <= m0_rdata;
        2'd1: pmon_axi_r_data1 <= m0_rdata;
        2'd2: pmon_axi_r_data2 <= m0_rdata;
        2'd3: pmon_axi_r_data3 <= m0_rdata;
      endcase
    end
  end
end

linux_debug_vio13 linux_debug_vio_i (
  .clk       (cpu_clk),
  .probe_in0 (linux_debug_snapshot),
  .probe_in1 (linux_first_exception_pc),
  .probe_in2 (linux_first_exception_inst),
  .probe_in3 (debug_crmd),
  .probe_in4 (debug_badv),
  .probe_in5 (debug_dmw0),
  .probe_in6 (debug_dmw1),
  .probe_in7 (debug_eentry),
  .probe_in8 (debug_tlbrentry),
  .probe_in9 (linux_kernel_arg0),
  .probe_in10(linux_kernel_arg1),
  .probe_in11(linux_kernel_arg2),
  .probe_in12(linux_kernel_arg3),
  .probe_in13(pmon_context_ptr),
  .probe_in14(pmon_context_arg0),
  .probe_in15(pmon_context_arg1),
  .probe_in16(pmon_context_arg2),
  .probe_in17(pmon_context_arg3),
  .probe_in18(pmon_fixed_access),
  .probe_in19(pmon_fixed_load_arg0),
  .probe_in20(pmon_fixed_load_arg1),
  .probe_in21(pmon_fixed_load_arg2),
  .probe_in22(pmon_fixed_load_arg3),
  .probe_in23(pmon_fixed_store_arg0),
  .probe_in24(pmon_fixed_store_arg1),
  .probe_in25(pmon_fixed_store_arg2),
  .probe_in26(pmon_fixed_store_arg3),
  .probe_in27(pmon_fixed_load_dest),
  .probe_in28(pmon_restore_gpr4),
  .probe_in29(pmon_restore_gpr5),
  .probe_in30(pmon_restore_gpr6),
  .probe_in31(pmon_restore_gpr7),
  .probe_in32({16'd0, pmon_fixed_store_addr_hi}),
  .probe_in33({16'd0, pmon_fixed_load_addr_hi}),
  .probe_in34(pmon_axi_access),
  .probe_in35(pmon_axi_aw_addr0),
  .probe_in36(pmon_axi_aw_addr1),
  .probe_in37(pmon_axi_aw_addr2),
  .probe_in38(pmon_axi_aw_addr3),
  .probe_in39(pmon_axi_w_data0),
  .probe_in40(pmon_axi_w_data1),
  .probe_in41(pmon_axi_w_data2),
  .probe_in42(pmon_axi_w_data3),
  .probe_in43(pmon_axi_ar_addr0),
  .probe_in44(pmon_axi_ar_addr1),
  .probe_in45(pmon_axi_ar_addr2),
  .probe_in46(pmon_axi_ar_addr3),
  .probe_in47(pmon_axi_r_data0),
  .probe_in48(pmon_axi_r_data1),
  .probe_in49(pmon_axi_r_data2),
  .probe_in50(pmon_axi_r_data3),
  .probe_in51(pmon_axi_w_data4),
  .probe_in52(pmon_axi_w_data5),
  .probe_in53(pmon_axi_w_data6),
  .probe_in54(pmon_axi_w_data7),
  .probe_in55(pmon_axi_write_meta)
);

//AXI_2x1_MUX
axi_2x1_mux u_axi_2x1_mux
(
    .INTERCONNECT_ACLK   (cpu_clk     ),
    .INTERCONNECT_ARESETN(resetn      ),
    .S00_AXI_ACLK        (cpu_clk     ),
    .S00_AXI_ARESET_OUT_N(            ),
    .S00_AXI_ARADDR      (m0_araddr   ),
    .S00_AXI_ARBURST     (m0_arburst  ),
    .S00_AXI_ARCACHE     (m0_arcache  ),
    .S00_AXI_ARID        (m0_arid[0]  ),
    .S00_AXI_ARLEN       (m0_arlen    ),
    .S00_AXI_ARLOCK      (m0_arlock[0]),
    .S00_AXI_ARPROT      (m0_arprot   ),
    .S00_AXI_ARQOS       (4'b0        ),
    .S00_AXI_ARREADY     (m0_arready  ),
    .S00_AXI_ARSIZE      (m0_arsize   ),
    .S00_AXI_ARVALID     (m0_arvalid  ),
    .S00_AXI_RDATA       (m0_rdata    ),
    .S00_AXI_RID         (mux_s0_rid  ),
    .S00_AXI_RLAST       (m0_rlast    ),
    .S00_AXI_RREADY      (m0_rready   ),
    .S00_AXI_RRESP       (m0_rresp    ),
    .S00_AXI_RVALID      (m0_rvalid   ),
    .S00_AXI_AWADDR      (`Lawaddr'b0 ),
    .S00_AXI_AWBURST     (`Lawburst'b0),
    .S00_AXI_AWCACHE     (`Lawcache'b0),
    .S00_AXI_AWID        (`LID'b0     ),
    .S00_AXI_AWLEN       (`Lawlen'b0  ),
    .S00_AXI_AWLOCK      (`Lawlock'b0 ),
    .S00_AXI_AWPROT      (`Lawprot'b0 ),
    .S00_AXI_AWQOS       (4'b0        ),
    .S00_AXI_AWREADY     (            ),
    .S00_AXI_AWSIZE      (`Lawsize'b0 ),
    .S00_AXI_AWVALID     (1'b0        ),
    .S00_AXI_WDATA       (`Lwdata'b0  ),
    .S00_AXI_WLAST       (1'b0        ),
    .S00_AXI_WREADY      (            ),
    .S00_AXI_WSTRB       (`Lwstrb'b0  ),
    .S00_AXI_WVALID      (1'b0        ),
    .S00_AXI_BID         (            ),
    .S00_AXI_BREADY      (1'b0        ),
    .S00_AXI_BRESP       (            ),
    .S00_AXI_BVALID      (            ),
   
    .S01_AXI_ACLK        (cpu_clk     ),
    .S01_AXI_ARESET_OUT_N(            ),
    .S01_AXI_ARADDR      (uart_araddr ),
    .S01_AXI_ARBURST     (uart_arburst),
    .S01_AXI_ARCACHE     (uart_arcache),
    .S01_AXI_ARID        (uart_arid[0]),
    .S01_AXI_ARLEN       (uart_arlen  ),
    .S01_AXI_ARLOCK      (uart_arlock[0]),
    .S01_AXI_ARPROT      (uart_arprot ),
    .S01_AXI_ARQOS       (4'b0        ),
    .S01_AXI_ARREADY     (uart_arready),
    .S01_AXI_ARSIZE      (uart_arsize ),
    .S01_AXI_ARVALID     (uart_arvalid),
    .S01_AXI_RDATA       (uart_rdata  ),
    .S01_AXI_RID         (mux_s1_rid  ),
    .S01_AXI_RLAST       (uart_rlast  ),
    .S01_AXI_RREADY      (uart_rready ),
    .S01_AXI_RRESP       (uart_rresp  ),
    .S01_AXI_RVALID      (uart_rvalid ),
    .S01_AXI_AWADDR      (`Lawaddr'b0 ),
    .S01_AXI_AWBURST     (`Lawburst'b0),
    .S01_AXI_AWCACHE     (`Lawcache'b0),
    .S01_AXI_AWID        (`LID'b0     ),
    .S01_AXI_AWLEN       (`Lawlen'b0  ),
    .S01_AXI_AWLOCK      (`Lawlock'b0 ),
    .S01_AXI_AWPROT      (`Lawprot'b0 ),
    .S01_AXI_AWQOS       (4'b0        ),
    .S01_AXI_AWREADY     (            ),
    .S01_AXI_AWSIZE      (`Lawsize'b0 ),
    .S01_AXI_AWVALID     (1'b0        ),
    .S01_AXI_WDATA       (`Lwdata'b0  ),
    .S01_AXI_WLAST       (1'b0        ),
    .S01_AXI_WREADY      (            ),
    .S01_AXI_WSTRB       (`Lwstrb'b0  ),
    .S01_AXI_WVALID      (1'b0        ),
    .S01_AXI_BID         (            ),
    .S01_AXI_BREADY      (1'b0        ),
    .S01_AXI_BRESP       (            ),
    .S01_AXI_BVALID      (            ),
    
    .M00_AXI_ACLK        (cpu_clk     ),
    .M00_AXI_ARESET_OUT_N(            ),
    .M00_AXI_ARADDR      (m1_araddr   ),
    .M00_AXI_ARBURST     (m1_arburst  ),
    .M00_AXI_ARCACHE     (m1_arcache  ),
    .M00_AXI_ARID        (mux_m_arid  ),
    .M00_AXI_ARLEN       (mux_m_arlen ),
    .M00_AXI_ARLOCK      (mux_m_arlock),
    .M00_AXI_ARPROT      (m1_arprot   ),
    .M00_AXI_ARQOS       (            ),
    .M00_AXI_ARREADY     (m1_arready  ),
    .M00_AXI_ARSIZE      (m1_arsize   ),
    .M00_AXI_ARVALID     (m1_arvalid  ),
    .M00_AXI_RDATA       (m1_rdata    ),
    .M00_AXI_RID         ({1'b0,m1_rid[3:0]} ),
    .M00_AXI_RLAST       (m1_rlast    ),
    .M00_AXI_RREADY      (m1_rready   ),
    .M00_AXI_RRESP       (m1_rresp    ),
    .M00_AXI_RVALID      (m1_rvalid   ),
    .M00_AXI_AWADDR      (            ),
    .M00_AXI_AWBURST     (            ),
    .M00_AXI_AWCACHE     (            ),
    .M00_AXI_AWID        (            ),
    .M00_AXI_AWLEN       (            ),
    .M00_AXI_AWLOCK      (            ),
    .M00_AXI_AWPROT      (            ),
    .M00_AXI_AWQOS       (            ),
    .M00_AXI_AWREADY     (1'b0        ),
    .M00_AXI_AWSIZE      (            ),
    .M00_AXI_AWVALID     (            ),
    .M00_AXI_WDATA       (            ),
    .M00_AXI_WLAST       (            ),
    .M00_AXI_WREADY      (1'b0        ),
    .M00_AXI_WSTRB       (            ),
    .M00_AXI_WVALID      (            ),
    .M00_AXI_BID         (5'b0        ),
    .M00_AXI_BREADY      (            ),
    .M00_AXI_BRESP       (`Lbresp'b0  ),
    .M00_AXI_BVALID      (1'b0        )
);

// cpu_axi asyn
axi_clock_converter_0 AXI_CLK_CONVERTER (
    .s_axi_awid       (m0_awid[3:0]       ),	
    .s_axi_awaddr     (m0_awaddr          ),
    .s_axi_awlen      (m0_awlen           ),
    .s_axi_awsize     (m0_awsize          ),
    .s_axi_awburst    (m0_awburst         ),
    .s_axi_awlock     (m0_awlock          ),
    .s_axi_awcache    (m0_awcache         ),
    .s_axi_awprot     (m0_awprot          ),
    .s_axi_awqos      (4'b0               ),
    .s_axi_awvalid    (m0_awvalid         ),
    .s_axi_awready    (m0_awready         ),
    .s_axi_wid        (m0_wid[3:0]        ),
    .s_axi_wdata      (m0_wdata           ),
    .s_axi_wstrb      (m0_wstrb           ),
    .s_axi_wlast      (m0_wlast           ),
    .s_axi_wvalid     (m0_wvalid          ),
    .s_axi_wready     (m0_wready          ),
    .s_axi_bid        (m0_bid[3:0]        ),
    .s_axi_bresp      (m0_bresp           ),
    .s_axi_bvalid     (m0_bvalid          ),
    .s_axi_bready     (m0_bready          ),
    .s_axi_arid       (m1_arid[3:0]       ),
    .s_axi_araddr     (m1_araddr          ),
    .s_axi_arlen      (m1_arlen           ),
    .s_axi_arsize     (m1_arsize          ),
    .s_axi_arburst    (m1_arburst         ),
    .s_axi_arlock     (m1_arlock          ),
    .s_axi_arcache    (m1_arcache         ),
    .s_axi_arprot     (m1_arprot          ),
    .s_axi_arqos      (4'b0               ),
    .s_axi_arvalid    (m1_arvalid         ),
    .s_axi_arready    (m1_arready         ),
    .s_axi_rid        (m1_rid[3:0]        ),
    .s_axi_rdata      (m1_rdata           ),
    .s_axi_rresp      (m1_rresp           ),
    .s_axi_rlast      (m1_rlast           ),
    .s_axi_rvalid     (m1_rvalid          ),
    .s_axi_rready     (m1_rready          ),

    .s_axi_aclk	      (cpu_clk            ),
    .s_axi_aresetn    (cpu_aresetn        ),
    
    .m_axi_awid       (m0_async_awid[3:0] ),
    .m_axi_awaddr     (m0_async_awaddr    ),
    .m_axi_awlen      (m0_async_awlen     ),
    .m_axi_awsize     (m0_async_awsize    ),
    .m_axi_awburst    (m0_async_awburst   ),
    .m_axi_awlock     (m0_async_awlock    ),
    .m_axi_awcache    (m0_async_awcache   ),
    .m_axi_awprot     (m0_async_awprot    ),
    .m_axi_awqos      (                   ),
    .m_axi_awvalid    (m0_async_awvalid   ),
    .m_axi_awready    (m0_async_awready   ),
    .m_axi_wid        (m0_async_wid[3:0]  ),
    .m_axi_wdata      (m0_async_wdata     ),
    .m_axi_wstrb      (m0_async_wstrb     ),
    .m_axi_wlast      (m0_async_wlast     ),
    .m_axi_wvalid     (m0_async_wvalid    ),
    .m_axi_wready     (m0_async_wready    ),
    .m_axi_bid        (m0_async_bid[3:0]  ),
    .m_axi_bresp      (m0_async_bresp     ),
    .m_axi_bvalid     (m0_async_bvalid    ),
    .m_axi_bready     (m0_async_bready    ),
    .m_axi_arid       (m0_async_arid[3:0] ),
    .m_axi_araddr     (m0_async_araddr    ),
    .m_axi_arlen      (m0_async_arlen     ),
    .m_axi_arsize     (m0_async_arsize    ),
    .m_axi_arburst    (m0_async_arburst   ),
    .m_axi_arlock     (m0_async_arlock    ),
    .m_axi_arcache    (m0_async_arcache   ),
    .m_axi_arprot     (m0_async_arprot    ),
    .m_axi_arqos      (                   ),
    .m_axi_arvalid    (m0_async_arvalid   ),
    .m_axi_arready    (m0_async_arready   ),
    .m_axi_rid        (m0_async_rid[3:0]  ),
    .m_axi_rdata      (m0_async_rdata     ),
    .m_axi_rresp      (m0_async_rresp     ),
    .m_axi_rlast      (m0_async_rlast     ),
    .m_axi_rvalid     (m0_async_rvalid    ),
    .m_axi_rready     (m0_async_rready    ),

    .m_axi_aclk	      (aclk               ),
    .m_axi_aresetn    (aresetn            )
);

// Split the NPU MMIO aperture before the legacy SoC decoder.  The router
// permits one outstanding read and one outstanding write, matching the
// OpenLA500 bridge used by this design.
axi_npu_mmio_router u_axi_npu_mmio_router (
    .aclk       (aclk),
    .aresetn    (aresetn),
    .s_awid     (m0_async_awid),
    .s_awaddr   (m0_async_awaddr),
    .s_awlen    ({4'b0, m0_async_awlen}),
    .s_awsize   (m0_async_awsize),
    .s_awburst  (m0_async_awburst),
    .s_awlock   (m0_async_awlock[0]),
    .s_awcache  (m0_async_awcache),
    .s_awprot   (m0_async_awprot),
    .s_awvalid  (m0_async_awvalid),
    .s_awready  (m0_async_awready),
    .s_wid      (m0_async_wid),
    .s_wdata    (m0_async_wdata),
    .s_wstrb    (m0_async_wstrb),
    .s_wlast    (m0_async_wlast),
    .s_wvalid   (m0_async_wvalid),
    .s_wready   (m0_async_wready),
    .s_bid      (m0_async_bid),
    .s_bresp    (m0_async_bresp),
    .s_bvalid   (m0_async_bvalid),
    .s_bready   (m0_async_bready),
    .s_arid     (m0_async_arid),
    .s_araddr   (m0_async_araddr),
    .s_arlen    ({4'b0, m0_async_arlen}),
    .s_arsize   (m0_async_arsize),
    .s_arburst  (m0_async_arburst),
    .s_arlock   (m0_async_arlock[0]),
    .s_arcache  (m0_async_arcache),
    .s_arprot   (m0_async_arprot),
    .s_arvalid  (m0_async_arvalid),
    .s_arready  (m0_async_arready),
    .s_rid      (m0_async_rid),
    .s_rdata    (m0_async_rdata),
    .s_rresp    (m0_async_rresp),
    .s_rlast    (m0_async_rlast),
    .s_rvalid   (m0_async_rvalid),
    .s_rready   (m0_async_rready),
    .m_awid     (soc_awid),
    .m_awaddr   (soc_awaddr),
    .m_awlen    (soc_awlen),
    .m_awsize   (soc_awsize),
    .m_awburst  (soc_awburst),
    .m_awlock   (soc_awlock),
    .m_awcache  (soc_awcache),
    .m_awprot   (soc_awprot),
    .m_awvalid  (soc_awvalid),
    .m_awready  (soc_awready),
    .m_wid      (soc_wid),
    .m_wdata    (soc_wdata),
    .m_wstrb    (soc_wstrb),
    .m_wlast    (soc_wlast),
    .m_wvalid   (soc_wvalid),
    .m_wready   (soc_wready),
    .m_bid      (soc_bid),
    .m_bresp    (soc_bresp),
    .m_bvalid   (soc_bvalid),
    .m_bready   (soc_bready),
    .m_arid     (soc_arid),
    .m_araddr   (soc_araddr),
    .m_arlen    (soc_arlen),
    .m_arsize   (soc_arsize),
    .m_arburst  (soc_arburst),
    .m_arlock   (soc_arlock),
    .m_arcache  (soc_arcache),
    .m_arprot   (soc_arprot),
    .m_arvalid  (soc_arvalid),
    .m_arready  (soc_arready),
    .m_rid      (soc_rid),
    .m_rdata    (soc_rdata),
    .m_rresp    (soc_rresp),
    .m_rlast    (soc_rlast),
    .m_rvalid   (soc_rvalid),
    .m_rready   (soc_rready),
    .n_awid     (npu_awid),
    .n_awaddr   (npu_awaddr),
    .n_awlen    (npu_awlen),
    .n_awsize   (npu_awsize),
    .n_awburst  (npu_awburst),
    .n_awlock   (npu_awlock),
    .n_awcache  (npu_awcache),
    .n_awprot   (npu_awprot),
    .n_awvalid  (npu_awvalid),
    .n_awready  (npu_awready),
    .n_wdata    (npu_wdata),
    .n_wstrb    (npu_wstrb),
    .n_wlast    (npu_wlast),
    .n_wvalid   (npu_wvalid),
    .n_wready   (npu_wready),
    .n_bid      (npu_bid),
    .n_bresp    (npu_bresp),
    .n_bvalid   (npu_bvalid),
    .n_bready   (npu_bready),
    .n_arid     (npu_arid),
    .n_araddr   (npu_araddr),
    .n_arlen    (npu_arlen),
    .n_arsize   (npu_arsize),
    .n_arburst  (npu_arburst),
    .n_arlock   (npu_arlock),
    .n_arcache  (npu_arcache),
    .n_arprot   (npu_arprot),
    .n_arvalid  (npu_arvalid),
    .n_arready  (npu_arready),
    .n_rid      (npu_rid),
    .n_rdata    (npu_rdata),
    .n_rresp    (npu_rresp),
    .n_rlast    (npu_rlast),
    .n_rvalid   (npu_rvalid),
    .n_rready   (npu_rready)
);

// AXI_MUX
axi_slave_mux AXI_SLAVE_MUX
(
.axi_s_aresetn     (aresetn              ),
.spi_boot          (1'b1                 ),  

.axi_s_awid        (soc_awid             ),
.axi_s_awaddr      (soc_awaddr           ),
.axi_s_awlen       (soc_awlen[3:0]       ),
.axi_s_awsize      (soc_awsize           ),
.axi_s_awburst     (soc_awburst          ),
.axi_s_awlock      ({1'b0, soc_awlock}   ),
.axi_s_awcache     (soc_awcache          ),
.axi_s_awprot      (soc_awprot           ),
.axi_s_awvalid     (soc_awvalid          ),
.axi_s_awready     (soc_awready          ),
.axi_s_wready      (soc_wready           ),
.axi_s_wid         (soc_wid              ),
.axi_s_wdata       (soc_wdata            ),
.axi_s_wstrb       (soc_wstrb            ),
.axi_s_wlast       (soc_wlast            ),
.axi_s_wvalid      (soc_wvalid           ),
.axi_s_bid         (soc_bid              ),
.axi_s_bresp       (soc_bresp            ),
.axi_s_bvalid      (soc_bvalid           ),
.axi_s_bready      (soc_bready           ),
.axi_s_arid        (soc_arid             ),
.axi_s_araddr      (soc_araddr           ),
.axi_s_arlen       (soc_arlen[3:0]       ),
.axi_s_arsize      (soc_arsize           ),
.axi_s_arburst     (soc_arburst          ),
.axi_s_arlock      ({1'b0, soc_arlock}   ),
.axi_s_arcache     (soc_arcache          ),
.axi_s_arprot      (soc_arprot           ),
.axi_s_arvalid     (soc_arvalid          ),
.axi_s_arready     (soc_arready          ),
.axi_s_rready      (soc_rready           ),
.axi_s_rid         (soc_rid              ),
.axi_s_rdata       (soc_rdata            ),
.axi_s_rresp       (soc_rresp            ),
.axi_s_rlast       (soc_rlast            ),
.axi_s_rvalid      (soc_rvalid           ),

.s0_awid           (s0_awid         ),
.s0_awaddr         (s0_awaddr       ),
.s0_awlen          (s0_awlen        ),
.s0_awsize         (s0_awsize       ),
.s0_awburst        (s0_awburst      ),
.s0_awlock         (s0_awlock       ),
.s0_awcache        (s0_awcache      ),
.s0_awprot         (s0_awprot       ),
.s0_awvalid        (s0_awvalid      ),
.s0_awready        (s0_awready      ),
.s0_wid            (s0_wid          ),
.s0_wdata          (s0_wdata        ),
.s0_wstrb          (s0_wstrb        ),
.s0_wlast          (s0_wlast        ),
.s0_wvalid         (s0_wvalid       ),
.s0_wready         (s0_wready       ),
.s0_bid            (s0_bid          ),
.s0_bresp          (s0_bresp        ),
.s0_bvalid         (s0_bvalid       ),
.s0_bready         (s0_bready       ),
.s0_arid           (s0_arid         ),
.s0_araddr         (s0_araddr       ),
.s0_arlen          (s0_arlen        ),
.s0_arsize         (s0_arsize       ),
.s0_arburst        (s0_arburst      ),
.s0_arlock         (s0_arlock       ),
.s0_arcache        (s0_arcache      ),
.s0_arprot         (s0_arprot       ),
.s0_arvalid        (s0_arvalid      ),
.s0_arready        (s0_arready      ),
.s0_rid            (s0_rid          ),
.s0_rdata          (s0_rdata        ),
.s0_rresp          (s0_rresp        ),
.s0_rlast          (s0_rlast        ),
.s0_rvalid         (s0_rvalid       ),
.s0_rready         (s0_rready       ),

.s1_awid           (spi_s_awid          ),
.s1_awaddr         (spi_s_awaddr        ),
.s1_awlen          (spi_s_awlen         ),
.s1_awsize         (spi_s_awsize        ),
.s1_awburst        (spi_s_awburst       ),
.s1_awlock         (spi_s_awlock        ),
.s1_awcache        (spi_s_awcache       ),
.s1_awprot         (spi_s_awprot        ),
.s1_awvalid        (spi_s_awvalid       ),
.s1_awready        (spi_s_awready       ),
.s1_wid            (spi_s_wid           ),
.s1_wdata          (spi_s_wdata         ),
.s1_wstrb          (spi_s_wstrb         ),
.s1_wlast          (spi_s_wlast         ),
.s1_wvalid         (spi_s_wvalid        ),
.s1_wready         (spi_s_wready        ),
.s1_bid            (spi_s_bid           ),
.s1_bresp          (spi_s_bresp         ),
.s1_bvalid         (spi_s_bvalid        ),
.s1_bready         (spi_s_bready        ),
.s1_arid           (spi_s_arid          ),
.s1_araddr         (spi_s_araddr        ),
.s1_arlen          (spi_s_arlen         ),
.s1_arsize         (spi_s_arsize        ),
.s1_arburst        (spi_s_arburst       ),
.s1_arlock         (spi_s_arlock        ),
.s1_arcache        (spi_s_arcache       ),
.s1_arprot         (spi_s_arprot        ),
.s1_arvalid        (spi_s_arvalid       ),
.s1_arready        (spi_s_arready       ),
.s1_rid            (spi_s_rid           ),
.s1_rdata          (spi_s_rdata         ),
.s1_rresp          (spi_s_rresp         ),
.s1_rlast          (spi_s_rlast         ),
.s1_rvalid         (spi_s_rvalid        ),
.s1_rready         (spi_s_rready        ),

.s2_awid           (apb_s_awid         ),
.s2_awaddr         (apb_s_awaddr       ),
.s2_awlen          (apb_s_awlen        ),
.s2_awsize         (apb_s_awsize       ),
.s2_awburst        (apb_s_awburst      ),
.s2_awlock         (apb_s_awlock       ),
.s2_awcache        (apb_s_awcache      ),
.s2_awprot         (apb_s_awprot       ),
.s2_awvalid        (apb_s_awvalid      ),
.s2_awready        (apb_s_awready      ),
.s2_wid            (apb_s_wid          ),
.s2_wdata          (apb_s_wdata        ),
.s2_wstrb          (apb_s_wstrb        ),
.s2_wlast          (apb_s_wlast        ),
.s2_wvalid         (apb_s_wvalid       ),
.s2_wready         (apb_s_wready       ),
.s2_bid            (apb_s_bid          ),
.s2_bresp          (apb_s_bresp        ),
.s2_bvalid         (apb_s_bvalid       ),
.s2_bready         (apb_s_bready       ),
.s2_arid           (apb_s_arid         ),
.s2_araddr         (apb_s_araddr       ),
.s2_arlen          (apb_s_arlen        ),
.s2_arsize         (apb_s_arsize       ),
.s2_arburst        (apb_s_arburst      ),
.s2_arlock         (apb_s_arlock       ),
.s2_arcache        (apb_s_arcache      ),
.s2_arprot         (apb_s_arprot       ),
.s2_arvalid        (apb_s_arvalid      ),
.s2_arready        (apb_s_arready      ),
.s2_rid            (apb_s_rid          ),
.s2_rdata          (apb_s_rdata        ),
.s2_rresp          (apb_s_rresp        ),
.s2_rlast          (apb_s_rlast        ),
.s2_rvalid         (apb_s_rvalid       ),
.s2_rready         (apb_s_rready       ),

.s3_awid           (conf_s_awid         ),
.s3_awaddr         (conf_s_awaddr       ),
.s3_awlen          (conf_s_awlen        ),
.s3_awsize         (conf_s_awsize       ),
.s3_awburst        (conf_s_awburst      ),
.s3_awlock         (conf_s_awlock       ),
.s3_awcache        (conf_s_awcache      ),
.s3_awprot         (conf_s_awprot       ),
.s3_awvalid        (conf_s_awvalid      ),
.s3_awready        (conf_s_awready      ),
.s3_wid            (conf_s_wid          ),
.s3_wdata          (conf_s_wdata        ),
.s3_wstrb          (conf_s_wstrb        ),
.s3_wlast          (conf_s_wlast        ),
.s3_wvalid         (conf_s_wvalid       ),
.s3_wready         (conf_s_wready       ),
.s3_bid            (conf_s_bid          ),
.s3_bresp          (conf_s_bresp        ),
.s3_bvalid         (conf_s_bvalid       ),
.s3_bready         (conf_s_bready       ),
.s3_arid           (conf_s_arid         ),
.s3_araddr         (conf_s_araddr       ),
.s3_arlen          (conf_s_arlen        ),
.s3_arsize         (conf_s_arsize       ),
.s3_arburst        (conf_s_arburst      ),
.s3_arlock         (conf_s_arlock       ),
.s3_arcache        (conf_s_arcache      ),
.s3_arprot         (conf_s_arprot       ),
.s3_arvalid        (conf_s_arvalid      ),
.s3_arready        (conf_s_arready      ),
.s3_rid            (conf_s_rid          ),
.s3_rdata          (conf_s_rdata        ),
.s3_rresp          (conf_s_rresp        ),
.s3_rlast          (conf_s_rlast        ),
.s3_rvalid         (conf_s_rvalid       ),
.s3_rready         (conf_s_rready       ),

.s4_awid           (mac_s_awid         ),
.s4_awaddr         (mac_s_awaddr       ),
.s4_awlen          (mac_s_awlen        ),
.s4_awsize         (mac_s_awsize       ),
.s4_awburst        (mac_s_awburst      ),
.s4_awlock         (mac_s_awlock       ),
.s4_awcache        (mac_s_awcache      ),
.s4_awprot         (mac_s_awprot       ),
.s4_awvalid        (mac_s_awvalid      ),
.s4_awready        (mac_s_awready      ),
.s4_wid            (mac_s_wid          ),
.s4_wdata          (mac_s_wdata        ),
.s4_wstrb          (mac_s_wstrb        ),
.s4_wlast          (mac_s_wlast        ),
.s4_wvalid         (mac_s_wvalid       ),
.s4_wready         (mac_s_wready       ),
.s4_bid            (mac_s_bid          ),
.s4_bresp          (mac_s_bresp        ),
.s4_bvalid         (mac_s_bvalid       ),
.s4_bready         (mac_s_bready       ),
.s4_arid           (mac_s_arid         ),
.s4_araddr         (mac_s_araddr       ),
.s4_arlen          (mac_s_arlen        ),
.s4_arsize         (mac_s_arsize       ),
.s4_arburst        (mac_s_arburst      ),
.s4_arlock         (mac_s_arlock       ),
.s4_arcache        (mac_s_arcache      ),
.s4_arprot         (mac_s_arprot       ),
.s4_arvalid        (mac_s_arvalid      ),
.s4_arready        (mac_s_arready      ),
.s4_rid            (mac_s_rid          ),
.s4_rdata          (mac_s_rdata        ),
.s4_rresp          (mac_s_rresp        ),
.s4_rlast          (mac_s_rlast        ),
.s4_rvalid         (mac_s_rvalid       ),
.s4_rready         (mac_s_rready       ),

.axi_s_aclk        (aclk                )
);

// Linux-visible NPU.  The integrated demonstration uses ABI-v2 DMA mode;
// the DMA master is firewalled to the DDR path by the arbiter below.
npu_rom_mmio #(
    .USE_AXI_DMA (1)
) u_npu (
    .aclk          (aclk),
    .aresetn       (aresetn),
    .s_axi_awid    (npu_awid),
    .s_axi_awaddr  (npu_awaddr),
    .s_axi_awlen   (npu_awlen),
    .s_axi_awsize  (npu_awsize),
    .s_axi_awburst (npu_awburst),
    .s_axi_awlock  (npu_awlock),
    .s_axi_awcache (npu_awcache),
    .s_axi_awprot  (npu_awprot),
    .s_axi_awvalid (npu_awvalid),
    .s_axi_awready (npu_awready),
    .s_axi_wdata   (npu_wdata),
    .s_axi_wstrb   (npu_wstrb),
    .s_axi_wlast   (npu_wlast),
    .s_axi_wvalid  (npu_wvalid),
    .s_axi_wready  (npu_wready),
    .s_axi_bid     (npu_bid),
    .s_axi_bresp   (npu_bresp),
    .s_axi_bvalid  (npu_bvalid),
    .s_axi_bready  (npu_bready),
    .s_axi_arid    (npu_arid),
    .s_axi_araddr  (npu_araddr),
    .s_axi_arlen   (npu_arlen),
    .s_axi_arsize  (npu_arsize),
    .s_axi_arburst (npu_arburst),
    .s_axi_arlock  (npu_arlock),
    .s_axi_arcache (npu_arcache),
    .s_axi_arprot  (npu_arprot),
    .s_axi_arvalid (npu_arvalid),
    .s_axi_arready (npu_arready),
    .s_axi_rid     (npu_rid),
    .s_axi_rdata   (npu_rdata),
    .s_axi_rresp   (npu_rresp),
    .s_axi_rlast   (npu_rlast),
    .s_axi_rvalid  (npu_rvalid),
    .s_axi_rready  (npu_rready),
    .m_axi_arid    (npu_dma_arid),
    .m_axi_araddr  (npu_dma_araddr),
    .m_axi_arlen   (npu_dma_arlen),
    .m_axi_arsize  (npu_dma_arsize),
    .m_axi_arburst (npu_dma_arburst),
    .m_axi_arlock  (npu_dma_arlock),
    .m_axi_arcache (npu_dma_arcache),
    .m_axi_arprot  (npu_dma_arprot),
    .m_axi_arvalid (npu_dma_arvalid),
    .m_axi_arready (npu_dma_arready),
    .m_axi_rid     (npu_dma_rid),
    .m_axi_rdata   (npu_dma_rdata),
    .m_axi_rresp   (npu_dma_rresp),
    .m_axi_rlast   (npu_dma_rlast),
    .m_axi_rvalid  (npu_dma_rvalid),
    .m_axi_rready  (npu_dma_rready),
    .m_axi_awid    (npu_dma_awid),
    .m_axi_awaddr  (npu_dma_awaddr),
    .m_axi_awlen   (npu_dma_awlen),
    .m_axi_awsize  (npu_dma_awsize),
    .m_axi_awburst (npu_dma_awburst),
    .m_axi_awlock  (npu_dma_awlock),
    .m_axi_awcache (npu_dma_awcache),
    .m_axi_awprot  (npu_dma_awprot),
    .m_axi_awvalid (npu_dma_awvalid),
    .m_axi_awready (npu_dma_awready),
    .m_axi_wid     (npu_dma_wid),
    .m_axi_wdata   (npu_dma_wdata),
    .m_axi_wstrb   (npu_dma_wstrb),
    .m_axi_wlast   (npu_dma_wlast),
    .m_axi_wvalid  (npu_dma_wvalid),
    .m_axi_wready  (npu_dma_wready),
    .m_axi_bid     (npu_dma_bid),
    .m_axi_bresp   (npu_dma_bresp),
    .m_axi_bvalid  (npu_dma_bvalid),
    .m_axi_bready  (npu_dma_bready),
    .irq           (npu_irq)
);

npu_axi_ram_arbiter #(
    .ID_WIDTH   (4),
    .ADDR_WIDTH (32),
    .DATA_WIDTH (32),
    .LEN_WIDTH  (8),
    .LOCK_WIDTH (1)
) u_npu_ddr_arbiter (
    .aclk        (aclk),
    .aresetn     (aresetn),
    .s0_awid     (s0_awid),
    .s0_awaddr   (s0_awaddr),
    .s0_awlen    ({4'b0, s0_awlen}),
    .s0_awsize   (s0_awsize),
    .s0_awburst  (s0_awburst),
    .s0_awlock   (s0_awlock[0]),
    .s0_awcache  (s0_awcache),
    .s0_awprot   (s0_awprot),
    .s0_awvalid  (s0_awvalid),
    .s0_awready  (s0_awready),
    .s0_wid      (s0_wid),
    .s0_wdata    (s0_wdata),
    .s0_wstrb    (s0_wstrb),
    .s0_wlast    (s0_wlast),
    .s0_wvalid   (s0_wvalid),
    .s0_wready   (s0_wready),
    .s0_bid      (s0_bid),
    .s0_bresp    (s0_bresp),
    .s0_bvalid   (s0_bvalid),
    .s0_bready   (s0_bready),
    .s0_arid     (s0_arid),
    .s0_araddr   (s0_araddr),
    .s0_arlen    ({4'b0, s0_arlen}),
    .s0_arsize   (s0_arsize),
    .s0_arburst  (s0_arburst),
    .s0_arlock   (s0_arlock[0]),
    .s0_arcache  (s0_arcache),
    .s0_arprot   (s0_arprot),
    .s0_arvalid  (s0_arvalid),
    .s0_arready  (s0_arready),
    .s0_rid      (s0_rid),
    .s0_rdata    (s0_rdata),
    .s0_rresp    (s0_rresp),
    .s0_rlast    (s0_rlast),
    .s0_rvalid   (s0_rvalid),
    .s0_rready   (s0_rready),
    .s1_awid     (npu_dma_awid),
    .s1_awaddr   (npu_dma_awaddr),
    .s1_awlen    (npu_dma_awlen),
    .s1_awsize   (npu_dma_awsize),
    .s1_awburst  (npu_dma_awburst),
    .s1_awlock   (npu_dma_awlock),
    .s1_awcache  (npu_dma_awcache),
    .s1_awprot   (npu_dma_awprot),
    .s1_awvalid  (npu_dma_awvalid),
    .s1_awready  (npu_dma_awready),
    .s1_wid      (npu_dma_wid),
    .s1_wdata    (npu_dma_wdata),
    .s1_wstrb    (npu_dma_wstrb),
    .s1_wlast    (npu_dma_wlast),
    .s1_wvalid   (npu_dma_wvalid),
    .s1_wready   (npu_dma_wready),
    .s1_bid      (npu_dma_bid),
    .s1_bresp    (npu_dma_bresp),
    .s1_bvalid   (npu_dma_bvalid),
    .s1_bready   (npu_dma_bready),
    .s1_arid     (npu_dma_arid),
    .s1_araddr   (npu_dma_araddr),
    .s1_arlen    (npu_dma_arlen),
    .s1_arsize   (npu_dma_arsize),
    .s1_arburst  (npu_dma_arburst),
    .s1_arlock   (npu_dma_arlock),
    .s1_arcache  (npu_dma_arcache),
    .s1_arprot   (npu_dma_arprot),
    .s1_arvalid  (npu_dma_arvalid),
    .s1_arready  (npu_dma_arready),
    .s1_rid      (npu_dma_rid),
    .s1_rdata    (npu_dma_rdata),
    .s1_rresp    (npu_dma_rresp),
    .s1_rlast    (npu_dma_rlast),
    .s1_rvalid   (npu_dma_rvalid),
    .s1_rready   (npu_dma_rready),
    .m_awid      (ddr_s0_awid),
    .m_awaddr    (ddr_s0_awaddr),
    .m_awlen     (ddr_s0_awlen),
    .m_awsize    (ddr_s0_awsize),
    .m_awburst   (ddr_s0_awburst),
    .m_awlock    (ddr_s0_awlock),
    .m_awcache   (ddr_s0_awcache),
    .m_awprot    (ddr_s0_awprot),
    .m_awvalid   (ddr_s0_awvalid),
    .m_awready   (ddr_s0_awready),
    .m_wid       (ddr_s0_wid),
    .m_wdata     (ddr_s0_wdata),
    .m_wstrb     (ddr_s0_wstrb),
    .m_wlast     (ddr_s0_wlast),
    .m_wvalid    (ddr_s0_wvalid),
    .m_wready    (ddr_s0_wready),
    .m_bid       (ddr_s0_bid),
    .m_bresp     (ddr_s0_bresp),
    .m_bvalid    (ddr_s0_bvalid),
    .m_bready    (ddr_s0_bready),
    .m_arid      (ddr_s0_arid),
    .m_araddr    (ddr_s0_araddr),
    .m_arlen     (ddr_s0_arlen),
    .m_arsize    (ddr_s0_arsize),
    .m_arburst   (ddr_s0_arburst),
    .m_arlock    (ddr_s0_arlock),
    .m_arcache  (ddr_s0_arcache),
    .m_arprot    (ddr_s0_arprot),
    .m_arvalid   (ddr_s0_arvalid),
    .m_arready   (ddr_s0_arready),
    .m_rid       (ddr_s0_rid),
    .m_rdata     (ddr_s0_rdata),
    .m_rresp     (ddr_s0_rresp),
    .m_rlast     (ddr_s0_rlast),
    .m_rvalid    (ddr_s0_rvalid),
    .m_rready    (ddr_s0_rready)
);

//SPI
spi_flash_ctrl SPI                    
(                                         
.aclk           (aclk              ),       
.aresetn        (aresetn           ),       
.spi_addr       (16'h1fe8          ),
.fast_startup   (1'b0              ),
.s_awid         (spi_s_awid        ),
.s_awaddr       (spi_s_awaddr      ),
.s_awlen        (spi_s_awlen       ),
.s_awsize       (spi_s_awsize      ),
.s_awburst      (spi_s_awburst     ),
.s_awlock       (spi_s_awlock      ),
.s_awcache      (spi_s_awcache     ),
.s_awprot       (spi_s_awprot      ),
.s_awvalid      (spi_s_awvalid     ),
.s_awready      (spi_s_awready     ),
.s_wready       (spi_s_wready      ),
.s_wid          (spi_s_wid         ),
.s_wdata        (spi_s_wdata       ),
.s_wstrb        (spi_s_wstrb       ),
.s_wlast        (spi_s_wlast       ),
.s_wvalid       (spi_s_wvalid      ),
.s_bid          (spi_s_bid         ),
.s_bresp        (spi_s_bresp       ),
.s_bvalid       (spi_s_bvalid      ),
.s_bready       (spi_s_bready      ),
.s_arid         (spi_s_arid        ),
.s_araddr       (spi_s_araddr      ),
.s_arlen        (spi_s_arlen       ),
.s_arsize       (spi_s_arsize      ),
.s_arburst      (spi_s_arburst     ),
.s_arlock       (spi_s_arlock      ),
.s_arcache      (spi_s_arcache     ),
.s_arprot       (spi_s_arprot      ),
.s_arvalid      (spi_s_arvalid     ),
.s_arready      (spi_s_arready     ),
.s_rready       (spi_s_rready      ),
.s_rid          (spi_s_rid         ),
.s_rdata        (spi_s_rdata       ),
.s_rresp        (spi_s_rresp       ),
.s_rlast        (spi_s_rlast       ),
.s_rvalid       (spi_s_rvalid      ),

.power_down_req (1'b0              ),
.power_down_ack (                  ),
.csn_o          (spi_csn_o         ),
.csn_en         (spi_csn_en        ), 
.sck_o          (spi_sck_o         ),
.sdo_i          (spi_sdo_i         ),
.sdo_o          (spi_sdo_o         ),
.sdo_en         (spi_sdo_en        ), // active low
.sdi_i          (spi_sdi_i         ),
.sdi_o          (spi_sdi_o         ),
.sdi_en         (spi_sdi_en        ),
.inta_o         (spi_inta_o        )
);

// Mechanical-arm UART register interface. A CPU write to 0x1fd0_e010
// transmits s_wdata[7:0] as one 9600-baud 8N1 byte on J15-4.
wire [7:0] arm_uart_data;
wire       arm_uart_valid;
wire       arm_uart_busy;

//confreg
confreg CONFREG(
.aclk              (aclk               ),       
.aresetn           (aresetn            ),       
.s_awid            (conf_s_awid        ),
.s_awaddr          (conf_s_awaddr      ),
.s_awlen           (conf_s_awlen       ),
.s_awsize          (conf_s_awsize      ),
.s_awburst         (conf_s_awburst     ),
.s_awlock          (conf_s_awlock[0]   ),
.s_awcache         (conf_s_awcache     ),
.s_awprot          (conf_s_awprot      ),
.s_awvalid         (conf_s_awvalid     ),
.s_awready         (conf_s_awready     ),
.s_wready          (conf_s_wready      ),
.s_wid             (conf_s_wid         ),
.s_wdata           (conf_s_wdata       ),
.s_wstrb           (conf_s_wstrb       ),
.s_wlast           (conf_s_wlast       ),
.s_wvalid          (conf_s_wvalid      ),
.s_bid             (conf_s_bid         ),
.s_bresp           (conf_s_bresp       ),
.s_bvalid          (conf_s_bvalid      ),
.s_bready          (conf_s_bready      ),
.s_arid            (conf_s_arid        ),
.s_araddr          (conf_s_araddr      ),
.s_arlen           (conf_s_arlen       ),
.s_arsize          (conf_s_arsize      ),
.s_arburst         (conf_s_arburst     ),
.s_arlock          (conf_s_arlock[0]   ),
.s_arcache         (conf_s_arcache     ),
.s_arprot          (conf_s_arprot      ),
.s_arvalid         (conf_s_arvalid     ),
.s_arready         (conf_s_arready     ),
.s_rready          (conf_s_rready      ),
.s_rid             (conf_s_rid         ),
.s_rdata           (conf_s_rdata       ),
.s_rresp           (conf_s_rresp       ),
.s_rlast           (conf_s_rlast       ),
.s_rvalid          (conf_s_rvalid      ),

//dma
.order_addr_reg    (order_addr_in      ),
.write_dma_end     (write_dma_end      ),
.finish_read_order (finish_read_order  ),

//cr00~cr07
.cr00              (cr00        ),
.cr01              (cr01        ),
.cr02              (cr02        ),
.cr03              (cr03        ),
.cr04              (cr04        ),
.cr05              (cr05        ),
.cr06              (cr06        ),
.cr07              (cr07        ),

.led               (soc_led     ),
.led_rg0           (led_rg0     ),
.led_rg1           (led_rg1     ),
.num_csn           (num_csn     ),
.num_a_g           (num_a_g     ),
.switch            (switch      ),
.btn_key_col       (btn_key_col ),
.btn_key_row       (btn_key_row ),
 .btn_step          (btn_step       ),
 .arm_uart_data     (arm_uart_data  ),
 .arm_uart_valid    (arm_uart_valid ),
 .arm_uart_busy     (arm_uart_busy  ),
 .camera_control    (camera_control          ),
 .camera_status     (camera_status_aclk      ),
 .camera_frame_count(camera_frame_count_aclk ),
 .camera_s2mm_status(camera_s2mm_status_aclk ),
 .camera_mm2s_status(camera_mm2s_status_aclk ),
 .lcd_control       (lcd_control              ),
 .lcd_frame_addr    (lcd_frame_addr           ),
 .lcd_status        (lcd_status_aclk          )
);

arm_uart_tx #(
    .CLK_FREQ_HZ (33000000),
    .BAUD_RATE   (9600)
) u_arm_uart_tx (
    .clk      (aclk),
    .resetn   (aresetn),
    .data     (arm_uart_data),
    .valid    (arm_uart_valid),
    .busy     (arm_uart_busy),
    .tx       (ARM_UART_TX)
);

// The board LEDs are active low, and the XDC maps led[15:11] to physical
// LED1..LED5.  All five indicators below therefore light on success.
// LED1=ID OK, LED2=initialization done, LED3=PCLK, LED4=VSYNC,
// LED5=one complete BRAM camera frame captured. LED6/7 report VDMA setup and
// a completed DDR frame. LED8 is a temporary VGA frame-sync heartbeat.
reg       vga_vsync_d;
reg [4:0] vga_frame_div;
reg       vga_heartbeat;

always @(posedge cpu_clk or negedge resetn) begin
    if (!resetn) begin
        vga_vsync_d   <= 1'b1;
        vga_frame_div <= 5'd0;
        vga_heartbeat <= 1'b0;
    end
    else begin
        vga_vsync_d <= vga_vsync;
        if (vga_vsync_d && !vga_vsync) begin
            if (vga_frame_div == 5'd29) begin
                vga_frame_div <= 5'd0;
                vga_heartbeat <= ~vga_heartbeat;
            end
            else
                vga_frame_div <= vga_frame_div + 5'd1;
        end
    end
end

// Fixed S2MM status display; no diagnostic switch is needed. Physical LED1
// shows DMASR bit0, LED2 bit1, ..., LED23 bit14; LED24=status valid.
wire [31:0] cam_vdma_selected_status = cam_vdma_s2mm_status;
assign led = {~cam_vdma_selected_status[0],
              ~cam_vdma_selected_status[1],
              ~cam_vdma_selected_status[2],
              ~cam_vdma_selected_status[3],
              ~cam_vdma_selected_status[4],
              ~cam_vdma_selected_status[5],
              ~cam_vdma_selected_status[6],
              ~cam_vdma_selected_status[7],
              ~cam_vdma_selected_status[8],
              ~cam_vdma_selected_status[9],
              ~cam_vdma_selected_status[10],
              ~cam_vdma_selected_status[11],
              ~cam_vdma_selected_status[12],
              ~cam_vdma_selected_status[13],
              ~cam_vdma_selected_status[14],
              ~cam_vdma_status_valid};

//MAC top
ethernet_top ETHERNET_TOP(

    .hclk       (aclk   ),
    .hrst_      (aresetn),      
    //axi master
    .mawid_o    (mac_m_awid    ),
    .mawaddr_o  (mac_m_awaddr  ),
    .mawlen_o   (mac_m_awlen   ),
    .mawsize_o  (mac_m_awsize  ),
    .mawburst_o (mac_m_awburst ),
    .mawlock_o  (mac_m_awlock  ),
    .mawcache_o (mac_m_awcache ),
    .mawprot_o  (mac_m_awprot  ),
    .mawvalid_o (mac_m_awvalid ),
    .mawready_i (mac_m_awready ),
    .mwid_o     (mac_m_wid     ),
    .mwdata_o   (mac_m_wdata   ),
    .mwstrb_o   (mac_m_wstrb   ),
    .mwlast_o   (mac_m_wlast   ),
    .mwvalid_o  (mac_m_wvalid  ),
    .mwready_i  (mac_m_wready  ),
    .mbid_i     (mac_m_bid     ),
    .mbresp_i   (mac_m_bresp   ),
    .mbvalid_i  (mac_m_bvalid  ),
    .mbready_o  (mac_m_bready  ),
    .marid_o    (mac_m_arid    ),
    .maraddr_o  (mac_m_araddr  ),
    .marlen_o   (mac_m_arlen   ),
    .marsize_o  (mac_m_arsize  ),
    .marburst_o (mac_m_arburst ),
    .marlock_o  (mac_m_arlock  ),
    .marcache_o (mac_m_arcache ),
    .marprot_o  (mac_m_arprot  ),
    .marvalid_o (mac_m_arvalid ),
    .marready_i (mac_m_arready ),
    .mrid_i     (mac_m_rid     ),
    .mrdata_i   (mac_m_rdata   ),
    .mrresp_i   (mac_m_rresp   ),
    .mrlast_i   (mac_m_rlast   ),
    .mrvalid_i  (mac_m_rvalid  ),
    .mrready_o  (mac_m_rready  ),
    //axi slaver
    .sawid_i    (mac_s_awid    ),
    .sawaddr_i  (mac_s_awaddr  ),
    .sawlen_i   (mac_s_awlen   ),
    .sawsize_i  (mac_s_awsize  ),
    .sawburst_i (mac_s_awburst ),
    .sawlock_i  (mac_s_awlock  ),
    .sawcache_i (mac_s_awcache ),
    .sawprot_i  (mac_s_awprot  ),
    .sawvalid_i (mac_s_awvalid ),
    .sawready_o (mac_s_awready ),   
    .swid_i     (mac_s_wid     ),
    .swdata_i   (mac_s_wdata   ),
    .swstrb_i   (mac_s_wstrb   ),
    .swlast_i   (mac_s_wlast   ),
    .swvalid_i  (mac_s_wvalid  ),
    .swready_o  (mac_s_wready  ),
    .sbid_o     (mac_s_bid     ),
    .sbresp_o   (mac_s_bresp   ),
    .sbvalid_o  (mac_s_bvalid  ),
    .sbready_i  (mac_s_bready  ),
    .sarid_i    (mac_s_arid    ),
    .saraddr_i  (mac_s_araddr  ),
    .sarlen_i   (mac_s_arlen   ),
    .sarsize_i  (mac_s_arsize  ),
    .sarburst_i (mac_s_arburst ),
    .sarlock_i  (mac_s_arlock  ),
    .sarcache_i (mac_s_arcache ),
    .sarprot_i  (mac_s_arprot  ),
    .sarvalid_i (mac_s_arvalid ),
    .sarready_o (mac_s_arready ),
    .srid_o     (mac_s_rid     ),
    .srdata_o   (mac_s_rdata   ),
    .srresp_o   (mac_s_rresp   ),
    .srlast_o   (mac_s_rlast   ),
    .srvalid_o  (mac_s_rvalid  ),
    .srready_i  (mac_s_rready  ),                 

    .interrupt_0 (mac_int),
 
    // I/O pad interface signals
    //TX
    .mtxclk_0    (mtxclk_0 ),     
    .mtxen_0     (mtxen_0  ),      
    .mtxd_0      (mtxd_0   ),       
    .mtxerr_0    (mtxerr_0 ),
    //RX
    .mrxclk_0    (mrxclk_0 ),      
    .mrxdv_0     (mrxdv_0  ),     
    .mrxd_0      (mrxd_0   ),        
    .mrxerr_0    (mrxerr_0 ),
    .mcoll_0     (mcoll_0  ),
    .mcrs_0      (mcrs_0   ),
    // MIIM
    .mdc_0       (mdc_0    ),
    .md_i_0      (md_i_0   ),
    .md_o_0      (md_o_0   ),       
    .md_oe_0     (md_oe_0  )

);

//ddr3
wire   c1_sys_clk_i;
wire   c1_clk_ref_i;
wire   c1_sys_rst_i;
wire   c1_calib_done;
wire   c1_clk0;
wire   c1_rst0;
wire        ddr_aresetn;
reg         interconnect_aresetn;
wire        vga_clk;

clk_pll_33  clk_pll_33
 (
  // Clock out ports
  .clk_out1(cpu_clk),    //40MHz
  .clk_out2(uncore_clk), //approximately 33MHz
  .clk_out3(vga_clk),    //50MHz; VGA modules divide by two
 // Clock in ports
  .clk_in1(clk)        //100MHz
 );

clk_wiz_0  clk_pll_1
(
    .clk_out1(c1_clk_ref_i),  //200MHz
    .clk_in1(clk)             //100MHz
);

assign c1_sys_clk_i      = clk;
assign c1_sys_rst_i      = resetn;
assign aclk              = uncore_clk;
//assign aclk              = c1_clk0;
// Reset to the AXI shim
reg c1_calib_done_0;
reg c1_calib_done_1;
reg c1_rst0_0;
reg c1_rst0_1;
reg interconnect_aresetn_0;
/*always @(posedge aclk)
begin
    c1_calib_done_0 <= c1_calib_done;
    c1_calib_done_1 <= c1_calib_done_0;
    c1_rst0_0       <= c1_rst0;
    c1_rst0_1       <= c1_rst0_0;

    interconnect_aresetn_0 <= ~c1_rst0_1 && c1_calib_done_1;
    interconnect_aresetn   <= interconnect_aresetn_0 ;
end*/
always @(posedge c1_clk0)
begin
    interconnect_aresetn <= ~c1_rst0 && c1_calib_done;
end

// AXI 5x1: the original CPU/MAC/DMA ports plus VDMA S2MM/MM2S.
camera_ddr_interconnect mig_axi_interconnect (
    .INTERCONNECT_ACLK    (c1_clk0             ),
    .INTERCONNECT_ARESETN (interconnect_aresetn),
    .S00_AXI_ARESET_OUT_N (aresetn             ),
    .S00_AXI_ACLK         (aclk                ),
    .S00_AXI_AWID         (ddr_s0_awid         ),
    .S00_AXI_AWADDR       (ddr_s0_awaddr       ),
    .S00_AXI_AWLEN        (ddr_s0_awlen        ),
    .S00_AXI_AWSIZE       (ddr_s0_awsize       ),
    .S00_AXI_AWBURST      (ddr_s0_awburst      ),
    .S00_AXI_AWLOCK       (ddr_s0_awlock       ),
    .S00_AXI_AWCACHE      (ddr_s0_awcache      ),
    .S00_AXI_AWPROT       (ddr_s0_awprot       ),
    .S00_AXI_AWQOS        (4'b0                ),
    .S00_AXI_AWVALID      (ddr_s0_awvalid      ),
    .S00_AXI_AWREADY      (ddr_s0_awready      ),
    .S00_AXI_WDATA        (ddr_s0_wdata        ),
    .S00_AXI_WSTRB        (ddr_s0_wstrb        ),
    .S00_AXI_WLAST        (ddr_s0_wlast        ),
    .S00_AXI_WVALID       (ddr_s0_wvalid       ),
    .S00_AXI_WREADY       (ddr_s0_wready       ),
    .S00_AXI_BID          (ddr_s0_bid          ),
    .S00_AXI_BRESP        (ddr_s0_bresp        ),
    .S00_AXI_BVALID       (ddr_s0_bvalid       ),
    .S00_AXI_BREADY       (ddr_s0_bready       ),
    .S00_AXI_ARID         (ddr_s0_arid         ),
    .S00_AXI_ARADDR       (ddr_s0_araddr       ),
    .S00_AXI_ARLEN        (ddr_s0_arlen        ),
    .S00_AXI_ARSIZE       (ddr_s0_arsize       ),
    .S00_AXI_ARBURST      (ddr_s0_arburst      ),
    .S00_AXI_ARLOCK       (ddr_s0_arlock       ),
    .S00_AXI_ARCACHE      (ddr_s0_arcache      ),
    .S00_AXI_ARPROT       (ddr_s0_arprot       ),
    .S00_AXI_ARQOS        (4'b0                ),
    .S00_AXI_ARVALID      (ddr_s0_arvalid      ),
    .S00_AXI_ARREADY      (ddr_s0_arready      ),
    .S00_AXI_RID          (ddr_s0_rid          ),
    .S00_AXI_RDATA        (ddr_s0_rdata        ),
    .S00_AXI_RRESP        (ddr_s0_rresp        ),
    .S00_AXI_RLAST        (ddr_s0_rlast        ),
    .S00_AXI_RVALID       (ddr_s0_rvalid       ),
    .S00_AXI_RREADY       (ddr_s0_rready       ),

    .S01_AXI_ARESET_OUT_N (                    ),
    .S01_AXI_ACLK         (aclk                ),
    .S01_AXI_AWID         (mac_m_awid[3:0]     ),
    .S01_AXI_AWADDR       (mac_m_awaddr        ),
    .S01_AXI_AWLEN        ({4'b0,mac_m_awlen}  ),
    .S01_AXI_AWSIZE       (mac_m_awsize        ),
    .S01_AXI_AWBURST      (mac_m_awburst       ),
    .S01_AXI_AWLOCK       (mac_m_awlock[0:0]   ),
    .S01_AXI_AWCACHE      (mac_m_awcache       ),
    .S01_AXI_AWPROT       (mac_m_awprot        ),
    .S01_AXI_AWQOS        (4'b0                ),
    .S01_AXI_AWVALID      (mac_m_awvalid       ),
    .S01_AXI_AWREADY      (mac_m_awready       ),
    .S01_AXI_WDATA        (mac_m_wdata         ),
    .S01_AXI_WSTRB        (mac_m_wstrb         ),
    .S01_AXI_WLAST        (mac_m_wlast         ),
    .S01_AXI_WVALID       (mac_m_wvalid        ),
    .S01_AXI_WREADY       (mac_m_wready        ),
    .S01_AXI_BID          (mac_m_bid[3:0]      ),
    .S01_AXI_BRESP        (mac_m_bresp         ),
    .S01_AXI_BVALID       (mac_m_bvalid        ),
    .S01_AXI_BREADY       (mac_m_bready        ),
    .S01_AXI_ARID         (mac_m_arid[3:0]     ),
    .S01_AXI_ARADDR       (mac_m_araddr        ),
    .S01_AXI_ARLEN        ({4'b0,mac_m_arlen}  ),
    .S01_AXI_ARSIZE       (mac_m_arsize        ),
    .S01_AXI_ARBURST      (mac_m_arburst       ),
    .S01_AXI_ARLOCK       (mac_m_arlock[0:0]   ),
    .S01_AXI_ARCACHE      (mac_m_arcache       ),
    .S01_AXI_ARPROT       (mac_m_arprot        ),
    .S01_AXI_ARQOS        (4'b0                ),
    .S01_AXI_ARVALID      (mac_m_arvalid       ),
    .S01_AXI_ARREADY      (mac_m_arready       ),
    .S01_AXI_RID          (mac_m_rid[3:0]      ),
    .S01_AXI_RDATA        (mac_m_rdata         ),
    .S01_AXI_RRESP        (mac_m_rresp         ),
    .S01_AXI_RLAST        (mac_m_rlast         ),
    .S01_AXI_RVALID       (mac_m_rvalid        ),
    .S01_AXI_RREADY       (mac_m_rready        ),

    .S02_AXI_ARESET_OUT_N (                    ),
    .S02_AXI_ACLK         (aclk                ),
    .S02_AXI_AWID         (dma0_awid           ),
    .S02_AXI_AWADDR       (dma0_awaddr         ),
    .S02_AXI_AWLEN        ({4'd0,dma0_awlen}   ),
    .S02_AXI_AWSIZE       (dma0_awsize         ),
    .S02_AXI_AWBURST      (dma0_awburst        ),
    .S02_AXI_AWLOCK       (dma0_awlock[0:0]    ),
    .S02_AXI_AWCACHE      (dma0_awcache        ),
    .S02_AXI_AWPROT       (dma0_awprot         ),
    .S02_AXI_AWQOS        (4'b0                ),
    .S02_AXI_AWVALID      (dma0_awvalid        ),
    .S02_AXI_AWREADY      (dma0_awready        ),
    .S02_AXI_WDATA        (dma0_wdata          ),
    .S02_AXI_WSTRB        (dma0_wstrb          ),
    .S02_AXI_WLAST        (dma0_wlast          ),
    .S02_AXI_WVALID       (dma0_wvalid         ),
    .S02_AXI_WREADY       (dma0_wready         ),
    .S02_AXI_BID          (dma0_bid            ),
    .S02_AXI_BRESP        (dma0_bresp          ),
    .S02_AXI_BVALID       (dma0_bvalid         ),
    .S02_AXI_BREADY       (dma0_bready         ),
    .S02_AXI_ARID         (dma0_arid           ),
    .S02_AXI_ARADDR       (dma0_araddr         ),
    .S02_AXI_ARLEN        ({4'd0,dma0_arlen}   ),
    .S02_AXI_ARSIZE       (dma0_arsize         ),
    .S02_AXI_ARBURST      (dma0_arburst        ),
    .S02_AXI_ARLOCK       (dma0_arlock[0:0]    ),
    .S02_AXI_ARCACHE      (dma0_arcache        ),
    .S02_AXI_ARPROT       (dma0_arprot         ),
    .S02_AXI_ARQOS        (4'b0                ),
    .S02_AXI_ARVALID      (dma0_arvalid        ),
    .S02_AXI_ARREADY      (dma0_arready        ),
    .S02_AXI_RID          (dma0_rid            ),
    .S02_AXI_RDATA        (dma0_rdata          ),
    .S02_AXI_RRESP        (dma0_rresp          ),
    .S02_AXI_RLAST        (dma0_rlast          ),
    .S02_AXI_RVALID       (dma0_rvalid         ),
    .S02_AXI_RREADY       (dma0_rready         ),

    .S03_AXI_ARESET_OUT_N (                    ),
    .S03_AXI_ACLK         (c1_clk0             ),
    .S03_AXI_AWID         (4'd0                ),
    .S03_AXI_AWADDR       (cam_s2mm_awaddr     ),
    .S03_AXI_AWLEN        (cam_s2mm_awlen      ),
    .S03_AXI_AWSIZE       (cam_s2mm_awsize     ),
    .S03_AXI_AWBURST      (cam_s2mm_awburst    ),
    .S03_AXI_AWLOCK       (1'b0                ),
    .S03_AXI_AWCACHE      (cam_s2mm_awcache    ),
    .S03_AXI_AWPROT       (cam_s2mm_awprot     ),
    .S03_AXI_AWQOS        (4'd0                ),
    .S03_AXI_AWVALID      (cam_s2mm_awvalid    ),
    .S03_AXI_AWREADY      (cam_s2mm_awready    ),
    .S03_AXI_WDATA        (cam_s2mm_wdata      ),
    .S03_AXI_WSTRB        (cam_s2mm_wstrb      ),
    .S03_AXI_WLAST        (cam_s2mm_wlast      ),
    .S03_AXI_WVALID       (cam_s2mm_wvalid     ),
    .S03_AXI_WREADY       (cam_s2mm_wready     ),
    .S03_AXI_BID          (                    ),
    .S03_AXI_BRESP        (cam_s2mm_bresp      ),
    .S03_AXI_BVALID       (cam_s2mm_bvalid     ),
    .S03_AXI_BREADY       (cam_s2mm_bready     ),
    .S03_AXI_ARID         (4'd0                ),
    .S03_AXI_ARADDR       (32'd0               ),
    .S03_AXI_ARLEN        (8'd0                ),
    .S03_AXI_ARSIZE       (3'd0                ),
    .S03_AXI_ARBURST      (2'd0                ),
    .S03_AXI_ARLOCK       (1'b0                ),
    .S03_AXI_ARCACHE      (4'd0                ),
    .S03_AXI_ARPROT       (3'd0                ),
    .S03_AXI_ARQOS        (4'd0                ),
    .S03_AXI_ARVALID      (1'b0                ),
    .S03_AXI_ARREADY      (                    ),
    .S03_AXI_RID          (                    ),
    .S03_AXI_RDATA        (                    ),
    .S03_AXI_RRESP        (                    ),
    .S03_AXI_RLAST        (                    ),
    .S03_AXI_RVALID       (                    ),
    .S03_AXI_RREADY       (1'b0                ),

    .S04_AXI_ARESET_OUT_N (                    ),
    .S04_AXI_ACLK         (c1_clk0             ),
    .S04_AXI_AWID         (4'd0                ),
    .S04_AXI_AWADDR       (32'd0               ),
    .S04_AXI_AWLEN        (8'd0                ),
    .S04_AXI_AWSIZE       (3'd0                ),
    .S04_AXI_AWBURST      (2'd0                ),
    .S04_AXI_AWLOCK       (1'b0                ),
    .S04_AXI_AWCACHE      (4'd0                ),
    .S04_AXI_AWPROT       (3'd0                ),
    .S04_AXI_AWQOS        (4'd0                ),
    .S04_AXI_AWVALID      (1'b0                ),
    .S04_AXI_AWREADY      (                    ),
    .S04_AXI_WDATA        (32'd0               ),
    .S04_AXI_WSTRB        (4'd0                ),
    .S04_AXI_WLAST        (1'b0                ),
    .S04_AXI_WVALID       (1'b0                ),
    .S04_AXI_WREADY       (                    ),
    .S04_AXI_BID          (                    ),
    .S04_AXI_BRESP        (                    ),
    .S04_AXI_BVALID       (                    ),
    .S04_AXI_BREADY       (1'b0                ),
    .S04_AXI_ARID         (4'd0                ),
    .S04_AXI_ARADDR       (s04_araddr          ),
    .S04_AXI_ARLEN        (s04_arlen           ),
    .S04_AXI_ARSIZE       (s04_arsize          ),
    .S04_AXI_ARBURST      (s04_arburst         ),
    .S04_AXI_ARLOCK       (1'b0                ),
    .S04_AXI_ARCACHE      (s04_arcache         ),
    .S04_AXI_ARPROT       (s04_arprot          ),
    .S04_AXI_ARQOS        (4'd0                ),
    .S04_AXI_ARVALID      (s04_arvalid         ),
    .S04_AXI_ARREADY      (s04_arready         ),
    .S04_AXI_RID          (                    ),
    .S04_AXI_RDATA        (s04_rdata           ),
    .S04_AXI_RRESP        (s04_rresp           ),
    .S04_AXI_RLAST        (s04_rlast           ),
    .S04_AXI_RVALID       (s04_rvalid          ),
    .S04_AXI_RREADY       (s04_rready          ),

    .M00_AXI_ARESET_OUT_N (ddr_aresetn         ),
    .M00_AXI_ACLK         (c1_clk0             ),
    .M00_AXI_AWID         (mig_awid            ),
    .M00_AXI_AWADDR       (mig_awaddr          ),
    .M00_AXI_AWLEN        ({mig_awlen}         ),
    .M00_AXI_AWSIZE       (mig_awsize          ),
    .M00_AXI_AWBURST      (mig_awburst         ),
    .M00_AXI_AWLOCK       (mig_awlock[0:0]     ),
    .M00_AXI_AWCACHE      (mig_awcache         ),
    .M00_AXI_AWPROT       (mig_awprot          ),
    .M00_AXI_AWQOS        (                    ),
    .M00_AXI_AWVALID      (mig_awvalid         ),
    .M00_AXI_AWREADY      (mig_awready         ),
    .M00_AXI_WDATA        (mig_wdata           ),
    .M00_AXI_WSTRB        (mig_wstrb           ),
    .M00_AXI_WLAST        (mig_wlast           ),
    .M00_AXI_WVALID       (mig_wvalid          ),
    .M00_AXI_WREADY       (mig_wready          ),
    .M00_AXI_BID          (mig_bid             ),
    .M00_AXI_BRESP        (mig_bresp           ),
    .M00_AXI_BVALID       (mig_bvalid          ),
    .M00_AXI_BREADY       (mig_bready          ),
    .M00_AXI_ARID         (mig_arid            ),
    .M00_AXI_ARADDR       (mig_araddr          ),
    .M00_AXI_ARLEN        ({mig_arlen}         ),
    .M00_AXI_ARSIZE       (mig_arsize          ),
    .M00_AXI_ARBURST      (mig_arburst         ),
    .M00_AXI_ARLOCK       (mig_arlock[0:0]     ),
    .M00_AXI_ARCACHE      (mig_arcache         ),
    .M00_AXI_ARPROT       (mig_arprot          ),
    .M00_AXI_ARQOS        (                    ),
    .M00_AXI_ARVALID      (mig_arvalid         ),
    .M00_AXI_ARREADY      (mig_arready         ),
    .M00_AXI_RID          (mig_rid             ),
    .M00_AXI_RDATA        (mig_rdata           ),
    .M00_AXI_RRESP        (mig_rresp           ),
    .M00_AXI_RLAST        (mig_rlast           ),
    .M00_AXI_RVALID       (mig_rvalid          ),
    .M00_AXI_RREADY       (mig_rready          )
);
//ddr3 controller
mig_axi_32 mig_axi (
    // Inouts
    .ddr3_dq             (ddr3_dq         ),  
    .ddr3_dqs_p          (ddr3_dqs_p      ),    // for X16 parts 
    .ddr3_dqs_n          (ddr3_dqs_n      ),  // for X16 parts
    // Outputs
    .ddr3_addr           (ddr3_addr       ),  
    .ddr3_ba             (ddr3_ba         ),
    .ddr3_ras_n          (ddr3_ras_n      ),                        
    .ddr3_cas_n          (ddr3_cas_n      ),                        
    .ddr3_we_n           (ddr3_we_n       ),                          
    .ddr3_reset_n        (ddr3_reset_n    ),
    .ddr3_ck_p           (ddr3_ck_p       ),                          
    .ddr3_ck_n           (ddr3_ck_n       ),       
    .ddr3_cke            (ddr3_cke        ),                          
    .ddr3_dm             (ddr3_dm         ),
    .ddr3_odt            (ddr3_odt        ),
    
		.ui_clk              (c1_clk0         ),
    .ui_clk_sync_rst     (c1_rst0         ),
	.device_temp         (                ),
 
    .sys_clk_i           (c1_sys_clk_i    ),
    .sys_rst             (c1_sys_rst_i    ),                        
    .init_calib_complete (c1_calib_done   ),
    .clk_ref_i           (c1_clk_ref_i    ),
    .mmcm_locked         (                ),
	
	.app_sr_active       (                ),
    .app_ref_ack         (                ),
    .app_zq_ack          (                ),
    .app_sr_req          (1'b0            ),
    .app_ref_req         (1'b0            ),
    .app_zq_req          (1'b0            ),
    
    .aresetn             (ddr_aresetn     ),
    .s_axi_awid          (mig_awid        ),
    .s_axi_awaddr        (mig_awaddr[26:0]),
    .s_axi_awlen         ({mig_awlen}     ),
    .s_axi_awsize        (mig_awsize      ),
    .s_axi_awburst       (mig_awburst     ),
    .s_axi_awlock        (mig_awlock[0:0] ),
    .s_axi_awcache       (mig_awcache     ),
    .s_axi_awprot        (mig_awprot      ),
    .s_axi_awqos         (4'b0            ),
    .s_axi_awvalid       (mig_awvalid     ),
    .s_axi_awready       (mig_awready     ),
    .s_axi_wdata         (mig_wdata       ),
    .s_axi_wstrb         (mig_wstrb       ),
    .s_axi_wlast         (mig_wlast       ),
    .s_axi_wvalid        (mig_wvalid      ),
    .s_axi_wready        (mig_wready      ),
    .s_axi_bid           (mig_bid         ),
    .s_axi_bresp         (mig_bresp       ),
    .s_axi_bvalid        (mig_bvalid      ),
    .s_axi_bready        (mig_bready      ),
    .s_axi_arid          (mig_arid        ),
    .s_axi_araddr        (mig_araddr[26:0]),
    .s_axi_arlen         ({mig_arlen}     ),
    .s_axi_arsize        (mig_arsize      ),
    .s_axi_arburst       (mig_arburst     ),
    .s_axi_arlock        (mig_arlock[0:0] ),
    .s_axi_arcache       (mig_arcache     ),
    .s_axi_arprot        (mig_arprot      ),
    .s_axi_arqos         (4'b0            ),
    .s_axi_arvalid       (mig_arvalid     ),
    .s_axi_arready       (mig_arready     ),
    .s_axi_rid           (mig_rid         ),
    .s_axi_rdata         (mig_rdata       ),
    .s_axi_rresp         (mig_rresp       ),
    .s_axi_rlast         (mig_rlast       ),
    .s_axi_rvalid        (mig_rvalid      ),
    .s_axi_rready        (mig_rready      )
);

//DMA
dma_master DMA_MASTER0
(
.clk                (aclk                   ),
.rst_n		        (aresetn                ),
.awid               (dma0_awid              ), 
.awaddr             (dma0_awaddr            ), 
.awlen              (dma0_awlen             ), 
.awsize             (dma0_awsize            ), 
.awburst            (dma0_awburst           ),
.awlock             (dma0_awlock            ), 
.awcache            (dma0_awcache           ), 
.awprot             (dma0_awprot            ), 
.awvalid            (dma0_awvalid           ), 
.awready            (dma0_awready           ), 
.wid                (dma0_wid               ), 
.wdata              (dma0_wdata             ), 
.wstrb              (dma0_wstrb             ), 
.wlast              (dma0_wlast             ), 
.wvalid             (dma0_wvalid            ), 
.wready             (dma0_wready            ),
.bid                (dma0_bid               ), 
.bresp              (dma0_bresp             ), 
.bvalid             (dma0_bvalid            ), 
.bready             (dma0_bready            ),
.arid               (dma0_arid              ), 
.araddr             (dma0_araddr            ), 
.arlen              (dma0_arlen             ), 
.arsize             (dma0_arsize            ), 
.arburst            (dma0_arburst           ), 
.arlock             (dma0_arlock            ), 
.arcache            (dma0_arcache           ),
.arprot             (dma0_arprot            ),
.arvalid            (dma0_arvalid           ), 
.arready            (dma0_arready           ),
.rid                (dma0_rid               ), 
.rdata              (dma0_rdata             ), 
.rresp              (dma0_rresp             ),
.rlast              (dma0_rlast             ), 
.rvalid             (dma0_rvalid            ), 
.rready             (dma0_rready            ),

.dma_int            (dma_int                ), 
.dma_req_in         (dma_req                ), 
.dma_ack_out        (dma_ack                ), 

.dma_gnt            (dma0_gnt               ),
.apb_rw             (apb_rw_dma0            ),
.apb_psel           (apb_psel_dma0          ),
.apb_valid_req      (apb_start_dma0	        ),
.apb_penable        (apb_penable_dma0       ),
.apb_addr           (apb_addr_dma0          ),
.apb_wdata          (apb_wdata_dma0         ),
.apb_rdata          (apb_rdata_dma0         ),

.order_addr_in      (order_addr_in          ),
.write_dma_end      (write_dma_end          ),
.finish_read_order  (finish_read_order      ) 
);

//AXI2APB
axi2apb_misc APB_DEV 
(
.clk                (aclk               ),
.rst_n              (aresetn            ),

.axi_s_awid         (apb_s_awid         ),
.axi_s_awaddr       (apb_s_awaddr       ),
.axi_s_awlen        (apb_s_awlen        ),
.axi_s_awsize       (apb_s_awsize       ),
.axi_s_awburst      (apb_s_awburst      ),
.axi_s_awlock       (apb_s_awlock       ),
.axi_s_awcache      (apb_s_awcache      ),
.axi_s_awprot       (apb_s_awprot       ),
.axi_s_awvalid      (apb_s_awvalid      ),
.axi_s_awready      (apb_s_awready      ),
.axi_s_wid          (apb_s_wid          ),
.axi_s_wdata        (apb_s_wdata        ),
.axi_s_wstrb        (apb_s_wstrb        ),
.axi_s_wlast        (apb_s_wlast        ),
.axi_s_wvalid       (apb_s_wvalid       ),
.axi_s_wready       (apb_s_wready       ),
.axi_s_bid          (apb_s_bid          ),
.axi_s_bresp        (apb_s_bresp        ),
.axi_s_bvalid       (apb_s_bvalid       ),
.axi_s_bready       (apb_s_bready       ),
.axi_s_arid         (apb_s_arid         ),
.axi_s_araddr       (apb_s_araddr       ),
.axi_s_arlen        (apb_s_arlen        ),
.axi_s_arsize       (apb_s_arsize       ),
.axi_s_arburst      (apb_s_arburst      ),
.axi_s_arlock       (apb_s_arlock       ),
.axi_s_arcache      (apb_s_arcache      ),
.axi_s_arprot       (apb_s_arprot       ),
.axi_s_arvalid      (apb_s_arvalid      ),
.axi_s_arready      (apb_s_arready      ),
.axi_s_rid          (apb_s_rid          ),
.axi_s_rdata        (apb_s_rdata        ),
.axi_s_rresp        (apb_s_rresp        ),
.axi_s_rlast        (apb_s_rlast        ),
.axi_s_rvalid       (apb_s_rvalid       ),
.axi_s_rready       (apb_s_rready       ),

.apb_rw_dma         (apb_rw_dma0        ),
.apb_psel_dma       (apb_psel_dma0      ),
.apb_enab_dma       (apb_penable_dma0   ),
.apb_addr_dma       (apb_addr_dma0[19:0]),
.apb_valid_dma      (apb_start_dma0     ),
.apb_wdata_dma      (apb_wdata_dma0     ),
.apb_rdata_dma      (apb_rdata_dma0     ),
.apb_ready_dma      (                   ), //output, no use
.dma_grant          (dma0_gnt           ),

.dma_req_o          (dma_req            ),
.dma_ack_i          (dma_ack            ),

//UART0
.uart0_txd_i        (uart0_txd_i      ),
.uart0_txd_o        (uart0_txd_o      ),
.uart0_txd_oe       (uart0_txd_oe     ),
.uart0_rxd_i        (uart0_rxd_i      ),
.uart0_rxd_o        (uart0_rxd_o      ),
.uart0_rxd_oe       (uart0_rxd_oe     ),
.uart0_rts_o        (uart0_rts_o      ),
.uart0_dtr_o        (uart0_dtr_o      ),
.uart0_cts_i        (uart0_cts_i      ),
.uart0_dsr_i        (uart0_dsr_i      ),
.uart0_dcd_i        (uart0_dcd_i      ),
.uart0_ri_i         (uart0_ri_i       ),
.uart0_int          (uart0_int        ),

.nand_type          (2'h2             ),  //1Gbit
.nand_cle           (nand_cle         ),
.nand_ale           (nand_ale         ),
.nand_rdy           (nand_rdy         ),
.nand_rd            (nand_rd          ),
.nand_ce            (nand_ce          ),
.nand_wr            (nand_wr          ),
.nand_dat_i         (nand_dat_i       ),
.nand_dat_o         (nand_dat_o       ),
.nand_dat_oe        (nand_dat_oe      ),

.nand_int           (nand_int         )
);

// Linux controls camera DMA through camera_control[0].  The camera is held in
// reset after power-on and no physical switch is required for normal use.
(* ASYNC_REG = "TRUE" *) reg [1:0] cam_dma_sw_enable_sync;
always @(posedge c1_clk0 or negedge interconnect_aresetn) begin
    if (!interconnect_aresetn) begin
        cam_dma_sw_enable_sync <= 2'b00;
    end
    else begin
        cam_dma_sw_enable_sync <= {cam_dma_sw_enable_sync[0], camera_control[0]};
    end
end
wire cam_dma_resetn = interconnect_aresetn &&
                       cam_dma_sw_enable_sync[1];

// -------------------------------------------------------------------------
// Linux-controlled LCD DDR frame path
// -------------------------------------------------------------------------
// Control registers are generated in the 33 MHz CONFREG domain and sampled
// into both consumers.  Bit 8 is a toggle, not a pulse, so no request can be
// lost while crossing clock domains.
(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_mode_c1_meta;
(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_mode_c1_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_start_c1_sync;
(* ASYNC_REG = "TRUE" *) reg [31:0] lcd_addr_c1_meta;
(* ASYNC_REG = "TRUE" *) reg [31:0] lcd_addr_c1_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_init_c1_sync;

(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_mode_pix_meta;
(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_mode_pix_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] lcd_start_pix_sync;

reg        lcd_start_consumed_c1;
reg        lcd_start_pending_c1;
reg        lcd_reader_start_c1;
reg        lcd_s04_owner;
reg [7:0]  cam_read_outstanding;
reg        lcd_reader_done_sticky;

wire lcd_init_done;
wire lcd_frame_busy;
wire lcd_frame_done_sticky;
wire lcd_underflow_sticky;
wire lcd_reader_busy;
wire lcd_reader_done;
wire lcd_reader_error;

always @(posedge c1_clk0 or negedge interconnect_aresetn) begin
    if (!interconnect_aresetn) begin
        lcd_mode_c1_meta       <= 2'b00;
        lcd_mode_c1_sync       <= 2'b00;
        lcd_start_c1_sync      <= 2'b00;
        lcd_addr_c1_meta       <= 32'h0780_0000;
        lcd_addr_c1_sync       <= 32'h0780_0000;
        lcd_init_c1_sync       <= 2'b00;
        lcd_start_consumed_c1  <= 1'b0;
        lcd_start_pending_c1   <= 1'b0;
        lcd_reader_start_c1    <= 1'b0;
        lcd_reader_done_sticky <= 1'b0;
    end else begin
        lcd_mode_c1_meta  <= lcd_control[1:0];
        lcd_mode_c1_sync  <= lcd_mode_c1_meta;
        lcd_start_c1_sync <= {lcd_start_c1_sync[0], lcd_control[8]};
        lcd_addr_c1_meta  <= lcd_frame_addr;
        lcd_addr_c1_sync  <= lcd_addr_c1_meta;
        lcd_init_c1_sync  <= {lcd_init_c1_sync[0], lcd_init_done};
        lcd_reader_start_c1 <= 1'b0;

        if (lcd_start_c1_sync[1] != lcd_start_consumed_c1) begin
            lcd_start_consumed_c1 <= lcd_start_c1_sync[1];
            lcd_start_pending_c1  <= 1'b1;
            lcd_reader_done_sticky <= 1'b0;
        end

        if (lcd_start_pending_c1 && lcd_s04_owner &&
            lcd_init_c1_sync[1] && !lcd_reader_busy) begin
            lcd_reader_start_c1  <= 1'b1;
            lcd_start_pending_c1 <= 1'b0;
        end

        if (lcd_reader_done)
            lcd_reader_done_sticky <= 1'b1;
    end
end

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        lcd_mode_pix_meta  <= 2'b00;
        lcd_mode_pix_sync  <= 2'b00;
        lcd_start_pix_sync <= 2'b00;
    end else begin
        lcd_mode_pix_meta  <= lcd_control[1:0];
        lcd_mode_pix_sync  <= lcd_mode_pix_meta;
        lcd_start_pix_sync <= {lcd_start_pix_sync[0], lcd_control[8]};
    end
end

wire lcd_photo_request = (lcd_mode_c1_sync == 2'b01) && !cam_dma_resetn;
wire cam_ar_accept = !lcd_s04_owner && !lcd_photo_request &&
                     cam_mm2s_arvalid && s04_arready;
wire cam_r_finish  = !lcd_s04_owner && s04_rvalid && s04_rready && s04_rlast;

// Count accepted camera bursts.  When Linux requests the LCD port, new camera
// AR transactions are stopped and any already accepted responses are drained
// before ownership changes.  This prevents the first LCD pixels from being a
// tail fragment of the previous VGA frame.
always @(posedge c1_clk0 or negedge interconnect_aresetn) begin
    if (!interconnect_aresetn) begin
        cam_read_outstanding <= 8'd0;
        lcd_s04_owner        <= 1'b0;
    end else begin
        case ({cam_ar_accept, cam_r_finish})
            2'b10: cam_read_outstanding <= cam_read_outstanding + 8'd1;
            2'b01: cam_read_outstanding <= cam_read_outstanding - 8'd1;
            default: cam_read_outstanding <= cam_read_outstanding;
        endcase

        if (!lcd_s04_owner) begin
            if (lcd_photo_request && (cam_read_outstanding == 0))
                lcd_s04_owner <= 1'b1;
        end else if (!lcd_photo_request && !lcd_reader_busy) begin
            lcd_s04_owner <= 1'b0;
        end
    end
end

assign s04_araddr   = lcd_s04_owner ? lcd_mm2s_araddr   : cam_mm2s_araddr;
assign s04_arlen    = lcd_s04_owner ? lcd_mm2s_arlen    : cam_mm2s_arlen;
assign s04_arsize   = lcd_s04_owner ? lcd_mm2s_arsize   : cam_mm2s_arsize;
assign s04_arburst  = lcd_s04_owner ? lcd_mm2s_arburst  : cam_mm2s_arburst;
assign s04_arprot   = lcd_s04_owner ? lcd_mm2s_arprot   : cam_mm2s_arprot;
assign s04_arcache  = lcd_s04_owner ? lcd_mm2s_arcache  : cam_mm2s_arcache;
assign s04_arvalid  = lcd_s04_owner ? lcd_mm2s_arvalid  :
                      (lcd_photo_request ? 1'b0 : cam_mm2s_arvalid);
assign s04_rready   = lcd_s04_owner ? lcd_mm2s_rready :
                      (lcd_photo_request ? 1'b1 : cam_mm2s_rready);

assign cam_mm2s_arready = (!lcd_s04_owner && !lcd_photo_request) ? s04_arready : 1'b0;
assign cam_mm2s_rdata   = s04_rdata;
assign cam_mm2s_rresp   = s04_rresp;
assign cam_mm2s_rlast   = s04_rlast;
assign cam_mm2s_rvalid  = !lcd_s04_owner && !lcd_photo_request && s04_rvalid;

assign lcd_mm2s_arready = lcd_s04_owner ? s04_arready : 1'b0;
assign lcd_mm2s_rdata   = s04_rdata;
assign lcd_mm2s_rresp   = s04_rresp;
assign lcd_mm2s_rlast   = s04_rlast;
assign lcd_mm2s_rvalid  = lcd_s04_owner && s04_rvalid;

lcd_axi_frame_reader #(
    .WORD_COUNT  (192000),
    .BURST_WORDS (64)
) u_lcd_axi_frame_reader (
    .clk           (c1_clk0),
    .resetn        (interconnect_aresetn),
    .start         (lcd_reader_start_c1),
    .frame_addr    (lcd_addr_c1_sync),
    .busy          (lcd_reader_busy),
    .done          (lcd_reader_done),
    .error         (lcd_reader_error),
    .m_axi_araddr  (lcd_mm2s_araddr),
    .m_axi_arlen   (lcd_mm2s_arlen),
    .m_axi_arsize  (lcd_mm2s_arsize),
    .m_axi_arburst (lcd_mm2s_arburst),
    .m_axi_arprot  (lcd_mm2s_arprot),
    .m_axi_arcache (lcd_mm2s_arcache),
    .m_axi_arvalid (lcd_mm2s_arvalid),
    .m_axi_arready (lcd_mm2s_arready),
    .m_axi_rdata   (lcd_mm2s_rdata),
    .m_axi_rresp   (lcd_mm2s_rresp),
    .m_axi_rlast   (lcd_mm2s_rlast),
    .m_axi_rvalid  (lcd_mm2s_rvalid),
    .m_axi_rready  (lcd_mm2s_rready),
    .fifo_wr_en    (lcd_fifo_wr_en),
    .fifo_wr_data  (lcd_fifo_wr_data),
    .fifo_full     (lcd_fifo_full)
);

lcd_async_fifo32 #(
    .ADDR_BITS (9)
) u_lcd_async_fifo32 (
    .wr_clk      (c1_clk0),
    .wr_resetn   (interconnect_aresetn),
    .wr_en       (lcd_fifo_wr_en),
    .wr_data     (lcd_fifo_wr_data),
    .wr_full     (lcd_fifo_full),
    .rd_clk      (clk),
    .rd_resetn   (resetn),
    .rd_en       (lcd_fifo_rd_en),
    .rd_data     (lcd_fifo_rd_data),
    .rd_valid    (lcd_fifo_rd_valid),
    .rd_empty    (lcd_fifo_empty)
);

lcd_nt35510_display #(
    .CLK_HZ (100000000),
    .H_RES  (800),
    .V_RES  (480)
) u_lcd_nt35510_display (
    .clk                (clk),
    .resetn             (resetn),
    .switch_mode        (switch[7:6]),
    .software_mode      (lcd_mode_pix_sync),
    .photo_start_toggle (lcd_start_pix_sync[1]),
    .fifo_rd_data       (lcd_fifo_rd_data),
    .fifo_rd_valid      (lcd_fifo_rd_valid),
    .fifo_empty         (lcd_fifo_empty),
    .fifo_rd_en         (lcd_fifo_rd_en),
    .lcd_db             (LCD_DB),
    .lcd_cs_n           (LCD_CS_N),
    .lcd_rs             (LCD_RS),
    .lcd_wr_n           (LCD_WR_N),
    .lcd_rd_n           (LCD_RD_N),
    .lcd_rst_n          (LCD_RST_N),
    .lcd_bl             (LCD_BL),
    .init_done          (lcd_init_done),
    .frame_busy         (lcd_frame_busy),
    .frame_done_sticky  (lcd_frame_done_sticky),
    .underflow_sticky   (lcd_underflow_sticky)
);

// Continuous double-buffered camera DDR path.  The test stream is compiled in
// for simulation, but hard-disabled in hardware.
camera_vdma_subsystem u_camera_vdma_subsystem (
    .ddr_clk        (c1_clk0),
    .vga_axis_clk   (vga_clk),
    .resetn         (cam_dma_resetn),
    .camera_ready   (cam_init_done),
    .cam_pclk       (cam_pclk),
    .cam_vsync      (cam_vsync),
    .cam_href       (cam_href),
    .cam_d          (cam_d),
    .test_stream_enable(1'b0),
    .s2mm_awaddr    (cam_s2mm_awaddr),
    .s2mm_awlen     (cam_s2mm_awlen),
    .s2mm_awsize    (cam_s2mm_awsize),
    .s2mm_awburst   (cam_s2mm_awburst),
    .s2mm_awprot    (cam_s2mm_awprot),
    .s2mm_awcache   (cam_s2mm_awcache),
    .s2mm_awvalid   (cam_s2mm_awvalid),
    .s2mm_awready   (cam_s2mm_awready),
    .s2mm_wdata     (cam_s2mm_wdata),
    .s2mm_wstrb     (cam_s2mm_wstrb),
    .s2mm_wlast     (cam_s2mm_wlast),
    .s2mm_wvalid    (cam_s2mm_wvalid),
    .s2mm_wready    (cam_s2mm_wready),
    .s2mm_bresp     (cam_s2mm_bresp),
    .s2mm_bvalid    (cam_s2mm_bvalid),
    .s2mm_bready    (cam_s2mm_bready),
    .mm2s_araddr    (cam_mm2s_araddr),
    .mm2s_arlen     (cam_mm2s_arlen),
    .mm2s_arsize    (cam_mm2s_arsize),
    .mm2s_arburst   (cam_mm2s_arburst),
    .mm2s_arprot    (cam_mm2s_arprot),
    .mm2s_arcache   (cam_mm2s_arcache),
    .mm2s_arvalid   (cam_mm2s_arvalid),
    .mm2s_arready   (cam_mm2s_arready),
    .mm2s_rdata     (cam_mm2s_rdata),
    .mm2s_rresp     (cam_mm2s_rresp),
    .mm2s_rlast     (cam_mm2s_rlast),
    .mm2s_rvalid    (cam_mm2s_rvalid),
    .mm2s_rready    (cam_mm2s_rready),
    .video_tdata    (cam_video_tdata),
    .video_tkeep    (cam_video_tkeep),
    .video_tuser    (cam_video_tuser),
    .video_tlast    (cam_video_tlast),
    .video_tvalid   (cam_video_tvalid),
    .video_tready   (cam_video_tready),
    .init_done      (cam_vdma_init_done),
    .init_error     (cam_vdma_init_error),
    .fifo_full      (cam_vdma_fifo_full),
    .fifo_overflow  (cam_vdma_fifo_overflow),
    .frame_seen     (cam_vdma_frame_seen),
    .mm2s_status    (cam_vdma_mm2s_status),
    .s2mm_status    (cam_vdma_s2mm_status),
    .status_valid   (cam_vdma_status_valid),
    .debug_state    (cam_vdma_debug_state),
    .debug_write_index(cam_vdma_debug_index)
);

// OV5640 colour diagnostic: switch[1:0] selects normal/bars/RB-swap/gray;
// switch[2] selects the sensor test pattern on the next reset.
wire [3:0] cam_bram_vga_r;
wire [3:0] cam_bram_vga_g;
wire [3:0] cam_bram_vga_b;
wire       cam_bram_vga_hsync;
wire       cam_bram_vga_vsync;

wire [3:0] cam_ddr_vga_r;
wire [3:0] cam_ddr_vga_g;
wire [3:0] cam_ddr_vga_b;
wire       cam_ddr_vga_hsync;
wire       cam_ddr_vga_vsync;


// Passive Linux UART console mirror and independent 80x30 text VGA mode.
// Linux camera_control selects it; the physical serial output remains live.
wire [3:0] terminal_vga_r;
wire [3:0] terminal_vga_g;
wire [3:0] terminal_vga_b;
wire       terminal_vga_hsync;
wire       terminal_vga_vsync;

uart_vga_terminal #(
    .CLOCK_HZ(50000000),
    .BAUD    (115200)
) u_uart_vga_terminal (
    .clk_50m   (vga_clk),
    .resetn    (resetn),
    .uart_txd  (uart0_txd_i),
    .vga_r     (terminal_vga_r),
    .vga_g     (terminal_vga_g),
    .vga_b     (terminal_vga_b),
    .vga_hsync (terminal_vga_hsync),
    .vga_vsync (terminal_vga_vsync)
);

ov5640_vga_bridge u_ov5640_vga_bridge (
    .clk_50m       (vga_clk),
    .resetn        (resetn),
    .capture_enable(cam_init_done),
    .cam_pclk      (cam_pclk),
    .cam_vsync     (cam_vsync),
    .cam_href      (cam_href),
    .cam_d         (cam_d),
    // Temporary diagnostic: force FPGA-generated colour bars.
    .display_mode  (switch[1:0]),
    .frame_ready   (cam_frame_ready),
    .vga_r      (cam_bram_vga_r),
    .vga_g      (cam_bram_vga_g),
    .vga_b      (cam_bram_vga_b),
    .vga_hsync  (cam_bram_vga_hsync),
    .vga_vsync  (cam_bram_vga_vsync)
);

axis_linebuffer_vga u_axis_linebuffer_vga (
    .clk_50m          (vga_clk),
    .resetn           (resetn),
    .s_axis_tdata     (cam_video_tdata),
    .s_axis_tuser     (cam_video_tuser),
    .s_axis_tlast     (cam_video_tlast),
    .s_axis_tvalid    (cam_video_tvalid),
    .s_axis_tready    (cam_video_tready),
    .stream_seen      (cam_ddr_stream_seen),
    .frame_started    (cam_ddr_frame_started),
    .underflow_sticky (cam_ddr_underflow),
    .vga_r            (cam_ddr_vga_r),
    .vga_g            (cam_ddr_vga_g),
    .vga_b            (cam_ddr_vga_b),
    .vga_hsync        (cam_ddr_vga_hsync),
    .vga_vsync        (cam_ddr_vga_vsync)
);

// Count frames at the MM2S output.  The toggle crosses from the 50 MHz VGA
// stream clock to the 33 MHz CPU/CONFREG clock without transferring a pulse
// directly between clock domains.
always @(posedge vga_clk or negedge resetn) begin
    if (!resetn)
        camera_frame_toggle_cpu <= 1'b0;
    else if (cam_video_tvalid && cam_video_tready && cam_video_tuser)
        camera_frame_toggle_cpu <= ~camera_frame_toggle_cpu;
end

// Camera enable also selects the VGA source.  Synchronizing the control bit
// prevents a software register write from producing a partial VGA clock-cycle.
(* ASYNC_REG = "TRUE" *) reg [1:0] cam_vga_select_sync;
always @(posedge vga_clk or negedge resetn) begin
    if (!resetn)
        cam_vga_select_sync <= 2'b00;
    else
        cam_vga_select_sync <= {cam_vga_select_sync[0], camera_control[0]};
end

// Bit assignments for 0x1fd0_e104 (CAM_STATUS):
//  0 ID OK, 1 SCCB init done, 2 SCCB error, 3 PCLK seen,
//  4 VSYNC seen, 5 HREF seen, 6 DMA effective enable,
//  7 VDMA init done, 8 VDMA init error, 9 FIFO full,
// 10 FIFO overflow, 11 complete S2MM frame seen, 12 status valid,
// 13 MM2S stream seen, 14 MM2S SOF seen, 15 VGA underflow,
// 16 retired switch gate (always zero), 17 software enable,
// 18 terminal selected,
// 19 DMA reset released, 20 sensor reset released, 21 frame count nonzero,
// 27:24 VDMA state, 31:28 VDMA configuration write index.
wire [31:0] camera_status_async = {
    cam_vdma_debug_index,
    cam_vdma_debug_state,
    2'b00,
    (camera_frame_count_aclk != 32'd0),
    cam_reset_release,
    cam_dma_resetn,
    !cam_vga_select_sync[1],
    camera_control[0],
    1'b0,
    cam_ddr_underflow,
    cam_ddr_frame_started,
    cam_ddr_stream_seen,
    cam_vdma_status_valid,
    cam_vdma_frame_seen,
    cam_vdma_fifo_overflow,
    cam_vdma_fifo_full,
    cam_vdma_init_error,
    cam_vdma_init_done,
    cam_dma_resetn,
    cam_href_seen,
    cam_vsync_seen,
    cam_pclk_seen,
    cam_init_error,
    cam_init_done,
    cam_id_ok
};

// Bit assignments for 0x1fd0_e148 (LCD_STATUS):
//  0 LCD initialized, 1 panel write busy, 2 panel frame complete,
//  3 FIFO had to wait for DDR, 4 AXI reader busy, 5 AXI frame fetched,
//  6 AXI response error, 7 LCD owns S04, 8 photo requested,
//  9 FIFO full, 10 FIFO empty, 11 camera DMA released,
//  23:16 outstanding camera read bursts, 31:24 ASCII 'L'.
wire [31:0] lcd_status_async = {
    8'h4c,
    cam_read_outstanding,
    4'd0,
    cam_dma_resetn,
    lcd_fifo_empty,
    lcd_fifo_full,
    lcd_photo_request,
    lcd_s04_owner,
    lcd_reader_error,
    lcd_reader_done_sticky,
    lcd_reader_busy,
    lcd_underflow_sticky,
    lcd_frame_done_sticky,
    lcd_frame_busy,
    lcd_init_done
};

always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        camera_status_meta       <= 32'd0;
        camera_status_aclk       <= 32'd0;
        camera_s2mm_status_meta  <= 32'd0;
        camera_s2mm_status_aclk  <= 32'd0;
        camera_mm2s_status_meta  <= 32'd0;
        camera_mm2s_status_aclk  <= 32'd0;
        camera_frame_toggle_sync <= 3'b000;
        camera_frame_count_aclk  <= 32'd0;
        lcd_status_meta          <= 32'd0;
        lcd_status_aclk          <= 32'd0;
    end
    else begin
        camera_status_meta      <= camera_status_async;
        camera_status_aclk      <= camera_status_meta;
        camera_s2mm_status_meta <= cam_vdma_s2mm_status;
        camera_s2mm_status_aclk <= camera_s2mm_status_meta;
        camera_mm2s_status_meta <= cam_vdma_mm2s_status;
        camera_mm2s_status_aclk <= camera_mm2s_status_meta;
        lcd_status_meta         <= lcd_status_async;
        lcd_status_aclk         <= lcd_status_meta;
        camera_frame_toggle_sync <= {camera_frame_toggle_sync[1:0],
                                     camera_frame_toggle_cpu};
        if (camera_frame_toggle_sync[2] ^ camera_frame_toggle_sync[1])
            camera_frame_count_aclk <= camera_frame_count_aclk + 32'd1;
    end
end

assign vga_r     = cam_vga_select_sync[1] ? cam_ddr_vga_r     : terminal_vga_r;
assign vga_g     = cam_vga_select_sync[1] ? cam_ddr_vga_g     : terminal_vga_g;
assign vga_b     = cam_vga_select_sync[1] ? cam_ddr_vga_b     : terminal_vga_b;
assign vga_hsync = cam_vga_select_sync[1] ? cam_ddr_vga_hsync : terminal_vga_hsync;
assign vga_vsync = cam_vga_select_sync[1] ? cam_ddr_vga_vsync : terminal_vga_vsync;

endmodule
