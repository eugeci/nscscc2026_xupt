// SPDX-License-Identifier: MIT
//
// Single-outstanding AXI4 router used by the VisionArm/OpenLA500 integration.
// Transactions in the NPU MMIO window are sent to n_*, while every other
// transaction follows the original SoC path on m_*.
`timescale 1ns/1ps

module axi_npu_mmio_router #(
    parameter [31:0] NPU_BASE = 32'h1f100000,
    parameter [31:0] NPU_MASK = 32'hffff0000
) (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [3:0]  s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [7:0]  s_awlen,
    input  wire [2:0]  s_awsize,
    input  wire [1:0]  s_awburst,
    input  wire        s_awlock,
    input  wire [3:0]  s_awcache,
    input  wire [2:0]  s_awprot,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [3:0]  s_wid,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [3:0]  s_bid,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [3:0]  s_arid,
    input  wire [31:0] s_araddr,
    input  wire [7:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire [1:0]  s_arburst,
    input  wire        s_arlock,
    input  wire [3:0]  s_arcache,
    input  wire [2:0]  s_arprot,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [3:0]  s_rid,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    output wire [3:0]  m_awid,
    output wire [31:0] m_awaddr,
    output wire [7:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire        m_awlock,
    output wire [3:0]  m_awcache,
    output wire [2:0]  m_awprot,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [3:0]  m_wid,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [3:0]  m_bid,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [3:0]  m_arid,
    output wire [31:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arlock,
    output wire [3:0]  m_arcache,
    output wire [2:0]  m_arprot,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [3:0]  m_rid,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    output wire [3:0]  n_awid,
    output wire [31:0] n_awaddr,
    output wire [7:0]  n_awlen,
    output wire [2:0]  n_awsize,
    output wire [1:0]  n_awburst,
    output wire        n_awlock,
    output wire [3:0]  n_awcache,
    output wire [2:0]  n_awprot,
    output wire        n_awvalid,
    input  wire        n_awready,
    output wire [31:0] n_wdata,
    output wire [3:0]  n_wstrb,
    output wire        n_wlast,
    output wire        n_wvalid,
    input  wire        n_wready,
    input  wire [3:0]  n_bid,
    input  wire [1:0]  n_bresp,
    input  wire        n_bvalid,
    output wire        n_bready,
    output wire [3:0]  n_arid,
    output wire [31:0] n_araddr,
    output wire [7:0]  n_arlen,
    output wire [2:0]  n_arsize,
    output wire [1:0]  n_arburst,
    output wire        n_arlock,
    output wire [3:0]  n_arcache,
    output wire [2:0]  n_arprot,
    output wire        n_arvalid,
    input  wire        n_arready,
    input  wire [3:0]  n_rid,
    input  wire [31:0] n_rdata,
    input  wire [1:0]  n_rresp,
    input  wire        n_rlast,
    input  wire        n_rvalid,
    output wire        n_rready
);

    reg write_active;
    reg write_to_npu;
    reg read_active;
    reg read_to_npu;

    wire aw_hits_npu = (s_awaddr & NPU_MASK) == NPU_BASE;
    wire ar_hits_npu = (s_araddr & NPU_MASK) == NPU_BASE;

    assign m_awid    = s_awid;
    assign m_awaddr  = s_awaddr;
    assign m_awlen   = s_awlen;
    assign m_awsize  = s_awsize;
    assign m_awburst = s_awburst;
    assign m_awlock  = s_awlock;
    assign m_awcache = s_awcache;
    assign m_awprot  = s_awprot;
    assign m_awvalid = !write_active && !aw_hits_npu && s_awvalid;
    assign n_awid    = s_awid;
    assign n_awaddr  = s_awaddr;
    assign n_awlen   = s_awlen;
    assign n_awsize  = s_awsize;
    assign n_awburst = s_awburst;
    assign n_awlock  = s_awlock;
    assign n_awcache = s_awcache;
    assign n_awprot  = s_awprot;
    assign n_awvalid = !write_active && aw_hits_npu && s_awvalid;
    assign s_awready = !write_active &&
                       (aw_hits_npu ? n_awready : m_awready);

    assign m_wid    = s_wid;
    assign m_wdata  = s_wdata;
    assign m_wstrb  = s_wstrb;
    assign m_wlast  = s_wlast;
    assign m_wvalid = write_active && !write_to_npu && s_wvalid;
    assign n_wdata  = s_wdata;
    assign n_wstrb  = s_wstrb;
    assign n_wlast  = s_wlast;
    assign n_wvalid = write_active && write_to_npu && s_wvalid;
    assign s_wready = write_active &&
                      (write_to_npu ? n_wready : m_wready);

    assign s_bid    = write_to_npu ? n_bid    : m_bid;
    assign s_bresp  = write_to_npu ? n_bresp  : m_bresp;
    assign s_bvalid = write_active &&
                      (write_to_npu ? n_bvalid : m_bvalid);
    assign m_bready = write_active && !write_to_npu && s_bready;
    assign n_bready = write_active && write_to_npu && s_bready;

    assign m_arid    = s_arid;
    assign m_araddr  = s_araddr;
    assign m_arlen   = s_arlen;
    assign m_arsize  = s_arsize;
    assign m_arburst = s_arburst;
    assign m_arlock  = s_arlock;
    assign m_arcache = s_arcache;
    assign m_arprot  = s_arprot;
    assign m_arvalid = !read_active && !ar_hits_npu && s_arvalid;
    assign n_arid    = s_arid;
    assign n_araddr  = s_araddr;
    assign n_arlen   = s_arlen;
    assign n_arsize  = s_arsize;
    assign n_arburst = s_arburst;
    assign n_arlock  = s_arlock;
    assign n_arcache = s_arcache;
    assign n_arprot  = s_arprot;
    assign n_arvalid = !read_active && ar_hits_npu && s_arvalid;
    assign s_arready = !read_active &&
                       (ar_hits_npu ? n_arready : m_arready);

    assign s_rid    = read_to_npu ? n_rid    : m_rid;
    assign s_rdata  = read_to_npu ? n_rdata  : m_rdata;
    assign s_rresp  = read_to_npu ? n_rresp  : m_rresp;
    assign s_rlast  = read_to_npu ? n_rlast  : m_rlast;
    assign s_rvalid = read_active &&
                      (read_to_npu ? n_rvalid : m_rvalid);
    assign m_rready = read_active && !read_to_npu && s_rready;
    assign n_rready = read_active && read_to_npu && s_rready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            write_active <= 1'b0;
            write_to_npu <= 1'b0;
            read_active  <= 1'b0;
            read_to_npu  <= 1'b0;
        end else begin
            if (!write_active && s_awvalid && s_awready) begin
                write_active <= 1'b1;
                write_to_npu <= aw_hits_npu;
            end else if (write_active && s_bvalid && s_bready) begin
                write_active <= 1'b0;
            end

            if (!read_active && s_arvalid && s_arready) begin
                read_active <= 1'b1;
                read_to_npu <= ar_hits_npu;
            end else if (read_active && s_rvalid && s_rready && s_rlast) begin
                read_active <= 1'b0;
            end
        end
    end

endmodule
