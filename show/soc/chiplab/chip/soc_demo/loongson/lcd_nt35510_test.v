`timescale 1ns / 1ps

// Stand-alone first-stage driver for the ALIENTEK 4.3-inch NT35510 module.
// It initializes the 16-bit 8080 interface and writes one RGB565 test frame
// whenever mode[1:0] changes.
module lcd_nt35510_test #(
    parameter integer CLK_HZ        = 100000000,
    parameter integer H_RES         = 800,
    parameter integer V_RES         = 480,
    parameter integer RESET_LOW_MS  = 20,
    parameter integer RESET_HIGH_MS = 120
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire [1:0]  mode,

    output wire [15:0] lcd_db,
    output wire        lcd_cs_n,
    output wire        lcd_rs,
    output wire        lcd_wr_n,
    output wire        lcd_rd_n,
    output reg         lcd_rst_n,
    output wire        lcd_bl,

    output reg         init_done,
    output reg         frame_done
);

localparam integer CYCLES_PER_MS    = CLK_HZ / 1000;
localparam integer RESET_LOW_CYCLES = RESET_LOW_MS * CYCLES_PER_MS;
localparam integer RESET_HIGH_CYCLES = RESET_HIGH_MS * CYCLES_PER_MS;

localparam [3:0] ST_RESET_LOW       = 4'd0,
                 ST_RESET_HIGH      = 4'd1,
                 ST_INIT_FETCH      = 4'd2,
                 ST_INIT_WAIT       = 4'd3,
                 ST_INIT_DELAY      = 4'd4,
                 ST_READY           = 4'd5,
                 ST_SETUP_FETCH     = 4'd6,
                 ST_SETUP_WAIT      = 4'd7,
                 ST_PIXEL_FETCH     = 4'd8,
                 ST_PIXEL_WAIT      = 4'd9;

localparam [1:0] OP_COMMAND = 2'b00,
                 OP_DATA    = 2'b01,
                 OP_DELAYMS = 2'b10,
                 OP_END     = 2'b11;

reg [3:0]  state;
reg [31:0] wait_count;
reg [9:0]  init_index;
wire [1:0] init_op;
wire [15:0] init_value;

reg         writer_start;
reg         writer_is_data;
reg [15:0]  writer_data;
wire        writer_busy;
wire        writer_done;
wire [15:0] writer_db;

reg [4:0]  setup_index;
reg [9:0]  pixel_x;
reg [8:0]  pixel_y;
reg [1:0]  draw_mode;
reg [1:0]  rendered_mode;

wire [16:0] setup_entry;
wire [15:0] test_pixel;

assign lcd_db = writer_db;
assign lcd_bl = init_done && (mode != 2'b00);

lcd_nt35510_init_rom u_init_rom (
    .index (init_index),
    .op    (init_op),
    .value (init_value)
);

lcd_8080_writer #(
    .LOW_CYCLES  (2),
    .HIGH_CYCLES (2)
) u_writer (
    .clk        (clk),
    .resetn     (resetn),
    .start      (writer_start),
    .is_data    (writer_is_data),
    .write_data (writer_data),
    .busy       (writer_busy),
    .done       (writer_done),
    .db_out     (writer_db),
    .cs_n       (lcd_cs_n),
    .rs         (lcd_rs),
    .wr_n       (lcd_wr_n),
    .rd_n       (lcd_rd_n)
);

// Full 800x480 landscape address window, followed by RAM write command.
function [16:0] frame_setup;
    input [4:0] idx;
    begin
        case (idx)
            5'd0:  frame_setup = {1'b0, 16'h2A00};
            5'd1:  frame_setup = {1'b1, 16'h0000};
            5'd2:  frame_setup = {1'b0, 16'h2A01};
            5'd3:  frame_setup = {1'b1, 16'h0000};
            5'd4:  frame_setup = {1'b0, 16'h2A02};
            5'd5:  frame_setup = 17'h10000 | ((H_RES - 1) >> 8);
            5'd6:  frame_setup = {1'b0, 16'h2A03};
            5'd7:  frame_setup = 17'h10000 | ((H_RES - 1) & 16'h00ff);
            5'd8:  frame_setup = {1'b0, 16'h2B00};
            5'd9:  frame_setup = {1'b1, 16'h0000};
            5'd10: frame_setup = {1'b0, 16'h2B01};
            5'd11: frame_setup = {1'b1, 16'h0000};
            5'd12: frame_setup = {1'b0, 16'h2B02};
            5'd13: frame_setup = 17'h10000 | ((V_RES - 1) >> 8);
            5'd14: frame_setup = {1'b0, 16'h2B03};
            5'd15: frame_setup = 17'h10000 | ((V_RES - 1) & 16'h00ff);
            default: frame_setup = {1'b0, 16'h2C00};
        endcase
    end
endfunction

// mode 01: eight vertical bars; mode 10: checkerboard; mode 11: gradient.
function [15:0] pattern_pixel;
    input [1:0] mode_i;
    input [9:0] x_i;
    input [8:0] y_i;
    begin
        case (mode_i)
            2'b01: begin
                if      (x_i < (H_RES * 1) / 8) pattern_pixel = 16'hFFFF;
                else if (x_i < (H_RES * 2) / 8) pattern_pixel = 16'hFFE0;
                else if (x_i < (H_RES * 3) / 8) pattern_pixel = 16'h07FF;
                else if (x_i < (H_RES * 4) / 8) pattern_pixel = 16'h07E0;
                else if (x_i < (H_RES * 5) / 8) pattern_pixel = 16'hF81F;
                else if (x_i < (H_RES * 6) / 8) pattern_pixel = 16'hF800;
                else if (x_i < (H_RES * 7) / 8) pattern_pixel = 16'h001F;
                else                             pattern_pixel = 16'h0000;
            end
            2'b10: pattern_pixel = (x_i[5] ^ y_i[5]) ? 16'hFFFF : 16'h001F;
            2'b11: pattern_pixel = {x_i[9:5], y_i[8:3], x_i[9:5]};
            default: pattern_pixel = 16'h0000;
        endcase
    end
endfunction

assign setup_entry = frame_setup(setup_index);
assign test_pixel  = pattern_pixel(draw_mode, pixel_x, pixel_y);

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state          <= ST_RESET_LOW;
        wait_count     <= 32'd0;
        init_index     <= 10'd0;
        writer_start   <= 1'b0;
        writer_is_data <= 1'b0;
        writer_data    <= 16'd0;
        setup_index    <= 5'd0;
        pixel_x        <= 10'd0;
        pixel_y        <= 9'd0;
        draw_mode      <= 2'b00;
        rendered_mode  <= 2'b00;
        lcd_rst_n      <= 1'b0;
        init_done      <= 1'b0;
        frame_done     <= 1'b0;
    end else begin
        writer_start <= 1'b0;
        frame_done   <= 1'b0;

        case (state)
            ST_RESET_LOW: begin
                lcd_rst_n <= 1'b0;
                if (wait_count >= RESET_LOW_CYCLES - 1) begin
                    wait_count <= 32'd0;
                    lcd_rst_n  <= 1'b1;
                    state      <= ST_RESET_HIGH;
                end else begin
                    wait_count <= wait_count + 32'd1;
                end
            end

            ST_RESET_HIGH: begin
                lcd_rst_n <= 1'b1;
                if (wait_count >= RESET_HIGH_CYCLES - 1) begin
                    wait_count <= 32'd0;
                    init_index <= 10'd0;
                    state      <= ST_INIT_FETCH;
                end else begin
                    wait_count <= wait_count + 32'd1;
                end
            end

            ST_INIT_FETCH: begin
                if (init_op == OP_END) begin
                    init_done <= 1'b1;
                    state     <= ST_READY;
                end else if (init_op == OP_DELAYMS) begin
                    wait_count <= init_value * CYCLES_PER_MS;
                    state      <= ST_INIT_DELAY;
                end else if (!writer_busy) begin
                    writer_is_data <= (init_op == OP_DATA);
                    writer_data    <= init_value;
                    writer_start   <= 1'b1;
                    state          <= ST_INIT_WAIT;
                end
            end

            ST_INIT_WAIT: begin
                if (writer_done) begin
                    init_index <= init_index + 10'd1;
                    state      <= ST_INIT_FETCH;
                end
            end

            ST_INIT_DELAY: begin
                if (wait_count <= 1) begin
                    wait_count <= 32'd0;
                    init_index <= init_index + 10'd1;
                    state      <= ST_INIT_FETCH;
                end else begin
                    wait_count <= wait_count - 32'd1;
                end
            end

            ST_READY: begin
                if ((mode != 2'b00) && (mode != rendered_mode)) begin
                    draw_mode   <= mode;
                    setup_index <= 5'd0;
                    state       <= ST_SETUP_FETCH;
                end
            end

            ST_SETUP_FETCH: begin
                if (mode == 2'b00) begin
                    state <= ST_READY;
                end else if (!writer_busy) begin
                    writer_is_data <= setup_entry[16];
                    writer_data    <= setup_entry[15:0];
                    writer_start   <= 1'b1;
                    state          <= ST_SETUP_WAIT;
                end
            end

            ST_SETUP_WAIT: begin
                if (writer_done) begin
                    if (setup_index == 5'd16) begin
                        pixel_x <= 10'd0;
                        pixel_y <= 9'd0;
                        state   <= ST_PIXEL_FETCH;
                    end else begin
                        setup_index <= setup_index + 5'd1;
                        state       <= ST_SETUP_FETCH;
                    end
                end
            end

            ST_PIXEL_FETCH: begin
                if (mode == 2'b00) begin
                    state <= ST_READY;
                end else if (!writer_busy) begin
                    writer_is_data <= 1'b1;
                    writer_data    <= test_pixel;
                    writer_start   <= 1'b1;
                    state          <= ST_PIXEL_WAIT;
                end
            end

            ST_PIXEL_WAIT: begin
                if (writer_done) begin
                    if ((pixel_x == H_RES - 1) && (pixel_y == V_RES - 1)) begin
                        rendered_mode <= draw_mode;
                        frame_done    <= 1'b1;
                        state         <= ST_READY;
                    end else begin
                        if (pixel_x == H_RES - 1) begin
                            pixel_x <= 10'd0;
                            pixel_y <= pixel_y + 9'd1;
                        end else begin
                            pixel_x <= pixel_x + 10'd1;
                        end
                        state <= ST_PIXEL_FETCH;
                    end
                end
            end

            default: state <= ST_RESET_LOW;
        endcase
    end
end

endmodule
