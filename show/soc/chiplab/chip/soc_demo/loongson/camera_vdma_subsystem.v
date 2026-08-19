// Stable QVGA camera capture, scaled to a 640x480 RGB565 DDR/VGA frame.
module camera_vdma_subsystem #(
    parameter integer IMAGE_WIDTH  = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer CAMERA_WIDTH  = 320,
    parameter integer CAMERA_HEIGHT = 240,
    parameter [31:0] FRAME0_ADDR   = 32'h07c0_0000,
    parameter [31:0] FRAME1_ADDR   = 32'h07d0_0000
) (
    input  wire        ddr_clk,
    input  wire        vga_axis_clk,
    input  wire        resetn,
    input  wire        camera_ready,
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_d,
    input  wire        test_stream_enable,

    // AXI S2MM write master (to interconnect S03).
    output wire [31:0] s2mm_awaddr,
    output wire [7:0]  s2mm_awlen,
    output wire [2:0]  s2mm_awsize,
    output wire [1:0]  s2mm_awburst,
    output wire [2:0]  s2mm_awprot,
    output wire [3:0]  s2mm_awcache,
    output wire        s2mm_awvalid,
    input  wire        s2mm_awready,
    output wire [31:0] s2mm_wdata,
    output wire [3:0]  s2mm_wstrb,
    output wire        s2mm_wlast,
    output wire        s2mm_wvalid,
    input  wire        s2mm_wready,
    input  wire [1:0]  s2mm_bresp,
    input  wire        s2mm_bvalid,
    output wire        s2mm_bready,

    // AXI MM2S read master (to interconnect S04; not started in stage 1).
    output wire [31:0] mm2s_araddr,
    output wire [7:0]  mm2s_arlen,
    output wire [2:0]  mm2s_arsize,
    output wire [1:0]  mm2s_arburst,
    output wire [2:0]  mm2s_arprot,
    output wire [3:0]  mm2s_arcache,
    output wire        mm2s_arvalid,
    input  wire        mm2s_arready,
    input  wire [31:0] mm2s_rdata,
    input  wire [1:0]  mm2s_rresp,
    input  wire        mm2s_rlast,
    input  wire        mm2s_rvalid,
    output wire        mm2s_rready,

    output wire [15:0] video_tdata,
    output wire [1:0]  video_tkeep,
    output wire        video_tuser,
    output wire        video_tlast,
    output wire        video_tvalid,
    input  wire        video_tready,

    output wire        init_done,
    output wire        init_error,
    output wire        fifo_full,
    output wire        fifo_overflow,
    output reg         frame_seen,
    output wire [31:0] mm2s_status,
    output wire [31:0] s2mm_status,
    output wire        status_valid,
    output wire [3:0]  debug_state,
    output wire [3:0]  debug_write_index
);

wire [15:0] camera_tdata;
wire [1:0]  camera_tkeep;
wire        camera_tuser;
wire        camera_tlast;
wire        camera_tvalid;
wire        camera_tready;
wire [15:0] scaled_tdata;
wire [1:0]  scaled_tkeep;
wire        scaled_tuser;
wire        scaled_tlast;
wire        scaled_tvalid;
wire        scaled_tready;
wire [15:0] test_tdata;
wire [1:0]  test_tkeep;
wire        test_tuser;
wire        test_tlast;
wire        test_tvalid;
wire        test_tready;
wire [15:0] input_tdata  = test_stream_enable ? test_tdata  : scaled_tdata;
wire [1:0]  input_tkeep  = test_stream_enable ? test_tkeep  : scaled_tkeep;
wire        input_tuser  = test_stream_enable ? test_tuser  : scaled_tuser;
wire        input_tlast  = test_stream_enable ? test_tlast  : scaled_tlast;
wire        input_tvalid = test_stream_enable ? test_tvalid : scaled_tvalid;
wire        input_tready;
wire        capture_active;
wire [5:0]  s2mm_frame_ptr;
localparam integer LINE_COUNT_WIDTH = (IMAGE_HEIGHT <= 2) ? 1 : $clog2(IMAGE_HEIGHT);
localparam [31:0] LINE_BYTES = IMAGE_WIDTH * 2;

reg  [LINE_COUNT_WIDTH-1:0] accepted_line_count;
reg         capture_frame_done;

ov5640_axis_capture #(
    .IMAGE_WIDTH (CAMERA_WIDTH),
    .IMAGE_HEIGHT(CAMERA_HEIGHT)
) u_axis_capture (
    .resetn          (resetn),
    .capture_enable  (camera_ready && capture_active && !test_stream_enable),
    .cam_pclk        (cam_pclk),
    .cam_vsync       (cam_vsync),
    .cam_href        (cam_href),
    .cam_d           (cam_d),
    .axis_clk        (ddr_clk),
    .m_axis_tdata    (camera_tdata),
    .m_axis_tkeep    (camera_tkeep),
    .m_axis_tuser    (camera_tuser),
    .m_axis_tlast    (camera_tlast),
    .m_axis_tvalid   (camera_tvalid),
    .m_axis_tready   (camera_tready),
    .fifo_full       (fifo_full),
    .overflow_sticky (fifo_overflow)
);

