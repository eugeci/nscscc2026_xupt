// Minimal SCCB/I2C read master for the OV5640.
// Performs: START, 0x78, register high, register low, repeated START,
//           0x79, one data byte, NACK, STOP.
// SCL and SDA are open-drain and require pull-ups (provided in soc_up.xdc).
module ov5640_sccb_master #(
    parameter integer CLK_HZ  = 100000000,
    parameter integer SCCB_HZ = 100000
)(
    input             clk,
    input             resetn,
    input             start,
    input             write,
    input      [15:0] reg_addr,
    input      [7:0]  write_data,
    output reg [7:0]  read_data,
    output reg        busy,
    output reg        done,
    output reg        ack_error,
    inout             scl,
    inout             sda
);

localparam integer TICK_DIV = CLK_HZ / (SCCB_HZ * 4);

localparam [4:0] ST_IDLE       = 5'd0,
                 ST_START_IDLE = 5'd1,
                 ST_START_HOLD = 5'd2,
                 ST_START_LOW  = 5'd3,
                 ST_SEND_SETUP = 5'd4,
                 ST_SEND_RISE  = 5'd5,
                 ST_SEND_HIGH  = 5'd6,
                 ST_SEND_FALL  = 5'd7,
                 ST_ACK_SETUP  = 5'd8,
                 ST_ACK_RISE   = 5'd9,
                 ST_ACK_SAMPLE = 5'd10,
                 ST_ACK_FALL   = 5'd11,
                 ST_REP_FREE   = 5'd12,
                 ST_REP_HIGH   = 5'd13,
                 ST_REP_START  = 5'd14,
                 ST_REP_LOW    = 5'd15,
                 ST_READ_SETUP = 5'd16,
                 ST_READ_RISE  = 5'd17,
                 ST_READ_HIGH  = 5'd18,
                 ST_READ_FALL  = 5'd19,
                 ST_NACK_SETUP = 5'd20,
                 ST_NACK_RISE  = 5'd21,
                 ST_NACK_HIGH  = 5'd22,
                 ST_NACK_FALL  = 5'd23,
                 ST_STOP_LOW   = 5'd24,
                 ST_STOP_HIGH  = 5'd25,
                 ST_STOP_FREE  = 5'd26;

reg [4:0]  state;
reg [15:0] div_count;
reg [15:0] reg_addr_latched;
reg        write_latched;
reg [7:0]  write_data_latched;
reg [7:0]  tx_byte;
reg [7:0]  rx_byte;
reg [2:0]  bit_index;
reg [2:0]  byte_index;
reg        scl_drive_low;
reg        sda_drive_low;

wire tick = (div_count == TICK_DIV - 1);
wire sda_in = sda;

assign scl = scl_drive_low ? 1'b0 : 1'bz;
assign sda = sda_drive_low ? 1'b0 : 1'bz;

always @(posedge clk or negedge resetn) begin
    if (!resetn)
        div_count <= 16'd0;
    else if (!busy || tick)
        div_count <= 16'd0;
    else
        div_count <= div_count + 16'd1;
