// -----------------------------------------------------------------------------
// npu_layer_debug
// -----------------------------------------------------------------------------
// Layer-level debug counters and readback mux for npu_core_top.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module npu_layer_debug #(
    parameter NUM_CHANNELS = 16
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [6:0]   i_layer_dbg_sel,
    input  wire         i_layer_start,
    input  wire         i_layer_done,
    input  wire [4:0]   i_layer_id,
    input  wire         i_is_init_phase,
    input  wire [3:0]   i_oc_group_idx,
    input  wire [5:0]   i_cin_group_idx,
    input  wire         i_pool_en,
    input  wire         i_is_fc_mode,
    input  wire         i_cfg_padding_en,
    input  wire [1:0]   i_kernel_size,
    input  wire         i_pingpong_sel,
    input  wire         i_pipeline_idle,

    input  wire         i_npu_in_valid,
    input  wire [7:0]   i_npu_pixel_in,
    input  wire         i_npu_out_valid,
    input  wire [127:0] i_npu_out_bus,
    input  wire [7:0]   i_npu_out_x,
    input  wire [7:0]   i_npu_out_y,
    input  wire [12:0]  i_bcu_wr_addr,

    input  wire [31:0]  i_bcu_dbg0,
    input  wire [31:0]  i_bcu_dbg2,
    input  wire [31:0]  i_dbg_pe_fold,
    input  wire [31:0]  i_dbg_bias_fold,
    input  wire [31:0]  i_dbg_quant_fold,
    input  wire [31:0]  i_dbg_wt_fold,
    input  wire [7:0]   i_dbg_valid_flags,

    output wire [31:0]  o_layer_dbg0,
    output wire [31:0]  o_layer_dbg1,
    output wire [31:0]  o_layer_dbg2,
    output wire [31:0]  o_layer_dbg3,
    output wire [31:0]  o_layer_dbg4,
    output wire [31:0]  o_layer_dbg5,
    output wire [31:0]  o_layer_dbg6,
    output wire [31:0]  o_layer_dbg7
);
    // Output-side debug.
    reg [31:0] r_layer_dbg_count [0:31];
    reg [31:0] r_layer_dbg_xor   [0:31];
    reg [31:0] r_layer_dbg_sum   [0:31];
    reg [31:0] r_layer_dbg_first [0:31];
    reg [31:0] r_layer_dbg_first_meta [0:31];
    reg [31:0] r_layer_dbg_last  [0:31];
    reg [31:0] r_layer_dbg_last_meta  [0:31];

    // Input-side debug.
    reg [31:0] r_layer_dbg_in_count [0:31];
    reg [31:0] r_layer_dbg_in_xor   [0:31];
    reg [31:0] r_layer_dbg_in_first [0:31];
    reg [31:0] r_layer_dbg_in_last  [0:31];

    // Intermediate pipeline debug.
    reg [31:0] r_layer_dbg_pe_xor      [0:31];
    reg [31:0] r_layer_dbg_bias_xor    [0:31];
    reg [31:0] r_layer_dbg_quant_xor   [0:31];
    reg [31:0] r_layer_dbg_wt_count    [0:31];
    reg [31:0] r_layer_dbg_wt_xor      [0:31];
    reg [31:0] r_layer_dbg_wt_first    [0:31];
    reg [31:0] r_layer_dbg_wt_last     [0:31];
    reg [31:0] r_layer_dbg_lb_count    [0:31];
    reg [31:0] r_layer_dbg_pe_count    [0:31];
    reg [31:0] r_layer_dbg_bias_count  [0:31];
    reg [31:0] r_layer_dbg_quant_count [0:31];

    reg [6:0]  r_layer_dbg_sel_q;
    reg [31:0] r_layer_dbg0_q;
    reg [31:0] r_layer_dbg1_q;
    reg [31:0] r_layer_dbg2_q;
    reg [31:0] r_layer_dbg3_q;
    reg [31:0] r_layer_dbg4_q;
    reg [31:0] r_layer_dbg5_q;
    reg [31:0] r_layer_dbg6_q;
    reg [31:0] r_layer_dbg7_q;

    wire        w_layer_dbg_fire = (!i_is_init_phase) && i_npu_out_valid;
    wire [31:0] w_layer_dbg_fold;
    reg  [31:0] w_layer_dbg_sum;
    wire [31:0] w_layer_dbg_meta = {i_oc_group_idx[2:0],
                                    i_npu_out_y,
                                    i_npu_out_x,
                                    i_bcu_wr_addr};

    wire        w_layer_dbg_in_fire = (!i_is_init_phase) && i_npu_in_valid;
    wire [31:0] w_layer_dbg_in_word = {24'd0, i_npu_pixel_in};

    wire        w_layer_dbg_clear = i_layer_start &&
                                    (i_layer_id == 5'd0) &&
                                    (i_oc_group_idx == 4'd0) &&
                                    (i_cin_group_idx == 6'd0);

    wire [1:0]  w_dbg_mode     = i_layer_dbg_sel[5:4];
    wire        w_dbg_sel_in   = (w_dbg_mode == 2'd1);
    wire        w_dbg_sel_pe   = (w_dbg_mode == 2'd2);
    wire        w_dbg_sel_bq   = (w_dbg_mode == 2'd3);
    wire        w_dbg_sel_wt   = i_layer_dbg_sel[6] && (w_dbg_mode == 2'd0);
    wire        w_dbg_sel_flow = i_layer_dbg_sel[6] && (w_dbg_mode == 2'd1);
    wire [4:0]  w_dbg_idx      = i_layer_dbg_sel[3:0];

    npu_xor_fold #(
        .IN_WIDTH (128),
        .OUT_WIDTH(32)
    ) u_layer_out_fold (
        .i_data(i_npu_out_bus),
        .o_fold(w_layer_dbg_fold)
    );

    integer sum_idx;
    always @(*) begin
        w_layer_dbg_sum = 32'd0;
        for (sum_idx = 0; sum_idx < NUM_CHANNELS; sum_idx = sum_idx + 1) begin
            w_layer_dbg_sum = w_layer_dbg_sum +
                              {24'd0, i_npu_out_bus[sum_idx*8 +: 8]};
        end
    end

    integer layer_dbg_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (layer_dbg_i = 0; layer_dbg_i < 32; layer_dbg_i = layer_dbg_i + 1) begin
                r_layer_dbg_count[layer_dbg_i] <= 32'd0;
                r_layer_dbg_xor[layer_dbg_i] <= 32'd0;
                r_layer_dbg_sum[layer_dbg_i] <= 32'd0;
                r_layer_dbg_first[layer_dbg_i] <= 32'd0;
                r_layer_dbg_first_meta[layer_dbg_i] <= 32'd0;
                r_layer_dbg_last[layer_dbg_i] <= 32'd0;
                r_layer_dbg_last_meta[layer_dbg_i] <= 32'd0;
                r_layer_dbg_in_count[layer_dbg_i] <= 32'd0;
                r_layer_dbg_in_xor[layer_dbg_i]   <= 32'd0;
                r_layer_dbg_in_first[layer_dbg_i] <= 32'd0;
                r_layer_dbg_in_last[layer_dbg_i]  <= 32'd0;
            end
            r_layer_dbg_sel_q <= 7'd0;
            r_layer_dbg0_q <= 32'd0;
            r_layer_dbg1_q <= 32'd0;
            r_layer_dbg2_q <= 32'd0;
            r_layer_dbg3_q <= 32'd0;
            r_layer_dbg4_q <= 32'd0;
            r_layer_dbg5_q <= 32'd0;
            r_layer_dbg6_q <= 32'd0;
            r_layer_dbg7_q <= 32'd0;
        end else begin
            r_layer_dbg_sel_q <= i_layer_dbg_sel;

            if (w_dbg_sel_wt) begin
                r_layer_dbg0_q <= r_layer_dbg_wt_count[w_dbg_idx];
                r_layer_dbg1_q <= r_layer_dbg_wt_xor[w_dbg_idx];
                r_layer_dbg2_q <= r_layer_dbg_wt_first[w_dbg_idx];
                r_layer_dbg3_q <= r_layer_dbg_wt_last[w_dbg_idx];
                r_layer_dbg4_q <= 32'd0;
                r_layer_dbg5_q <= 32'd0;
                r_layer_dbg6_q <= 32'd0;
            end else if (w_dbg_sel_flow) begin
                r_layer_dbg0_q <= r_layer_dbg_in_count[w_dbg_idx];
                r_layer_dbg1_q <= r_layer_dbg_lb_count[w_dbg_idx];
                r_layer_dbg2_q <= r_layer_dbg_pe_count[w_dbg_idx];
                r_layer_dbg3_q <= r_layer_dbg_bias_count[w_dbg_idx];
                r_layer_dbg4_q <= r_layer_dbg_quant_count[w_dbg_idx];
                r_layer_dbg5_q <= r_layer_dbg_count[w_dbg_idx];
                r_layer_dbg6_q <= i_bcu_dbg0;
            end else if (w_dbg_sel_in) begin
                r_layer_dbg0_q <= r_layer_dbg_in_count[w_dbg_idx];
                r_layer_dbg1_q <= r_layer_dbg_in_xor[w_dbg_idx];
                r_layer_dbg2_q <= r_layer_dbg_in_first[w_dbg_idx];
                r_layer_dbg3_q <= r_layer_dbg_in_last[w_dbg_idx];
                r_layer_dbg4_q <= 32'd0;
                r_layer_dbg5_q <= 32'd0;
                r_layer_dbg6_q <= 32'd0;
            end else if (w_dbg_sel_pe) begin
                r_layer_dbg0_q <= 32'd0;
                r_layer_dbg1_q <= r_layer_dbg_pe_xor[w_dbg_idx];
                r_layer_dbg2_q <= 32'd0;
                r_layer_dbg3_q <= 32'd0;
                r_layer_dbg4_q <= 32'd0;
                r_layer_dbg5_q <= 32'd0;
                r_layer_dbg6_q <= 32'd0;
            end else if (w_dbg_sel_bq) begin
                r_layer_dbg0_q <= r_layer_dbg_bias_xor[w_dbg_idx];
                r_layer_dbg1_q <= r_layer_dbg_quant_xor[w_dbg_idx];
                r_layer_dbg2_q <= 32'd0;
                r_layer_dbg3_q <= 32'd0;
                r_layer_dbg4_q <= 32'd0;
                r_layer_dbg5_q <= 32'd0;
                r_layer_dbg6_q <= 32'd0;
            end else begin
                r_layer_dbg0_q <= r_layer_dbg_count[w_dbg_idx];
                r_layer_dbg1_q <= r_layer_dbg_xor[w_dbg_idx];
                r_layer_dbg2_q <= r_layer_dbg_sum[w_dbg_idx];
                r_layer_dbg3_q <= r_layer_dbg_first[w_dbg_idx];
                r_layer_dbg4_q <= r_layer_dbg_first_meta[w_dbg_idx];
                r_layer_dbg5_q <= r_layer_dbg_last[w_dbg_idx];
                r_layer_dbg6_q <= r_layer_dbg_last_meta[w_dbg_idx];
            end

            r_layer_dbg7_q <= w_dbg_sel_flow ?
                               i_bcu_dbg2 :
                               {1'b0, r_layer_dbg_sel_q, i_layer_id,
                                i_oc_group_idx, i_cin_group_idx,
                                1'b0, i_pool_en, i_is_fc_mode,
                                i_cfg_padding_en, i_kernel_size,
                                i_pingpong_sel, i_layer_start, i_layer_done,
                                i_pipeline_idle, i_npu_out_valid};

            if (w_layer_dbg_clear) begin
                for (layer_dbg_i = 0; layer_dbg_i < 32; layer_dbg_i = layer_dbg_i + 1) begin
                    r_layer_dbg_count[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_xor[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_sum[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_first[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_first_meta[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_last[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_last_meta[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_in_count[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_in_xor[layer_dbg_i]   <= 32'd0;
                    r_layer_dbg_in_first[layer_dbg_i] <= 32'd0;
                    r_layer_dbg_in_last[layer_dbg_i]  <= 32'd0;
                end
            end else begin
                if (w_layer_dbg_fire) begin
                    if (r_layer_dbg_count[i_layer_id] == 32'd0) begin
                        r_layer_dbg_first[i_layer_id] <= w_layer_dbg_fold;
                        r_layer_dbg_first_meta[i_layer_id] <= w_layer_dbg_meta;
                    end
                    if (r_layer_dbg_count[i_layer_id] != 32'hffffffff) begin
                        r_layer_dbg_count[i_layer_id] <= r_layer_dbg_count[i_layer_id] + 32'd1;
                    end
                    r_layer_dbg_xor[i_layer_id] <= r_layer_dbg_xor[i_layer_id] ^ w_layer_dbg_fold;
                    r_layer_dbg_sum[i_layer_id] <= r_layer_dbg_sum[i_layer_id] + w_layer_dbg_sum;
                    r_layer_dbg_last[i_layer_id] <= w_layer_dbg_fold;
                    r_layer_dbg_last_meta[i_layer_id] <= w_layer_dbg_meta;
                end

                if (w_layer_dbg_in_fire) begin
                    if (r_layer_dbg_in_count[i_layer_id] == 32'd0) begin
                        r_layer_dbg_in_first[i_layer_id] <= w_layer_dbg_in_word;
                    end
                    if (r_layer_dbg_in_count[i_layer_id] != 32'hffffffff) begin
                        r_layer_dbg_in_count[i_layer_id] <= r_layer_dbg_in_count[i_layer_id] + 32'd1;
                    end
                    r_layer_dbg_in_xor[i_layer_id] <= r_layer_dbg_in_xor[i_layer_id] ^ w_layer_dbg_in_word;
                    r_layer_dbg_in_last[i_layer_id] <= w_layer_dbg_in_word;
                end
            end
        end
    end

    reg        r_dbg_wt_fire_d1;
    reg [4:0]  r_dbg_wt_layer_d1;
    integer layer_dbg_mid_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_dbg_wt_fire_d1 <= 1'b0;
            r_dbg_wt_layer_d1 <= 5'd0;
            for (layer_dbg_mid_i = 0; layer_dbg_mid_i < 32; layer_dbg_mid_i = layer_dbg_mid_i + 1) begin
                r_layer_dbg_pe_xor[layer_dbg_mid_i]    <= 32'd0;
                r_layer_dbg_bias_xor[layer_dbg_mid_i]  <= 32'd0;
                r_layer_dbg_quant_xor[layer_dbg_mid_i] <= 32'd0;
                r_layer_dbg_wt_count[layer_dbg_mid_i]  <= 32'd0;
                r_layer_dbg_wt_xor[layer_dbg_mid_i]    <= 32'd0;
                r_layer_dbg_wt_first[layer_dbg_mid_i]  <= 32'd0;
                r_layer_dbg_wt_last[layer_dbg_mid_i]   <= 32'd0;
                r_layer_dbg_lb_count[layer_dbg_mid_i]    <= 32'd0;
                r_layer_dbg_pe_count[layer_dbg_mid_i]    <= 32'd0;
                r_layer_dbg_bias_count[layer_dbg_mid_i]  <= 32'd0;
                r_layer_dbg_quant_count[layer_dbg_mid_i] <= 32'd0;
            end
        end else begin
            r_dbg_wt_fire_d1 <= (!i_is_init_phase) && i_npu_in_valid;
            r_dbg_wt_layer_d1 <= i_layer_id;

            if (w_layer_dbg_clear) begin
                r_dbg_wt_fire_d1 <= 1'b0;
                r_dbg_wt_layer_d1 <= 5'd0;
                for (layer_dbg_mid_i = 0; layer_dbg_mid_i < 32; layer_dbg_mid_i = layer_dbg_mid_i + 1) begin
                    r_layer_dbg_pe_xor[layer_dbg_mid_i]    <= 32'd0;
                    r_layer_dbg_bias_xor[layer_dbg_mid_i]  <= 32'd0;
                    r_layer_dbg_quant_xor[layer_dbg_mid_i] <= 32'd0;
                    r_layer_dbg_wt_count[layer_dbg_mid_i]  <= 32'd0;
                    r_layer_dbg_wt_xor[layer_dbg_mid_i]    <= 32'd0;
                    r_layer_dbg_wt_first[layer_dbg_mid_i]  <= 32'd0;
                    r_layer_dbg_wt_last[layer_dbg_mid_i]   <= 32'd0;
                    r_layer_dbg_lb_count[layer_dbg_mid_i]    <= 32'd0;
                    r_layer_dbg_pe_count[layer_dbg_mid_i]    <= 32'd0;
                    r_layer_dbg_bias_count[layer_dbg_mid_i]  <= 32'd0;
                    r_layer_dbg_quant_count[layer_dbg_mid_i] <= 32'd0;
                end
            end else if (!i_is_init_phase) begin
                if (i_dbg_valid_flags[2] && r_layer_dbg_lb_count[i_layer_id] != 32'hffffffff)
                    r_layer_dbg_lb_count[i_layer_id] <= r_layer_dbg_lb_count[i_layer_id] + 32'd1;
                if (i_dbg_valid_flags[3] && r_layer_dbg_pe_count[i_layer_id] != 32'hffffffff)
                    r_layer_dbg_pe_count[i_layer_id] <= r_layer_dbg_pe_count[i_layer_id] + 32'd1;
                if (i_dbg_valid_flags[4] && r_layer_dbg_bias_count[i_layer_id] != 32'hffffffff)
                    r_layer_dbg_bias_count[i_layer_id] <= r_layer_dbg_bias_count[i_layer_id] + 32'd1;
                if (i_dbg_valid_flags[5] && r_layer_dbg_quant_count[i_layer_id] != 32'hffffffff)
                    r_layer_dbg_quant_count[i_layer_id] <= r_layer_dbg_quant_count[i_layer_id] + 32'd1;

                if (i_dbg_pe_fold != 32'd0)
                    r_layer_dbg_pe_xor[i_layer_id] <= r_layer_dbg_pe_xor[i_layer_id] ^ i_dbg_pe_fold;
                if (i_dbg_bias_fold != 32'd0)
                    r_layer_dbg_bias_xor[i_layer_id] <= r_layer_dbg_bias_xor[i_layer_id] ^ i_dbg_bias_fold;
                if (i_dbg_quant_fold != 32'd0)
                    r_layer_dbg_quant_xor[i_layer_id] <= r_layer_dbg_quant_xor[i_layer_id] ^ i_dbg_quant_fold;

                if (r_dbg_wt_fire_d1) begin
                    if (r_layer_dbg_wt_count[r_dbg_wt_layer_d1] == 32'd0)
                        r_layer_dbg_wt_first[r_dbg_wt_layer_d1] <= i_dbg_wt_fold;
                    if (r_layer_dbg_wt_count[r_dbg_wt_layer_d1] != 32'hffffffff)
                        r_layer_dbg_wt_count[r_dbg_wt_layer_d1] <= r_layer_dbg_wt_count[r_dbg_wt_layer_d1] + 32'd1;
                    r_layer_dbg_wt_xor[r_dbg_wt_layer_d1] <= r_layer_dbg_wt_xor[r_dbg_wt_layer_d1] ^ i_dbg_wt_fold;
                    r_layer_dbg_wt_last[r_dbg_wt_layer_d1] <= i_dbg_wt_fold;
                end
            end
        end
    end

    assign o_layer_dbg0 = r_layer_dbg0_q;
    assign o_layer_dbg1 = r_layer_dbg1_q;
    assign o_layer_dbg2 = r_layer_dbg2_q;
    assign o_layer_dbg3 = r_layer_dbg3_q;
    assign o_layer_dbg4 = r_layer_dbg4_q;
    assign o_layer_dbg5 = r_layer_dbg5_q;
    assign o_layer_dbg6 = r_layer_dbg6_q;
    assign o_layer_dbg7 = r_layer_dbg7_q;
endmodule
