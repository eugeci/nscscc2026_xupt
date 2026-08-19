`timescale 1ns/1ps

// Native 640x480 AXI4-Stream RGB565 to VGA using two 640-pixel line buffers.
// Only two source lines are stored here; the complete frame remains in DDR.
//
// This bring-up version expects the AXI stream and VGA logic to share clk_50m.
module axis_linebuffer_vga (
    input  wire        clk_50m,
    input  wire        resetn,

    input  wire [15:0] s_axis_tdata,
    input  wire        s_axis_tuser,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,

    output reg         stream_seen,
    output reg         frame_started,
    output reg         underflow_sticky,

    output reg  [3:0]  vga_r,
    output reg  [3:0]  vga_g,
    output reg  [3:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync
);

(* ram_style = "block" *) reg [15:0] line_buffer_0 [0:639];
(* ram_style = "block" *) reg [15:0] line_buffer_1 [0:639];

reg       write_buffer;
reg [9:0] write_x;
reg       buffer_0_ready;
reg       buffer_1_ready;

reg       read_buffer;
reg       display_active;
reg       pixel_enable;
reg [9:0] h_count;
reg [9:0] v_count;
reg       active_d;
reg       hsync_d;
reg       vsync_d;
reg [15:0] pixel_d;

wire write_buffer_ready = write_buffer ? buffer_1_ready : buffer_0_ready;
// Never block a start-of-frame beat.  TUSER is the recovery point after a
// reset, an MM2S restart, or any earlier malformed packet.
assign s_axis_tready = s_axis_tuser || !write_buffer_ready;
wire stream_accept = s_axis_tvalid && s_axis_tready;
wire stream_write_buffer = s_axis_tuser ? 1'b0 : write_buffer;
wire [9:0] stream_write_x = s_axis_tuser ? 10'd0 : write_x;
wire write_line_done = stream_accept && (s_axis_tlast || (write_x == 10'd639));
wire set_buffer_0 = write_line_done && !write_buffer;
wire set_buffer_1 = write_line_done &&  write_buffer;

wire active_now = (h_count < 10'd640) && (v_count < 10'd480);
wire hsync_now = ~((h_count >= 10'd656) && (h_count < 10'd752));
wire vsync_now = ~((v_count >= 10'd490) && (v_count < 10'd492));
wire [9:0] source_x = (h_count < 10'd640) ? h_count : 10'd0;
wire [15:0] source_pixel = read_buffer
                         ? line_buffer_1[source_x]
                         : line_buffer_0[source_x];

// A native-resolution source line has just been shown on one VGA scan line.
wire consume_line = pixel_enable && (h_count == 10'd799)
                  && (v_count < 10'd480) && display_active;
wire clear_buffer_0 = consume_line && !read_buffer;
wire clear_buffer_1 = consume_line &&  read_buffer;
wire next_buffer_ready = read_buffer ? buffer_0_ready : buffer_1_ready;
wire next_buffer_finishing = write_line_done && (write_buffer != read_buffer);
wire next_buffer_available = next_buffer_ready || next_buffer_finishing;

// Keep the pixel memories in a reset-free, single-write-port clocked block so
// Vivado can infer RAM instead of dissolving 10 kbits into flip-flops.
always @(posedge clk_50m) begin
    if (stream_accept) begin
        if (stream_write_buffer)
            line_buffer_1[stream_write_x] <= s_axis_tdata;
        else
            line_buffer_0[stream_write_x] <= s_axis_tdata;
    end
end

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        write_buffer     <= 1'b0;
        write_x          <= 10'd0;
        stream_seen      <= 1'b0;
    end
    else if (stream_accept) begin
        stream_seen <= 1'b1;

        if (s_axis_tuser) begin
            // AXI4-Stream Video defines TUSER on the first pixel of a frame.
            // Force that pixel to source coordinate (0,0), independently of
            // whatever partial line preceded it.
            write_buffer <= 1'b0;
            write_x      <= 10'd1;
        end
        else begin
            if (s_axis_tlast || (write_x == 10'd639)) begin
                write_x      <= 10'd0;
                write_buffer <= ~write_buffer;
            end
            else
                write_x <= write_x + 10'd1;
        end
    end
end

// Buffer ownership flags.  The writer sets a flag only after a complete line;
// the VGA reader clears it after displaying that line once.
always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        buffer_0_ready <= 1'b0;
        buffer_1_ready <= 1'b0;
    end
    else begin
        case ({set_buffer_0, clear_buffer_0})
            2'b10: buffer_0_ready <= 1'b1;
            2'b01: buffer_0_ready <= 1'b0;
            2'b11: buffer_0_ready <= 1'b1;
            default: ;
        endcase
        case ({set_buffer_1, clear_buffer_1})
            2'b10: buffer_1_ready <= 1'b1;
            2'b01: buffer_1_ready <= 1'b0;
            2'b11: buffer_1_ready <= 1'b1;
            default: ;
        endcase
    end
end

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        read_buffer      <= 1'b0;
        display_active   <= 1'b0;
        frame_started    <= 1'b0;
        underflow_sticky <= 1'b0;
        pixel_enable     <= 1'b0;
        h_count          <= 10'd0;
        v_count          <= 10'd0;
        active_d         <= 1'b0;
        hsync_d          <= 1'b1;
        vsync_d          <= 1'b1;
        pixel_d          <= 16'd0;
    end
    else begin
        pixel_enable <= ~pixel_enable;

        if (consume_line) begin
            if (next_buffer_available)
                read_buffer <= ~read_buffer;
            else begin
                display_active   <= 1'b0;
                underflow_sticky <= 1'b1;
            end
        end

        if (pixel_enable) begin
            active_d <= active_now;
            hsync_d <= hsync_now;
            vsync_d <= vsync_now;
            pixel_d <= source_pixel;

            if (h_count == 10'd799) begin
                h_count <= 10'd0;
                if (v_count == 10'd524) begin
                    v_count <= 10'd0;
                    // Start only at a VGA frame boundary with line 0 ready.
                    if (!display_active) begin
                        if ((!read_buffer && buffer_0_ready) ||
                            ( read_buffer && buffer_1_ready)) begin
                            display_active <= 1'b1;
                            frame_started  <= 1'b1;
                        end
                    end
                end
                else
                    v_count <= v_count + 10'd1;
            end
            else
                h_count <= h_count + 10'd1;
        end
    end
end

assign vga_hsync = hsync_d;
assign vga_vsync = vsync_d;

always @* begin
    vga_r = 4'h0;
    vga_g = 4'h0;
    vga_b = 4'h0;

    if (active_d) begin
        if (display_active) begin
            vga_r = pixel_d[15:12];
            vga_g = pixel_d[10:7];
            vga_b = pixel_d[4:1];
        end
        else begin
            // Blue means MM2S has not supplied the first complete line yet.
            vga_b = 4'hf;
        end
    end
end

endmodule
