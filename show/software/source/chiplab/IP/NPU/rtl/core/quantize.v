// ----------------------------------------------------------------------------
// 5. Quantize 
// [修复]：强化防呆设计，处理 INT8 严重下溢
// ----------------------------------------------------------------------------
module quantize #(
    parameter ACC_WIDTH    = 32,
    parameter NUM_CHANNELS = 16
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [ACC_WIDTH*NUM_CHANNELS-1:0]  act_out_bus,
    input  wire                   act_valid,
    input  wire[7:0]             act_x,
    input  wire [7:0]             act_y,
    input  wire [3:0]             shift_bits,

    output wire[NUM_CHANNELS*8-1:0]          out_pixel_bus,
    output wire                   out_valid,
    output reg  [7:0]             out_x,
    output reg  [7:0]             out_y
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_x <= 8'd0; out_y <= 8'd0;
        end else if (act_valid) begin
            out_x <= act_x; out_y <= act_y;
        end
    end

    wire[NUM_CHANNELS-1:0] valid_array;
    genvar i;
    generate
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin : QUANT_ARRAY
            quantize_single #(.ACC_WIDTH(ACC_WIDTH)) u_q (
                .clk        (clk),
                .rst_n      (rst_n),
                .in_act     (act_out_bus[i*ACC_WIDTH +: ACC_WIDTH]),
                .in_valid   (act_valid),
                .shift_bits (shift_bits),
                .out_pixel  (out_pixel_bus[i*8 +: 8]),
                .out_valid  (valid_array[i])
            );
        end
    endgenerate
    assign out_valid = valid_array[0];
endmodule