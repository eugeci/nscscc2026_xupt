// ============================================================================
// Module      : max_pool.v
// Description : 参数化多通道最大池化顶层（支持 8/16/32 等并行通道数）
//               内部例化 NUM_CHANNELS 个单通道 2x2 池化核心
// ============================================================================

module max_pool #(
    parameter NUM_CHANNELS = 16          // 并行输出通道数（默认 16）
) (
    input  wire                                 clk,
    input  wire                                 rst_n,

    // 输入总线（4 组像素总线，每组位宽 = NUM_CHANNELS * 8）
    input  wire [NUM_CHANNELS*8-1:0]            in_p00_bus,
    input  wire [NUM_CHANNELS*8-1:0]            in_p01_bus,
    input  wire [NUM_CHANNELS*8-1:0]            in_p10_bus,
    input  wire [NUM_CHANNELS*8-1:0]            in_p11_bus,
    input  wire                                 in_valid,
    input  wire [7:0]                           in_x,
    input  wire [7:0]                           in_y,

    // 输出总线（位宽 = NUM_CHANNELS * 8）
    output wire [NUM_CHANNELS*8-1:0]            out_pixel_bus,
    output wire                                 out_valid,
    output wire [7:0]                           out_x,
    output wire [7:0]                           out_y
);

    // ------------------------------------------------------------------------
    // 内部连线：每个通道的 valid、x、y 信号
    // ------------------------------------------------------------------------
    wire [NUM_CHANNELS-1:0] pool_valids;
    wire [7:0] pool_x_array [0:NUM_CHANNELS-1];
    wire [7:0] pool_y_array [0:NUM_CHANNELS-1];

    // ------------------------------------------------------------------------
    // 生成 NUM_CHANNELS 个单通道池化核心
    // ------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin : gen_pool_cores
            max_pool_2x2 #(
                .DATA_WIDTH(8)                     // 单通道像素位宽固定为 8
            ) u_pool (
                .clk       (clk),
                .rst_n     (rst_n),
                .p00       (in_p00_bus[i*8 +: 8]),
                .p01       (in_p01_bus[i*8 +: 8]),
                .p10       (in_p10_bus[i*8 +: 8]),
                .p11       (in_p11_bus[i*8 +: 8]),
                .valid_in  (in_valid),
                .x_in      (in_x),
                .y_in      (in_y),
                .data_out  (out_pixel_bus[i*8 +: 8]),
                .valid_out (pool_valids[i]),
                .pool_x    (pool_x_array[i]),
                .pool_y    (pool_y_array[i])
            );
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 统一输出信号（所有通道的 valid/x/y 完全同步，取通道 0 即可）
    // ------------------------------------------------------------------------
    assign out_valid = pool_valids[0];
    assign out_x     = pool_x_array[0];
    assign out_y     = pool_y_array[0];

endmodule