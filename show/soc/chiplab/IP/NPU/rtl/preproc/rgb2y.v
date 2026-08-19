// ============================================================================
// File Name   : rgb2y.v
// Description : RGB888 -> 8-bit luminance (Y) 转换。
//               与 OpenCV cv2.cvtColor(BGR, COLOR_BGR2GRAY) 严格 bit-true 对齐:
//                 Y = (B*1868 + G*9617 + R*4899 + 8192) >> 14
//               OpenCV 内部使用上述定点系数 (Q14)。系数和等于 16384, 误差 ≤ 1。
//
//               一拍组合 + 一拍寄存 (流水线友好), 不引入 valid 翻转。
//               输入 valid_in 高时 Y 在 1 拍后跟随 valid_out 输出。
//
//               用途: 摄像头 RGB888 -> NPU 预处理链 第 1 段。
// ============================================================================
module rgb2y (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        valid_in,
    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,

    output reg         valid_out,
    output reg  [7:0]  y_out
);

    // OpenCV BT.601 全范围灰度系数 (Q14):
    //   B*1868 + G*9617 + R*4899 + (1<<13) >> 14
    (* multstyle = "logic" *) wire [21:0] mul_b;
    (* multstyle = "logic" *) wire [21:0] mul_g;
    (* multstyle = "logic" *) wire [21:0] mul_r;
    assign mul_b = b_in * 16'd1868;
    assign mul_g = g_in * 16'd9617;
    assign mul_r = r_in * 16'd4899;
    wire [22:0] sum   = mul_b + mul_g + mul_r + 23'd8192;
    wire [7:0]  y_w   = sum[21:14];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            y_out     <= 8'd0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) y_out <= y_w;
        end
    end

endmodule
