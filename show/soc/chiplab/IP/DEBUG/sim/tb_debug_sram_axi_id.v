`timescale 1ns/1ps

module tb_debug_sram_axi_id;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg infom_flag = 1'b0;
    reg [31:0] start_addr = 32'h1000_0002;
    reg arready = 1'b0;
    reg [3:0] rid = 4'd0;
    reg [31:0] rdata = 32'haabb_ccdd;
    reg [1:0] rresp = 2'b00;
    reg rlast = 1'b1;
    reg rvalid = 1'b0;

    wire [3:0] arid;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire [1:0] arlock;
    wire [3:0] arcache;
    wire [2:0] arprot;
    wire arvalid;
    wire rready;
    wire mem_flag;
    wire [7:0] mem_rdata;

    always #5 clk = ~clk;

    debug_sram dut (
        .clk(clk), .aresetn(resetn),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache),
        .arprot(arprot), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .break_point(1'b0), .cpu_rready(1'b0), .rvalid_r(), .rid_r(),
        .rdata_r(), .rlast_r(), .flag(),
        .infom_flag(infom_flag), .start_addr(start_addr),
        .mem_flag(mem_flag), .mem_rdata(mem_rdata)
    );

    task fail;
        input [255:0] reason;
        begin
            $display("[FAIL] %0s", reason);
            $finish;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        resetn <= 1'b1;
        @(posedge clk);

        infom_flag <= 1'b1;
        @(posedge clk);
        infom_flag <= 1'b0;
        @(posedge clk);
        #1;
        if (!arvalid || arid !== 4'd0)
            fail("debug read did not use representable AXI ID zero");

        arready <= 1'b1;
        @(posedge clk);
        arready <= 1'b0;
        rvalid <= 1'b1;
        @(posedge clk);
        #1;
        if (!mem_flag || mem_rdata !== 8'hbb)
            fail("RID zero response or 32-bit byte-lane selection failed");

        rvalid <= 1'b0;
        @(posedge clk);
        #1;
        if (mem_flag)
            fail("memory response flag was not a pulse");

        $display("[PASS] debug SRAM accepts mux ID zero and selects 32-bit byte lanes");
        $finish;
    end
endmodule
