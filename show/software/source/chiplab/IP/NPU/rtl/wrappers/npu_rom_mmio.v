// Chiplab adapter for the migrated NPU.
//
// USE_AXI_DMA=0 preserves the verified on-chip parameter-ROM path.
// USE_AXI_DMA=1 exposes the NPU master to the SoC RAM arbiter without changing
// the MMIO register ABI.
`timescale 1ns/1ps

module npu_rom_mmio #(
    parameter integer USE_AXI_DMA = 0
) (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [3:0]  s_axi_awid,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire [2:0]  s_axi_awsize,
    input  wire [1:0]  s_axi_awburst,
    input  wire        s_axi_awlock,
    input  wire [3:0]  s_axi_awcache,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [3:0]  s_axi_bid,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [3:0]  s_axi_arid,
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,
    input  wire [2:0]  s_axi_arsize,
    input  wire [1:0]  s_axi_arburst,
    input  wire        s_axi_arlock,
    input  wire [3:0]  s_axi_arcache,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output wire [3:0]  s_axi_rid,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rlast,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire [3:0]  m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [3:0]  m_axi_rid,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output wire [3:0]  m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [2:0]  m_axi_awprot,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [3:0]  m_axi_wid,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [3:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire        irq
);

    wire [4:0] wrapper_bid;
    wire [4:0] wrapper_rid;

    assign s_axi_bid = wrapper_bid[3:0];
    assign s_axi_rid = wrapper_rid[3:0];

    axi_npu_wrapper #(
        .USE_AXI_DMA(USE_AXI_DMA)
    ) u_axi_npu_wrapper (
        .aclk          (aclk),
        .aresetn       (aresetn),

        .s_awid        ({1'b0, s_axi_awid}),
        .s_awaddr      (s_axi_awaddr),
        .s_awlen       (s_axi_awlen),
        .s_awsize      (s_axi_awsize),
        .s_awburst     (s_axi_awburst),
        .s_awlock      (s_axi_awlock),
        .s_awcache     (s_axi_awcache),
        .s_awprot      (s_axi_awprot),
        .s_awvalid     (s_axi_awvalid),
        .s_awready     (s_axi_awready),

        .s_wdata       (s_axi_wdata),
        .s_wstrb       (s_axi_wstrb),
        .s_wlast       (s_axi_wlast),
        .s_wvalid      (s_axi_wvalid),
        .s_wready      (s_axi_wready),

        .s_bid         (wrapper_bid),
        .s_bresp       (s_axi_bresp),
        .s_bvalid      (s_axi_bvalid),
        .s_bready      (s_axi_bready),

        .s_arid        ({1'b0, s_axi_arid}),
        .s_araddr      (s_axi_araddr),
        .s_arlen       (s_axi_arlen),
        .s_arsize      (s_axi_arsize),
        .s_arburst     (s_axi_arburst),
        .s_arlock      (s_axi_arlock),
        .s_arcache     (s_axi_arcache),
        .s_arprot      (s_axi_arprot),
        .s_arvalid     (s_axi_arvalid),
        .s_arready     (s_axi_arready),

        .s_rid         (wrapper_rid),
        .s_rdata       (s_axi_rdata),
        .s_rresp       (s_axi_rresp),
        .s_rlast       (s_axi_rlast),
        .s_rvalid      (s_axi_rvalid),
        .s_rready      (s_axi_rready),

        .npu_irq       (irq),

        .m_axi_arid    (m_axi_arid),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rid     (m_axi_rid),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready),

        .m_axi_awid    (m_axi_awid),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wid     (m_axi_wid),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready)
    );

endmodule
