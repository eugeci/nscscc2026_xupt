// -----------------------------------------------------------------------------
// weight_kernel_mapper
// -----------------------------------------------------------------------------
// Maps compact 1x1/2x2 weights into the 3x3 grid consumed by the PE array.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module weight_kernel_mapper (
    input  wire [71:0] i_raw_w,
    input  wire [1:0]  i_kernel_size,
    output reg  [71:0] o_mapped_w
);
    localparam MODE_1X1 = 2'b00;
    localparam MODE_2X2 = 2'b01;

    always @(*) begin
        o_mapped_w = 72'd0;
        case (i_kernel_size)
            MODE_1X1: begin
                o_mapped_w[39:32] = i_raw_w[7:0];
            end
            MODE_2X2: begin
                o_mapped_w[7:0]   = i_raw_w[7:0];
                o_mapped_w[15:8]  = i_raw_w[15:8];
                o_mapped_w[31:24] = i_raw_w[23:16];
                o_mapped_w[39:32] = i_raw_w[31:24];
            end
            default: begin
                o_mapped_w = i_raw_w;
            end
        endcase
    end
endmodule
