`timescale 1ns/1ps

module tb_uart_rx_burst;
    localparam int DIVISOR = 18;
    localparam int BIT_CYCLES = DIVISOR * 16;
    localparam int BYTE_COUNT = 32;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic psel = 1'b0;
    logic penable = 1'b0;
    logic pwrite = 1'b0;
    logic [7:0] paddr = 8'd0;
    logic [7:0] pwdata = 8'd0;
    logic rxd = 1'b1;
    wire [7:0] prdata;
    wire irq;
    wire txd;
    byte received [0:BYTE_COUNT-1];
    integer received_count = 0;

    always #5 clk = ~clk;

    UART_TOP dut (
        .PCLK(clk), .PRST_(rst_n),
        .PSEL(psel), .PENABLE(penable), .PADDR(paddr),
        .PWRITE(pwrite), .PWDATA(pwdata), .URT_PRDATA(prdata),
        .INT(irq), .clk_carrier(1'b0),
        .TXD_i(1'b1), .TXD_o(txd), .TXD_oe(),
        .RXD_i(rxd), .RXD_o(), .RXD_oe(),
        .RTS(), .CTS(1'b0), .DSR(1'b0), .DCD(1'b0),
        .DTR(), .RI(1'b0)
    );

    task automatic apb_write(input [2:0] addr, input [7:0] data);
        @(negedge clk);
        psel = 1'b1;
        penable = 1'b1;
        pwrite = 1'b1;
        paddr = {5'd0, addr};
        pwdata = data;
        @(negedge clk);
        psel = 1'b0;
        penable = 1'b0;
        pwrite = 1'b0;
    endtask

    task automatic apb_read(input [2:0] addr, output [7:0] data);
        @(negedge clk);
        psel = 1'b1;
        penable = 1'b1;
        pwrite = 1'b0;
        paddr = {5'd0, addr};
        @(posedge clk);
        data = prdata;
        @(negedge clk);
        psel = 1'b0;
        penable = 1'b0;
        // The real AXI bridge returns the prior response and leaves enough
        // cycles for the synchronous FIFO read port to follow the new bottom
        // pointer before it launches another APB transaction.
        repeat (2) @(posedge clk);
    endtask

    task automatic send_byte(input [7:0] data);
        rxd = 1'b0;
        repeat (BIT_CYCLES) @(posedge clk);
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            rxd = data[bit_index];
            repeat (BIT_CYCLES) @(posedge clk);
        end
        rxd = 1'b1;
        repeat (BIT_CYCLES) @(posedge clk);
    endtask

    initial begin
        byte value;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        apb_write(3, 8'h83);       // DLAB, 8N1
        apb_write(0, DIVISOR[7:0]);
        apb_write(1, 8'd0);
        apb_write(2, 8'd0);
        apb_write(3, 8'h03);       // 8N1, clear DLAB
        apb_write(2, 8'h82);       // RX reset, FIFO trigger level 8
        apb_write(1, 8'h01);       // received-data interrupt enable

        fork
            begin : sender
                for (int index = 0; index < BYTE_COUNT; index++)
                    send_byte(8'h40 + index[7:0]);
            end
            begin : interrupt_service
                while (received_count < BYTE_COUNT) begin
                    wait (irq === 1'b1);
                    // Keep a realistic but comfortably bounded interrupt
                    // entry delay while bytes continue arriving.
                    repeat (100) @(posedge clk);
                    while (dut.regs.receiver.rf_count != 0) begin
                        apb_read(0, value);
                        received[received_count] = value;
                        received_count = received_count + 1;
                    end
                end
            end
        join

        for (int index = 0; index < BYTE_COUNT; index++) begin
            if (received[index] !== (8'h40 + index[7:0]))
                $fatal(1,
                       "UART_RX_BURST_FAIL index=%0d expected=%02x got=%02x",
                       index, 8'h40 + index[7:0], received[index]);
        end
        if (dut.regs.receiver.rf_overrun !== 1'b0)
            $fatal(1, "UART_RX_BURST_FAIL FIFO overrun");
        $display("UART_RX_BURST_PASS count=%0d", received_count);
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "UART_RX_BURST_FAIL timeout count=%0d fifo=%0d irq=%0b",
               received_count, dut.regs.receiver.rf_count, irq);
    end
endmodule
