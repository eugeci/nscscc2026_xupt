// ============================================================================
// File Name   : sync_fifo.v
// Description : 标准同步 FIFO (纯 Verilog-2001) - 带同步清空功能
// ============================================================================
module sync_fifo_npu_module #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 256
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   clr,     // 【新增】：同步清空端口
    
    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  din,
    output reg                    full,
    
    input  wire                   rd_en,
    output wire [DATA_WIDTH-1:0]  dout,
    output reg                    empty
);

    // Derive the pointer width from the configured depth.  Several users of
    // this FIFO request 512 entries, so a fixed 8-bit pointer silently wraps
    // after entry 255 and overwrites unread data.
    localparam ADDR_WIDTH = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam [ADDR_WIDTH-1:0] FIFO_LAST_PTR = FIFO_DEPTH - 1;
    localparam [ADDR_WIDTH:0]   FIFO_DEPTH_COUNT = FIFO_DEPTH;
    
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count; 

    wire write_accept = wr_en && !full;
    wire read_accept  = rd_en && !empty;

    always @(posedge clk) begin
        if (write_accept) begin
            mem[wr_ptr] <= din;
        end
    end

    assign dout = mem[rd_ptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
            empty  <= 1'b1;
            full   <= 1'b0;
        end else if (clr) begin            // 【新增】：硬件秒清逻辑
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
            empty  <= 1'b1;
            full   <= 1'b0;
        end else begin
            case ({write_accept, read_accept})
                2'b10: begin 
                    wr_ptr <= (wr_ptr == FIFO_LAST_PTR) ? 0 : wr_ptr + 1'b1;
                    count  <= count + 1'b1;
                    empty  <= 1'b0;
                    full   <= (count == FIFO_DEPTH_COUNT - 1'b1);
                end
                2'b01: begin 
                    rd_ptr <= (rd_ptr == FIFO_LAST_PTR) ? 0 : rd_ptr + 1'b1;
                    count  <= count - 1'b1;
                    empty  <= (count == 1);
                    full   <= 1'b0;
                end
                2'b11: begin 
                    wr_ptr <= (wr_ptr == FIFO_LAST_PTR) ? 0 : wr_ptr + 1'b1;
                    rd_ptr <= (rd_ptr == FIFO_LAST_PTR) ? 0 : rd_ptr + 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule
