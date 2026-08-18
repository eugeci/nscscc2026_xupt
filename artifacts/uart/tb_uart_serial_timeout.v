module tb_uart_serial_timeout;
    localparam integer DIVISOR = 18;
    localparam integer BIT_CLOCKS = DIVISOR * 16;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [2:0] addr = 3'd0;
    reg [7:0] dat_i = 8'd0;
    reg we = 1'b0;
    reg re = 1'b0;
    reg serial_rx = 1'b1;
    wire [7:0] dat_o;
    wire int_o;
    wire stx_pad_o;
    wire rts_pad_o;
    wire dtr_pad_o;
    wire rxd_o;
    wire usart_mode;
    wire rx_en;
    wire tx2rx_en;
    integer bit_index;
    integer wait_count;

    always #5 clk = ~clk;

    uart_regs dut (
        .clk(clk), .rst(rst), .clk_carrier(1'b0),
        .addr(addr), .dat_i(dat_i), .dat_o(dat_o), .we(we), .re(re),
        .modem_inputs(4'b1111), .rts_pad_o(rts_pad_o),
        .dtr_pad_o(dtr_pad_o), .stx_pad_o(stx_pad_o), .TXD_i(1'b1),
        .srx_pad_i(serial_rx), .RXD_o(rxd_o), .int_o(int_o),
        .usart_mode(usart_mode), .rx_en(rx_en), .tx2rx_en(tx2rx_en)
    );

    task write_reg;
        input [2:0] reg_addr;
        input [7:0] value;
        begin
            @(negedge clk);
            addr = reg_addr;
            dat_i = value;
            we = 1'b1;
            @(negedge clk);
            we = 1'b0;
        end
    endtask

    task send_byte;
        input [7:0] value;
        begin
            serial_rx = 1'b0;
            repeat (BIT_CLOCKS) @(negedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                serial_rx = value[bit_index];
                repeat (BIT_CLOCKS) @(negedge clk);
            end
            serial_rx = 1'b1;
            repeat (BIT_CLOCKS) @(negedge clk);
        end
    endtask

    initial begin
        repeat (8) @(negedge clk);
        rst = 1'b0;

        write_reg(3'd3, 8'h83);
        write_reg(3'd0, DIVISOR[7:0]);
        write_reg(3'd1, 8'h00);
        write_reg(3'd3, 8'h03);
        write_reg(3'd2, 8'h81);
        write_reg(3'd1, 8'h05);

        repeat (BIT_CLOCKS) @(negedge clk);
        send_byte(8'h68);

        wait_count = 0;
        while (dut.rf_count != 5'd1 && wait_count < BIT_CLOCKS * 4) begin
            @(negedge clk);
            wait_count = wait_count + 1;
        end
        if (dut.rf_count != 5'd1)
            $fatal(1, "serial byte never reached RX FIFO count=%0d state=%0d",
                   dut.rf_count, dut.rstate);

        wait_count = 0;
        while (!int_o && wait_count < BIT_CLOCKS * 80) begin
            @(negedge clk);
            wait_count = wait_count + 1;
        end
        if (!int_o)
            $fatal(1, "serial timeout IRQ never asserted count=%0d counter_t=%0d ti=%b pnd=%b ier=%h",
                   dut.rf_count, dut.counter_t, dut.ti_int,
                   dut.ti_int_pnd, dut.ier);
        if (dut.iir[3:1] !== 3'b110 || dut.iir[0] !== 1'b0)
            $fatal(1, "serial timeout IIR wrong: %b", dut.iir);

        $display("UART_SERIAL_TIMEOUT_PASS count=%0d counter_t=%0d iir=0x0c ier=%h",
                 dut.rf_count, dut.counter_t, dut.ier);
        $finish;
    end
endmodule
