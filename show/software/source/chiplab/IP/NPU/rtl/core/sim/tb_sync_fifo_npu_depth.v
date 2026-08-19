`timescale 1ns/1ps

module tb_sync_fifo_npu_depth;
    localparam DATA_WIDTH = 16;
    localparam FIFO_DEPTH = 512;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg clr = 1'b0;
    reg wr_en = 1'b0;
    reg [DATA_WIDTH-1:0] din = {DATA_WIDTH{1'b0}};
    reg rd_en = 1'b0;
    wire [DATA_WIDTH-1:0] dout;
    wire full;
    wire empty;

    integer i;

    sync_fifo_npu_module #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clr(clr),
        .wr_en(wr_en),
        .din(din),
        .full(full),
        .rd_en(rd_en),
        .dout(dout),
        .empty(empty)
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
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            wr_en <= 1'b1;
            din <= i[DATA_WIDTH-1:0];
            @(posedge clk);
            #1;
            if (i != FIFO_DEPTH - 1 && full)
                fail("FIFO asserted full before 512 accepted writes");
        end
        wr_en <= 1'b0;
        #1;
        if (!full)
            fail("FIFO did not assert full after 512 accepted writes");

        // At full, the implementation rejects the simultaneous write but
        // accepts the read.  FULL must reflect the decremented count at once.
        #1;
        if (dout !== {DATA_WIDTH{1'b0}})
            fail("full-boundary read head was not entry zero");
        wr_en <= 1'b1;
        rd_en <= 1'b1;
        din <= {DATA_WIDTH{1'b1}};
        @(posedge clk);
        #1;
        if (full || empty)
            fail("full-boundary simultaneous request left stale flags");
        if (dout !== {{(DATA_WIDTH-1){1'b0}}, 1'b1})
            fail("full-boundary read did not advance to entry one");

        // Restart the depth test after the explicit full-boundary check.
        wr_en <= 1'b0;
        rd_en <= 1'b0;
        clr <= 1'b1;
        @(posedge clk);
        clr <= 1'b0;
        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            wr_en <= 1'b1;
            din <= i[DATA_WIDTH-1:0];
            @(posedge clk);
        end
        wr_en <= 1'b0;

        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            #1;
            if (empty)
                fail("FIFO became empty before 512 reads");
            if (dout !== i[DATA_WIDTH-1:0]) begin
                $display("[FAIL] read index=%0d expected=%0h actual=%0h", i, i, dout);
                $finish;
            end
            rd_en <= 1'b1;
            @(posedge clk);
        end
        rd_en <= 1'b0;
        #1;
        if (!empty)
            fail("FIFO did not become empty after 512 reads");

        // At empty, the implementation accepts only the write.  EMPTY must
        // deassert immediately and expose the newly written word.
        wr_en <= 1'b1;
        rd_en <= 1'b1;
        din <= 16'hbeef;
        @(posedge clk);
        #1;
        if (empty || full || dout !== 16'hbeef)
            fail("empty-boundary simultaneous request left stale flags/data");
        wr_en <= 1'b0;
        rd_en <= 1'b1;
        @(posedge clk);
        #1;
        if (!empty)
            fail("FIFO did not return to empty after boundary read");
        rd_en <= 1'b0;

        $display("[PASS] 512-entry FIFO preserves all entries and boundary flags");
        $finish;
    end
endmodule
