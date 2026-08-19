// -----------------------------------------------------------------------------
// npu_xor_fold
// -----------------------------------------------------------------------------
// Fold a wide bus into OUT_WIDTH bits by XORing OUT_WIDTH-wide lanes.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module npu_xor_fold #(
    parameter IN_WIDTH  = 128,
    parameter OUT_WIDTH = 32
) (
    input  wire [IN_WIDTH-1:0]  i_data,
    output wire [OUT_WIDTH-1:0] o_fold
);
    localparam LANES        = (IN_WIDTH + OUT_WIDTH - 1) / OUT_WIDTH;
    localparam PADDED_WIDTH = LANES * OUT_WIDTH;

    wire [PADDED_WIDTH-1:0] w_padded_data;

    generate
        if (PADDED_WIDTH == IN_WIDTH) begin : G_NO_PAD
            assign w_padded_data = i_data;
        end else begin : G_PAD
            assign w_padded_data = {{(PADDED_WIDTH-IN_WIDTH){1'b0}}, i_data};
        end
    endgenerate

    genvar bit_idx;
    genvar lane_idx;
    generate
        for (bit_idx = 0; bit_idx < OUT_WIDTH; bit_idx = bit_idx + 1) begin : G_FOLD_BIT
            wire [LANES-1:0] w_fold_bits;
            for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin : G_LANE
                assign w_fold_bits[lane_idx] = w_padded_data[(lane_idx*OUT_WIDTH) + bit_idx];
            end
            assign o_fold[bit_idx] = ^w_fold_bits;
        end
    endgenerate
endmodule
