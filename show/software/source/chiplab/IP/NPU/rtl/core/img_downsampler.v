// ============================================================================
// Module      : img_downsampler
// Description : 固定 4:1 双线性 resize 近似 (640x480 -> 160x120)
//
//               对齐软件训练/推理路径中的 resize -> gray -> LBP 顺序。
//               对 4:1 固定比例，OpenCV/Pillow bilinear 的目标像素中心
//               对应源坐标:
//                   src_x = (dst_x + 0.5) * 4 - 0.5 = 4*dst_x + 1.5
//                   src_y = (dst_y + 0.5) * 4 - 0.5 = 4*dst_y + 1.5
//               因此每个输出像素等价于源图 2x2 中心块平均:
//                   round((p[4y+1,4x+1] + p[4y+1,4x+2]
//                        + p[4y+2,4x+1] + p[4y+2,4x+2]) / 4)
// ============================================================================
module img_downsampler #(
    parameter IMG_W = 640,
    parameter IMG_H = 480
)(
    input  wire        clk,
    input  wire        rst_n,

    // 输入原始像素流 (640x480)
    input  wire [7:0]  pixel_in,
    input  wire        valid_in,

    // 输出降采样像素流 (160x120)
    output wire [7:0]  pixel_out,
    output reg         valid_out
);

    // 内部行列计数器 (至少需要 10 bit 才能数到 640)
    reg [9:0] cnt_x;
    reg [9:0] cnt_y;

    // 1. 行列坐标追踪
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_x <= 0;
            cnt_y <= 0;
        end else if (valid_in) begin
            if (cnt_x == IMG_W - 1) begin
                cnt_x <= 0;
                if (cnt_y == IMG_H - 1)
                    cnt_y <= 0;
                else
                    cnt_y <= cnt_y + 1;
            end else begin
                cnt_x <= cnt_x + 1;
            end
        end
    end

    // 2. 保存上一行灰度。只需在 y%4==2 时使用上一行 y%4==1 的像素。
    reg [7:0] prev_line [0:IMG_W-1];
    always @(posedge clk) begin
        if (valid_in) begin
            prev_line[cnt_x] <= pixel_in;
        end
    end

    // 3. 固定 2x2 中心块平均。输出时刻为当前像素 (x%4==2,y%4==2),
    //    此时:
    //      prev_left, prev_line[x] = 上一行两个中心像素
    //      cur_left,  pixel_in     = 当前行两个中心像素
    reg [7:0] cur_left;
    reg [7:0] prev_left;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_left <= 8'd0;
            prev_left <= 8'd0;
        end else if (valid_in) begin
            cur_left  <= pixel_in;
            prev_left <= prev_line[cnt_x];
        end
    end

    wire emit_pixel = valid_in &&
                      (cnt_x[1:0] == 2'b10) &&
                      (cnt_y[1:0] == 2'b10);
    wire [9:0] sum_2x2 = {2'd0, prev_left} +
                         {2'd0, prev_line[cnt_x]} +
                         {2'd0, cur_left} +
                         {2'd0, pixel_in};
    wire [7:0] avg_2x2 = (sum_2x2 + 10'd2) >> 2;

    // 4. 输出寄存 (打一拍改善时序)
    reg [7:0] pixel_out_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_out_reg <= 0;
            valid_out     <= 0;
        end else begin
            valid_out <= emit_pixel;
            if (emit_pixel)
                pixel_out_reg <= avg_2x2;
        end
    end

    assign pixel_out = pixel_out_reg;

endmodule
