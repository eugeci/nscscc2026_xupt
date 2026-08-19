// ----------------------------------------------------------------------------
// Bias Buffer
// 分组偏置双缓冲：每页 16 路 INT32，DMA 写闲页，update_bias_en 末沿切页
// ----------------------------------------------------------------------------
module bias_buffer #(
    parameter NUM_CHANNELS = 16
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // DMA 写入接口
    input  wire [31:0]                   bias_in_data,
    input  wire                          bias_in_valid,
    input  wire [4:0]                    bias_in_addr,
    input  wire                          update_bias_en,

    // 当前计算页偏置总线
    output reg  [NUM_CHANNELS*32-1:0]    bias_bus_out
);
    reg [31:0] bias_page [0:1][0:NUM_CHANNELS-1];
    reg        active_page;
    reg        dma_page;
    reg        update_en_d;

    wire update_fall = update_en_d && !update_bias_en;

    integer page_i, ch_i, map_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_page <= 1'b0;
            dma_page    <= 1'b0;
            update_en_d <= 1'b0;
            for (page_i = 0; page_i < 2; page_i = page_i + 1) begin
                for (ch_i = 0; ch_i < NUM_CHANNELS; ch_i = ch_i + 1)
                    bias_page[page_i][ch_i] <= 32'd0;
            end
        end else begin
            update_en_d <= update_bias_en;

            if (bias_in_valid && (bias_in_addr < NUM_CHANNELS))
                bias_page[dma_page][bias_in_addr] <= bias_in_data;

            if (update_fall) begin
                active_page <= dma_page;
                dma_page    <= ~dma_page;
            end
        end
    end

    always @(*) begin
        for (map_i = 0; map_i < NUM_CHANNELS; map_i = map_i + 1)
            bias_bus_out[map_i*32 +: 32] = bias_page[active_page][map_i];
    end
endmodule
