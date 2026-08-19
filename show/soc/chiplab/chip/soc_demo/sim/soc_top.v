`include "config.h"

module soc_top#(
    parameter   BUS_WIDTH  = 32,
    parameter   DATA_WIDTH = 64, 
    parameter   CPU_WIDTH  = 32
)
(
    input  wire        aresetn           , 
    input  wire        aclk              ,
    input  wire        enable_delay      ,
    input  wire [22:0] random_seed       ,

    output wire [CPU_WIDTH-1:0] debug0_wb_pc      ,
    output wire [CPU_WIDTH-1:0] debug0_wb_rf_wdata,
    output wire                 debug0_wb_rf_wen  ,
    output wire [4 :0]          debug0_wb_rf_wnum ,

    `ifdef CPU_2CMT
    output wire [CPU_WIDTH-1:0] debug1_wb_pc      ,
    output wire [CPU_WIDTH-1:0] debug1_wb_rf_wdata,
    output wire                 debug1_wb_rf_wen  ,
    output wire [4 :0]          debug1_wb_rf_wnum ,
    `endif

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

    //ram
    output wire [BUS_WIDTH -1:0] sram_raddr        ,
    input  wire [DATA_WIDTH-1:0] sram_rdata        ,
    output wire                  sram_ren          ,
    output wire [BUS_WIDTH -1:0] sram_waddr        ,
    output wire [DATA_WIDTH-1:0] sram_wdata        ,
    output wire [DATA_WIDTH/8-1:0] sram_wen        ,

    //------uart-------
    inout         UART_RX,
    inout         UART_TX
/*
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
    inout         SPI_MOSI
*/
);

`ifdef NPU_AXI_DMA_ENABLE
localparam integer NPU_AXI_DMA_EN = 1;
`else
localparam integer NPU_AXI_DMA_EN = 0;
`endif

wire [`LID         -1 :0] cpu_awid;
wire [`Lawaddr     -1 :0] cpu_awaddr;
wire [`Lawlen      -1 :0] cpu_awlen;
wire [`Lawsize     -1 :0] cpu_awsize;
wire [`Lawburst    -1 :0] cpu_awburst;
wire [`Lawlock     -1 :0] cpu_awlock;
wire [`Lawcache    -1 :0] cpu_awcache;
wire [`Lawprot     -1 :0] cpu_awprot;
wire                      cpu_awvalid;
wire                      cpu_awready;
wire [`LID         -1 :0] cpu_wid;
wire [`Lwdata      -1 :0] cpu_wdata;
wire [`Lwstrb      -1 :0] cpu_wstrb;
wire                      cpu_wlast;
wire                      cpu_wvalid;
wire                      cpu_wready;
wire [`LID         -1 :0] cpu_bid;
wire [`Lbresp      -1 :0] cpu_bresp;
wire                      cpu_bvalid;
wire                      cpu_bready;
wire [`LID         -1 :0] cpu_arid;
wire [`Laraddr     -1 :0] cpu_araddr;
wire [`Larlen      -1 :0] cpu_arlen;
wire [`Larsize     -1 :0] cpu_arsize;
wire [`Larburst    -1 :0] cpu_arburst;
wire [`Larlock     -1 :0] cpu_arlock;
wire [`Larcache    -1 :0] cpu_arcache;
wire [`Larprot     -1 :0] cpu_arprot;
wire                      cpu_arvalid;
wire                      cpu_arready;
wire [`LID         -1 :0] cpu_rid;
wire [`Lrdata      -1 :0] cpu_rdata;
wire [`Lrresp      -1 :0] cpu_rresp;
wire                      cpu_rlast;
wire                      cpu_rvalid;
wire                      cpu_rready;

