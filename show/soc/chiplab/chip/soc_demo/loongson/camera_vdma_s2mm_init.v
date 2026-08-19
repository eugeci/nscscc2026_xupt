// AXI4-Lite sequencer for the continuous camera -> DDR -> VGA path.
//
// S2MM is a dynamic-genlock master and continuously alternates FRAME0/FRAME1.
// MM2S is started after the first complete frame and remains one frame behind
// the writer.  This avoids reading a frame while the camera is modifying it.
module camera_vdma_s2mm_init #(
    parameter [31:0] FRAME0_ADDR = 32'h07c0_0000,
    parameter [31:0] FRAME1_ADDR = 32'h07d0_0000,
    parameter [31:0] HSIZE_BYTES = 32'd1280,
    parameter [31:0] STRIDE_BYTES = 32'd1280,
    parameter [31:0] VSIZE_LINES = 32'd480,
    // AXI VDMA resets are synchronized into several independent clock
    // domains.  Do not touch AXI-Lite immediately when axi_resetn rises.
    parameter integer RESET_SETTLE_CYCLES = 256,
    // VSIZE starts the S2MM engine, but its stream-side FIFOs need several
    // cycles before the first SOF can be accepted without losing pixels.
    parameter integer CHANNEL_ARM_CYCLES = 64
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire        capture_frame_done,

    output reg  [8:0]  m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,

    output reg  [8:0]  m_axi_araddr,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output reg         m_axi_rready,

    output reg         capture_active,
    output reg         init_done,
    output reg         init_error,
    output reg  [31:0] mm2s_status,
    output reg  [31:0] s2mm_status,
    output reg         status_valid,
    output wire [3:0]  debug_state,
    output wire [3:0]  debug_write_index
);

localparam [3:0] ST_WAIT        = 4'd0;
localparam [3:0] ST_LOAD        = 4'd1;
localparam [3:0] ST_WRITE       = 4'd2;
localparam [3:0] ST_RESP        = 4'd3;
localparam [3:0] ST_FIRST_FRAME = 4'd4;
localparam [3:0] ST_DONE        = 4'd5;
localparam [3:0] ST_ARM_S2MM    = 4'd6;

reg [3:0] state;
reg [3:0] write_index;
reg       aw_complete;
reg       w_complete;
reg [15:0] reset_settle_count;
reg [15:0] channel_arm_count;

assign m_axi_wstrb = 4'b1111;
assign debug_state = state;
assign debug_write_index = write_index;

// Low-rate status polling remains available on the physical LEDs.
localparam [1:0] RD_WAIT = 2'd0;
localparam [1:0] RD_ADDR = 2'd1;
localparam [1:0] RD_DATA = 2'd2;
reg [1:0]  read_state;
reg        read_s2mm;
reg [15:0] read_delay;

always @(posedge clk) begin
    if (!resetn) begin
        m_axi_araddr  <= 9'd0;
        m_axi_arvalid <= 1'b0;
        m_axi_rready  <= 1'b0;
        mm2s_status   <= 32'd0;
        s2mm_status   <= 32'd0;
        status_valid  <= 1'b0;
        read_state    <= RD_WAIT;
        read_s2mm     <= 1'b0;
        read_delay    <= 16'd0;
    end
    else if (!init_done) begin
        m_axi_arvalid <= 1'b0;
        m_axi_rready  <= 1'b0;
        status_valid  <= 1'b0;
        read_state    <= RD_WAIT;
        read_s2mm     <= 1'b0;
        read_delay    <= 16'd0;
    end
    else begin
        case (read_state)
            RD_WAIT: begin
                read_delay <= read_delay + 16'd1;
                if (&read_delay) begin
                    m_axi_araddr  <= read_s2mm ? 9'h034 : 9'h004;
                    m_axi_arvalid <= 1'b1;
                    read_state    <= RD_ADDR;
                end
            end
            RD_ADDR: if (m_axi_arvalid && m_axi_arready) begin
                m_axi_arvalid <= 1'b0;
                m_axi_rready  <= 1'b1;
                read_state    <= RD_DATA;
            end
            RD_DATA: if (m_axi_rvalid) begin
                m_axi_rready <= 1'b0;
                if (read_s2mm)
                    s2mm_status <= m_axi_rdata;
                else
                    mm2s_status <= m_axi_rdata;
                status_valid <= 1'b1;
                read_s2mm    <= ~read_s2mm;
                read_delay   <= 16'd0;
                read_state   <= RD_WAIT;
            end
            default: read_state <= RD_WAIT;
        endcase
    end
end

