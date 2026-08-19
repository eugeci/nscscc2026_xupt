// ============================================================================
// File Name   : lbp_extractor.v
// Description : 纯硬件 LBP (局部二值模式) 特征提取器
//               利用 line_buffer 提取 3x3 窗口，生成 8-bit 纹理特征
// ============================================================================

module lbp_extractor #(
    parameter IMG_W = 160,
    parameter IMG_H = 120
)(
    input  wire        clk,
    input  wire        rst_n,

    // 输入 160x120 灰度像素流 (来自降采样模块)
    input  wire [7:0]  pixel_in,
    input  wire        valid_in,

    // 输出 160x120 LBP 特征图 (送给 CNN Layer 0)
    output reg  [7:0]  lbp_out,
    output reg         valid_out,
    output reg  [7:0]  out_x,
    output reg  [7:0]  out_y
);

    // ==========================================
    // 1. 例化行缓冲，提取 3x3 像素窗口
    // ==========================================
    wire [71:0] win_flat;
    wire        win_valid;
    wire [7:0]  win_x;
    wire [7:0]  win_y;

    line_buffer #(
        .DATA_WIDTH(8)
    ) u_lb_3x3 (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_width      (IMG_W[7:0]),
        .cfg_height     (IMG_H[7:0]),
        .kernel_size    (2'b10),     // 强制 3x3 模式
        .padding_en     (1'b1),      // 【关键】：开启边缘补零，确保输出分辨率严格保持 160x120
        .data_in        (pixel_in),
        .data_in_valid  (valid_in),
        .win_out_flat   (win_flat),
        .win_valid      (win_valid),
        .out_x          (win_x),
        .out_y          (win_y)
    );

    // ==========================================
    // 2. 映射 9 个像素点 (解包平铺总线)
    // ==========================================
    // 按照 line_buffer 的排列：
    // w0(左上)  w1(正上)  w2(右上)
    // w3(左中)  w4(中心)  w5(右中)
    // w6(左下)  w7(正下)  w8(右下)
    wire [7:0] w0 = win_flat[ 7: 0]; 
    wire [7:0] w1 = win_flat[15: 8]; 
    wire [7:0] w2 = win_flat[23:16]; 
    wire [7:0] w3 = win_flat[31:24]; 
    wire [7:0] w4 = win_flat[39:32]; // w4 是阈值中心点
    wire [7:0] w5 = win_flat[47:40]; 
    wire [7:0] w6 = win_flat[55:48]; 
    wire [7:0] w7 = win_flat[63:56]; 
    wire [7:0] w8 = win_flat[71:64]; 

    // ==========================================
    // 3. LBP 核心逻辑：阈值比较 (纯组合逻辑)
    // ==========================================
    // 规则：周围像素 >= 中心像素，则置 1，否则置 0。
    // 位序对齐 face/webcam_inference.py::compute_lbp_fast:
    // bit7=左上, bit6=正上, bit5=右上, bit4=右中,
    // bit3=右下, bit2=正下, bit1=左下, bit0=左中。
    wire b7 = (w0 >= w4) ? 1'b1 : 1'b0;
    wire b6 = (w1 >= w4) ? 1'b1 : 1'b0;
    wire b5 = (w2 >= w4) ? 1'b1 : 1'b0;
    wire b4 = (w5 >= w4) ? 1'b1 : 1'b0;
    wire b3 = (w8 >= w4) ? 1'b1 : 1'b0;
    wire b2 = (w7 >= w4) ? 1'b1 : 1'b0;
    wire b1 = (w6 >= w4) ? 1'b1 : 1'b0;
    wire b0 = (w3 >= w4) ? 1'b1 : 1'b0;

    // ==========================================
    // 4. 打一拍寄存输出 (提升 Fmax，改善时序)
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lbp_out   <= 8'd0;
            valid_out <= 1'b0;
            out_x     <= 8'd0;
            out_y     <= 8'd0;
        end else begin
            valid_out <= win_valid;
            out_x     <= win_x;
            out_y     <= win_y;
            
            if (win_valid) begin
                // 拼接出最终的 8-bit LBP 特征像素
                lbp_out <= {b7, b6, b5, b4, b3, b2, b1, b0};
            end
        end
    end

endmodule
