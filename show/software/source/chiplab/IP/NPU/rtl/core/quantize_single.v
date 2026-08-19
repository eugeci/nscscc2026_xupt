module quantize_single #(
    parameter ACC_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire signed [ACC_WIDTH-1:0] in_act,
    input  wire                   in_valid,
    input  wire [3:0]             shift_bits,
    output reg  [7:0]             out_pixel,
    output reg                    out_valid
);
    wire signed [ACC_WIDTH-1:0] shifted = in_act >>> shift_bits;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pixel <= 0; out_valid <= 0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                // 【下溢防卫】：如果移位后是负数，强制归零，防止截断成 0xFF
                if (shifted < 0) 
                    out_pixel <= 8'd0;
                else if (shifted > 255)
                    out_pixel <= 8'd255;
                else
                    out_pixel <= shifted[7:0];
            end
        end
    end
endmodule