`timescale 1ns/1ps

module tb_peripheral_irq_cdc;
    localparam integer WIDTH    = 6;
    localparam integer MAC_BIT  = 0;
    localparam integer UART_BIT = 1;
    localparam integer SPI_BIT  = 2;
    localparam integer NAND_BIT = 3;
    localparam integer DMA_BIT  = 4;
    localparam integer NPU_BIT  = 5;
    localparam logic [WIDTH-1:0] LEVEL_IRQ_MASK =
        (1 << MAC_BIT) | (1 << UART_BIT) | (1 << SPI_BIT) | (1 << NPU_BIT);

    reg                  src_clk;
    reg                  dst_clk;
    reg                  resetn;
    reg  [WIDTH-1:0]     irq_src;
    wire [WIDTH-1:0]     irq_dst;

    integer errors;
    integer pulse_cycles;
    integer level_cycles;

    peripheral_irq_cdc #(
        .WIDTH(WIDTH)
    ) dut (
        .src_clk(src_clk),
        .dst_clk(dst_clk),
        .resetn(resetn),
        .irq_src(irq_src),
        .irq_dst(irq_dst)
    );

    initial begin
        src_clk = 1'b0;
        forever #3 src_clk = ~src_clk;
    end

    initial begin
        dst_clk = 1'b0;
        forever #11 dst_clk = ~dst_clk;
    end

    task automatic check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (!condition) begin
                $display("[FAIL] %0s", message);
                errors = errors + 1;
            end
        end
    endtask

    // Generate exactly one source-clock pulse wholly between two destination
    // rising edges. The ordinary level synchronizer therefore cannot observe
    // it; delivery must come from the event-toggle path.
    task automatic inject_short_pulse;
        input integer bit_index;
        begin
            @(posedge dst_clk);
            #1;
            @(negedge src_clk);
            irq_src[bit_index] = 1'b1;
            @(negedge src_clk);
            irq_src[bit_index] = 1'b0;
        end
    endtask

    task automatic expect_short_event;
        input integer bit_index;
        input [8*32-1:0] name;
        integer cycle;
        begin
            pulse_cycles = 0;
            level_cycles = 0;
            for (cycle = 0; cycle < 6; cycle = cycle + 1) begin
                @(posedge dst_clk);
                #1;
                if (irq_dst[bit_index])
                    pulse_cycles = pulse_cycles + 1;
                if (dut.level_sync_dst[bit_index])
                    level_cycles = level_cycles + 1;
            end
            check(pulse_cycles == 1,
                  {name, " short event was not delivered for exactly one CPU cycle"});
            check(level_cycles == 0,
                  {name, " test pulse unexpectedly reached the level synchronizer"});
        end
    endtask

    initial begin
        resetn      = 1'b0;
        irq_src     = {WIDTH{1'b0}};
        errors      = 0;
        pulse_cycles = 0;
        level_cycles = 0;

        repeat (3) @(posedge dst_clk);
        resetn = 1'b1;
        repeat (3) @(posedge dst_clk);

        // DMA completion is currently a one-aclk pulse. Exercise it twice to
        // prove separate transactions are not lost by the CPU clock crossing.
        inject_short_pulse(DMA_BIT);
        expect_short_event(DMA_BIT, "DMA");
        inject_short_pulse(DMA_BIT);
        expect_short_event(DMA_BIT, "DMA repeat");

        // NAND completion can also be shorter than a CPU clock period.
        inject_short_pulse(NAND_BIT);
        expect_short_event(NAND_BIT, "NAND");

        // Normal level sources must remain asserted rather than being reduced
        // to one-cycle events. Exercise every current level IRQ vector bit at
        // once: MAC, UART, SPI, and NPU.
        @(negedge src_clk);
        irq_src = LEVEL_IRQ_MASK;
        repeat (4) @(posedge dst_clk);
        #1;
        check((irq_dst & LEVEL_IRQ_MASK) === LEVEL_IRQ_MASK,
              "one or more level interrupts did not reach the CPU domain");
        repeat (3) begin
            @(posedge dst_clk);
            #1;
            check((irq_dst & LEVEL_IRQ_MASK) === LEVEL_IRQ_MASK,
                  "one or more level interrupts did not remain asserted");
        end

        @(negedge src_clk);
        irq_src = {WIDTH{1'b0}};
        repeat (4) @(posedge dst_clk);
        #1;
        check((irq_dst & LEVEL_IRQ_MASK) === {WIDTH{1'b0}},
              "one or more level interrupts did not deassert after synchronization");

        check(irq_dst == {WIDTH{1'b0}},
              "an unrelated peripheral interrupt was asserted");

        if (errors == 0) begin
            $display("[PASS] peripheral IRQ CDC preserves levels and short pulses");
            $finish;
        end

        $fatal(1, "[FAIL] peripheral IRQ CDC test had %0d error(s)", errors);
    end

    initial begin
        #10000;
        $fatal(1, "[FAIL] peripheral IRQ CDC test timed out");
    end
endmodule
