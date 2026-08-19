// OV5640 8-bit DVP (320x240 RGB565) to 640x480 VGA.
// A single dual-clock frame buffer crosses from cam_pclk to the 25 MHz VGA
// pixel rate.  Each camera pixel is displayed as a 2x2 block.
module ov5640_vga_bridge (
    input  wire       clk_50m,
    input  wire       resetn,
    input  wire       capture_enable,
    input  wire       cam_pclk,
    input  wire       cam_vsync,
    input  wire       cam_href,
    input  wire [7:0] cam_d,
    input  wire [1:0] display_mode,
    output wire       frame_ready,
    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output wire       vga_hsync,
    output wire       vga_vsync
);

localparam integer FRAME_PIXELS = 320 * 240;

(* ram_style = "block" *) reg [15:0] frame_buffer [0:FRAME_PIXELS-1];

// Camera clock domain: assemble the two RGB565 bytes and write one frame.
reg [1:0]  capture_enable_sync;
reg        byte_phase;
reg [7:0]  first_byte;
reg [16:0] write_addr;
reg        frame_ready_cam;
wire       camera_pixel_write = capture_enable_sync[1]
                              && !cam_vsync && cam_href && byte_phase;

// Keep the memory write in a reset-free clocked process so Vivado can infer
// true dual-port block RAM.
always @(posedge cam_pclk) begin
    if (camera_pixel_write)
        frame_buffer[write_addr] <= {first_byte, cam_d};
end

always @(posedge cam_pclk or negedge resetn) begin
    if (!resetn)
        capture_enable_sync <= 2'b00;
    else
        capture_enable_sync <= {capture_enable_sync[0], capture_enable};
end

always @(posedge cam_pclk or negedge resetn) begin
    if (!resetn) begin
        byte_phase      <= 1'b0;
        first_byte      <= 8'd0;
        write_addr      <= 17'd0;
        frame_ready_cam <= 1'b0;
    end
    else if (!capture_enable_sync[1]) begin
        byte_phase      <= 1'b0;
        write_addr      <= 17'd0;
        frame_ready_cam <= 1'b0;
    end
    else if (cam_vsync) begin
        byte_phase <= 1'b0;
        write_addr <= 17'd0;
    end
    else if (cam_href) begin
        if (!byte_phase) begin
            first_byte <= cam_d;
            byte_phase <= 1'b1;
        end
        else begin
            // FORMAT_CTRL00=0x61 sends the RGB565 high byte first.
            byte_phase <= 1'b0;
            if (write_addr == FRAME_PIXELS-1)
                frame_ready_cam <= 1'b1;
            else
                write_addr <= write_addr + 17'd1;
        end
    end
    else begin
        byte_phase <= 1'b0;
    end
end

// VGA clock domain: 50 MHz / 2 gives a 25 MHz 640x480 pixel rate.
reg [1:0] frame_ready_sync;
reg       pixel_enable;
reg [9:0] h_count;
reg [9:0] v_count;
reg       active_d;
reg       hsync_d;
reg       vsync_d;
reg [15:0] frame_pixel;

wire active_now = (h_count < 10'd640) && (v_count < 10'd480);
wire hsync_now = ~((h_count >= 10'd656) && (h_count < 10'd752));
wire vsync_now = ~((v_count >= 10'd490) && (v_count < 10'd492));
wire [8:0] source_x = h_count[9:1];
wire [7:0] source_y = v_count[8:1];
wire [16:0] read_addr = {1'b0, source_y, 8'b0}
                      + {3'b000, source_y, 6'b0}
                      + {8'b00000000, source_x};

// Reset-free synchronous read port for block-RAM inference.
always @(posedge clk_50m) begin
    if (pixel_enable && active_now)
        frame_pixel <= frame_buffer[read_addr];
end

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        frame_ready_sync <= 2'b00;
        pixel_enable <= 1'b0;
        h_count <= 10'd0;
        v_count <= 10'd0;
        active_d <= 1'b0;
        hsync_d <= 1'b1;
        vsync_d <= 1'b1;
    end
    else begin
        frame_ready_sync <= {frame_ready_sync[0], frame_ready_cam};
        pixel_enable <= ~pixel_enable;

        if (pixel_enable) begin
            active_d <= active_now;
            hsync_d <= hsync_now;
            vsync_d <= vsync_now;

            if (h_count == 10'd799) begin
                h_count <= 10'd0;
                if (v_count == 10'd524)
                    v_count <= 10'd0;
                else
                    v_count <= v_count + 10'd1;
            end
            else
                h_count <= h_count + 10'd1;
        end
    end
end

assign frame_ready = frame_ready_sync[1];
assign vga_hsync = hsync_d;
assign vga_vsync = vsync_d;

always @* begin
    vga_r = 4'h0;
    vga_g = 4'h0;
    vga_b = 4'h0;

    if (active_d) begin
        case (display_mode)
            2'b01: begin
                // FPGA-generated reference bars: white, yellow, cyan, green,
                // magenta, red, blue and black.  This bypasses the camera.
                if (h_count < 10'd80) begin
                    vga_r = 4'hf; vga_g = 4'hf; vga_b = 4'hf;
                end else if (h_count < 10'd160) begin
                    vga_r = 4'hf; vga_g = 4'hf; vga_b = 4'h0;
                end else if (h_count < 10'd240) begin
                    vga_r = 4'h0; vga_g = 4'hf; vga_b = 4'hf;
                end else if (h_count < 10'd320) begin
                    vga_r = 4'h0; vga_g = 4'hf; vga_b = 4'h0;
                end else if (h_count < 10'd400) begin
                    vga_r = 4'hf; vga_g = 4'h0; vga_b = 4'hf;
                end else if (h_count < 10'd480) begin
                    vga_r = 4'hf; vga_g = 4'h0; vga_b = 4'h0;
                end else if (h_count < 10'd560) begin
                    vga_r = 4'h0; vga_g = 4'h0; vga_b = 4'hf;
                end
            end
            2'b10: begin
                // Camera image with red and blue exchanged.
                vga_r = frame_pixel[4:1];
                vga_g = frame_pixel[10:7];
                vga_b = frame_pixel[15:12];
            end
            2'b11: begin
                // Green-derived grayscale helps separate colour-order faults
                // from exposure and geometry problems.
                vga_r = frame_pixel[10:7];
                vga_g = frame_pixel[10:7];
                vga_b = frame_pixel[10:7];
            end
            default: begin
                if (frame_ready_sync[1]) begin
                    vga_r = frame_pixel[15:12];
                    vga_g = frame_pixel[10:7];
                    vga_b = frame_pixel[4:1];
                end
                else begin
                    // Blue means initialization/capture has not produced a frame yet.
                    vga_b = 4'hf;
                end
            end
        endcase
    end
end

endmodule
