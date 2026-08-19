// ============================================================================
// Module      : max_pool_2x2.v
// Description : 纯粹的 2x2 最大池化计算单元 (无旁路逻辑)
// ============================================================================

module max_pool_2x2 #(
    parameter DATA_WIDTH = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // 输入窗口数据
    input  wire [DATA_WIDTH-1:0]  p00, 
    input  wire [DATA_WIDTH-1:0]  p01, 
    input  wire [DATA_WIDTH-1:0]  p10, 
    input  wire [DATA_WIDTH-1:0]  p11,
    input  wire                   valid_in,
    input  wire [7:0]             x_in, 
    input  wire [7:0]             y_in,

    // 输出池化结果
    output reg  [DATA_WIDTH-1:0]  data_out,
    output reg                    valid_out,
    output wire [7:0]             pool_x, // 已完成坐标下采样
    output wire [7:0]             pool_y
);

    reg [DATA_WIDTH-1:0] max_row0, max_row1;
    reg                  v_s1;
    reg [7:0]            x_s1, y_s1, x_s2, y_s2;

    // ------------------------------------------------------------------------
    // Stage 1 : 行比较
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_s1     <= 1'b0; 
            max_row0 <= {DATA_WIDTH{1'b0}}; 
            max_row1 <= {DATA_WIDTH{1'b0}};
            x_s1     <= 8'd0; 
            y_s1     <= 8'd0;
        end else if (valid_in) begin
            max_row0 <= (p00 > p01) ? p00 : p01;
            max_row1 <= (p10 > p11) ? p10 : p11;
            x_s1     <= x_in; 
            y_s1     <= y_in;
            v_s1     <= 1'b1;
        end else begin
            v_s1     <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // Stage 2 : 列比较与输出
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= {DATA_WIDTH{1'b0}}; 
            valid_out <= 1'b0;
            x_s2      <= 8'd0; 
            y_s2      <= 8'd0;
        end else if (v_s1) begin
            data_out  <= (max_row0 > max_row1) ? max_row0 : max_row1;
            x_s2      <= x_s1; 
            y_s2      <= y_s1;
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // 坐标映射：右移 1 位实现维度减半
    // ------------------------------------------------------------------------
    assign pool_x = (x_s2 >> 1);
    assign pool_y = (y_s2 >> 1);

endmodule