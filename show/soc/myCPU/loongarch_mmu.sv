// ============================================================
// Module: loongarch_mmu
// Description: LA32R direct/DMW/TLB address translation and TLB storage.
//
// The TLB contains paired even/odd pages.  Each entry stores the common
// VPPN/PS/ASID/G fields and two architecturally formatted TLBELO words.
// Translation is combinational; architectural maintenance is serialized by
// the privileged unit and updates the array on a clock edge.
// ============================================================

module loongarch_mmu #(
    parameter integer TLB_ENTRIES = 32,
    parameter integer TLB_INDEX_W = $clog2(TLB_ENTRIES),
    parameter integer DATA_L0_ENTRIES = 4,
    parameter integer DATA_L0_INDEX_W = $clog2(DATA_L0_ENTRIES)
) (
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   crmd_da,
    input  logic                   crmd_pg,
    input  logic [1:0]             crmd_plv,
    input  logic [1:0]             crmd_datf,
    input  logic [1:0]             crmd_datm,
    input  logic [9:0]             csr_asid,
    input  logic [31:0]            csr_dmw0,
    input  logic [31:0]            csr_dmw1,

    input  logic                   inst_valid,
    input  logic [31:0]            inst_vaddr,
    output logic [31:0]            inst_paddr,
    output logic [1:0]             inst_mat,
    output logic                   inst_tlbr,
    output logic                   inst_pif,
    output logic                   inst_ppi,
    output logic                   inst_tlb_hit,
    output logic [TLB_INDEX_W-1:0] inst_tlb_index,

    input  logic                   data_valid,
    input  logic                   data_store,
    input  logic [31:0]            data_vaddr,
    output logic                   data_ready,
    output logic [31:0]            data_paddr,
    output logic [1:0]             data_mat,
    output logic                   data_tlbr,
    output logic                   data_pil,
    output logic                   data_pis,
    output logic                   data_pme,
    output logic                   data_ppi,
    output logic                   data_tlb_hit,
    output logic [TLB_INDEX_W-1:0] data_tlb_index,

    input  logic                   tlbsrch_valid,
    input  logic [31:0]            tlbsrch_vaddr,
    output logic                   tlbsrch_found,
    output logic [TLB_INDEX_W-1:0] tlbsrch_index,

    input  logic                   tlbrd_valid,
    input  logic [TLB_INDEX_W-1:0] tlbrd_index,
    output logic                   tlbrd_e,
    output logic [18:0]            tlbrd_vppn,
    output logic [5:0]             tlbrd_ps,
    output logic [9:0]             tlbrd_asid,
    output logic                   tlbrd_g,
    output logic [31:0]            tlbrd_elo0,
    output logic [31:0]            tlbrd_elo1,

    input  logic                   tlbwr_valid,
    input  logic [TLB_INDEX_W-1:0] tlbwr_index,
    input  logic                   tlbwr_e,
    input  logic [18:0]            tlbwr_vppn,
    input  logic [5:0]             tlbwr_ps,
    input  logic [9:0]             tlbwr_asid,
    input  logic                   tlbwr_g,
    input  logic [31:0]            tlbwr_elo0,
    input  logic [31:0]            tlbwr_elo1,

    input  logic                   tlbfill_valid,
    input  logic                   tlbfill_e,
    input  logic [18:0]            tlbfill_vppn,
    input  logic [5:0]             tlbfill_ps,
    input  logic [9:0]             tlbfill_asid,
    input  logic                   tlbfill_g,
    input  logic [31:0]            tlbfill_elo0,
    input  logic [31:0]            tlbfill_elo1,
    output logic [TLB_INDEX_W-1:0] tlbfill_index,

    input  logic                   invtlb_valid,
    input  logic [4:0]             invtlb_op,
    input  logic [9:0]             invtlb_asid,
    input  logic [31:0]            invtlb_vaddr
);

