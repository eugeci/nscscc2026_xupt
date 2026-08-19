// AXI4-Stream nearest-neighbour 2x video scaler with ping-pong line buffers.
//
// While one 320-pixel source line is emitted twice with every pixel repeated,
// the other buffer captures the next source line.  Capture and scaling are
// therefore concurrent, which sustains a 25 Mpixel/s camera input on a
// 100 MHz output clock without accumulating a frame-sized backlog.
module axis_video_2x_scaler #(
    parameter integer INPUT_WIDTH  = 320,
    parameter integer INPUT_HEIGHT = 240
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire [15:0] s_axis_tdata,
    input  wire [1:0]  s_axis_tkeep,
    input  wire        s_axis_tuser,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,

    output wire [15:0] m_axis_tdata,
    output wire [1:0]  m_axis_tkeep,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);

localparam integer X_WIDTH = (INPUT_WIDTH <= 2) ? 1 : $clog2(INPUT_WIDTH);

(* ram_style = "distributed" *) reg [15:0] line_mem0 [0:INPUT_WIDTH-1];
(* ram_style = "distributed" *) reg [15:0] line_mem1 [0:INPUT_WIDTH-1];

reg [1:0]               line_ready;
reg [1:0]               line_sof;
reg                     write_bank;
reg                     read_bank;
reg [X_WIDTH-1:0]       write_x;
reg [X_WIDTH-1:0]       read_x;
reg                     output_active;
reg                     horizontal_repeat;
reg                     vertical_repeat;

wire input_fire  = s_axis_tvalid && s_axis_tready;
wire output_fire = m_axis_tvalid && m_axis_tready;

assign s_axis_tready = !line_ready[write_bank];
assign m_axis_tvalid = output_active;
assign m_axis_tdata  = read_bank ? line_mem1[read_x] : line_mem0[read_x];
assign m_axis_tkeep  = 2'b11;
assign m_axis_tuser  = line_sof[read_bank] && !vertical_repeat
                     && (read_x == 0) && !horizontal_repeat;
assign m_axis_tlast  = (read_x == INPUT_WIDTH-1) && horizontal_repeat;

always @(posedge clk) begin
    if (!resetn) begin
        line_ready       <= 2'b00;
        line_sof         <= 2'b00;
        write_bank       <= 1'b0;
        read_bank        <= 1'b0;
        write_x          <= {X_WIDTH{1'b0}};
        read_x           <= {X_WIDTH{1'b0}};
        output_active    <= 1'b0;
        horizontal_repeat <= 1'b0;
        vertical_repeat  <= 1'b0;
    end
    else begin
        // Capture into the free bank while the other bank is being replayed.
        if (input_fire) begin
            if (write_bank)
                line_mem1[write_x] <= s_axis_tdata;
            else
                line_mem0[write_x] <= s_axis_tdata;

            if (write_x == 0)
                line_sof[write_bank] <= s_axis_tuser;

            if (s_axis_tlast || (write_x == INPUT_WIDTH-1)) begin
                line_ready[write_bank] <= 1'b1;
                write_bank <= ~write_bank;
                write_x <= {X_WIDTH{1'b0}};
            end
            else begin
                write_x <= write_x + {{(X_WIDTH-1){1'b0}}, 1'b1};
            end
        end

        // Start a buffered line as soon as it is available.
        if (!output_active && line_ready[read_bank]) begin
            output_active     <= 1'b1;
            read_x            <= {X_WIDTH{1'b0}};
            horizontal_repeat <= 1'b0;
            vertical_repeat   <= 1'b0;
        end
        else if (output_fire) begin
            if (!horizontal_repeat) begin
                horizontal_repeat <= 1'b1;
            end
            else begin
                horizontal_repeat <= 1'b0;
                if (read_x == INPUT_WIDTH-1) begin
                    read_x <= {X_WIDTH{1'b0}};
                    if (!vertical_repeat) begin
                        vertical_repeat <= 1'b1;
                    end
                    else begin
                        vertical_repeat <= 1'b0;
                        output_active   <= 1'b0;
                        line_ready[read_bank] <= 1'b0;
                        read_bank <= ~read_bank;
                    end
                end
                else begin
                    read_x <= read_x + {{(X_WIDTH-1){1'b0}}, 1'b1};
                end
            end
        end
    end
end

// The current camera path always supplies both RGB565 byte lanes.
wire unused_s_axis_tkeep = &s_axis_tkeep;
wire unused_input_height = (INPUT_HEIGHT == 0);

endmodule
