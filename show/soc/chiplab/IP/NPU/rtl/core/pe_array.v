// ============================================================================
// File Name   : pe_array.v
// Description : 计算单元顶层 - 8输出通道并行架构
// ============================================================================
module pe_array #(
    parameter PIXEL_W = 8,
    parameter WEIGHT_W = 8,
    parameter ACC_WIDTH = 32,
    parameter NUM_CHANNELS = 16,
    parameter DSP_MAC_LANES = 9
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // 1. 广播级像素总线 (来自 Line Buffer, 72-bit)
    input  wire [PIXEL_W*9-1:0]   win_data_flat, 
    input  wire                   win_valid,
    input  wire [7:0]             win_x,
    input  wire [7:0]             win_y,

    // 2. 独立权重总线 (576-bit = 8通道 * 9个权重 * 8-bit)
    // 权重排列：通道0权重在低 72 位，通道7权重在高 72 位
    input  wire [NUM_CHANNELS*72-1:0]   weights_bus,
    
    // 3. 状态机控制信号
    input  wire [7:0]             cfg_width,
    input  wire                   is_first_cin,
    input  wire                   is_last_cin,

    // 4. 并行累加结果总线 (打包为一维总线)
    // 输出总和为 256-bit (8 * 32-bit)，其他均为 8 位信号阵列
    output wire [ACC_WIDTH*NUM_CHANNELS-1:0] out_sum_bus,
    output wire [NUM_CHANNELS-1:0]       out_valid_bus,
    output wire [NUM_CHANNELS*8-1:0]     out_x_bus, out_y_bus
);

    genvar i;
    generate
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin : PE_CORE
            
            // 为第 i 个核心切片专用的 72-bit 权重
            wire [71:0] cur_weight = weights_bus[i*72 +: 72];
            
            // 内部连线
            wire signed [19:0] mac_res;
            wire               mac_val, mac_first, mac_last;
            wire [7:0]         mac_x, mac_y;

            // cfg_width is constant for a complete layer, but its source is a
            // distant sequencer register.  Preserve one copy per PE so the
            // configuration path ends locally before the accumulator's
            // row-address multiply and BRAM address input.
            (* keep = "true" *) reg [7:0] cfg_width_local;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    cfg_width_local <= 8'd0;
                else
                    cfg_width_local <= cfg_width;
            end

            // 例化算力引擎
            mac_tree_3x3 #(
                .PIXEL_W (PIXEL_W),
                .WEIGHT_W(WEIGHT_W),
                .OUT_W   (20),
                .USE_DSP ((i < DSP_MAC_LANES) ? 1 : 0)
            ) u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                .pixels_flat  (win_data_flat),
                .weights_flat (cur_weight),
                .valid_in     (win_valid),
                .x_in         (win_x),
                .y_in         (win_y),
                .is_first_cin (is_first_cin),
                .is_last_cin  (is_last_cin),
                .mac_out      (mac_res),
                .valid_out    (mac_val),
                .x_out        (mac_x),
                .y_out        (mac_y),
                .first_cin_out(mac_first),
                .last_cin_out (mac_last)
            );

            // 例化通道累加器
            channel_accumulator #(
                .ACC_WIDTH(ACC_WIDTH)
            ) u_acc (
                .clk             (clk),
                .rst_n           (rst_n),
                .cfg_width       (cfg_width_local),
                .is_first_cin    (mac_first),
                .is_last_cin     (mac_last),
                .mac_data        (mac_res),
                .mac_valid       (mac_val),
                .mac_x           (mac_x),
                .mac_y           (mac_y),
                
                // 输出结果打包进顶层总线
                .final_sum       (out_sum_bus[i*ACC_WIDTH +: ACC_WIDTH]),
                .final_valid     (out_valid_bus[i]),
                .final_x         (out_x_bus[i*8 +: 8]),
                .final_y         (out_y_bus[i*8 +: 8])
            );
        end
    endgenerate

endmodule
