// -----------------------------------------------------------------------------
// Module      : dummy_npu
// Description : 纯算力占位符 (模拟固定延时的处理黑盒)
// -----------------------------------------------------------------------------
module dummy_npu #(
    parameter PIPELINE_DEPTH = 5
)(
    input  wire         clk,
    input  wire         rst_n,
    
    input  wire [7:0]   pixel_in_data,
    input  wire         pixel_in_valid,
    
    output wire [127:0] out_pixel_bus,
    output wire         out_valid
);
    // 移位寄存器模拟流水线延迟
    reg [PIPELINE_DEPTH-1:0] r_valid_pipe;
    reg [7:0]                r_data_pipe [0:PIPELINE_DEPTH-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_valid_pipe <= 0;
            for(i=0; i<PIPELINE_DEPTH; i=i+1) r_data_pipe[i] <= 8'd0;
        end else begin
            r_valid_pipe <= {r_valid_pipe[PIPELINE_DEPTH-2:0], pixel_in_valid};
            r_data_pipe[0] <= pixel_in_data;
            for(i=1; i<PIPELINE_DEPTH; i=i+1) begin
                r_data_pipe[i] <= r_data_pipe[i-1];
            end
        end
    end

    assign out_valid = r_valid_pipe[PIPELINE_DEPTH-1];
    
    // 伪造 16 通道并行输出 (简单地将处理后的数据复制 16 份)
    wire [7:0] w_computed = r_data_pipe[PIPELINE_DEPTH-1] + 8'h01; // 模拟一次运算
    assign out_pixel_bus = {16{w_computed}};

endmodule
