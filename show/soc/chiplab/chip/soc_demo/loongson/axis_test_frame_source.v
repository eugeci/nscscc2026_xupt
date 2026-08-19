`timescale 1ns/1ps

// Deterministic 640x480 RGB565 AXI4-Stream source for VDMA bring-up.
// It obeys back-pressure and emits exactly one SOF and 480 EOL markers/frame.
module axis_test_frame_source #(
    parameter integer IMAGE_WIDTH  = 640,
    parameter integer IMAGE_HEIGHT = 480
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        enable,
    output wire [15:0] m_axis_tdata,
    output wire [1:0]  m_axis_tkeep,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);

localparam integer X_WIDTH = $clog2(IMAGE_WIDTH);
localparam integer Y_WIDTH = $clog2(IMAGE_HEIGHT);

reg [X_WIDTH-1:0] pixel_x;
reg [Y_WIDTH-1:0] pixel_y;
reg [15:0] bar_colour;

always @* begin
    if      (pixel_x < (IMAGE_WIDTH*1)/8) bar_colour = 16'hf800; // red
    else if (pixel_x < (IMAGE_WIDTH*2)/8) bar_colour = 16'hffe0; // yellow
    else if (pixel_x < (IMAGE_WIDTH*3)/8) bar_colour = 16'h07e0; // green
    else if (pixel_x < (IMAGE_WIDTH*4)/8) bar_colour = 16'h07ff; // cyan
    else if (pixel_x < (IMAGE_WIDTH*5)/8) bar_colour = 16'h001f; // blue
    else if (pixel_x < (IMAGE_WIDTH*6)/8) bar_colour = 16'hf81f; // magenta
    else if (pixel_x < (IMAGE_WIDTH*7)/8) bar_colour = 16'hffff; // white
    else                                  bar_colour = 16'h0000; // black
end

assign m_axis_tdata  = bar_colour;
assign m_axis_tkeep  = 2'b11;
assign m_axis_tuser  = enable && (pixel_x == 0) && (pixel_y == 0);
assign m_axis_tlast  = enable && (pixel_x == IMAGE_WIDTH-1);
assign m_axis_tvalid = enable;

always @(posedge clk) begin
    if (!resetn || !enable) begin
        pixel_x <= {X_WIDTH{1'b0}};
        pixel_y <= {Y_WIDTH{1'b0}};
    end
    else if (m_axis_tvalid && m_axis_tready) begin
        if (pixel_x == IMAGE_WIDTH-1) begin
            pixel_x <= {X_WIDTH{1'b0}};
            if (pixel_y == IMAGE_HEIGHT-1)
                pixel_y <= {Y_WIDTH{1'b0}};
            else
                pixel_y <= pixel_y + 1'b1;
        end
        else begin
            pixel_x <= pixel_x + 1'b1;
        end
    end
end

endmodule
