`timescale 1ns/1ps

// UART console monitor and 80x30 text-mode VGA display.
//
// The module passively listens to the existing 115200-8-N-1 Linux UART TX
// signal.  It does not replace or load the external serial connection.  Each
// printable character is stored in a circular 80x30 text buffer and rendered
// with a compact 5x7 font inside an 8x16 cell at 640x480 @ 60 Hz.
module uart_vga_terminal #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD     = 115200
) (
    input  wire       clk_50m,
    input  wire       resetn,
    input  wire       uart_txd,
    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output wire       vga_hsync,
    output wire       vga_vsync
);

localparam integer CLKS_PER_BIT = CLOCK_HZ / BAUD;
localparam integer COLS = 80;
localparam integer ROWS = 30;
localparam integer CELLS = COLS * ROWS;

// -------------------------------------------------------------------------
// Passive UART receiver
// -------------------------------------------------------------------------
reg [1:0] uart_sync;
reg [1:0] rx_state;
reg [15:0] rx_count;
reg [2:0] rx_bit;
reg [7:0] rx_shift;
reg [7:0] rx_data;
reg       rx_valid;

localparam RX_IDLE  = 2'd0;
localparam RX_START = 2'd1;
localparam RX_DATA  = 2'd2;
localparam RX_STOP  = 2'd3;

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        uart_sync <= 2'b11;
        rx_state  <= RX_IDLE;
        rx_count  <= 16'd0;
        rx_bit    <= 3'd0;
        rx_shift  <= 8'd0;
        rx_data   <= 8'd0;
        rx_valid  <= 1'b0;
    end else begin
        uart_sync <= {uart_sync[0], uart_txd};
        rx_valid  <= 1'b0;

        case (rx_state)
            RX_IDLE: begin
                rx_count <= 16'd0;
                if (!uart_sync[1])
                    rx_state <= RX_START;
            end

            RX_START: begin
                if (rx_count == (CLKS_PER_BIT/2)-1) begin
                    rx_count <= 16'd0;
                    if (!uart_sync[1]) begin
                        rx_bit   <= 3'd0;
                        rx_state <= RX_DATA;
                    end else begin
                        rx_state <= RX_IDLE;
                    end
                end else begin
                    rx_count <= rx_count + 16'd1;
                end
            end

            RX_DATA: begin
                if (rx_count == CLKS_PER_BIT-1) begin
                    rx_count        <= 16'd0;
                    rx_shift[rx_bit] <= uart_sync[1];
                    if (rx_bit == 3'd7)
                        rx_state <= RX_STOP;
                    else
                        rx_bit <= rx_bit + 3'd1;
                end else begin
                    rx_count <= rx_count + 16'd1;
                end
            end

            default: begin // RX_STOP
                if (rx_count == CLKS_PER_BIT-1) begin
                    rx_count <= 16'd0;
                    rx_state <= RX_IDLE;
                    if (uart_sync[1]) begin
                        rx_data  <= rx_shift;
                        rx_valid <= 1'b1;
                    end
                end else begin
                    rx_count <= rx_count + 16'd1;
                end
            end
        endcase
    end
end

// -------------------------------------------------------------------------
// 80x30 terminal buffer and minimal ANSI/control-character parser
// -------------------------------------------------------------------------
(* ram_style = "block" *) reg [7:0] text_ram [0:CELLS-1];
reg        text_we;
reg [11:0] text_waddr;
reg [7:0]  text_wdata;

reg [6:0] cursor_col;
reg [4:0] cursor_row;
reg [4:0] row_base;
reg [1:0] ansi_state;
reg       clear_active;
reg [11:0] clear_addr;
reg       row_clear_active;
reg [6:0] row_clear_col;
reg [4:0] row_clear_phys;

localparam ANSI_NORMAL = 2'd0;
localparam ANSI_ESC    = 2'd1;
localparam ANSI_CSI    = 2'd2;

function [4:0] physical_row;
    input [4:0] logical_row;
    input [4:0] base_row;
    reg [5:0] sum;
    begin
        sum = logical_row + base_row;
        if (sum >= ROWS)
            physical_row = sum - ROWS;
        else
            physical_row = sum[4:0];
    end
endfunction

wire [4:0] cursor_phys = physical_row(cursor_row, row_base);
wire [11:0] cursor_addr = (cursor_phys << 6)
                        + (cursor_phys << 4)
                        + cursor_col;
wire [11:0] row_clear_addr = (row_clear_phys << 6)
                           + (row_clear_phys << 4)
                           + row_clear_col;

// Keep both RAM ports in reset-free processes so Vivado can infer a true
// dual-port block RAM. The terminal state machine drives a registered write
// request; the request is committed on the following clock.
always @(posedge clk_50m) begin
    if (text_we)
        text_ram[text_waddr] <= text_wdata;
end

task advance_line;
    begin
        cursor_col <= 7'd0;
        if (cursor_row == ROWS-1) begin
            cursor_row       <= ROWS-1;
            row_clear_active <= 1'b1;
            row_clear_col    <= 7'd0;
            row_clear_phys   <= row_base;
            if (row_base == ROWS-1)
                row_base <= 5'd0;
            else
                row_base <= row_base + 5'd1;
        end else begin
            cursor_row <= cursor_row + 5'd1;
        end
    end
endtask

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        cursor_col       <= 7'd0;
        cursor_row       <= 5'd0;
        row_base         <= 5'd0;
        ansi_state       <= ANSI_NORMAL;
        clear_active     <= 1'b1;
        clear_addr       <= 12'd0;
        row_clear_active <= 1'b0;
        row_clear_col    <= 7'd0;
        row_clear_phys   <= 5'd0;
        text_we          <= 1'b0;
        text_waddr       <= 12'd0;
        text_wdata       <= 8'h20;
    end else begin
        text_we <= 1'b0;
        if (clear_active) begin
        text_we    <= 1'b1;
        text_waddr <= clear_addr;
        text_wdata <= 8'h20;
        if (clear_addr == CELLS-1) begin
            clear_active <= 1'b0;
            clear_addr   <= 12'd0;
            cursor_col   <= 7'd0;
            cursor_row   <= 5'd0;
            row_base     <= 5'd0;
        end else begin
            clear_addr <= clear_addr + 12'd1;
        end
        end else if (row_clear_active) begin
        text_we    <= 1'b1;
        text_waddr <= row_clear_addr;
        text_wdata <= 8'h20;
        if (row_clear_col == COLS-1) begin
            row_clear_active <= 1'b0;
            row_clear_col    <= 7'd0;
        end else begin
            row_clear_col <= row_clear_col + 7'd1;
        end
        end else if (rx_valid) begin
        case (ansi_state)
            ANSI_ESC: begin
                if (rx_data == 8'h5b)
                    ansi_state <= ANSI_CSI; // ESC [
                else
                    ansi_state <= ANSI_NORMAL;
            end

            ANSI_CSI: begin
                // A CSI sequence ends at the first byte in 0x40..0x7e.
                // Colour/style controls are intentionally discarded.  Clear
                // screen and cursor-home get small useful implementations.
                if ((rx_data >= 8'h40) && (rx_data <= 8'h7e)) begin
                    ansi_state <= ANSI_NORMAL;
                    if (rx_data == 8'h4a) begin // J
                        clear_active <= 1'b1;
                        clear_addr   <= 12'd0;
                    end else if (rx_data == 8'h48) begin // H
                        cursor_col <= 7'd0;
                        cursor_row <= 5'd0;
                    end
                end
            end

            default: begin
                if (rx_data == 8'h1b) begin
                    ansi_state <= ANSI_ESC;
                end else if ((rx_data == 8'h0a) || (rx_data == 8'h0b)
                          || (rx_data == 8'h0c)) begin
                    advance_line();
                end else if (rx_data == 8'h0d) begin
                    cursor_col <= 7'd0;
                end else if ((rx_data == 8'h08) || (rx_data == 8'h7f)) begin
                    if (cursor_col != 0)
                        cursor_col <= cursor_col - 7'd1;
                end else if (rx_data == 8'h09) begin
                    if (cursor_col < 7'd72)
                        cursor_col <= {cursor_col[6:3] + 4'd1, 3'b000};
                    else
                        advance_line();
                end else if ((rx_data >= 8'h20) && (rx_data <= 8'h7e)) begin
                    text_we    <= 1'b1;
                    text_waddr <= cursor_addr;
                    text_wdata <= rx_data;
                    if (cursor_col == COLS-1)
                        advance_line();
                    else
                        cursor_col <= cursor_col + 7'd1;
                end
            end
        endcase
        end
    end
end

// -------------------------------------------------------------------------
// 640x480 timing, text RAM read port and font renderer
// -------------------------------------------------------------------------
reg       pixel_enable;
reg [9:0] h_count;
reg [9:0] v_count;
reg       active_q;
reg       hsync_q;
reg       vsync_q;
reg [2:0] glyph_x_q;
reg [3:0] glyph_y_q;
reg [6:0] char_col_q;
reg [4:0] char_row_q;
reg [7:0] char_q;
reg [24:0] blink_count;
reg        blink_on;

wire active_now = (h_count < 10'd640) && (v_count < 10'd480);
wire hsync_now = ~((h_count >= 10'd656) && (h_count < 10'd752));
wire vsync_now = ~((v_count >= 10'd490) && (v_count < 10'd492));
wire [6:0] display_col = h_count[9:3];
wire [4:0] display_row = v_count[8:4];
wire [4:0] display_phys = physical_row(display_row, row_base);
wire [11:0] display_addr = (display_phys << 6)
                         + (display_phys << 4)
                         + display_col;

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn) begin
        pixel_enable <= 1'b0;
        h_count      <= 10'd0;
        v_count      <= 10'd0;
        active_q     <= 1'b0;
        hsync_q      <= 1'b1;
        vsync_q      <= 1'b1;
        glyph_x_q    <= 3'd0;
        glyph_y_q    <= 4'd0;
        char_col_q   <= 7'd0;
        char_row_q   <= 5'd0;
        blink_count  <= 25'd0;
        blink_on     <= 1'b0;
    end else begin
        pixel_enable <= ~pixel_enable;
        if (blink_count == 25'd24999999) begin
            blink_count <= 25'd0;
            blink_on    <= ~blink_on;
        end else begin
            blink_count <= blink_count + 25'd1;
        end

        if (pixel_enable) begin
            active_q   <= active_now;
            hsync_q    <= hsync_now;
            vsync_q    <= vsync_now;
            glyph_x_q  <= h_count[2:0];
            glyph_y_q  <= v_count[3:0];
            char_col_q <= display_col;
            char_row_q <= display_row;
            if (h_count == 10'd799) begin
                h_count <= 10'd0;
                if (v_count == 10'd524)
                    v_count <= 10'd0;
                else
                    v_count <= v_count + 10'd1;
            end else begin
                h_count <= h_count + 10'd1;
            end
        end
    end
end

// Synchronous block-RAM display read port.
always @(posedge clk_50m) begin
    if (pixel_enable && active_now)
        char_q <= text_ram[display_addr];
end

assign vga_hsync = hsync_q;
assign vga_vsync = vsync_q;

// Five useful pixels per eight-pixel character cell. Lower-case characters
// deliberately share the upper-case glyph to keep the ROM small and robust.
function [39:0] glyph5x8;
    input [7:0] code;
    reg [7:0] c;
    begin
        if ((code >= "a") && (code <= "z"))
            c = code - 8'd32;
        else
            c = code;

        case (c)
            "!": glyph5x8={5'b00100,5'b00100,5'b00100,5'b00100,5'b00000,5'b00100,5'b00000,5'b00000};
            "\"":glyph5x8={5'b01010,5'b01010,5'b01010,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000};
            "#": glyph5x8={5'b01010,5'b11111,5'b01010,5'b01010,5'b11111,5'b01010,5'b00000,5'b00000};
            "$": glyph5x8={5'b00100,5'b01111,5'b10100,5'b01110,5'b00101,5'b11110,5'b00100,5'b00000};
            "%": glyph5x8={5'b11001,5'b11010,5'b00100,5'b01000,5'b10110,5'b00110,5'b00000,5'b00000};
            "&": glyph5x8={5'b01100,5'b10010,5'b10100,5'b01000,5'b10101,5'b10010,5'b01101,5'b00000};
            "'": glyph5x8={5'b00100,5'b00100,5'b01000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000};
            "(": glyph5x8={5'b00010,5'b00100,5'b01000,5'b01000,5'b01000,5'b00100,5'b00010,5'b00000};
            ")": glyph5x8={5'b01000,5'b00100,5'b00010,5'b00010,5'b00010,5'b00100,5'b01000,5'b00000};
            "*": glyph5x8={5'b00000,5'b10101,5'b01110,5'b11111,5'b01110,5'b10101,5'b00000,5'b00000};
            "+": glyph5x8={5'b00000,5'b00100,5'b00100,5'b11111,5'b00100,5'b00100,5'b00000,5'b00000};
            ",": glyph5x8={5'b00000,5'b00000,5'b00000,5'b00000,5'b00110,5'b00100,5'b01000,5'b00000};
            "-": glyph5x8={5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000,5'b00000};
            ".": glyph5x8={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b01100,5'b01100,5'b00000};
            "/": glyph5x8={5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b00000,5'b00000,5'b00000};
            "0": glyph5x8={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110,5'b00000};
            "1": glyph5x8={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110,5'b00000};
            "2": glyph5x8={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111,5'b00000};
            "3": glyph5x8={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110,5'b00000};
            "4": glyph5x8={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010,5'b00000};
            "5": glyph5x8={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110,5'b00000};
            "6": glyph5x8={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110,5'b00000};
            "7": glyph5x8={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000,5'b00000};
            "8": glyph5x8={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110,5'b00000};
            "9": glyph5x8={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110,5'b00000};
            ":": glyph5x8={5'b00000,5'b01100,5'b01100,5'b00000,5'b01100,5'b01100,5'b00000,5'b00000};
            ";": glyph5x8={5'b00000,5'b00110,5'b00110,5'b00000,5'b00110,5'b00100,5'b01000,5'b00000};
            "<": glyph5x8={5'b00010,5'b00100,5'b01000,5'b10000,5'b01000,5'b00100,5'b00010,5'b00000};
            "=": glyph5x8={5'b00000,5'b00000,5'b11111,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
            ">": glyph5x8={5'b01000,5'b00100,5'b00010,5'b00001,5'b00010,5'b00100,5'b01000,5'b00000};
            "?": glyph5x8={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b00000,5'b00100,5'b00000};
            "@": glyph5x8={5'b01110,5'b10001,5'b10111,5'b10101,5'b10111,5'b10000,5'b01111,5'b00000};
            "A": glyph5x8={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001,5'b00000};
            "B": glyph5x8={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110,5'b00000};
            "C": glyph5x8={5'b01110,5'b10001,5'b10000,5'b10000,5'b10000,5'b10001,5'b01110,5'b00000};
            "D": glyph5x8={5'b11100,5'b10010,5'b10001,5'b10001,5'b10001,5'b10010,5'b11100,5'b00000};
            "E": glyph5x8={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111,5'b00000};
            "F": glyph5x8={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000,5'b00000};
            "G": glyph5x8={5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110,5'b00000};
            "H": glyph5x8={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001,5'b00000};
            "I": glyph5x8={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110,5'b00000};
            "J": glyph5x8={5'b00111,5'b00010,5'b00010,5'b00010,5'b00010,5'b10010,5'b01100,5'b00000};
            "K": glyph5x8={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001,5'b00000};
            "L": glyph5x8={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111,5'b00000};
            "M": glyph5x8={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001,5'b00000};
            "N": glyph5x8={5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001,5'b00000};
            "O": glyph5x8={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110,5'b00000};
            "P": glyph5x8={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000,5'b00000};
            "Q": glyph5x8={5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101,5'b00000};
            "R": glyph5x8={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001,5'b00000};
            "S": glyph5x8={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110,5'b00000};
            "T": glyph5x8={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000};
            "U": glyph5x8={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110,5'b00000};
            "V": glyph5x8={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100,5'b00000};
            "W": glyph5x8={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010,5'b00000};
            "X": glyph5x8={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001,5'b00000};
            "Y": glyph5x8={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000};
            "Z": glyph5x8={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111,5'b00000};
            "[": glyph5x8={5'b01110,5'b01000,5'b01000,5'b01000,5'b01000,5'b01000,5'b01110,5'b00000};
            "\\":glyph5x8={5'b10000,5'b01000,5'b00100,5'b00010,5'b00001,5'b00000,5'b00000,5'b00000};
            "]": glyph5x8={5'b01110,5'b00010,5'b00010,5'b00010,5'b00010,5'b00010,5'b01110,5'b00000};
            "^": glyph5x8={5'b00100,5'b01010,5'b10001,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000};
            "_": glyph5x8={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b11111,5'b00000};
            "`": glyph5x8={5'b01000,5'b00100,5'b00010,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000};
            "{": glyph5x8={5'b00010,5'b00100,5'b00100,5'b01000,5'b00100,5'b00100,5'b00010,5'b00000};
            "|": glyph5x8={5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000};
            "}": glyph5x8={5'b01000,5'b00100,5'b00100,5'b00010,5'b00100,5'b00100,5'b01000,5'b00000};
            "~": glyph5x8={5'b00000,5'b00000,5'b01001,5'b10110,5'b00000,5'b00000,5'b00000,5'b00000};
            default: glyph5x8=40'd0;
        endcase
    end
endfunction

wire [39:0] glyph_bits = glyph5x8(char_q);
wire [2:0] glyph_row = glyph_y_q[3:1];
wire [4:0] glyph_row_bits = glyph_bits >> ((3'd7-glyph_row) * 5);
wire glyph_pixel = (glyph_x_q >= 3'd1) && (glyph_x_q <= 3'd5)
                 && glyph_row_bits[3'd5-glyph_x_q];
wire cursor_pixel = blink_on
                  && (char_col_q == cursor_col)
                  && (char_row_q == cursor_row)
                  && (glyph_y_q >= 4'd13);
wire text_pixel = glyph_pixel | cursor_pixel;

always @* begin
    vga_r = 4'h0;
    vga_g = 4'h0;
    vga_b = 4'h0;
    if (active_q && text_pixel) begin
        vga_r = 4'hd;
        vga_g = 4'hf;
        vga_b = 4'hd;
    end
end

endmodule
