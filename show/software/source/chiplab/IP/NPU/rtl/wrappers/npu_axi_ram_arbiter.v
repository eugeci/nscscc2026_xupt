// SPDX-License-Identifier: MIT
//
// Two-initiator AXI RAM arbiter used by the Chiplab NPU integration.
//
// s0 is the SoC interconnect's existing RAM path and s1 is the NPU DMA
// master.  The output is connected only to RAM/MIG, which is also the address
// firewall for the NPU.  Read and write channels are arbitrated independently.
// One read burst and one write burst may be outstanding at a time.
`timescale 1ns/1ps

module npu_axi_ram_arbiter #(
    parameter integer ID_WIDTH   = 4,
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer LEN_WIDTH  = 8,
    parameter integer LOCK_WIDTH = 1
) (
    input  wire                      aclk,
    input  wire                      aresetn,

    input  wire [ID_WIDTH-1:0]       s0_awid,
    input  wire [ADDR_WIDTH-1:0]     s0_awaddr,
    input  wire [LEN_WIDTH-1:0]      s0_awlen,
    input  wire [2:0]                s0_awsize,
    input  wire [1:0]                s0_awburst,
    input  wire [LOCK_WIDTH-1:0]     s0_awlock,
    input  wire [3:0]                s0_awcache,
    input  wire [2:0]                s0_awprot,
    input  wire                      s0_awvalid,
    output wire                      s0_awready,
    input  wire [ID_WIDTH-1:0]       s0_wid,
    input  wire [DATA_WIDTH-1:0]     s0_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s0_wstrb,
    input  wire                      s0_wlast,
    input  wire                      s0_wvalid,
    output wire                      s0_wready,
    output wire [ID_WIDTH-1:0]       s0_bid,
    output wire [1:0]                s0_bresp,
    output wire                      s0_bvalid,
    input  wire                      s0_bready,

    input  wire [ID_WIDTH-1:0]       s0_arid,
    input  wire [ADDR_WIDTH-1:0]     s0_araddr,
    input  wire [LEN_WIDTH-1:0]      s0_arlen,
    input  wire [2:0]                s0_arsize,
    input  wire [1:0]                s0_arburst,
    input  wire [LOCK_WIDTH-1:0]     s0_arlock,
    input  wire [3:0]                s0_arcache,
    input  wire [2:0]                s0_arprot,
    input  wire                      s0_arvalid,
    output wire                      s0_arready,
    output wire [ID_WIDTH-1:0]       s0_rid,
    output wire [DATA_WIDTH-1:0]     s0_rdata,
    output wire [1:0]                s0_rresp,
    output wire                      s0_rlast,
    output wire                      s0_rvalid,
    input  wire                      s0_rready,

    input  wire [ID_WIDTH-1:0]       s1_awid,
    input  wire [ADDR_WIDTH-1:0]     s1_awaddr,
    input  wire [LEN_WIDTH-1:0]      s1_awlen,
    input  wire [2:0]                s1_awsize,
    input  wire [1:0]                s1_awburst,
    input  wire [LOCK_WIDTH-1:0]     s1_awlock,
    input  wire [3:0]                s1_awcache,
    input  wire [2:0]                s1_awprot,
    input  wire                      s1_awvalid,
    output wire                      s1_awready,
    input  wire [ID_WIDTH-1:0]       s1_wid,
    input  wire [DATA_WIDTH-1:0]     s1_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s1_wstrb,
    input  wire                      s1_wlast,
    input  wire                      s1_wvalid,
    output wire                      s1_wready,
    output wire [ID_WIDTH-1:0]       s1_bid,
    output wire [1:0]                s1_bresp,
    output wire                      s1_bvalid,
    input  wire                      s1_bready,

    input  wire [ID_WIDTH-1:0]       s1_arid,
    input  wire [ADDR_WIDTH-1:0]     s1_araddr,
    input  wire [LEN_WIDTH-1:0]      s1_arlen,
    input  wire [2:0]                s1_arsize,
    input  wire [1:0]                s1_arburst,
    input  wire [LOCK_WIDTH-1:0]     s1_arlock,
    input  wire [3:0]                s1_arcache,
    input  wire [2:0]                s1_arprot,
    input  wire                      s1_arvalid,
    output wire                      s1_arready,
    output wire [ID_WIDTH-1:0]       s1_rid,
    output wire [DATA_WIDTH-1:0]     s1_rdata,
    output wire [1:0]                s1_rresp,
    output wire                      s1_rlast,
    output wire                      s1_rvalid,
    input  wire                      s1_rready,

    output wire [ID_WIDTH-1:0]       m_awid,
    output wire [ADDR_WIDTH-1:0]     m_awaddr,
    output wire [LEN_WIDTH-1:0]      m_awlen,
    output wire [2:0]                m_awsize,
    output wire [1:0]                m_awburst,
    output wire [LOCK_WIDTH-1:0]     m_awlock,
    output wire [3:0]                m_awcache,
    output wire [2:0]                m_awprot,
    output wire                      m_awvalid,
    input  wire                      m_awready,
    output wire [ID_WIDTH-1:0]       m_wid,
    output wire [DATA_WIDTH-1:0]     m_wdata,
    output wire [(DATA_WIDTH/8)-1:0] m_wstrb,
    output wire                      m_wlast,
    output wire                      m_wvalid,
    input  wire                      m_wready,
    input  wire [ID_WIDTH-1:0]       m_bid,
    input  wire [1:0]                m_bresp,
    input  wire                      m_bvalid,
    output wire                      m_bready,

    output wire [ID_WIDTH-1:0]       m_arid,
    output wire [ADDR_WIDTH-1:0]     m_araddr,
    output wire [LEN_WIDTH-1:0]      m_arlen,
    output wire [2:0]                m_arsize,
    output wire [1:0]                m_arburst,
    output wire [LOCK_WIDTH-1:0]     m_arlock,
    output wire [3:0]                m_arcache,
    output wire [2:0]                m_arprot,
    output wire                      m_arvalid,
    input  wire                      m_arready,
    input  wire [ID_WIDTH-1:0]       m_rid,
    input  wire [DATA_WIDTH-1:0]     m_rdata,
    input  wire [1:0]                m_rresp,
    input  wire                      m_rlast,
    input  wire                      m_rvalid,
    output wire                      m_rready
);

    reg read_active;
    reg read_owner;
    reg read_last_owner;
    reg read_grant_valid;
    reg read_grant_owner;
    reg write_active;
    reg write_owner;
    reg write_last_owner;
    reg write_grant_valid;
    reg write_grant_owner;

    // Round-robin only matters when both requesters are valid.  Reset gives
    // s0 first service, preserving the pre-NPU boot path.
    wire arbitrate_read_s1 = s1_arvalid &&
                             (!s0_arvalid || !read_last_owner);
    wire arbitrate_read_s0 = s0_arvalid && !arbitrate_read_s1;
    wire choose_read_s1 = read_grant_valid ? read_grant_owner
                                           : arbitrate_read_s1;
    wire choose_read_s0 = read_grant_valid ? !read_grant_owner
                                           : arbitrate_read_s0;
    wire arbitrate_write_s1 = s1_awvalid &&
                              (!s0_awvalid || !write_last_owner);
    wire arbitrate_write_s0 = s0_awvalid && !arbitrate_write_s1;
    wire choose_write_s1 = write_grant_valid ? write_grant_owner
                                             : arbitrate_write_s1;
    wire choose_write_s0 = write_grant_valid ? !write_grant_owner
                                             : arbitrate_write_s0;

    assign m_arid    = choose_read_s1 ? s1_arid    : s0_arid;
    assign m_araddr  = choose_read_s1 ? s1_araddr  : s0_araddr;
    assign m_arlen   = choose_read_s1 ? s1_arlen   : s0_arlen;
    assign m_arsize  = choose_read_s1 ? s1_arsize  : s0_arsize;
    assign m_arburst = choose_read_s1 ? s1_arburst : s0_arburst;
    assign m_arlock  = choose_read_s1 ? s1_arlock  : s0_arlock;
    assign m_arcache = choose_read_s1 ? s1_arcache : s0_arcache;
    assign m_arprot  = choose_read_s1 ? s1_arprot  : s0_arprot;
    assign m_arvalid = !read_active &&
                       ((choose_read_s0 && s0_arvalid) ||
                        (choose_read_s1 && s1_arvalid));
    assign s0_arready = !read_active && choose_read_s0 && m_arready;
    assign s1_arready = !read_active && choose_read_s1 && m_arready;

    assign s0_rid    = m_rid;
    assign s0_rdata  = m_rdata;
    assign s0_rresp  = m_rresp;
    assign s0_rlast  = m_rlast;
    assign s0_rvalid = read_active && !read_owner && m_rvalid;
    assign s1_rid    = m_rid;
    assign s1_rdata  = m_rdata;
    assign s1_rresp  = m_rresp;
    assign s1_rlast  = m_rlast;
    assign s1_rvalid = read_active && read_owner && m_rvalid;
    assign m_rready  = read_active ?
                       (read_owner ? s1_rready : s0_rready) : 1'b0;

    assign m_awid    = choose_write_s1 ? s1_awid    : s0_awid;
    assign m_awaddr  = choose_write_s1 ? s1_awaddr  : s0_awaddr;
    assign m_awlen   = choose_write_s1 ? s1_awlen   : s0_awlen;
    assign m_awsize  = choose_write_s1 ? s1_awsize  : s0_awsize;
    assign m_awburst = choose_write_s1 ? s1_awburst : s0_awburst;
    assign m_awlock  = choose_write_s1 ? s1_awlock  : s0_awlock;
    assign m_awcache = choose_write_s1 ? s1_awcache : s0_awcache;
    assign m_awprot  = choose_write_s1 ? s1_awprot  : s0_awprot;
    assign m_awvalid = !write_active &&
                       ((choose_write_s0 && s0_awvalid) ||
                        (choose_write_s1 && s1_awvalid));
    assign s0_awready = !write_active && choose_write_s0 && m_awready;
    assign s1_awready = !write_active && choose_write_s1 && m_awready;

    assign m_wid    = write_owner ? s1_wid   : s0_wid;
    assign m_wdata  = write_owner ? s1_wdata : s0_wdata;
    assign m_wstrb  = write_owner ? s1_wstrb : s0_wstrb;
    assign m_wlast  = write_owner ? s1_wlast : s0_wlast;
    assign m_wvalid = write_active &&
                      (write_owner ? s1_wvalid : s0_wvalid);
    assign s0_wready = write_active && !write_owner && m_wready;
    assign s1_wready = write_active && write_owner && m_wready;

    assign s0_bid    = m_bid;
    assign s0_bresp  = m_bresp;
    assign s0_bvalid = write_active && !write_owner && m_bvalid;
    assign s1_bid    = m_bid;
    assign s1_bresp  = m_bresp;
    assign s1_bvalid = write_active && write_owner && m_bvalid;
    assign m_bready  = write_active ?
                       (write_owner ? s1_bready : s0_bready) : 1'b0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            read_active     <= 1'b0;
            read_owner      <= 1'b0;
            read_last_owner <= 1'b1;
            read_grant_valid <= 1'b0;
            read_grant_owner <= 1'b0;
        end else begin
            if (!read_active) begin
                if (m_arvalid && m_arready) begin
                    read_active      <= 1'b1;
                    read_owner       <= choose_read_s1;
                    read_grant_valid <= 1'b0;
                end else if (!read_grant_valid && m_arvalid) begin
                    // Once VALID is visible while the slave is stalled, AXI
                    // requires every address-channel field to remain stable.
                    read_grant_valid <= 1'b1;
                    read_grant_owner <= choose_read_s1;
                end
            end else if (read_active && m_rvalid && m_rready && m_rlast) begin
                read_active     <= 1'b0;
                read_last_owner <= read_owner;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            write_active     <= 1'b0;
            write_owner      <= 1'b0;
            write_last_owner <= 1'b1;
            write_grant_valid <= 1'b0;
            write_grant_owner <= 1'b0;
        end else begin
            if (!write_active) begin
                if (m_awvalid && m_awready) begin
                    write_active      <= 1'b1;
                    write_owner       <= choose_write_s1;
                    write_grant_valid <= 1'b0;
                end else if (!write_grant_valid && m_awvalid) begin
                    // AW is independent from W; lock the selected requester
                    // until the downstream AW handshake completes.
                    write_grant_valid <= 1'b1;
                    write_grant_owner <= choose_write_s1;
                end
            end else if (write_active && m_bvalid && m_bready) begin
                write_active     <= 1'b0;
                write_last_owner <= write_owner;
            end
        end
    end

endmodule
