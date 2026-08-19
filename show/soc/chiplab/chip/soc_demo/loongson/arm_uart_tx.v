`timescale 1ns / 1ps

// Minimal write-only UART transmitter used by the mechanical-arm control port.
// The input valid pulse is accepted only while busy is low.
module arm_uart_tx #(
    parameter integer CLK_FREQ_HZ = 33000000,
    parameter integer BAUD_RATE   = 9600
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire [7:0] data,
    input  wire       valid,
    output reg        busy,
    output reg        tx
);

localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
localparam integer COUNT_WIDTH  = $clog2(CLKS_PER_BIT);

reg [COUNT_WIDTH-1:0] baud_count;
reg [3:0]             bit_index;
reg [7:0]             data_latched;

always @(posedge clk) begin
    if (!resetn) begin
        busy         <= 1'b0;
        tx           <= 1'b1;
        baud_count   <= {COUNT_WIDTH{1'b0}};
        bit_index    <= 4'd0;
        data_latched <= 8'd0;
    end else if (!busy) begin
        tx         <= 1'b1;
        baud_count <= {COUNT_WIDTH{1'b0}};
        bit_index  <= 4'd0;
        if (valid) begin
            data_latched <= data;
            busy         <= 1'b1;
            tx           <= 1'b0; // start bit
        end
    end else if (baud_count == CLKS_PER_BIT - 1) begin
        baud_count <= {COUNT_WIDTH{1'b0}};
        if (bit_index < 4'd8) begin
            tx        <= data_latched[bit_index];
            bit_index <= bit_index + 1'b1;
        end else begin
            tx        <= 1'b1; // stop bit
            bit_index <= bit_index + 1'b1;
            if (bit_index == 4'd9)
                busy <= 1'b0;
        end
    end else begin
        baud_count <= baud_count + 1'b1;
    end
end

endmodule