axis_video_2x_scaler #(
    .INPUT_WIDTH (CAMERA_WIDTH),
    .INPUT_HEIGHT(CAMERA_HEIGHT)
) u_axis_video_2x_scaler (
    .clk          (ddr_clk),
    .resetn       (resetn),
    .s_axis_tdata (camera_tdata),
    .s_axis_tkeep (camera_tkeep),
    .s_axis_tuser (camera_tuser),
    .s_axis_tlast (camera_tlast),
    .s_axis_tvalid(camera_tvalid),
    .s_axis_tready(camera_tready),
    .m_axis_tdata (scaled_tdata),
    .m_axis_tkeep (scaled_tkeep),
    .m_axis_tuser (scaled_tuser),
    .m_axis_tlast (scaled_tlast),
    .m_axis_tvalid(scaled_tvalid),
    .m_axis_tready(scaled_tready)
);

assign scaled_tready = !test_stream_enable && input_tready;
assign test_tready   =  test_stream_enable && input_tready;

axis_test_frame_source #(
    .IMAGE_WIDTH (IMAGE_WIDTH),
    .IMAGE_HEIGHT(IMAGE_HEIGHT)
) u_axis_test_frame_source (
    .clk          (ddr_clk),
    .resetn       (resetn),
    .enable       (capture_active && test_stream_enable),
    .m_axis_tdata (test_tdata),
    .m_axis_tkeep (test_tkeep),
    .m_axis_tuser (test_tuser),
    .m_axis_tlast (test_tlast),
    .m_axis_tvalid(test_tvalid),
    .m_axis_tready(test_tready)
);

wire [8:0]  lite_awaddr;
wire        lite_awvalid;
wire        lite_awready;
wire [31:0] lite_wdata;
wire [3:0]  lite_wstrb;
wire        lite_wvalid;
wire        lite_wready;
wire [1:0]  lite_bresp;
wire        lite_bvalid;
wire        lite_bready;
wire [8:0]  lite_araddr;
wire        lite_arvalid;
wire        lite_arready;
wire [31:0] lite_rdata;
wire [1:0]  lite_rresp;
wire        lite_rvalid;
wire        lite_rready;