`ifndef SYNTHESIS
    initial begin
        if ((TLB_ENTRIES < 1) || (TLB_ENTRIES > (1 << TLB_INDEX_W)))
            $fatal(1, "TLB_ENTRIES must fit the architectural TLB index");
    end
`endif

    logic        tlb_e     [0:TLB_ENTRIES-1];
    logic [18:0] tlb_vppn  [0:TLB_ENTRIES-1];
    logic [ 5:0] tlb_ps    [0:TLB_ENTRIES-1];
    logic [ 9:0] tlb_asid  [0:TLB_ENTRIES-1];
    logic        tlb_g     [0:TLB_ENTRIES-1];
    logic [31:0] tlb_elo0  [0:TLB_ENTRIES-1];
    logic [31:0] tlb_elo1  [0:TLB_ENTRIES-1];

    logic [TLB_INDEX_W-1:0] fill_pointer;
    logic [TLB_INDEX_W-1:0] invalid_index;
    logic                   invalid_found;
    integer seq_i;

    function automatic logic entry_vaddr_match(
        input logic [31:0] vaddr,
        input logic [18:0] vppn,
        input logic [5:0]  ps
    );
        begin
            // PRCFG2 advertises only 4KB and 2MB pages.  Spell out both
            // comparisons so ordinary translation and INVTLB never infer a
            // variable shifter from the architecturally encoded PS field.
            case (ps)
                6'd12: entry_vaddr_match = vaddr[31:13] == vppn;
                6'd21: entry_vaddr_match = vaddr[31:22] == vppn[18:9];
                default: entry_vaddr_match = 1'b0;
            endcase
        end
    endfunction

    function automatic logic entry_matches(
        input logic [31:0] vaddr,
        input logic [9:0]  asid,
        input logic        e,
        input logic [18:0] vppn,
        input logic [5:0]  ps,
        input logic [9:0]  entry_asid,
        input logic        g
    );
        begin
            entry_matches = e && (g || (entry_asid == asid))
                          && entry_vaddr_match(vaddr, vppn, ps);
        end
    endfunction

    function automatic logic dmw_matches(
        input logic [31:0] vaddr,
        input logic [1:0]  plv,
        input logic [31:0] dmw
    );
        logic plv_enabled;
        begin
            // LA32R defines enable bits only for PLV0 and PLV3. DMW[2:1]
            // are reserved and must not accidentally enable PLV1/PLV2.
            case (plv)
                2'd0: plv_enabled = dmw[0];
                2'd3: plv_enabled = dmw[3];
                default: plv_enabled = 1'b0;
            endcase
            dmw_matches = plv_enabled && (vaddr[31:29] == dmw[31:29]);
        end
    endfunction

    function automatic logic [31:0] page_paddr(
        input logic [31:0] vaddr,
        input logic [19:0] ppn,
        input logic [5:0]  ps
    );
        begin
            case (ps)
                6'd12: page_paddr = {ppn, vaddr[11:0]};
                6'd21: page_paddr = {ppn[19:9], vaddr[20:0]};
                default: page_paddr = vaddr;
            endcase
        end
    endfunction

    function automatic logic entry_odd_page(
        input logic [31:0] vaddr,
        input logic [5:0]  ps
    );
        begin
            case (ps)
                6'd12: entry_odd_page = vaddr[12];
                6'd21: entry_odd_page = vaddr[21];
                default: entry_odd_page = 1'b0;
            endcase
        end
    endfunction

    logic [TLB_ENTRIES-1:0] inst_hit_vector;
    wire  [TLB_ENTRIES-1:0] inst_select_vector;
    logic inst_match_found;
    logic [5:0] inst_match_ps;
    logic [31:0] inst_match_elo;
    logic inst_dmw0_hit;
    logic inst_dmw1_hit;
    logic inst_paging;

    always_comb begin
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            inst_hit_vector[i] = entry_matches(
                inst_vaddr, csr_asid, tlb_e[i], tlb_vppn[i],
                tlb_ps[i], tlb_asid[i], tlb_g[i]
            );
        end
    end

    for (genvar i = 0; i < TLB_ENTRIES; i = i + 1) begin : g_inst_select
        if (i == 0)
            assign inst_select_vector[i] = inst_hit_vector[i];
        else
            assign inst_select_vector[i] = inst_hit_vector[i]
                                           & ~|inst_hit_vector[i-1:0];
    end

    // A legal TLB contains at most one match.  OR-reduction expresses the
    // selected payload as a parallel one-hot mux instead of the former
    // loop-carried first-match priority chain.
    always_comb begin
        inst_match_found = |inst_hit_vector;
        inst_match_ps = 6'd0;
        inst_match_elo = 32'd0;
        inst_tlb_index = '0;
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            if (inst_select_vector[i]) begin
                inst_tlb_index = inst_tlb_index
                               | i[TLB_INDEX_W-1:0];
                inst_match_ps = inst_match_ps | tlb_ps[i];
                inst_match_elo = inst_match_elo
                               | (entry_odd_page(inst_vaddr, tlb_ps[i])
                                  ? tlb_elo1[i] : tlb_elo0[i]);
            end
        end
    end

    always_comb begin
        inst_dmw0_hit = dmw_matches(inst_vaddr, crmd_plv, csr_dmw0);
        inst_dmw1_hit = !inst_dmw0_hit
                      && dmw_matches(inst_vaddr, crmd_plv, csr_dmw1);
        inst_paging = !crmd_da && crmd_pg;

        inst_paddr = inst_vaddr;
        inst_mat = crmd_datf;
        inst_tlbr = 1'b0;
        inst_pif = 1'b0;
        inst_ppi = 1'b0;
        inst_tlb_hit = 1'b0;

        if (inst_paging && inst_dmw0_hit) begin
            inst_paddr = {csr_dmw0[27:25], inst_vaddr[28:0]};
            inst_mat = csr_dmw0[5:4];
        end else if (inst_paging && inst_dmw1_hit) begin
            inst_paddr = {csr_dmw1[27:25], inst_vaddr[28:0]};
            inst_mat = csr_dmw1[5:4];
        end else if (inst_paging) begin
            inst_tlb_hit = inst_match_found;
            if (inst_match_found) begin
                // In LA32R TLBELO.PPN occupies CSR bits 27:8 for a
                // 32-bit physical-address implementation.
                inst_paddr = page_paddr(inst_vaddr,
                                        inst_match_elo[27:8],
                                        inst_match_ps);
                inst_mat = inst_match_elo[5:4];
            end
            if (inst_valid) begin
                if (!inst_match_found)
                    inst_tlbr = 1'b1;
                else if (!inst_match_elo[0])
                    inst_pif = 1'b1;
                else if (crmd_plv > inst_match_elo[3:2])
                    inst_ppi = 1'b1;
            end
        end
    end

    // The data-side L0 is a non-architectural translation cache.  Its small
    // parallel lookup stays on the ordinary load/store hit path; an L0 miss
    // holds EX while a registered virtual address probes the 32-entry MTLB.
    // This removes the full MTLB compare/select network from
    // EX-address -> DCache and EX-address -> pipeline-allow timing paths.
    logic        data_l0_e     [0:DATA_L0_ENTRIES-1];
    logic [18:0] data_l0_vppn  [0:DATA_L0_ENTRIES-1];
    logic [ 5:0] data_l0_ps    [0:DATA_L0_ENTRIES-1];
    logic [ 9:0] data_l0_asid  [0:DATA_L0_ENTRIES-1];
    logic        data_l0_g     [0:DATA_L0_ENTRIES-1];
    logic [31:0] data_l0_elo0  [0:DATA_L0_ENTRIES-1];
    logic [31:0] data_l0_elo1  [0:DATA_L0_ENTRIES-1];
    logic [TLB_INDEX_W-1:0]
                 data_l0_mtlb_index [0:DATA_L0_ENTRIES-1];

    logic [DATA_L0_ENTRIES-1:0] data_l0_hit_vector;
    wire  [DATA_L0_ENTRIES-1:0] data_l0_select_vector;
    logic data_l0_match_found;
    logic [5:0] data_l0_match_ps;
    logic [31:0] data_l0_match_elo;
    logic [TLB_INDEX_W-1:0] data_l0_match_mtlb_index;
    logic [DATA_L0_INDEX_W-1:0] data_l0_fill_pointer;

    logic data_slow_pending;
    logic [31:0] data_slow_vaddr_q;
    logic [9:0] data_slow_asid_q;
    logic data_slow_miss_valid;
    logic [31:0] data_slow_miss_vaddr_q;
    logic [9:0] data_slow_miss_asid_q;

    always_comb begin
        for (int i = 0; i < DATA_L0_ENTRIES; i = i + 1) begin
            data_l0_hit_vector[i] = entry_matches(
                data_vaddr, csr_asid, data_l0_e[i], data_l0_vppn[i],
                data_l0_ps[i], data_l0_asid[i], data_l0_g[i]
            );
        end
    end

    for (genvar i = 0; i < DATA_L0_ENTRIES; i = i + 1) begin : g_data_l0_select
        if (i == 0)
            assign data_l0_select_vector[i] = data_l0_hit_vector[i];
        else
            assign data_l0_select_vector[i] = data_l0_hit_vector[i]
                                                 & ~|data_l0_hit_vector[i-1:0];
    end

    always_comb begin
        data_l0_match_found = |data_l0_hit_vector;
        data_l0_match_ps = 6'd0;
        data_l0_match_elo = 32'd0;
        data_l0_match_mtlb_index = '0;
        for (int i = 0; i < DATA_L0_ENTRIES; i = i + 1) begin
            if (data_l0_select_vector[i]) begin
                data_l0_match_ps = data_l0_match_ps | data_l0_ps[i];
                data_l0_match_elo = data_l0_match_elo
                                  | (entry_odd_page(data_vaddr,
                                                    data_l0_ps[i])
                                     ? data_l0_elo1[i]
                                     : data_l0_elo0[i]);
                data_l0_match_mtlb_index = data_l0_match_mtlb_index
                                         | data_l0_mtlb_index[i];
            end
        end
    end

    logic [TLB_ENTRIES-1:0] data_hit_vector;
    wire  [TLB_ENTRIES-1:0] data_select_vector;
    logic data_match_found;
    logic [5:0] data_match_ps;
    logic [31:0] data_match_elo;
    logic [TLB_INDEX_W-1:0] data_match_index;
    logic data_dmw0_hit;
    logic data_dmw1_hit;
    logic data_paging;

    always_comb begin
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            data_hit_vector[i] = entry_matches(
                data_slow_vaddr_q, data_slow_asid_q,
                tlb_e[i], tlb_vppn[i],
                tlb_ps[i], tlb_asid[i], tlb_g[i]
            );
        end
    end

    for (genvar i = 0; i < TLB_ENTRIES; i = i + 1) begin : g_data_select
        if (i == 0)
            assign data_select_vector[i] = data_hit_vector[i];
        else
            assign data_select_vector[i] = data_hit_vector[i]
                                           & ~|data_hit_vector[i-1:0];
    end

    always_comb begin
        data_match_found = |data_hit_vector;
        data_match_ps = 6'd0;
        data_match_elo = 32'd0;
        data_match_index = '0;
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            if (data_select_vector[i]) begin
                data_match_index = data_match_index
                                 | i[TLB_INDEX_W-1:0];
                data_match_ps = data_match_ps | tlb_ps[i];
                data_match_elo = data_match_elo
                               | (entry_odd_page(data_slow_vaddr_q,
                                                 tlb_ps[i])
                                  ? tlb_elo1[i] : tlb_elo0[i]);
            end
        end
    end

    always_comb begin
        data_dmw0_hit = dmw_matches(data_vaddr, crmd_plv, csr_dmw0);
        data_dmw1_hit = !data_dmw0_hit
                      && dmw_matches(data_vaddr, crmd_plv, csr_dmw1);
        data_paging = !crmd_da && crmd_pg;

        data_paddr = data_vaddr;
        data_mat = crmd_datm;
        data_tlbr = 1'b0;
        data_pil = 1'b0;
        data_pis = 1'b0;
        data_pme = 1'b0;
        data_ppi = 1'b0;
        data_tlb_hit = 1'b0;
        data_tlb_index = '0;
        data_ready = 1'b1;

        if (data_paging && data_dmw0_hit) begin
            data_paddr = {csr_dmw0[27:25], data_vaddr[28:0]};
            data_mat = csr_dmw0[5:4];
        end else if (data_paging && data_dmw1_hit) begin
            data_paddr = {csr_dmw1[27:25], data_vaddr[28:0]};
            data_mat = csr_dmw1[5:4];
        end else if (data_paging) begin
            data_tlb_hit = data_l0_match_found;
            data_tlb_index = data_l0_match_mtlb_index;
            data_ready = !data_valid | data_l0_match_found
                       | (data_slow_miss_valid
                          && (data_slow_miss_vaddr_q == data_vaddr)
                          && (data_slow_miss_asid_q == csr_asid));
            if (data_l0_match_found) begin
                data_paddr = page_paddr(data_vaddr,
                                        data_l0_match_elo[27:8],
                                        data_l0_match_ps);
                data_mat = data_l0_match_elo[5:4];
            end
            if (data_valid) begin
                if (data_slow_miss_valid
                    && (data_slow_miss_vaddr_q == data_vaddr)
                    && (data_slow_miss_asid_q == csr_asid))
                    data_tlbr = 1'b1;
                else if (data_l0_match_found
                         && !data_l0_match_elo[0]) begin
                    data_pil = !data_store;
                    data_pis = data_store;
                end else if (data_l0_match_found
                             && (crmd_plv > data_l0_match_elo[3:2])) begin
                    data_ppi = 1'b1;
                end else if (data_l0_match_found && data_store
                             && !data_l0_match_elo[1]) begin
                    data_pme = 1'b1;
                end
            end
        end
    end

    wire data_tlb_lookup_required = data_valid & data_paging
                                  & ~data_dmw0_hit & ~data_dmw1_hit;
    wire data_slow_result_matches = data_slow_miss_valid
                                  & (data_slow_miss_vaddr_q == data_vaddr)
                                  & (data_slow_miss_asid_q == csr_asid);
    wire data_slow_request_matches = data_slow_pending
                                   & (data_slow_vaddr_q == data_vaddr)
                                   & (data_slow_asid_q == csr_asid);
    wire data_slow_start = data_tlb_lookup_required
                         & ~data_l0_match_found
                         & ~data_slow_result_matches
                         & ~data_slow_request_matches;

    integer data_l0_i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            data_l0_fill_pointer <= '0;
            data_slow_pending <= 1'b0;
            data_slow_vaddr_q <= 32'd0;
            data_slow_asid_q <= 10'd0;
            data_slow_miss_valid <= 1'b0;
            data_slow_miss_vaddr_q <= 32'd0;
            data_slow_miss_asid_q <= 10'd0;
            for (data_l0_i = 0; data_l0_i < DATA_L0_ENTRIES;
                 data_l0_i = data_l0_i + 1) begin
                data_l0_e[data_l0_i] <= 1'b0;
                data_l0_vppn[data_l0_i] <= 19'd0;
                data_l0_ps[data_l0_i] <= 6'd0;
                data_l0_asid[data_l0_i] <= 10'd0;
                data_l0_g[data_l0_i] <= 1'b0;
                data_l0_elo0[data_l0_i] <= 32'd0;
                data_l0_elo1[data_l0_i] <= 32'd0;
                data_l0_mtlb_index[data_l0_i] <= '0;
            end
        end else if (invtlb_valid | tlbwr_valid | tlbfill_valid) begin
            // Maintenance is rare and serialized.  Conservatively dropping
            // all dL0 entries keeps the fast cache invisible to software and
            // prevents a stale translation surviving an architectural update.
            data_l0_fill_pointer <= '0;
            data_slow_pending <= 1'b0;
            data_slow_miss_valid <= 1'b0;
            for (data_l0_i = 0; data_l0_i < DATA_L0_ENTRIES;
                 data_l0_i = data_l0_i + 1)
                data_l0_e[data_l0_i] <= 1'b0;
        end else if (data_slow_pending) begin
            data_slow_pending <= 1'b0;
            if (data_match_found) begin
                data_l0_e[data_l0_fill_pointer] <= 1'b1;
                data_l0_vppn[data_l0_fill_pointer]
                    <= tlb_vppn[data_match_index];
                data_l0_ps[data_l0_fill_pointer] <= data_match_ps;
                data_l0_asid[data_l0_fill_pointer]
                    <= tlb_asid[data_match_index];
                data_l0_g[data_l0_fill_pointer]
                    <= tlb_g[data_match_index];
                data_l0_elo0[data_l0_fill_pointer]
                    <= tlb_elo0[data_match_index];
                data_l0_elo1[data_l0_fill_pointer]
                    <= tlb_elo1[data_match_index];
                data_l0_mtlb_index[data_l0_fill_pointer]
                    <= data_match_index;
                if (data_l0_fill_pointer == DATA_L0_ENTRIES-1)
                    data_l0_fill_pointer <= '0;
                else
                    data_l0_fill_pointer <= data_l0_fill_pointer + 1'b1;
                data_slow_miss_valid <= 1'b0;
            end else begin
                data_slow_miss_valid <= 1'b1;
                data_slow_miss_vaddr_q <= data_slow_vaddr_q;
                data_slow_miss_asid_q <= data_slow_asid_q;
            end
        end else if (data_slow_start) begin
            data_slow_pending <= 1'b1;
            data_slow_vaddr_q <= data_vaddr;
            data_slow_asid_q <= csr_asid;
            data_slow_miss_valid <= 1'b0;
        end else if (!data_valid
                     || (data_slow_miss_vaddr_q != data_vaddr)
                     || (data_slow_miss_asid_q != csr_asid)) begin
            data_slow_miss_valid <= 1'b0;
        end
    end

    logic [TLB_ENTRIES-1:0] search_hit_vector;
    wire  [TLB_ENTRIES-1:0] search_select_vector;
    always_comb begin
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            search_hit_vector[i] = tlbsrch_valid && entry_matches(
                tlbsrch_vaddr, csr_asid, tlb_e[i],
                tlb_vppn[i], tlb_ps[i], tlb_asid[i], tlb_g[i]
            );
        end
    end

    for (genvar i = 0; i < TLB_ENTRIES; i = i + 1) begin : g_search_select
        if (i == 0)
            assign search_select_vector[i] = search_hit_vector[i];
        else
            assign search_select_vector[i] = search_hit_vector[i]
                                             & ~|search_hit_vector[i-1:0];
    end

    always_comb begin
        tlbsrch_found = |search_hit_vector;
        tlbsrch_index = '0;
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            if (search_select_vector[i])
                tlbsrch_index = tlbsrch_index
                               | i[TLB_INDEX_W-1:0];
        end
    end

    // TLBFILL consumes invalid entries before replacing a valid one.  This
    // encoder is maintenance-only and therefore intentionally kept out of all
    // instruction/data translation cones.
    always_comb begin
        invalid_found = 1'b0;
        invalid_index = '0;
        for (int i = 0; i < TLB_ENTRIES; i = i + 1) begin
            if (!invalid_found && !tlb_e[i]) begin
                invalid_found = 1'b1;
                invalid_index = i[TLB_INDEX_W-1:0];
            end
        end
    end

    always_comb begin
        tlbfill_index = invalid_found ? invalid_index : fill_pointer;
    end

    always_comb begin
        tlbrd_e = 1'b0;
        tlbrd_vppn = 19'd0;
        tlbrd_ps = 6'd0;
        tlbrd_asid = 10'd0;
        tlbrd_g = 1'b0;
        tlbrd_elo0 = 32'd0;
        tlbrd_elo1 = 32'd0;
        if (tlbrd_valid && (tlbrd_index < TLB_ENTRIES)) begin
            tlbrd_e = tlb_e[tlbrd_index];
            tlbrd_vppn = tlb_vppn[tlbrd_index];
            tlbrd_ps = tlb_ps[tlbrd_index];
            tlbrd_asid = tlb_asid[tlbrd_index];
            tlbrd_g = tlb_g[tlbrd_index];
            tlbrd_elo0 = tlb_elo0[tlbrd_index];
            tlbrd_elo1 = tlb_elo1[tlbrd_index];
            tlbrd_elo0[6] = tlb_g[tlbrd_index];
            tlbrd_elo1[6] = tlb_g[tlbrd_index];
        end
    end

    logic inv_match;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fill_pointer <= '0;
            for (seq_i = 0; seq_i < TLB_ENTRIES; seq_i = seq_i + 1) begin
                tlb_e[seq_i] <= 1'b0;
                tlb_vppn[seq_i] <= 19'd0;
                tlb_ps[seq_i] <= 6'd0;
                tlb_asid[seq_i] <= 10'd0;
                tlb_g[seq_i] <= 1'b0;
                tlb_elo0[seq_i] <= 32'd0;
                tlb_elo1[seq_i] <= 32'd0;
            end
        end else begin
            if (invtlb_valid) begin
                for (seq_i = 0; seq_i < TLB_ENTRIES;
                     seq_i = seq_i + 1) begin
                    inv_match = entry_vaddr_match(invtlb_vaddr,
                                                  tlb_vppn[seq_i],
                                                  tlb_ps[seq_i]);
                    case (invtlb_op)
                        5'd0, 5'd1:
                            tlb_e[seq_i] <= 1'b0;
                        5'd2:
                            if (tlb_g[seq_i])
                                tlb_e[seq_i] <= 1'b0;
                        5'd3:
                            if (!tlb_g[seq_i])
                                tlb_e[seq_i] <= 1'b0;
                        5'd4:
                            if (!tlb_g[seq_i]
                                && (tlb_asid[seq_i] == invtlb_asid))
                                tlb_e[seq_i] <= 1'b0;
                        5'd5:
                            if (!tlb_g[seq_i]
                                && (tlb_asid[seq_i] == invtlb_asid)
                                && inv_match)
                                tlb_e[seq_i] <= 1'b0;
                        5'd6:
                            if ((tlb_g[seq_i]
                                 || (tlb_asid[seq_i] == invtlb_asid))
                                && inv_match)
                                tlb_e[seq_i] <= 1'b0;
                        default: ;
                    endcase
                end
            end else if (tlbwr_valid && (tlbwr_index < TLB_ENTRIES)) begin
                tlb_e[tlbwr_index] <= tlbwr_e;
                tlb_vppn[tlbwr_index] <= tlbwr_vppn;
                tlb_ps[tlbwr_index] <= tlbwr_ps;
                tlb_asid[tlbwr_index] <= tlbwr_asid;
                tlb_g[tlbwr_index] <= tlbwr_g;
                tlb_elo0[tlbwr_index] <= tlbwr_elo0;
                tlb_elo1[tlbwr_index] <= tlbwr_elo1;
            end else if (tlbfill_valid) begin
                tlb_e[tlbfill_index] <= tlbfill_e;
                tlb_vppn[tlbfill_index] <= tlbfill_vppn;
                tlb_ps[tlbfill_index] <= tlbfill_ps;
                tlb_asid[tlbfill_index] <= tlbfill_asid;
                tlb_g[tlbfill_index] <= tlbfill_g;
                tlb_elo0[tlbfill_index] <= tlbfill_elo0;
                tlb_elo1[tlbfill_index] <= tlbfill_elo1;
                if (tlbfill_index == TLB_ENTRIES-1)
                    fill_pointer <= '0;
                else
                    fill_pointer <= tlbfill_index + 1'b1;
            end
        end
    end

endmodule
