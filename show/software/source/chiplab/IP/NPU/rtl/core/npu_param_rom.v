// ----------------------------------------------------------------------------
// npu_param_rom
// 64b 微码保持不变，基址信息独立放在参数 ROM
//
// [Step 16.3 / Path B M3] base 值按新块状 ROM 布局重生
//   由 face/quant_int8.py:export_blocked_npu_params 自动计算
//   单位：32-bit 字 (与 sequencer 字单位算术一致, RPT-3 决议)
//   ROM 总大小：21098 字 = 82.4 KB (详见 docs/weight_rom_dma_设计_PathB.md)
// ----------------------------------------------------------------------------
module npu_param_rom (
    input  wire [4:0]  i_layer_id,
    output reg  [15:0] o_weight_base_addr,
    output reg  [15:0] o_bias_base_addr
);
    always @(*) begin
        o_weight_base_addr = 16'd0;
        o_bias_base_addr   = 16'd0;
        case (i_layer_id)
            5'd0: begin o_weight_base_addr = 16'd0;     o_bias_base_addr = 16'd576;   end // C1  (shift @   592)
            5'd1: begin o_weight_base_addr = 16'd593;   o_bias_base_addr = 16'd1169;  end // C2  (shift @  1185)
            5'd2: begin o_weight_base_addr = 16'd1186;  o_bias_base_addr = 16'd1250;  end // C3  (shift @  1266)
            5'd3: begin o_weight_base_addr = 16'd1267;  o_bias_base_addr = 16'd2419;  end // C4  (shift @  2451)
            5'd4: begin o_weight_base_addr = 16'd2452;  o_bias_base_addr = 16'd4756;  end // C5  (shift @  4788)
            5'd5: begin o_weight_base_addr = 16'd4789;  o_bias_base_addr = 16'd5045;  end // C6  (shift @  5077)
            5'd6: begin o_weight_base_addr = 16'd5078;  o_bias_base_addr = 16'd7382;  end // C7  (shift @  7414)
            5'd7: begin o_weight_base_addr = 16'd7415;  o_bias_base_addr = 16'd8439;  end // C8  (shift @  8471)
            5'd8: begin o_weight_base_addr = 16'd8472;  o_bias_base_addr = 16'd20760; end // FC1 (shift @ 20824)
            5'd9: begin o_weight_base_addr = 16'd20825; o_bias_base_addr = 16'd21081; end // FC2 (shift @ 21097)
            default: begin
                o_weight_base_addr = 16'd0;
                o_bias_base_addr   = 16'd0;
            end
        endcase
    end
endmodule
