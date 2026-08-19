`timescale 1ns/1ps

module tb_axi_npu_mmio_router;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    always #5 clk = ~clk;

    reg [3:0] s_awid;
    reg [31:0] s_awaddr;
    reg s_awvalid;
    wire s_awready;
    reg [3:0] s_wid;
    reg [31:0] s_wdata;
    reg [3:0] s_wstrb;
    reg s_wlast;
    reg s_wvalid;
    wire s_wready;
    wire [3:0] s_bid;
    wire [1:0] s_bresp;
    wire s_bvalid;
    reg s_bready;
    reg [3:0] s_arid;
    reg [31:0] s_araddr;
    reg s_arvalid;
    wire s_arready;
    wire [3:0] s_rid;
    wire [31:0] s_rdata;
    wire [1:0] s_rresp;
    wire s_rlast;
    wire s_rvalid;
    reg s_rready;

    wire m_awvalid;
    reg m_awready;
    wire m_wvalid;
    reg m_wready;
    reg [3:0] m_bid;
    reg [1:0] m_bresp;
    reg m_bvalid;
    wire m_bready;
    wire m_arvalid;
    reg m_arready;
    reg [3:0] m_rid;
    reg [31:0] m_rdata;
    reg [1:0] m_rresp;
    reg m_rlast;
    reg m_rvalid;
    wire m_rready;

    wire n_awvalid;
    reg n_awready;
    wire n_wvalid;
    reg n_wready;
    reg [3:0] n_bid;
    reg [1:0] n_bresp;
    reg n_bvalid;
    wire n_bready;
    wire n_arvalid;
    reg n_arready;
    reg [3:0] n_rid;
    reg [31:0] n_rdata;
    reg [1:0] n_rresp;
    reg n_rlast;
    reg n_rvalid;
    wire n_rready;

    axi_npu_mmio_router dut (
        .aclk(clk), .aresetn(resetn),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(8'd0),
        .s_awsize(3'd2), .s_awburst(2'b01), .s_awlock(1'b0),
        .s_awcache(4'd0), .s_awprot(3'd0), .s_awvalid(s_awvalid),
        .s_awready(s_awready), .s_wid(s_wid), .s_wdata(s_wdata),
        .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bid(s_bid), .s_bresp(s_bresp),
        .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(8'd0),
        .s_arsize(3'd2), .s_arburst(2'b01), .s_arlock(1'b0),
        .s_arcache(4'd0), .s_arprot(3'd0), .s_arvalid(s_arvalid),
        .s_arready(s_arready), .s_rid(s_rid), .s_rdata(s_rdata),
        .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready), .m_arvalid(m_arvalid),
        .m_arready(m_arready), .m_rid(m_rid), .m_rdata(m_rdata),
        .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .n_awvalid(n_awvalid), .n_awready(n_awready),
        .n_wvalid(n_wvalid), .n_wready(n_wready),
        .n_bid(n_bid), .n_bresp(n_bresp), .n_bvalid(n_bvalid),
        .n_bready(n_bready), .n_arvalid(n_arvalid),
        .n_arready(n_arready), .n_rid(n_rid), .n_rdata(n_rdata),
        .n_rresp(n_rresp), .n_rlast(n_rlast), .n_rvalid(n_rvalid),
        .n_rready(n_rready)
    );

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                $finish(1);
            end
        end
    endtask

    initial begin
        s_awid = 0; s_awaddr = 0; s_awvalid = 0;
        s_wid = 0; s_wdata = 0; s_wstrb = 4'hf; s_wlast = 1;
        s_wvalid = 0; s_bready = 0;
        s_arid = 0; s_araddr = 0; s_arvalid = 0; s_rready = 0;
        m_awready = 1; m_wready = 1; m_bid = 4'ha; m_bresp = 0;
        m_bvalid = 0; m_arready = 1; m_rid = 4'hb;
        m_rdata = 32'h11223344; m_rresp = 0; m_rlast = 1; m_rvalid = 0;
        n_awready = 1; n_wready = 1; n_bid = 4'hc; n_bresp = 0;
        n_bvalid = 0; n_arready = 1; n_rid = 4'hd;
        n_rdata = 32'h55667788; n_rresp = 0; n_rlast = 1; n_rvalid = 0;

        repeat (3) @(posedge clk);
        resetn <= 1;
        @(posedge clk);

        // Ordinary writes remain on the legacy SoC path.
        s_awaddr <= 32'h1fd00000; s_awvalid <= 1;
        #1 check(m_awvalid && !n_awvalid, "legacy AW route");
        @(posedge clk); s_awvalid <= 0; s_wvalid <= 1;
        #1 check(m_wvalid && !n_wvalid, "legacy W route");
        @(posedge clk); s_wvalid <= 0; m_bvalid <= 1; s_bready <= 1;
        #1 check(s_bvalid && s_bid == 4'ha && m_bready, "legacy B route");
        @(posedge clk); m_bvalid <= 0; s_bready <= 0;

        // NPU reads are isolated to the accelerator window.
        s_arid <= 4'h3; s_araddr <= 32'h1f100158; s_arvalid <= 1;
        #1 check(n_arvalid && !m_arvalid, "NPU AR route");
        @(posedge clk); s_arvalid <= 0; n_rvalid <= 1; s_rready <= 1;
        #1 check(s_rvalid && s_rdata == 32'h55667788 && n_rready,
                 "NPU R route");
        @(posedge clk); n_rvalid <= 0; s_rready <= 0;

        $display("AXI_NPU_MMIO_ROUTER_PASS");
        $finish;
    end
endmodule
