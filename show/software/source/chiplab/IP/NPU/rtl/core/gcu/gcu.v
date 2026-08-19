// -----------------------------------------------------------------------------
// Module      : gcu
// Description : Global Control Unit (全局配置与状态机)
// -----------------------------------------------------------------------------
module gcu (
    input  wire         clk,
    input  wire         rst_n,

    // SoC Bus Interface
    input  wire [31:0]  cfg_wdata,
    input  wire [31:0]  cfg_addr,
    input  wire         cfg_wen,
    output reg  [31:0]  cfg_rdata,
    output wire         irq_layer_done,

    // NPU Global Static Configs
    output reg  [7:0]   cfg_width,
    output reg  [7:0]   cfg_height,
    output reg  [1:0]   cfg_kernel,
    output reg          cfg_pool_en,
    output reg          cfg_padding_en,
    output reg  [3:0]   cfg_shift_bits,
    output reg  [7:0]   cfg_cin_total,

    // Handshake
    output reg          layer_start,
    input  wire         layer_done,
    output reg          pingpong_sel
);

    reg r_busy;
    reg r_irq_status;

    // 寄存器写入与控制逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_width       <= 8'd16;
            cfg_height      <= 8'd16;
            cfg_kernel      <= 2'b10;
            cfg_pool_en     <= 1'b0;
            cfg_padding_en  <= 1'b1;
            cfg_shift_bits  <= 4'd0;
            cfg_cin_total   <= 8'd1;
            
            layer_start     <= 1'b0;
            pingpong_sel    <= 1'b0; // 0: Read PING, Write PONG
            r_busy          <= 1'b0;
            r_irq_status    <= 1'b0;
        end else begin
            // 默认清除脉冲
            layer_start <= 1'b0;

            // 接收底层完成信号
            if (layer_done) begin
                r_busy       <= 1'b0;
                r_irq_status <= 1'b1; // 拉高中断
                pingpong_sel <= ~pingpong_sel; // 翻转乒乓缓冲
            end

            // SoC 总线写入解析
            if (cfg_wen) begin
                case (cfg_addr[7:0])
                    8'h00: begin // CTRL_START
                        if (cfg_wdata[0] && !r_busy) begin
                            layer_start <= 1'b1;
                            r_busy      <= 1'b1;
                            r_irq_status<= 1'b0; // 启动时清空上一层中断
                        end
                    end
                    8'h04: begin // CTRL_STATUS (W1C: Write 1 to Clear)
                        if (cfg_wdata[1]) r_irq_status <= 1'b0;
                    end
                    8'h08: begin // CFG_IMG
                        cfg_height <= cfg_wdata[15:8];
                        cfg_width  <= cfg_wdata[7:0];
                    end
                    8'h0C: begin // CFG_LAYER
                        cfg_padding_en <= cfg_wdata[8];
                        cfg_kernel     <= cfg_wdata[5:4];
                        cfg_pool_en    <= cfg_wdata[0];
                    end
                    8'h10: begin // CFG_QUANT
                        cfg_shift_bits <= cfg_wdata[3:0];
                    end
                    8'h14: begin // CFG_CH
                        cfg_cin_total  <= cfg_wdata[23:16];
                    end
                    default: ;
                endcase
            end
        end
    end

    // 寄存器读取逻辑 (组合逻辑 MUX)
    always @(*) begin
        cfg_rdata = 32'd0;
        case (cfg_addr[7:0])
            8'h04: cfg_rdata = {30'd0, r_irq_status, r_busy};
            8'h08: cfg_rdata = {16'd0, cfg_height, cfg_width};
            8'h0C: cfg_rdata = {23'd0, cfg_padding_en, 2'd0, cfg_kernel, 3'd0, cfg_pool_en};
            8'h10: cfg_rdata = {28'd0, cfg_shift_bits};
            8'h14: cfg_rdata = {8'd0, cfg_cin_total, 16'd0};
            default: cfg_rdata = 32'd0;
        endcase
    end

    assign irq_layer_done = r_irq_status;

endmodule