camera_vdma_s2mm_init #(
    .FRAME0_ADDR (FRAME0_ADDR),
    .FRAME1_ADDR (FRAME1_ADDR),
    .HSIZE_BYTES (LINE_BYTES),
    .STRIDE_BYTES(LINE_BYTES),
    .VSIZE_LINES (IMAGE_HEIGHT)
) u_s2mm_init (
    .clk          (ddr_clk),
    .resetn       (resetn),
    .start        (1'b1),
    .capture_frame_done(capture_frame_done),
    .m_axi_awaddr (lite_awaddr),
    .m_axi_awvalid(lite_awvalid),
    .m_axi_awready(lite_awready),
    .m_axi_wdata  (lite_wdata),
    .m_axi_wstrb  (lite_wstrb),
    .m_axi_wvalid (lite_wvalid),
    .m_axi_wready (lite_wready),
    .m_axi_bresp  (lite_bresp),
    .m_axi_bvalid (lite_bvalid),
    .m_axi_bready (lite_bready),
    .m_axi_araddr (lite_araddr),
    .m_axi_arvalid(lite_arvalid),
    .m_axi_arready(lite_arready),
    .m_axi_rdata  (lite_rdata),
    .m_axi_rresp  (lite_rresp),
    .m_axi_rvalid (lite_rvalid),
    .m_axi_rready (lite_rready),
    .capture_active(capture_active),
    .init_done    (init_done),
    .init_error   (init_error),
    .mm2s_status  (mm2s_status),
    .s2mm_status  (s2mm_status),
    .status_valid (status_valid),
    .debug_state  (debug_state),
    .debug_write_index(debug_write_index)
);

reg  [5:0] s2mm_frame_ptr_d;

// A trustworthy camera-frame completion event: count IMAGE_HEIGHT AXI-stream line
// handshakes accepted by the VDMA.  This cannot be triggered merely by VDMA
// channel initialization or frame-pointer bookkeeping.
always @(posedge ddr_clk) begin
    if (!resetn) begin
        accepted_line_count <= {LINE_COUNT_WIDTH{1'b0}};
        capture_frame_done  <= 1'b0;
    end
    else if (input_tvalid && input_tready) begin
        if (input_tuser) begin
            accepted_line_count <= {LINE_COUNT_WIDTH{1'b0}};
            capture_frame_done  <= 1'b0;
        end
        if (input_tlast) begin
            if (accepted_line_count == IMAGE_HEIGHT-1)
                capture_frame_done <= 1'b1;
            else
                accepted_line_count <= accepted_line_count + {{(LINE_COUNT_WIDTH-1){1'b0}}, 1'b1};
        end
    end
end

always @(posedge ddr_clk) begin
    if (!resetn) begin
        s2mm_frame_ptr_d <= 6'd0;
        frame_seen <= 1'b0;
    end
    else begin
        s2mm_frame_ptr_d <= s2mm_frame_ptr;
        if (s2mm_frame_ptr != s2mm_frame_ptr_d)
            frame_seen <= 1'b1;
    end
end

camera_axi_vdma u_camera_axi_vdma (
    .s_axi_lite_aclk       (ddr_clk),
    .m_axi_mm2s_aclk       (ddr_clk),
    .m_axis_mm2s_aclk      (vga_axis_clk),
    .m_axi_s2mm_aclk       (ddr_clk),
    .s_axis_s2mm_aclk      (ddr_clk),
    .axi_resetn            (resetn),

    .s_axi_lite_awvalid    (lite_awvalid),
    .s_axi_lite_awready    (lite_awready),
    .s_axi_lite_awaddr     (lite_awaddr),
    .s_axi_lite_wvalid     (lite_wvalid),
    .s_axi_lite_wready     (lite_wready),
    .s_axi_lite_wdata      (lite_wdata),
    .s_axi_lite_bresp      (lite_bresp),
    .s_axi_lite_bvalid     (lite_bvalid),
    .s_axi_lite_bready     (lite_bready),
    .s_axi_lite_arvalid    (lite_arvalid),
    .s_axi_lite_arready    (lite_arready),
    .s_axi_lite_araddr     (lite_araddr),
    .s_axi_lite_rvalid     (lite_rvalid),
    .s_axi_lite_rready     (lite_rready),
    .s_axi_lite_rdata      (lite_rdata),
    .s_axi_lite_rresp      (lite_rresp),

    .mm2s_frame_ptr_out    (),
    .s2mm_frame_ptr_out    (s2mm_frame_ptr),

    .m_axi_mm2s_araddr     (mm2s_araddr),
    .m_axi_mm2s_arlen      (mm2s_arlen),
    .m_axi_mm2s_arsize     (mm2s_arsize),
    .m_axi_mm2s_arburst    (mm2s_arburst),
    .m_axi_mm2s_arprot     (mm2s_arprot),
    .m_axi_mm2s_arcache    (mm2s_arcache),
    .m_axi_mm2s_arvalid    (mm2s_arvalid),
    .m_axi_mm2s_arready    (mm2s_arready),
    .m_axi_mm2s_rdata      (mm2s_rdata),
    .m_axi_mm2s_rresp      (mm2s_rresp),
    .m_axi_mm2s_rlast      (mm2s_rlast),
    .m_axi_mm2s_rvalid     (mm2s_rvalid),
    .m_axi_mm2s_rready     (mm2s_rready),
    .m_axis_mm2s_tdata     (video_tdata),
    .m_axis_mm2s_tkeep     (video_tkeep),
    .m_axis_mm2s_tuser     (video_tuser),
    .m_axis_mm2s_tvalid    (video_tvalid),
    .m_axis_mm2s_tready    (video_tready),
    .m_axis_mm2s_tlast     (video_tlast),

    .m_axi_s2mm_awaddr     (s2mm_awaddr),
    .m_axi_s2mm_awlen      (s2mm_awlen),
    .m_axi_s2mm_awsize     (s2mm_awsize),
    .m_axi_s2mm_awburst    (s2mm_awburst),
    .m_axi_s2mm_awprot     (s2mm_awprot),
    .m_axi_s2mm_awcache    (s2mm_awcache),
    .m_axi_s2mm_awvalid    (s2mm_awvalid),
    .m_axi_s2mm_awready    (s2mm_awready),
    .m_axi_s2mm_wdata      (s2mm_wdata),
    .m_axi_s2mm_wstrb      (s2mm_wstrb),
    .m_axi_s2mm_wlast      (s2mm_wlast),
    .m_axi_s2mm_wvalid     (s2mm_wvalid),
    .m_axi_s2mm_wready     (s2mm_wready),
    .m_axi_s2mm_bresp      (s2mm_bresp),
    .m_axi_s2mm_bvalid     (s2mm_bvalid),
    .m_axi_s2mm_bready     (s2mm_bready),
    .s_axis_s2mm_tdata     (input_tdata),
    .s_axis_s2mm_tkeep     (input_tkeep),
    .s_axis_s2mm_tuser     (input_tuser),
    .s_axis_s2mm_tvalid    (input_tvalid),
    .s_axis_s2mm_tready    (input_tready),
    .s_axis_s2mm_tlast     (input_tlast),
    .mm2s_introut          (),
    .s2mm_introut          ()
);

endmodule
