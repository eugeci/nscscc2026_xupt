// OV5640 8-bit DVP RGB565 to 16-bit AXI4-Stream.
//
// The camera cannot be back-pressured.  A dual-clock FIFO absorbs temporary
// stalls from the DDR/VDMA side.  If it ever fills, the remainder of the
// current camera frame is discarded and streaming resumes at the next VSYNC.
module ov5640_axis_capture #(
    parameter integer IMAGE_WIDTH  = 320,
    parameter integer IMAGE_HEIGHT = 240,
    parameter integer FIFO_DEPTH   = 2048
) (
    input  wire        resetn,
    input  wire        capture_enable,

    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_d,

    input  wire        axis_clk,
    output wire [15:0] m_axis_tdata,
    output wire [1:0]  m_axis_tkeep,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,

    output wire        fifo_full,
    output reg         overflow_sticky
);

localparam integer X_WIDTH = $clog2(IMAGE_WIDTH);
localparam integer Y_WIDTH = $clog2(IMAGE_HEIGHT);

reg [1:0] capture_enable_sync;
reg       byte_phase;
reg [7:0] first_byte;
reg [X_WIDTH-1:0] pixel_x;
reg [Y_WIDTH-1:0] pixel_y;
reg       drop_frame;
reg       cam_href_d;
reg       line_complete;
reg       frame_synced;

wire       pixel_complete = capture_enable_sync[1]
                          && frame_synced
                          && !cam_vsync && cam_href && byte_phase
                          && !line_complete;
wire       pixel_in_range = (pixel_x < IMAGE_WIDTH) && (pixel_y < IMAGE_HEIGHT);
wire       pixel_sof      = (pixel_x == 0) && (pixel_y == 0);
wire       pixel_eol      = (pixel_x == IMAGE_WIDTH-1);
wire [17:0] fifo_din      = {pixel_sof, pixel_eol, first_byte, cam_d};
wire        fifo_wr_en    = pixel_complete && pixel_in_range
                          && !drop_frame && !fifo_full;

always @(posedge cam_pclk or negedge resetn) begin
    if (!resetn)
        capture_enable_sync <= 2'b00;
    else
        capture_enable_sync <= {capture_enable_sync[0], capture_enable};
end

always @(posedge cam_pclk or negedge resetn) begin
    if (!resetn) begin
        byte_phase     <= 1'b0;
        first_byte     <= 8'd0;
        pixel_x        <= {X_WIDTH{1'b0}};
        pixel_y        <= {Y_WIDTH{1'b0}};
        drop_frame     <= 1'b0;
        cam_href_d     <= 1'b0;
        line_complete  <= 1'b0;
        frame_synced   <= 1'b0;
        overflow_sticky <= 1'b0;
    end
    else begin
        cam_href_d <= cam_href;

        if (!capture_enable_sync[1]) begin
            byte_phase    <= 1'b0;
            pixel_x       <= {X_WIDTH{1'b0}};
            pixel_y       <= {Y_WIDTH{1'b0}};
            drop_frame    <= 1'b0;
            line_complete <= 1'b0;
            frame_synced  <= 1'b0;
        end
        else if (cam_vsync) begin
            // capture_active can become asserted in the middle of a camera
            // frame.  Do not present that truncated frame to VDMA: arm the
            // stream only after observing a real VSYNC frame boundary.
            byte_phase <= 1'b0;
            pixel_x    <= {X_WIDTH{1'b0}};
            pixel_y    <= {Y_WIDTH{1'b0}};
            drop_frame <= 1'b0;
            line_complete <= 1'b0;
            frame_synced <= 1'b1;
        end
        else if (!frame_synced) begin
            byte_phase    <= 1'b0;
            pixel_x       <= {X_WIDTH{1'b0}};
            pixel_y       <= {Y_WIDTH{1'b0}};
            drop_frame    <= 1'b0;
            line_complete <= 1'b0;
        end
        else if (!cam_href) begin
            // HREF, rather than a free-running pixel count, defines a DVP
            // source line.  Reset X at the actual line boundary and advance Y
            // only if a complete IMAGE_WIDTH-pixel line was accepted.
            byte_phase <= 1'b0;
            pixel_x    <= {X_WIDTH{1'b0}};
            if (cam_href_d) begin
                if (line_complete && (pixel_y < IMAGE_HEIGHT))
                    pixel_y <= pixel_y + {{(Y_WIDTH-1){1'b0}}, 1'b1};
                line_complete <= 1'b0;
            end
        end
        else if (!line_complete) begin
            if (!byte_phase) begin
                first_byte <= cam_d;
                byte_phase <= 1'b1;
            end
            else begin
                byte_phase <= 1'b0;

                if (!drop_frame && fifo_full) begin
                    drop_frame      <= 1'b1;
                    overflow_sticky <= 1'b1;
                end

                if (pixel_x == IMAGE_WIDTH-1)
                    line_complete <= 1'b1;
                else
                    pixel_x <= pixel_x + {{(X_WIDTH-1){1'b0}}, 1'b1};
            end
        end
        else begin
            // Ignore source pixels beyond the requested IMAGE_WIDTH-pixel line.
            byte_phase <= 1'b0;
        end
    end
end

wire [17:0] fifo_dout;
wire        fifo_empty;
wire        fifo_rd_en = m_axis_tready && !fifo_empty;

assign m_axis_tdata  = fifo_dout[15:0];
assign m_axis_tkeep  = 2'b11;
assign m_axis_tlast  = fifo_dout[16];
assign m_axis_tuser  = fifo_dout[17];
assign m_axis_tvalid = !fifo_empty;

xpm_fifo_async #(
    .CDC_SYNC_STAGES     (2),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("block"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (FIFO_DEPTH-8),
    .RD_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1),
    .READ_DATA_WIDTH     (18),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (18),
    .WR_DATA_COUNT_WIDTH ($clog2(FIFO_DEPTH)+1)
) u_pixel_fifo (
    .rst          (~resetn),
    .wr_clk       (cam_pclk),
    .wr_en        (fifo_wr_en),
    .din          (fifo_din),
    .full         (fifo_full),
    .overflow     (),
    .wr_rst_busy  (),
    .almost_full  (),
    .prog_full    (),
    .wr_data_count(),
    .wr_ack       (),
    .rd_clk       (axis_clk),
    .rd_en        (fifo_rd_en),
    .dout         (fifo_dout),
    .empty        (fifo_empty),
    .underflow    (),
    .rd_rst_busy  (),
    .almost_empty (),
    .prog_empty   (),
    .rd_data_count(),
    .data_valid   (),
    .sleep        (1'b0),
    .injectsbiterr(1'b0),
    .injectdbiterr(1'b0),
    .sbiterr      (),
    .dbiterr      ()
);

endmodule
