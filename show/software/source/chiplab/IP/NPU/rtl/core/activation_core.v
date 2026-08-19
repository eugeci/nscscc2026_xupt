// ----------------------------------------------------------------------------
// Activation Core (含 ReLU 与 HardSigmoid)
// ----------------------------------------------------------------------------
module activation_core #(
    parameter ACC_WIDTH    = 32,
    parameter NUM_CHANNELS = 16
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [1:0]             cfg_activation_type, // 0: ReLU, 1: HardSigmoid
    input  wire[ACC_WIDTH*NUM_CHANNELS-1:0]  in_sum_bus,
    input  wire                   in_valid,
    input  wire [7:0]             in_x,
    input  wire [7:0]             in_y,

    output wire [ACC_WIDTH*NUM_CHANNELS-1:0]  act_out_bus,
    output wire                   act_valid,
    output reg  [7:0]             act_x,
    output reg  [7:0]             act_y
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_x <= 8'd0; act_y <= 8'd0;
        end else if (in_valid) begin
            act_x <= in_x; act_y <= in_y;
        end
    end

    wire [NUM_CHANNELS-1:0] valid_array;
    genvar i;
    generate
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin : ACT_ARRAY
            activation_single #(.ACC_WIDTH(ACC_WIDTH)) u_act_1ch (
                .clk                 (clk),
                .rst_n               (rst_n),
                .cfg_activation_type (cfg_activation_type),
                .in_sum              (in_sum_bus[i*ACC_WIDTH +: ACC_WIDTH]),
                .in_valid            (in_valid),
                .out_act             (act_out_bus[i*ACC_WIDTH +: ACC_WIDTH]),
                .out_valid           (valid_array[i])
            );
        end
    endgenerate
    assign act_valid = valid_array[0];
endmodule