wire [`LID         -1 :0] m0_awid;
wire [`Lawaddr     -1 :0] m0_awaddr;
wire [`Lawlen      -1 :0] m0_awlen;
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

// NPU AXI slave, physical window 0x1f100000..0x1f10ffff.
wire [`LID         -1 :0] npu_s_awid;
wire [`Lawaddr     -1 :0] npu_s_awaddr;
wire [`Lawlen      -1 :0] npu_s_awlen;
wire [`Lawsize     -1 :0] npu_s_awsize;
wire [`Lawburst    -1 :0] npu_s_awburst;
wire [`Lawlock     -1 :0] npu_s_awlock;
wire [`Lawcache    -1 :0] npu_s_awcache;
wire [`Lawprot     -1 :0] npu_s_awprot;
wire                      npu_s_awvalid;
wire                      npu_s_awready;
wire [`LID         -1 :0] npu_s_wid;
wire [`Lwdata      -1 :0] npu_s_wdata;
wire [`Lwstrb      -1 :0] npu_s_wstrb;
wire                      npu_s_wlast;
wire                      npu_s_wvalid;
wire                      npu_s_wready;
wire [`LID         -1 :0] npu_s_bid;
wire [`Lbresp      -1 :0] npu_s_bresp;
wire                      npu_s_bvalid;
wire                      npu_s_bready;
wire [`LID         -1 :0] npu_s_arid;
wire [`Laraddr     -1 :0] npu_s_araddr;
wire [`Larlen      -1 :0] npu_s_arlen;
wire [`Larsize     -1 :0] npu_s_arsize;
wire [`Larburst    -1 :0] npu_s_arburst;
wire [`Larlock     -1 :0] npu_s_arlock;
wire [`Larcache    -1 :0] npu_s_arcache;
wire [`Larprot     -1 :0] npu_s_arprot;
wire                      npu_s_arvalid;
wire                      npu_s_arready;
wire [`LID         -1 :0] npu_s_rid;
wire [`Lrdata      -1 :0] npu_s_rdata;
wire [`Lrresp      -1 :0] npu_s_rresp;
wire                      npu_s_rlast;
wire                      npu_s_rvalid;
wire                      npu_s_rready;
wire                      npu_irq;

wire [3:0]  npu_m_awid;
wire [31:0] npu_m_awaddr;
wire [7:0]  npu_m_awlen;
wire [2:0]  npu_m_awsize;
wire [1:0]  npu_m_awburst;
wire        npu_m_awlock;
wire [3:0]  npu_m_awcache;
wire [2:0]  npu_m_awprot;
wire        npu_m_awvalid;
wire        npu_m_awready;
wire [3:0]  npu_m_wid;
wire [31:0] npu_m_wdata;
wire [3:0]  npu_m_wstrb;
wire        npu_m_wlast;
wire        npu_m_wvalid;
wire        npu_m_wready;
wire [3:0]  npu_m_bid;
wire [1:0]  npu_m_bresp;
wire        npu_m_bvalid;
wire        npu_m_bready;
wire [3:0]  npu_m_arid;
wire [31:0] npu_m_araddr;
wire [7:0]  npu_m_arlen;
wire [2:0]  npu_m_arsize;
wire [1:0]  npu_m_arburst;
wire        npu_m_arlock;
wire [3:0]  npu_m_arcache;
wire [2:0]  npu_m_arprot;
wire        npu_m_arvalid;
wire        npu_m_arready;
wire [3:0]  npu_m_rid;
wire [31:0] npu_m_rdata;
wire [1:0]  npu_m_rresp;
wire        npu_m_rlast;
wire        npu_m_rvalid;
wire        npu_m_rready;

wire [`LID         -1 :0] ram_m_awid;
wire [`Lawaddr     -1 :0] ram_m_awaddr;
wire [`Lawlen      -1 :0] ram_m_awlen;
wire [`Lawsize     -1 :0] ram_m_awsize;
wire [`Lawburst    -1 :0] ram_m_awburst;
wire [`Lawlock     -1 :0] ram_m_awlock;
wire [`Lawcache    -1 :0] ram_m_awcache;
wire [`Lawprot     -1 :0] ram_m_awprot;
wire                      ram_m_awvalid;
wire                      ram_m_awready;
wire [`LID         -1 :0] ram_m_wid;
wire [`Lwdata      -1 :0] ram_m_wdata;
wire [`Lwstrb      -1 :0] ram_m_wstrb;
wire                      ram_m_wlast;
wire                      ram_m_wvalid;
wire                      ram_m_wready;
wire [`LID         -1 :0] ram_m_bid;
wire [`Lbresp      -1 :0] ram_m_bresp;
wire                      ram_m_bvalid;
wire                      ram_m_bready;
wire [`LID         -1 :0] ram_m_arid;
wire [`Laraddr     -1 :0] ram_m_araddr;
wire [`Larlen      -1 :0] ram_m_arlen;
wire [`Larsize     -1 :0] ram_m_arsize;
wire [`Larburst    -1 :0] ram_m_arburst;
wire [`Larlock     -1 :0] ram_m_arlock;
wire [`Larcache    -1 :0] ram_m_arcache;
wire [`Larprot     -1 :0] ram_m_arprot;
wire                      ram_m_arvalid;
wire                      ram_m_arready;
wire [`LID         -1 :0] ram_m_rid;
wire [`Lrdata      -1 :0] ram_m_rdata;
wire [`Lrresp      -1 :0] ram_m_rresp;
wire                      ram_m_rlast;
wire                      ram_m_rvalid;
wire                      ram_m_rready;

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

// conf ram
wire [BUS_WIDTH -1:0]     conf_s_ram_raddr;
wire [DATA_WIDTH-1:0]     conf_s_ram_rdata;
wire                      conf_s_ram_ren;
wire [BUS_WIDTH -1:0]     conf_s_ram_waddr;
wire [DATA_WIDTH-1:0]     conf_s_ram_wdata;
wire [DATA_WIDTH/8-1:0]   conf_s_ram_wen;

wire [7  :0] interrupt  ;
wire         reset      ;
wire         timer_clk  ;

assign interrupt = {6'b0, uart0_int, npu_irq};
assign reset     = !aresetn;
assign timer_clk = aclk;

//uart
wire UART_CTS,   UART_RTS;
wire UART_DTR,   UART_DSR;
wire UART_RI,    UART_DCD;
assign UART_CTS = 1'b0;
assign UART_DSR = 1'b0;
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

core_top cpu
(
    .intrpt            (interrupt         ),// I, 8  

    .aclk              (aclk              ),// I, 1  
    .aresetn           (aresetn           ),// I, 1  
    .arid              (cpu_arid          ),// O, 4  
    .araddr            (cpu_araddr        ),// O, 64 
    .arlen             (cpu_arlen         ),// O, 4  
    .arsize            (cpu_arsize        ),// O, 3  
    .arburst           (cpu_arburst       ),// O, 2  
    .arlock            (cpu_arlock        ),// O, 2  
    .arcache           (cpu_arcache       ),// O, 4  
    .arprot            (cpu_arprot        ),// O, 3  
    .arvalid           (cpu_arvalid       ),// O, 1  
    .arready           (cpu_arready       ),// I, 1  
    .awid              (cpu_awid          ),// O, 4  
    .awaddr            (cpu_awaddr        ),// O, 64 
    .awlen             (cpu_awlen         ),// O, 4  
    .awsize            (cpu_awsize        ),// O, 3  
    .awburst           (cpu_awburst       ),// O, 2  
    .awlock            (cpu_awlock        ),// O, 2  
    .awcache           (cpu_awcache       ),// O, 4  
    .awprot            (cpu_awprot        ),// O, 3  
    .awvalid           (cpu_awvalid       ),// O, 1  
    .awready           (cpu_awready       ),// I, 1  
    .rid               (cpu_rid           ),// I, 4  
    .rdata             (cpu_rdata         ),// I, 128
    .rresp             (cpu_rresp         ),// I, 2  
    .rlast             (cpu_rlast         ),// I, 1  
    .rvalid            (cpu_rvalid        ),// I, 1  
    .rready            (cpu_rready        ),// O, 1  
    .wid               (cpu_wid           ),// O, 4  
    .wdata             (cpu_wdata         ),// O, 128
    .wstrb             (cpu_wstrb         ),// O, 16 
    .wlast             (cpu_wlast         ),// O, 1  
    .wvalid            (cpu_wvalid        ),// O, 1  
    .wready            (cpu_wready        ),// I, 1  
    .bid               (cpu_bid           ),// I, 4  
    .bresp             (cpu_bresp         ),// I, 2  
    .bvalid            (cpu_bvalid        ),// I, 1  
    .bready            (cpu_bready        ),// O, 1  

    .break_point       (1'b0              ),
    .infor_flag        (1'b0              ),
    .reg_num           (5'b0              ),
    .ws_valid          (                  ),
    .rf_rdata          (                  )
    
    ,
    .debug0_wb_pc      (debug0_wb_pc      ),// O, 64 
    .debug0_wb_rf_wen  (debug0_wb_rf_wen  ),// O, 1  
    .debug0_wb_rf_wnum (debug0_wb_rf_wnum ),// O, 5  
    .debug0_wb_rf_wdata(debug0_wb_rf_wdata) // O, 64 
    `ifdef CPU_2CMT
    ,
    .debug1_wb_pc      (debug1_wb_pc      ),// O, 64 
    .debug1_wb_rf_wen  (debug1_wb_rf_wen  ),// O, 1  
    .debug1_wb_rf_wnum (debug1_wb_rf_wnum ),// O, 5  
    .debug1_wb_rf_wdata(debug1_wb_rf_wdata) // O, 64 
    `endif
);

soc_axi_delay_rand
#(
    .BUS_WIDTH      (BUS_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .CPU_WIDTH      (CPU_WIDTH)

)
delay
(
    .enable_delay(enable_delay),// I, 1  
    .random_seed (random_seed ),// I, 23
    .aclk        (aclk        ),// I, 1  
    .aresetn     (aresetn     ),// I, 1 
    // slave 
    .s_arid      (m0_arid   ),// O, 4  
    .s_araddr    (m0_araddr ),// O, 64 
    .s_arlen     (m0_arlen  ),// O, 4  
    .s_arsize    (m0_arsize ),// O, 3  
    .s_arburst   (m0_arburst),// O, 2  
    .s_arlock    (m0_arlock ),// O, 2  
    .s_arcache   (m0_arcache),// O, 4  
    .s_arprot    (m0_arprot ),// O, 3  
    .s_arvalid   (m0_arvalid),// O, 1  
    .s_arready   (m0_arready),// I, 1  
    .s_awid      (m0_awid   ),// O, 4  
    .s_awaddr    (m0_awaddr ),// O, 64 
    .s_awlen     (m0_awlen  ),// O, 4  
    .s_awsize    (m0_awsize ),// O, 3  
    .s_awburst   (m0_awburst),// O, 2  
    .s_awlock    (m0_awlock ),// O, 2  
    .s_awcache   (m0_awcache),// O, 4  
    .s_awprot    (m0_awprot ),// O, 3  
    .s_awvalid   (m0_awvalid),// O, 1  
    .s_awready   (m0_awready),// I, 1  
    .s_rid       (m0_rid    ),// I, 4  
    .s_rdata     (m0_rdata  ),// I, 128
    .s_rresp     (m0_rresp  ),// I, 2  
    .s_rlast     (m0_rlast  ),// I, 1  
    .s_rvalid    (m0_rvalid ),// I, 1  
    .s_rready    (m0_rready ),// O, 1  
    .s_wid       (m0_wid    ),// O, 4  
    .s_wdata     (m0_wdata  ),// O, 128
    .s_wstrb     (m0_wstrb  ),// O, 16 
    .s_wlast     (m0_wlast  ),// O, 1  
    .s_wvalid    (m0_wvalid ),// O, 1  
    .s_wready    (m0_wready ),// I, 1  
    .s_bid       (m0_bid    ),// I, 4  
    .s_bresp     (m0_bresp  ),// I, 2  
    .s_bvalid    (m0_bvalid ),// I, 1  
    .s_bready    (m0_bready ),// O, 1  
    // master
    .m_arid      (cpu_arid   ),// I, 4  
    .m_araddr    (cpu_araddr ),// I, 64 
    .m_arlen     (cpu_arlen  ),// I, 4  
    .m_arsize    (cpu_arsize ),// I, 3  
    .m_arburst   (cpu_arburst),// I, 2  
    .m_arlock    (cpu_arlock ),// I, 2  
    .m_arcache   (cpu_arcache),// I, 4  
    .m_arprot    (cpu_arprot ),// I, 3  
    .m_arvalid   (cpu_arvalid),// I, 1  
    .m_arready   (cpu_arready),// O, 1  
    .m_awid      (cpu_awid   ),// I, 4  
    .m_awaddr    (cpu_awaddr ),// I, 64 
    .m_awlen     (cpu_awlen  ),// I, 4  
    .m_awsize    (cpu_awsize ),// I, 3  
    .m_awburst   (cpu_awburst),// I, 2  
    .m_awlock    (cpu_awlock ),// I, 2  
    .m_awcache   (cpu_awcache),// I, 4  
    .m_awprot    (cpu_awprot ),// I, 3  
    .m_awvalid   (cpu_awvalid),// I, 1  
    .m_awready   (cpu_awready),// O, 1  
    .m_rid       (cpu_rid    ),// O, 4  
    .m_rdata     (cpu_rdata  ),// O, 128
    .m_rresp     (cpu_rresp  ),// O, 2  
    .m_rlast     (cpu_rlast  ),// O, 1  
    .m_rvalid    (cpu_rvalid ),// O, 1  
    .m_rready    (cpu_rready ),// I, 1  
    .m_wid       (cpu_wid    ),// I, 4  
    .m_wdata     (cpu_wdata  ),// I, 128
    .m_wstrb     (cpu_wstrb  ),// I, 16 
    .m_wlast     (cpu_wlast  ),// I, 1  
    .m_wvalid    (cpu_wvalid ),// I, 1  
    .m_wready    (cpu_wready ),// O, 1  
    .m_bid       (cpu_bid    ),// O, 4  
    .m_bresp     (cpu_bresp  ),// O, 2  
    .m_bvalid    (cpu_bvalid ),// O, 1  
    .m_bready    (cpu_bready ) // I, 1  
);

// AXI_MUX 
axi_slave_mux AXI_SLAVE_MUX
(
.axi_s_aresetn     (aresetn        ),
.spi_boot          (1'b0           ),  

.axi_s_awid        (m0_awid        ),
.axi_s_awaddr      (m0_awaddr      ),
.axi_s_awlen       (m0_awlen       ),
.axi_s_awsize      (m0_awsize      ),
.axi_s_awburst     (m0_awburst     ),
.axi_s_awlock      (m0_awlock      ),
.axi_s_awcache     (m0_awcache     ),
.axi_s_awprot      (m0_awprot      ),
.axi_s_awvalid     (m0_awvalid     ),
.axi_s_awready     (m0_awready     ),
.axi_s_wready      (m0_wready      ),
.axi_s_wid         (m0_wid         ),
.axi_s_wdata       (m0_wdata       ),
.axi_s_wstrb       (m0_wstrb       ),
.axi_s_wlast       (m0_wlast       ),
.axi_s_wvalid      (m0_wvalid      ),
.axi_s_bid         (m0_bid         ),
.axi_s_bresp       (m0_bresp       ),
.axi_s_bvalid      (m0_bvalid      ),
.axi_s_bready      (m0_bready      ),
.axi_s_arid        (m0_arid        ),
.axi_s_araddr      (m0_araddr      ),
.axi_s_arlen       (m0_arlen       ),
.axi_s_arsize      (m0_arsize      ),
.axi_s_arburst     (m0_arburst     ),
.axi_s_arlock      (m0_arlock      ),
.axi_s_arcache     (m0_arcache     ),
.axi_s_arprot      (m0_arprot      ),
.axi_s_arvalid     (m0_arvalid     ),
.axi_s_arready     (m0_arready     ),
.axi_s_rready      (m0_rready      ),
.axi_s_rid         (m0_rid         ),
.axi_s_rdata       (m0_rdata       ),
.axi_s_rresp       (m0_rresp       ),
.axi_s_rlast       (m0_rlast       ),
.axi_s_rvalid      (m0_rvalid      ),

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

.s1_awid           (                    ),
.s1_awaddr         (                    ),
.s1_awlen          (                    ),
.s1_awsize         (                    ),
.s1_awburst        (                    ),
.s1_awlock         (                    ),
.s1_awcache        (                    ),
.s1_awprot         (                    ),
.s1_awvalid        (                    ),
.s1_awready        (1'b0                ),
.s1_wid            (                    ),
.s1_wdata          (                    ),
.s1_wstrb          (                    ),
.s1_wlast          (                    ),
.s1_wvalid         (                    ),
.s1_wready         (1'b0                ),
.s1_bid            (                    ),
.s1_bresp          (                    ),
.s1_bvalid         (1'b0                ),
.s1_bready         (                    ),
.s1_arid           (                    ),
.s1_araddr         (                    ),
.s1_arlen          (                    ),
.s1_arsize         (                    ),
.s1_arburst        (                    ),
.s1_arlock         (                    ),
.s1_arcache        (                    ),
.s1_arprot         (                    ),
.s1_arvalid        (                    ),
.s1_arready        (1'b0                ),
.s1_rid            (                    ),
.s1_rdata          (                    ),
.s1_rresp          (                    ),
.s1_rlast          (                    ),
.s1_rvalid         (1'b0                ),
.s1_rready         (                    ),

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

`ifndef RAND_TEST
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
`endif

.s4_awid           (npu_s_awid          ),
.s4_awaddr         (npu_s_awaddr        ),
.s4_awlen          (npu_s_awlen         ),
.s4_awsize         (npu_s_awsize        ),
.s4_awburst        (npu_s_awburst       ),
.s4_awlock         (npu_s_awlock        ),
.s4_awcache        (npu_s_awcache       ),
.s4_awprot         (npu_s_awprot        ),
.s4_awvalid        (npu_s_awvalid       ),
.s4_awready        (npu_s_awready       ),
.s4_wid            (npu_s_wid           ),
.s4_wdata          (npu_s_wdata         ),
.s4_wstrb          (npu_s_wstrb         ),
.s4_wlast          (npu_s_wlast         ),
.s4_wvalid         (npu_s_wvalid        ),
.s4_wready         (npu_s_wready        ),
.s4_bid            (npu_s_bid           ),
.s4_bresp          (npu_s_bresp         ),
.s4_bvalid         (npu_s_bvalid        ),
.s4_bready         (npu_s_bready        ),
.s4_arid           (npu_s_arid          ),
.s4_araddr         (npu_s_araddr        ),
.s4_arlen          (npu_s_arlen         ),
.s4_arsize         (npu_s_arsize        ),
.s4_arburst        (npu_s_arburst       ),
.s4_arlock         (npu_s_arlock        ),
.s4_arcache        (npu_s_arcache       ),
.s4_arprot         (npu_s_arprot        ),
.s4_arvalid        (npu_s_arvalid       ),
.s4_arready        (npu_s_arready       ),
.s4_rid            (npu_s_rid           ),
.s4_rdata          (npu_s_rdata         ),
.s4_rresp          (npu_s_rresp         ),
.s4_rlast          (npu_s_rlast         ),
.s4_rvalid         (npu_s_rvalid        ),
.s4_rready         (npu_s_rready        ),

.axi_s_aclk        (aclk                )
);

npu_rom_mmio #(
    .USE_AXI_DMA (NPU_AXI_DMA_EN)
) u_npu (
    .aclk          (aclk),
    .aresetn       (aresetn),
    .s_axi_awid    (npu_s_awid),
    .s_axi_awaddr  (npu_s_awaddr),
    .s_axi_awlen   ({4'b0, npu_s_awlen}),
    .s_axi_awsize  (npu_s_awsize),
    .s_axi_awburst (npu_s_awburst),
    .s_axi_awlock  (npu_s_awlock[0]),
    .s_axi_awcache (npu_s_awcache),
    .s_axi_awprot  (npu_s_awprot),
    .s_axi_awvalid (npu_s_awvalid),
    .s_axi_awready (npu_s_awready),
    .s_axi_wdata   (npu_s_wdata),
    .s_axi_wstrb   (npu_s_wstrb),
    .s_axi_wlast   (npu_s_wlast),
    .s_axi_wvalid  (npu_s_wvalid),
    .s_axi_wready  (npu_s_wready),
    .s_axi_bid     (npu_s_bid),
    .s_axi_bresp   (npu_s_bresp),
    .s_axi_bvalid  (npu_s_bvalid),
    .s_axi_bready  (npu_s_bready),
    .s_axi_arid    (npu_s_arid),
    .s_axi_araddr  (npu_s_araddr),
    .s_axi_arlen   ({4'b0, npu_s_arlen}),
    .s_axi_arsize  (npu_s_arsize),
    .s_axi_arburst (npu_s_arburst),
    .s_axi_arlock  (npu_s_arlock[0]),
    .s_axi_arcache (npu_s_arcache),
    .s_axi_arprot  (npu_s_arprot),
    .s_axi_arvalid (npu_s_arvalid),
    .s_axi_arready (npu_s_arready),
    .s_axi_rid     (npu_s_rid),
    .s_axi_rdata   (npu_s_rdata),
    .s_axi_rresp   (npu_s_rresp),
    .s_axi_rlast   (npu_s_rlast),
    .s_axi_rvalid  (npu_s_rvalid),
    .s_axi_rready  (npu_s_rready),
    .m_axi_arid    (npu_m_arid),
    .m_axi_araddr  (npu_m_araddr),
    .m_axi_arlen   (npu_m_arlen),
    .m_axi_arsize  (npu_m_arsize),
    .m_axi_arburst (npu_m_arburst),
    .m_axi_arlock  (npu_m_arlock),
    .m_axi_arcache (npu_m_arcache),
    .m_axi_arprot  (npu_m_arprot),
    .m_axi_arvalid (npu_m_arvalid),
    .m_axi_arready (npu_m_arready),
    .m_axi_rid     (npu_m_rid),
    .m_axi_rdata   (npu_m_rdata),
    .m_axi_rresp   (npu_m_rresp),
    .m_axi_rlast   (npu_m_rlast),
    .m_axi_rvalid  (npu_m_rvalid),
    .m_axi_rready  (npu_m_rready),
    .m_axi_awid    (npu_m_awid),
    .m_axi_awaddr  (npu_m_awaddr),
    .m_axi_awlen   (npu_m_awlen),
    .m_axi_awsize  (npu_m_awsize),
    .m_axi_awburst (npu_m_awburst),
    .m_axi_awlock  (npu_m_awlock),
    .m_axi_awcache (npu_m_awcache),
    .m_axi_awprot  (npu_m_awprot),
    .m_axi_awvalid (npu_m_awvalid),
    .m_axi_awready (npu_m_awready),
    .m_axi_wid     (npu_m_wid),
    .m_axi_wdata   (npu_m_wdata),
    .m_axi_wstrb   (npu_m_wstrb),
    .m_axi_wlast   (npu_m_wlast),
    .m_axi_wvalid  (npu_m_wvalid),
    .m_axi_wready  (npu_m_wready),
    .m_axi_bid     (npu_m_bid),
    .m_axi_bresp   (npu_m_bresp),
    .m_axi_bvalid  (npu_m_bvalid),
    .m_axi_bready  (npu_m_bready),
    .irq           (npu_irq)
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
/*
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
*/
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
.uart0_int          (uart0_int        )
/*
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
*/
);

`ifndef RAND_TEST
soc_axi_sram_bridge 
#(
    .BUS_WIDTH      (BUS_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .CPU_WIDTH      (CPU_WIDTH)
)
conf_axi_ram
(
    .aclk       (aclk       ),// I, 1  
    .aresetn    (aresetn    ),// I, 1  
    .m_arid     (conf_s_arid   ),// I, 4  
    .m_araddr   (conf_s_araddr ),// I, 64 
    .m_arlen    (conf_s_arlen  ),// I, 4  
    .m_arsize   (conf_s_arsize ),// I, 3  
    .m_arburst  (conf_s_arburst),// I, 2  
    .m_arlock   (conf_s_arlock ),// I, 2  
    .m_arcache  (conf_s_arcache),// I, 4  
    .m_arprot   (conf_s_arprot ),// I, 3  
    .m_arvalid  (conf_s_arvalid),// I, 1  
    .m_arready  (conf_s_arready),// O, 1  
    .m_awid     (conf_s_awid   ),// I, 4  
    .m_awaddr   (conf_s_awaddr ),// I, 64 
    .m_awlen    (conf_s_awlen  ),// I, 4  
    .m_awsize   (conf_s_awsize ),// I, 3  
    .m_awburst  (conf_s_awburst),// I, 2  
    .m_awlock   (conf_s_awlock ),// I, 2  
    .m_awcache  (conf_s_awcache),// I, 4  
    .m_awprot   (conf_s_awprot ),// I, 3  
    .m_awvalid  (conf_s_awvalid),// I, 1  
    .m_awready  (conf_s_awready),// O, 1  
    .m_rid      (conf_s_rid    ),// O, 4  
    .m_rdata    (conf_s_rdata  ),// O, 128
    .m_rresp    (conf_s_rresp  ),// O, 2  
    .m_rlast    (conf_s_rlast  ),// O, 1  
    .m_rvalid   (conf_s_rvalid ),// O, 1  
    .m_rready   (conf_s_rready ),// I, 1  
    .m_wid      (conf_s_wid    ),// I, 4  
    .m_wdata    (conf_s_wdata  ),// I, 128
    .m_wstrb    (conf_s_wstrb  ),// I, 16 
    .m_wlast    (conf_s_wlast  ),// I, 1  
    .m_wvalid   (conf_s_wvalid ),// I, 1  
    .m_wready   (conf_s_wready ),// O, 1  
    .m_bid      (conf_s_bid    ),// O, 4  
    .m_bresp    (conf_s_bresp  ),// O, 2  
    .m_bvalid   (conf_s_bvalid ),// O, 1  
    .m_bready   (conf_s_bready ),// I, 1  
    .ram_raddr  (conf_s_ram_raddr ),// O, 64 
    .ram_rdata  (conf_s_ram_rdata ),// I, 128
    .ram_ren    (conf_s_ram_ren   ),// O, 1  
    .ram_waddr  (conf_s_ram_waddr ),// O, 64 
    .ram_wdata  (conf_s_ram_wdata ),// O, 128
    .ram_wen    (conf_s_ram_wen   ) // O, 16 
);
`endif

npu_axi_ram_arbiter #(
    .ID_WIDTH   (`LID),
    .ADDR_WIDTH (`Lawaddr),
    .DATA_WIDTH (`Lwdata),
    .LEN_WIDTH  (`Lawlen),
    .LOCK_WIDTH (`Lawlock)
) u_npu_ram_arbiter (
    .aclk        (aclk),
    .aresetn     (aresetn),
    .s0_awid     (s0_awid),
    .s0_awaddr   (s0_awaddr),
    .s0_awlen    (s0_awlen),
    .s0_awsize   (s0_awsize),
    .s0_awburst  (s0_awburst),
    .s0_awlock   (s0_awlock),
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
    .s0_arlen    (s0_arlen),
    .s0_arsize   (s0_arsize),
    .s0_arburst  (s0_arburst),
    .s0_arlock   (s0_arlock),
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
    .s1_awid     (npu_m_awid),
    .s1_awaddr   (npu_m_awaddr),
    .s1_awlen    (npu_m_awlen[`Lawlen-1:0]),
    .s1_awsize   (npu_m_awsize),
    .s1_awburst  (npu_m_awburst),
    .s1_awlock   ({1'b0, npu_m_awlock}),
    .s1_awcache  (npu_m_awcache),
    .s1_awprot   (npu_m_awprot),
    .s1_awvalid  (npu_m_awvalid),
    .s1_awready  (npu_m_awready),
    .s1_wid      (npu_m_wid),
    .s1_wdata    (npu_m_wdata),
    .s1_wstrb    (npu_m_wstrb),
    .s1_wlast    (npu_m_wlast),
    .s1_wvalid   (npu_m_wvalid),
    .s1_wready   (npu_m_wready),
    .s1_bid      (npu_m_bid),
    .s1_bresp    (npu_m_bresp),
    .s1_bvalid   (npu_m_bvalid),
    .s1_bready   (npu_m_bready),
    .s1_arid     (npu_m_arid),
    .s1_araddr   (npu_m_araddr),
    .s1_arlen    (npu_m_arlen[`Larlen-1:0]),
    .s1_arsize   (npu_m_arsize),
    .s1_arburst  (npu_m_arburst),
    .s1_arlock   ({1'b0, npu_m_arlock}),
    .s1_arcache  (npu_m_arcache),
    .s1_arprot   (npu_m_arprot),
    .s1_arvalid  (npu_m_arvalid),
    .s1_arready  (npu_m_arready),
    .s1_rid      (npu_m_rid),
    .s1_rdata    (npu_m_rdata),
    .s1_rresp    (npu_m_rresp),
    .s1_rlast    (npu_m_rlast),
    .s1_rvalid   (npu_m_rvalid),
    .s1_rready   (npu_m_rready),
    .m_awid      (ram_m_awid),
    .m_awaddr    (ram_m_awaddr),
    .m_awlen     (ram_m_awlen),
    .m_awsize    (ram_m_awsize),
    .m_awburst   (ram_m_awburst),
    .m_awlock    (ram_m_awlock),
    .m_awcache   (ram_m_awcache),
    .m_awprot    (ram_m_awprot),
    .m_awvalid   (ram_m_awvalid),
    .m_awready   (ram_m_awready),
    .m_wid       (ram_m_wid),
    .m_wdata     (ram_m_wdata),
    .m_wstrb     (ram_m_wstrb),
    .m_wlast     (ram_m_wlast),
    .m_wvalid    (ram_m_wvalid),
    .m_wready    (ram_m_wready),
    .m_bid       (ram_m_bid),
    .m_bresp     (ram_m_bresp),
    .m_bvalid    (ram_m_bvalid),
    .m_bready    (ram_m_bready),
    .m_arid      (ram_m_arid),
    .m_araddr    (ram_m_araddr),
    .m_arlen     (ram_m_arlen),
    .m_arsize    (ram_m_arsize),
    .m_arburst   (ram_m_arburst),
    .m_arlock    (ram_m_arlock),
    .m_arcache   (ram_m_arcache),
    .m_arprot    (ram_m_arprot),
    .m_arvalid   (ram_m_arvalid),
    .m_arready   (ram_m_arready),
    .m_rid       (ram_m_rid),
    .m_rdata     (ram_m_rdata),
    .m_rresp     (ram_m_rresp),
    .m_rlast     (ram_m_rlast),
    .m_rvalid    (ram_m_rvalid),
    .m_rready    (ram_m_rready)
);

soc_axi_sram_bridge
#(
    .BUS_WIDTH      (BUS_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .CPU_WIDTH      (CPU_WIDTH)
)
sram_axi_ram
(
    .aclk       (aclk       ),// I, 1  
    .aresetn    (aresetn    ),// I, 1  
    .m_arid     (ram_m_arid   ),// I, 4
    .m_araddr   (ram_m_araddr ),// I, 32
    .m_arlen    (ram_m_arlen  ),// I, 4
    .m_arsize   (ram_m_arsize ),// I, 3
    .m_arburst  (ram_m_arburst),// I, 2
    .m_arlock   (ram_m_arlock ),// I, 2
    .m_arcache  (ram_m_arcache),// I, 4
    .m_arprot   (ram_m_arprot ),// I, 3
    .m_arvalid  (ram_m_arvalid),// I, 1
    .m_arready  (ram_m_arready),// O, 1
    .m_awid     (ram_m_awid   ),// I, 4
    .m_awaddr   (ram_m_awaddr ),// I, 32
    .m_awlen    (ram_m_awlen  ),// I, 4
    .m_awsize   (ram_m_awsize ),// I, 3
    .m_awburst  (ram_m_awburst),// I, 2
    .m_awlock   (ram_m_awlock ),// I, 2
    .m_awcache  (ram_m_awcache),// I, 4
    .m_awprot   (ram_m_awprot ),// I, 3
    .m_awvalid  (ram_m_awvalid),// I, 1
    .m_awready  (ram_m_awready),// O, 1
    .m_rid      (ram_m_rid    ),// O, 4
    .m_rdata    (ram_m_rdata  ),// O, 32
    .m_rresp    (ram_m_rresp  ),// O, 2
    .m_rlast    (ram_m_rlast  ),// O, 1
    .m_rvalid   (ram_m_rvalid ),// O, 1
    .m_rready   (ram_m_rready ),// I, 1
    .m_wid      (ram_m_wid    ),// I, 4
    .m_wdata    (ram_m_wdata  ),// I, 32
    .m_wstrb    (ram_m_wstrb  ),// I, 4
    .m_wlast    (ram_m_wlast  ),// I, 1
    .m_wvalid   (ram_m_wvalid ),// I, 1
    .m_wready   (ram_m_wready ),// O, 1
    .m_bid      (ram_m_bid    ),// O, 4
    .m_bresp    (ram_m_bresp  ),// O, 2
    .m_bvalid   (ram_m_bvalid ),// O, 1
    .m_bready   (ram_m_bready ),// I, 1
    .ram_raddr  (sram_raddr ),// O, 64 
    .ram_rdata  (sram_rdata ),// I, 128
    .ram_ren    (sram_ren   ),// O, 1  
    .ram_waddr  (sram_waddr ),// O, 64 
    .ram_wdata  (sram_wdata ),// O, 128
    .ram_wen    (sram_wen   ) // O, 16 
);

`ifndef RAND_TEST
confreg #(
    .BUS_WIDTH      (BUS_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .CPU_WIDTH      (CPU_WIDTH)

)confreg
(                     
    .clk                 (aclk           ),
    .timer_clk           (timer_clk     ),
    .resetn              (aresetn        ),

	.conf_ren            (conf_s_ram_ren  ),
	.conf_wen            (conf_s_ram_wen  ),
	.conf_raddr          (conf_s_ram_raddr),
	.conf_waddr          (conf_s_ram_waddr),
	.conf_wdatain        (conf_s_ram_wdata),
	.conf_rdata          (conf_s_ram_rdata),

    .led                 (led           ),
    .led_rg0             (led_rg0       ),
    .led_rg1             (led_rg1       ),
    .num_csn             (num_csn       ),
    .num_a_g             (num_a_g       ),
    .switch              (switch        ),
    .btn_key_col         (btn_key_col   ),
    .btn_key_row         (btn_key_row   ),
    .btn_step            (btn_step      )
);
`endif

endmodule