end

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state            <= ST_IDLE;
        reg_addr_latched <= 16'd0;
        write_latched    <= 1'b0;
        write_data_latched <= 8'd0;
        tx_byte          <= 8'd0;
        rx_byte          <= 8'd0;
        read_data        <= 8'd0;
        bit_index        <= 3'd7;
        byte_index       <= 3'd0;
        scl_drive_low    <= 1'b0;
        sda_drive_low    <= 1'b0;
        busy             <= 1'b0;
        done             <= 1'b0;
        ack_error        <= 1'b0;
    end
    else begin
        done <= 1'b0;

        if ((state == ST_IDLE) && start) begin
            reg_addr_latched <= reg_addr;
            write_latched    <= write;
            write_data_latched <= write_data;
            tx_byte          <= 8'h78;
            rx_byte          <= 8'd0;
            bit_index        <= 3'd7;
            byte_index       <= 3'd0;
            scl_drive_low    <= 1'b0;
            sda_drive_low    <= 1'b0;
            busy             <= 1'b1;
            ack_error        <= 1'b0;
            state            <= ST_START_IDLE;
        end
        else if (busy && tick) begin
            case (state)
                ST_START_IDLE: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    state <= ST_START_HOLD;
                end

                ST_START_HOLD: begin
                    sda_drive_low <= 1'b1;
                    state <= ST_START_LOW;
                end

                ST_START_LOW: begin
                    scl_drive_low <= 1'b1;
                    state <= ST_SEND_SETUP;
                end

                ST_SEND_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= ~tx_byte[bit_index];
                    state <= ST_SEND_RISE;
                end

                ST_SEND_RISE: begin
                    scl_drive_low <= 1'b0;
                    state <= ST_SEND_HIGH;
                end

                ST_SEND_HIGH: begin
                    state <= ST_SEND_FALL;
                end

                ST_SEND_FALL: begin
                    scl_drive_low <= 1'b1;
                    if (bit_index == 3'd0) begin
                        sda_drive_low <= 1'b0;
                        state <= ST_ACK_SETUP;
                    end
                    else begin
                        bit_index <= bit_index - 3'd1;
                        state <= ST_SEND_SETUP;
                    end
                end

                ST_ACK_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;
                    state <= ST_ACK_RISE;
                end

                ST_ACK_RISE: begin
                    scl_drive_low <= 1'b0;
                    state <= ST_ACK_SAMPLE;
                end

                ST_ACK_SAMPLE: begin
                    if (sda_in)
                        ack_error <= 1'b1;
                    state <= ST_ACK_FALL;
                end

                ST_ACK_FALL: begin
                    scl_drive_low <= 1'b1;
                    if (byte_index == 3'd0) begin
                        byte_index <= 3'd1;
                        tx_byte <= reg_addr_latched[15:8];
                        bit_index <= 3'd7;
                        state <= ST_SEND_SETUP;
                    end
                    else if (byte_index == 3'd1) begin
                        byte_index <= 3'd2;
                        tx_byte <= reg_addr_latched[7:0];
                        bit_index <= 3'd7;
                        state <= ST_SEND_SETUP;
                    end
                    else if (byte_index == 3'd2) begin
                        if (write_latched) begin
                            byte_index <= 3'd4;
                            tx_byte <= write_data_latched;
                            bit_index <= 3'd7;
                            state <= ST_SEND_SETUP;
                        end
                        else
                            state <= ST_REP_FREE;
                    end
                    else if (byte_index == 3'd3) begin
                        bit_index <= 3'd7;
                        state <= ST_READ_SETUP;
                    end
                    else begin
                        state <= ST_STOP_LOW;
                    end
                end

                ST_REP_FREE: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;
                    state <= ST_REP_HIGH;
                end

                ST_REP_HIGH: begin
                    scl_drive_low <= 1'b0;
                    state <= ST_REP_START;
                end

                ST_REP_START: begin
                    sda_drive_low <= 1'b1;
                    state <= ST_REP_LOW;
                end

                ST_REP_LOW: begin
                    scl_drive_low <= 1'b1;
                    byte_index <= 3'd3;
                    tx_byte <= 8'h79;
                    bit_index <= 3'd7;
                    state <= ST_SEND_SETUP;
                end

                ST_READ_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;
                    state <= ST_READ_RISE;
                end

                ST_READ_RISE: begin
                    scl_drive_low <= 1'b0;
                    state <= ST_READ_HIGH;
                end

                ST_READ_HIGH: begin
                    rx_byte[bit_index] <= sda_in;
                    state <= ST_READ_FALL;
                end

                ST_READ_FALL: begin
                    scl_drive_low <= 1'b1;
                    if (bit_index == 3'd0)
                        state <= ST_NACK_SETUP;
                    else begin
                        bit_index <= bit_index - 3'd1;
                        state <= ST_READ_SETUP;
                    end
                end

                ST_NACK_SETUP: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b0;
                    state <= ST_NACK_RISE;
                end

                ST_NACK_RISE: begin
                    scl_drive_low <= 1'b0;
                    state <= ST_NACK_HIGH;
                end

                ST_NACK_HIGH: begin
                    state <= ST_NACK_FALL;
                end

                ST_NACK_FALL: begin
                    scl_drive_low <= 1'b1;
                    state <= ST_STOP_LOW;
                end

                ST_STOP_LOW: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b1;
                    state <= ST_STOP_HIGH;
                end

                ST_STOP_HIGH: begin
                    scl_drive_low <= 1'b0;
                    state <= ST_STOP_FREE;
                end

                ST_STOP_FREE: begin
                    sda_drive_low <= 1'b0;
                    read_data <= rx_byte;
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    busy <= 1'b0;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
end

endmodule
