`timescale 1ns/1ps

module tb_npu_axi_ram_arbiter_stability;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    npu_axi_ram_arbiter dut (
        .aclk(clk),
        .aresetn(rst_n)
    );

    always #5 clk = ~clk;

    task fail;
        input [255:0] reason;
        begin
            $display("[FAIL] %0s", reason);
            $finish;
        end
    endtask

    initial begin
        force dut.s0_arid = 4'h0;
        force dut.s0_arlen = 8'h0;
        force dut.s0_arsize = 3'h2;
        force dut.s0_arburst = 2'h1;
        force dut.s0_arlock = 1'b0;
        force dut.s0_arcache = 4'h0;
        force dut.s0_arprot = 3'h0;
        force dut.s1_arid = 4'h1;
        force dut.s1_arlen = 8'h0;
        force dut.s1_arsize = 3'h2;
        force dut.s1_arburst = 2'h1;
        force dut.s1_arlock = 1'b0;
        force dut.s1_arcache = 4'h0;
        force dut.s1_arprot = 3'h0;
        force dut.s0_araddr = 32'h1000_0000;
        force dut.s1_araddr = 32'h2000_0000;
        force dut.s0_arvalid = 1'b0;
        force dut.s1_arvalid = 1'b0;
        force dut.s0_rready = 1'b1;
        force dut.s1_rready = 1'b1;
        force dut.m_arready = 1'b0;
        force dut.m_rid = 4'h0;
        force dut.m_rdata = 32'h0;
        force dut.m_rresp = 2'h0;
        force dut.m_rlast = 1'b0;
        force dut.m_rvalid = 1'b0;

        force dut.s0_awid = 4'h0;
        force dut.s0_awlen = 8'h0;
        force dut.s0_awsize = 3'h2;
        force dut.s0_awburst = 2'h1;
        force dut.s0_awlock = 1'b0;
        force dut.s0_awcache = 4'h0;
        force dut.s0_awprot = 3'h0;
        force dut.s1_awid = 4'h1;
        force dut.s1_awlen = 8'h0;
        force dut.s1_awsize = 3'h2;
        force dut.s1_awburst = 2'h1;
        force dut.s1_awlock = 1'b0;
        force dut.s1_awcache = 4'h0;
        force dut.s1_awprot = 3'h0;
        force dut.s0_awaddr = 32'h3000_0000;
        force dut.s1_awaddr = 32'h4000_0000;
        force dut.s0_awvalid = 1'b0;
        force dut.s1_awvalid = 1'b0;
        force dut.s0_wid = 4'h0;
        force dut.s0_wdata = 32'h0;
        force dut.s0_wstrb = 4'hf;
        force dut.s0_wlast = 1'b1;
        force dut.s0_wvalid = 1'b0;
        force dut.s1_wid = 4'h1;
        force dut.s1_wdata = 32'h0;
        force dut.s1_wstrb = 4'hf;
        force dut.s1_wlast = 1'b1;
        force dut.s1_wvalid = 1'b0;
        force dut.s0_bready = 1'b1;
        force dut.s1_bready = 1'b1;
        force dut.m_awready = 1'b0;
        force dut.m_wready = 1'b0;
        force dut.m_bid = 4'h0;
        force dut.m_bresp = 2'h0;
        force dut.m_bvalid = 1'b0;

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // Complete an s0 read first so round-robin gives s1 priority next.
        force dut.s0_arvalid = 1'b1;
        force dut.m_arready = 1'b1;
        @(posedge clk);
        #1;
        force dut.s0_arvalid = 1'b0;
        force dut.m_arready = 1'b0;
        force dut.m_rlast = 1'b1;
        force dut.m_rvalid = 1'b1;
        @(posedge clk);
        #1;
        force dut.m_rvalid = 1'b0;
        force dut.m_rlast = 1'b0;

        // s0 is already presenting a stalled address.  A later s1 request
        // must not change the downstream payload before the handshake.
        force dut.s0_arvalid = 1'b1;
        #1;
        if (!dut.m_arvalid || dut.m_araddr !== 32'h1000_0000)
            fail("s0 stalled read was not initially selected");
        @(posedge clk);
        force dut.s1_arvalid = 1'b1;
        #1;
        if (dut.m_araddr !== 32'h1000_0000)
            fail("AR payload changed while VALID=1 and READY=0");

        force dut.m_arready = 1'b1;
        @(posedge clk);
        #1;
        force dut.s0_arvalid = 1'b0;
        force dut.s1_arvalid = 1'b0;
        force dut.m_arready = 1'b0;
        force dut.m_rlast = 1'b1;
        force dut.m_rvalid = 1'b1;
        @(posedge clk);
        #1;
        force dut.m_rvalid = 1'b0;
        force dut.m_rlast = 1'b0;

        // Repeat the same stability check for AW.
        force dut.s0_awvalid = 1'b1;
        force dut.m_awready = 1'b1;
        @(posedge clk);
        #1;
        force dut.s0_awvalid = 1'b0;
        force dut.m_awready = 1'b0;
        force dut.m_bvalid = 1'b1;
        @(posedge clk);
        #1;
        force dut.m_bvalid = 1'b0;

        force dut.s0_awvalid = 1'b1;
        #1;
        if (!dut.m_awvalid || dut.m_awaddr !== 32'h3000_0000)
            fail("s0 stalled write was not initially selected");
        @(posedge clk);
        force dut.s1_awvalid = 1'b1;
        #1;
        if (dut.m_awaddr !== 32'h3000_0000)
            fail("AW payload changed while VALID=1 and READY=0");

        $display("[PASS] AXI address payload remains stable under contention/backpressure");
        $finish;
    end
endmodule
