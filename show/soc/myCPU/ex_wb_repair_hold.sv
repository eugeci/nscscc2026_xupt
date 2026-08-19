// ============================================================
// Module: ex_wb_repair_hold
// Description: Keep late WB-load repair data with a stalled EX token.
// ============================================================

module ex_wb_repair_hold (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic        advance,
    input  logic        repair_valid,
    input  logic [31:0] live_data,
    output logic        hold_valid,
    output logic [31:0] hold_data,
    output logic [31:0] repair_data
);

    assign repair_data = hold_valid ? hold_data : live_data;

    always_ff @(posedge clk) begin
        if (!rst_n || flush)
            hold_valid <= 1'b0;
        else if (advance)
            hold_valid <= 1'b0;
        else if (repair_valid && !hold_valid) begin
            hold_valid <= 1'b1;
            hold_data <= live_data;
        end
    end

endmodule
