module activation_single #(
    parameter ACC_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire[1:0]             cfg_activation_type,
    input  wire signed [ACC_WIDTH-1:0] in_sum,
    input  wire                   in_valid,
    output reg  signed[ACC_WIDTH-1:0] out_act,
    output reg                    out_valid
);
    // 【硬件魔法】拓宽位宽防溢出，用纯组合移位替代 (x+3)/6 的 DSP 除法
    // 1/6 近似于 43/256。 43 = 32 + 8 + 2 + 1。
    wire signed [ACC_WIDTH:0] act_plus_3 = in_sum + 3; // 强行拓宽1位防呆
    
    wire signed[ACC_WIDTH:0] sum_x1  = act_plus_3;
    wire signed [ACC_WIDTH:0] sum_x2  = act_plus_3 <<< 1;
    wire signed [ACC_WIDTH:0] sum_x8  = act_plus_3 <<< 3;
    wire signed [ACC_WIDTH:0] sum_x32 = act_plus_3 <<< 5;
    
    wire signed[ACC_WIDTH-1:0] hardsig_val = (sum_x1 + sum_x2 + sum_x8 + sum_x32) >>> 8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_act   <= 0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid; 
            if (in_valid) begin
                if (cfg_activation_type == 2'b01) begin // HardSigmoid
                    out_act <= hardsig_val;
                end else begin                          // ReLU (Default)
                    out_act <= (in_sum < 0) ? 0 : in_sum;
                end
            end
        end
    end
endmodule