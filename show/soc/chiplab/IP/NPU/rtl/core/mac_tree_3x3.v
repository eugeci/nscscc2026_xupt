// ============================================================================
// File Name   : mac_tree_3x3.v
// Description : [对齐增强版] 采用统一移位链，消除采样竞争，确保严格 4 拍延迟
// ============================================================================
module mac_tree_3x3 #(
    parameter PIXEL_W = 8,
    parameter WEIGHT_W = 8,
    parameter OUT_W = 20,
    parameter USE_DSP = 1
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [PIXEL_W*9-1:0]   pixels_flat,
    input  wire [WEIGHT_W*9-1:0]  weights_flat,
    input  wire                   valid_in,
    input  wire [7:0]             x_in, y_in,
    input  wire                   is_first_cin, is_last_cin,

    output reg  signed [OUT_W-1:0] mac_out,
    output reg                    valid_out,
    output reg  [7:0]             x_out, y_out,
    output reg                    first_cin_out, last_cin_out
);

    // 1. 数据级寄存器
    (* use_dsp = "yes" *) reg signed [16:0] prod_dsp [0:8];
    reg signed [16:0] prod_lut [0:8];
    wire signed [16:0] prod [0:8];
    reg signed [17:0] s1_0, s1_1, s1_2, s1_3, s1_4;
    reg signed [18:0] s2_0, s2_1, s2_2;

    // 2. 控制级移位寄存器 (精确匹配数据级数)
    reg [2:0] v_pipe, f_pipe, l_pipe;
    reg [7:0] x_pipe [0:2], y_pipe [0:2];

    integer i;

    // 统一同步块：所有流水线阶段都在 posedge clk 更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位所有寄存器，彻底杜绝 X 态传播
            for (i=0; i<9; i=i+1) begin
                prod_dsp[i] <= 0;
                prod_lut[i] <= 0;
            end
            s1_0 <= 0; s1_1 <= 0; s1_2 <= 0; s1_3 <= 0; s1_4 <= 0;
            s2_0 <= 0; s2_1 <= 0; s2_2 <= 0;
            mac_out <= 0; valid_out <= 0;
            x_out <= 0; y_out <= 0;
            first_cin_out <= 0; last_cin_out <= 0;
            v_pipe <= 0; f_pipe <= 0; l_pipe <= 0;
            for (i=0; i<3; i=i+1) begin x_pipe[i] <= 0; y_pipe[i] <= 0; end
        end else begin
            // --- STAGE 1: Multiplication ---
            for (i = 0; i < 9; i = i + 1) begin
                if (USE_DSP) begin
                    prod_dsp[i] <= $signed({1'b0, pixels_flat[i*PIXEL_W +: PIXEL_W]}) *
                                   $signed(weights_flat[i*WEIGHT_W +: WEIGHT_W]);
                end else begin
                    prod_lut[i] <= $signed({1'b0, pixels_flat[i*PIXEL_W +: PIXEL_W]}) *
                                   $signed(weights_flat[i*WEIGHT_W +: WEIGHT_W]);
                end
            end
            v_pipe[0] <= valid_in;
            f_pipe[0] <= is_first_cin;
            l_pipe[0] <= is_last_cin;
            x_pipe[0] <= x_in;
            y_pipe[0] <= y_in;

            // --- STAGE 2: Adder Tree L1 ---
            s1_0 <= prod[0] + prod[1]; s1_1 <= prod[2] + prod[3];
            s1_2 <= prod[4] + prod[5]; s1_3 <= prod[6] + prod[7];
            s1_4 <= prod[8];
            v_pipe[1] <= v_pipe[0];
            f_pipe[1] <= f_pipe[0];
            l_pipe[1] <= l_pipe[0];
            x_pipe[1] <= x_pipe[0];
            y_pipe[1] <= y_pipe[0];

            // --- STAGE 3: Adder Tree L2 ---
            s2_0 <= s1_0 + s1_1; s2_1 <= s1_2 + s1_3;
            s2_2 <= s1_4;
            v_pipe[2] <= v_pipe[1];
            f_pipe[2] <= f_pipe[1];
            l_pipe[2] <= l_pipe[1];
            x_pipe[2] <= x_pipe[1];
            y_pipe[2] <= y_pipe[1];

            // --- STAGE 4: Final Sum & Alignment ---
            mac_out <= s2_0 + s2_1 + s2_2;
            valid_out <= v_pipe[2];
            x_out <= x_pipe[2];
            y_out <= y_pipe[2];
            first_cin_out <= f_pipe[2];
            last_cin_out <= l_pipe[2];
        end
    end

    genvar gp;
    generate
        for (gp = 0; gp < 9; gp = gp + 1) begin : GEN_PROD_SEL
            assign prod[gp] = USE_DSP ? prod_dsp[gp] : prod_lut[gp];
        end
    endgenerate
endmodule