always @(posedge clk) begin
    if (!resetn) begin
        state          <= ST_WAIT;
        write_index    <= 4'd0;
        m_axi_awaddr   <= 9'd0;
        m_axi_awvalid  <= 1'b0;
        m_axi_wdata    <= 32'd0;
        m_axi_wvalid   <= 1'b0;
        m_axi_bready   <= 1'b0;
        aw_complete    <= 1'b0;
        w_complete     <= 1'b0;
        reset_settle_count <= 16'd0;
        channel_arm_count <= 16'd0;
        capture_active <= 1'b0;
        init_done      <= 1'b0;
        init_error     <= 1'b0;
    end
    else begin
        case (state)
            ST_WAIT: begin
                init_done <= 1'b0;
                if (start) begin
                    if ((RESET_SETTLE_CYCLES <= 1) ||
                        (reset_settle_count == RESET_SETTLE_CYCLES-1)) begin
                        write_index <= 4'd0;
                        state <= ST_LOAD;
                    end
                    else begin
                        reset_settle_count <= reset_settle_count + 16'd1;
                    end
                end
                else
                    reset_settle_count <= 16'd0;
            end

            ST_LOAD: begin
                case (write_index)
                    // Run + circular + internal dynamic genlock.
                    4'd0:  begin m_axi_awaddr <= 9'h030; m_axi_wdata <= 32'h0000_008b; end
                    4'd1:  begin m_axi_awaddr <= 9'h0ac; m_axi_wdata <= FRAME0_ADDR; end
                    4'd2:  begin m_axi_awaddr <= 9'h0b0; m_axi_wdata <= FRAME1_ADDR; end
                    4'd3:  begin m_axi_awaddr <= 9'h0a8; m_axi_wdata <= STRIDE_BYTES; end
                    4'd4:  begin m_axi_awaddr <= 9'h0a4; m_axi_wdata <= HSIZE_BYTES; end
                    4'd5:  begin m_axi_awaddr <= 9'h0a0; m_axi_wdata <= VSIZE_LINES; end

                    // Start reader only after frame 0 is complete.  Frame delay
                    // 1 keeps the MM2S dynamic slave one frame behind S2MM.
                    4'd6:  begin m_axi_awaddr <= 9'h000; m_axi_wdata <= 32'h0000_008b; end
                    4'd7:  begin m_axi_awaddr <= 9'h028; m_axi_wdata <= 32'h0000_0000; end
                    4'd8:  begin m_axi_awaddr <= 9'h05c; m_axi_wdata <= FRAME0_ADDR; end
                    4'd9:  begin m_axi_awaddr <= 9'h060; m_axi_wdata <= FRAME1_ADDR; end
                    4'd10: begin m_axi_awaddr <= 9'h058; m_axi_wdata <= STRIDE_BYTES | 32'h0100_0000; end
                    4'd11: begin m_axi_awaddr <= 9'h054; m_axi_wdata <= HSIZE_BYTES; end
                    default: begin m_axi_awaddr <= 9'h050; m_axi_wdata <= VSIZE_LINES; end
                endcase
                aw_complete   <= 1'b0;
                w_complete    <= 1'b0;
                m_axi_awvalid <= 1'b1;
                m_axi_wvalid  <= 1'b1;
                state         <= ST_WRITE;
            end

            ST_WRITE: begin
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    aw_complete <= 1'b1;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wvalid <= 1'b0;
                    w_complete <= 1'b1;
                end
                if ((aw_complete || (m_axi_awvalid && m_axi_awready)) &&
                    (w_complete  || (m_axi_wvalid  && m_axi_wready))) begin
                    m_axi_bready <= 1'b1;
                    state <= ST_RESP;
                end
            end

            ST_RESP: if (m_axi_bvalid) begin
                m_axi_bready <= 1'b0;
                if (m_axi_bresp != 2'b00)
                    init_error <= 1'b1;

                if (write_index == 4'd5) begin
                    channel_arm_count <= 16'd0;
                    state <= ST_ARM_S2MM;
                end
                else if (write_index == 4'd12)
                    state <= ST_DONE;
                else begin
                    write_index <= write_index + 4'd1;
                    state <= ST_LOAD;
                end
            end

            ST_FIRST_FRAME: if (capture_frame_done) begin
                write_index <= 4'd6;
                state <= ST_LOAD;
            end

            ST_ARM_S2MM: begin
                if ((CHANNEL_ARM_CYCLES <= 1) ||
                    (channel_arm_count == CHANNEL_ARM_CYCLES-1)) begin
                    capture_active <= 1'b1;
                    state <= ST_FIRST_FRAME;
                end
                else begin
                    channel_arm_count <= channel_arm_count + 16'd1;
                end
            end

            ST_DONE: begin
                capture_active <= 1'b1;
                init_done <= 1'b1;
            end

            default: state <= ST_WAIT;
        endcase
    end
end

endmodule
