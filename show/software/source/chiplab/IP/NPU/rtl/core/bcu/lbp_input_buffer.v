// -----------------------------------------------------------------------------
// Module      : lbp_input_buffer
// Description : Layer-0 LBP 输入图像专用单 bank BRAM。
//               深度 20480 (15b 地址)，承载 160x120=19200 像素 LBP 图像。
//               与 fm_bank_array (8K) 解耦，避免 layer-0 单通道输入挤占
//               其余层的 16-bank 激活存储空间。
//               单端口 8b 写入 + 单端口 8b 读出，1 拍读延迟。
//
// Lifecycle   :
//   - 写入 : npu_sequencer ST_LOAD_IMG 状态期间，每 i_lbp_valid 拍写一次
//   - 读取 : layer-0 ST_CALC 期间，BCU 以 r_pixel_cnt 顺序读出
//   - 复用 : 下一帧到来时（ST_IDLE→ST_LOAD_IMG）原地覆盖写入
//
// BRAM 占用 : 20480 * 8b = 160 Kb ≈ 40 个 M4K (512x9 配置)
// -----------------------------------------------------------------------------
module lbp_input_buffer (
    input  wire        clk,

    // Write Port (single 8-bit, sequential pixel-stream)
    input  wire        i_write_en,
    input  wire [14:0] i_write_addr,
    input  wire [7:0]  i_write_data,

    // Read Port (single 8-bit, BCU pixel scan)
    input  wire        i_read_en,
    input  wire [14:0] i_read_addr,
`ifdef NPU_USE_XPM_BRAM
    output wire [7:0]  o_read_data
`else
    output reg  [7:0]  o_read_data
`endif
);

`ifdef NPU_USE_XPM_BRAM
    npu_xilinx_sdpram #(
        .DATA_WIDTH  (8),
        .ADDR_WIDTH  (15),
        .MEMORY_DEPTH(20480)
    ) u_lbp_bram (
        .clk     (clk),
        .wr_en   (i_write_en),
        .wr_strb (1'b1),
        .wr_addr (i_write_addr),
        .wr_data (i_write_data),
        .rd_en   (i_read_en),
        .rd_addr (i_read_addr),
        .rd_data (o_read_data)
    );
`else
    // 强制推断为 Block RAM
    (* ram_style = "block" *) reg [7:0] mem [0:20479];

    // 写入逻辑
    always @(posedge clk) begin
        if (i_write_en) begin
            mem[i_write_addr] <= i_write_data;
        end
    end

    // 读取逻辑（同步读，1 拍延迟，与 fm_bank_array 一致）
    always @(posedge clk) begin
        if (i_read_en) begin
            o_read_data <= mem[i_read_addr];
        end
    end
`endif

endmodule
