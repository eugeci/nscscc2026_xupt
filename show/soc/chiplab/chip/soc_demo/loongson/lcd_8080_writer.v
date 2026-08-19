`timescale 1ns / 1ps

// One 16-bit Intel-8080 style LCD write transaction.
// RS=0 writes a command, RS=1 writes display/register data.
module lcd_8080_writer #(
    parameter integer LOW_CYCLES  = 2,
    parameter integer HIGH_CYCLES = 2
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire        is_data,
    input  wire [15:0] write_data,

    output reg         busy,
    output reg         done,
    output reg  [15:0] db_out,
    output reg         cs_n,
    output reg         rs,
    output reg         wr_n,
    output wire        rd_n
);

localparam [2:0] ST_IDLE  = 3'd0,
                 ST_SETUP = 3'd1,
                 ST_LOW   = 3'd2,
                 ST_HIGH  = 3'd3,
                 ST_DONE  = 3'd4;

reg [2:0] state;
reg [7:0] phase_count;

assign rd_n = 1'b1;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state       <= ST_IDLE;
        phase_count <= 8'd0;
        busy        <= 1'b0;
        done        <= 1'b0;
        db_out      <= 16'd0;
        cs_n        <= 1'b1;
        rs          <= 1'b0;
        wr_n        <= 1'b1;
    end else begin
        done <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                cs_n <= 1'b1;
                wr_n <= 1'b1;
                if (start) begin
                    db_out <= write_data;
                    rs     <= is_data;
                    busy   <= 1'b1;
                    cs_n   <= 1'b0;
                    state  <= ST_SETUP;
                end
            end

            ST_SETUP: begin
                // One full setup clock keeps RS and DB stable before WR#.
                wr_n        <= 1'b1;
                phase_count <= 8'd0;
                state       <= ST_LOW;
            end

            ST_LOW: begin
                wr_n <= 1'b0;
                if (phase_count == LOW_CYCLES - 1) begin
                    phase_count <= 8'd0;
                    state       <= ST_HIGH;
                end else begin
                    phase_count <= phase_count + 8'd1;
                end
            end

            ST_HIGH: begin
                wr_n <= 1'b1;
                if (phase_count == HIGH_CYCLES - 1) begin
                    phase_count <= 8'd0;
                    state       <= ST_DONE;
                end else begin
                    phase_count <= phase_count + 8'd1;
                end
            end

            ST_DONE: begin
                cs_n <= 1'b1;
                busy <= 1'b0;
                done <= 1'b1;
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
