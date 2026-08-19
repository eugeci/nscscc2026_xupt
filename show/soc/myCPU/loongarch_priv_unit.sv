// ============================================================
// Module: loongarch_priv_unit
// Description: LA32R CSR, synchronous trap, interrupt, and ERTN state.
//
// This file is selected only by the LoongArch filelist.  CSR numbers, reset
// values, exception codes, and CSRXCHG behavior deliberately stay outside the
// ISA-neutral pipeline.
// ============================================================

module loongarch_priv_unit
    import cpu_defs::*;
#(
    parameter integer TLB_ENTRIES = 32,
    parameter logic [31:0] CPUCFG_CACHE_PRESENT = 32'd0,
    parameter logic [31:0] CPUCFG_ICACHE = 32'd0,
    parameter logic [31:0] CPUCFG_DCACHE = 32'd0,
    parameter logic [ 7:0] IRQ_EDGE_MASK = 8'd0
)
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        ex_priv_commit_ready,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_inst,
    input  logic [31:0] ex_src0_data,
    input  logic [31:0] ex_src1_data,
    input  priv_op_t    ex_priv_op,
    input  logic        ex_priv_uses_imm,
    input  priv_cmd_t   ex_priv_cmd,
    input  logic [PRIV_ADDR_W-1:0] ex_priv_addr,
    input  logic [ 4:0] ex_priv_imm,
    input  decode_exception_t ex_exception,
    input  logic        ex_mem_read_en,
    input  logic        ex_mem_write_en,
    input  mem_size_t   ex_mem_size,
    input  logic [31:0] ex_mem_addr,
    input  logic [ 1:0] ex_mem_addr_low,
    input  logic        ex_s1_valid,
    input  logic        ex_s1_mem_read_en,
    input  logic        ex_s1_mem_write_en,
    input  mem_size_t   ex_s1_mem_size,
    input  logic [31:0] ex_s1_mem_addr,
    input  logic [ 1:0] ex_s1_mem_addr_low,
    input  logic [ 7:0] irq_pending,
    input  logic        timer_irq_take,
    input  logic [31:0] timer_irq_mepc,
    input  logic        llbit_set,
    input  logic        llbit_clear,
    output logic        llbit,
    input  logic        mmu_inst_valid,
    input  logic [31:0] mmu_inst_vaddr,
    output logic [31:0] mmu_inst_paddr,
    output logic [ 1:0] mmu_inst_mat,
    output logic        mmu_inst_tlbr,
    output logic        mmu_inst_pif,
    output logic        mmu_inst_ppi,
    input  logic        mmu_data_valid,
    input  logic        mmu_data_store,
    input  logic [31:0] mmu_data_vaddr,
    output logic        mmu_data_ready,
    output logic [31:0] mmu_data_paddr,
    output logic [ 1:0] mmu_data_mat,
    output logic        mmu_data_mat_valid,
    output logic        mmu_data_tlbr,
    output logic        mmu_data_pil,
    output logic        mmu_data_pis,
    output logic        mmu_data_pme,
    output logic        mmu_data_ppi,
    output logic        ex_priv_flow,
    output logic        ex_priv_redirect,
    output logic [31:0] ex_priv_target,
    output logic        ex_priv_trap,
    output logic        ex_priv_wait_older,
    output logic        ex_s1_addr_replay,
    output logic        idle_enter,
    output logic        timer_irq_request,
    output logic        timer_irq_redirect,
    output logic [31:0] timer_irq_target,
    output logic [31:0] ex_priv_rdata,
    output logic        debug_excp_valid,
    output logic        debug_ertn,
    output logic [31:0] debug_intr_no,
    output logic [ 5:0] debug_cause,
    output logic [31:0] debug_exception_pc,
    output logic [31:0] debug_exception_inst,
    output logic [ 4:0] debug_tlbfill_index,
    output logic [PRIV_DEBUG_STATE_W-1:0] debug_priv_state
);

    localparam logic [13:0] CSR_CRMD      = 14'h000;
    localparam logic [13:0] CSR_PRMD      = 14'h001;
    localparam logic [13:0] CSR_EUEN      = 14'h002;
    localparam logic [13:0] CSR_ECFG      = 14'h004;
    localparam logic [13:0] CSR_ESTAT     = 14'h005;
    localparam logic [13:0] CSR_ERA       = 14'h006;
    localparam logic [13:0] CSR_BADV      = 14'h007;
    localparam logic [13:0] CSR_EENTRY    = 14'h00c;
    localparam logic [13:0] CSR_TLBIDX    = 14'h010;
    localparam logic [13:0] CSR_TLBEHI    = 14'h011;
    localparam logic [13:0] CSR_TLBELO0   = 14'h012;
    localparam logic [13:0] CSR_TLBELO1   = 14'h013;
    localparam logic [13:0] CSR_ASID      = 14'h018;
    localparam logic [13:0] CSR_PGDL      = 14'h019;
    localparam logic [13:0] CSR_PGDH      = 14'h01a;
    localparam logic [13:0] CSR_PGD       = 14'h01b;
    localparam logic [13:0] CSR_CPUID     = 14'h020;
    localparam logic [13:0] CSR_PRCFG1    = 14'h021;
    localparam logic [13:0] CSR_PRCFG2    = 14'h022;
    localparam logic [13:0] CSR_PRCFG3    = 14'h023;
    localparam logic [13:0] CSR_SAVE0     = 14'h030;
    localparam logic [13:0] CSR_SAVE1     = 14'h031;
    localparam logic [13:0] CSR_SAVE2     = 14'h032;
    localparam logic [13:0] CSR_SAVE3     = 14'h033;
    localparam logic [13:0] CSR_TID       = 14'h040;
    localparam logic [13:0] CSR_TCFG      = 14'h041;
    localparam logic [13:0] CSR_TVAL      = 14'h042;
    localparam logic [13:0] CSR_CNTC      = 14'h043;
    localparam logic [13:0] CSR_TICLR     = 14'h044;
    localparam logic [13:0] CSR_LLBCTL    = 14'h060;
    localparam logic [13:0] CSR_TLBRENTRY = 14'h088;
    localparam logic [13:0] CSR_DMW0      = 14'h180;
    localparam logic [13:0] CSR_DMW1      = 14'h181;
    // Chiplab compatibility CSR used by the reference startup code.
    localparam logic [13:0] CSR_DISABLE_CACHE = 14'h101;

    localparam logic [5:0] ECODE_INT = 6'h00;
    localparam logic [5:0] ECODE_PIL = 6'h01;
    localparam logic [5:0] ECODE_PIS = 6'h02;
    localparam logic [5:0] ECODE_PIF = 6'h03;
    localparam logic [5:0] ECODE_PME = 6'h04;
    localparam logic [5:0] ECODE_PPI = 6'h07;
    localparam logic [5:0] ECODE_ADE = 6'h08;
    localparam logic [5:0] ECODE_ALE = 6'h09;
    localparam logic [5:0] ECODE_SYS = 6'h0b;
    localparam logic [5:0] ECODE_BRK = 6'h0c;
    localparam logic [5:0] ECODE_INE = 6'h0d;
    localparam logic [5:0] ECODE_IPE = 6'h0e;
    localparam logic [5:0] ECODE_TLBR = 6'h3f;

    localparam logic [15:0] TLB_CMD_SEARCH = 16'h0000;
    localparam logic [15:0] TLB_CMD_READ   = 16'h0001;
    localparam logic [15:0] TLB_CMD_WRITE  = 16'h0002;
    localparam logic [15:0] TLB_CMD_FILL   = 16'h0003;

    logic [31:0] csr_crmd;
    logic [31:0] csr_prmd;
    logic [31:0] csr_euen;
    logic [31:0] csr_ecfg;
    logic [31:0] csr_estat;
    logic [31:0] csr_era;
    logic [31:0] csr_badv;
    logic [31:0] csr_eentry;
    logic [31:0] csr_tlbidx;
    logic [31:0] csr_tlbehi;
    logic [31:0] csr_tlbelo0;
    logic [31:0] csr_tlbelo1;
    logic [31:0] csr_asid;
    logic [31:0] csr_pgdl;
    logic [31:0] csr_pgdh;
    logic [31:0] csr_save0;
    logic [31:0] csr_save1;
    logic [31:0] csr_save2;
    logic [31:0] csr_save3;
    logic [31:0] csr_tid;
    logic [31:0] csr_tcfg;
    logic [31:0] csr_tval;
    logic [31:0] csr_cntc;
    logic [31:0] csr_llbctl;
    logic [31:0] csr_tlbrentry;
    logic [31:0] csr_dmw0;
    logic [31:0] csr_dmw1;
    logic [31:0] csr_disable_cache;
    logic [ 4:0] last_tlbfill_index;
    logic [63:0] stable_counter;
    logic        timer_active;
    logic [ 7:0] irq_pending_d;
    logic [ 7:0] irq_event_pending;
    logic [ 7:0] irq_service_pending;
    logic        irq_service_active;

    assign llbit = csr_llbctl[0];

    wire [13:0] csr_addr = ex_priv_addr[13:0];
    wire ex_is_csr = ex_priv_op == PRIV_REG;
    assign mmu_data_mat_valid = 1'b1;
    wire ex_is_counter = ex_priv_op == PRIV_COUNTER;
    wire ex_is_cpucfg = ex_priv_op == PRIV_CPUCFG;
    wire ex_is_syscall = ex_priv_op == PRIV_SYSCALL;
    wire ex_is_return = ex_priv_op == PRIV_RETURN;
    wire ex_is_tlb = ex_priv_op == PRIV_TLB;
    wire ex_is_cacop = ex_priv_op == PRIV_CACOP;
    wire ex_is_idle = ex_priv_op == PRIV_IDLE;
    wire [4:0] ex_cacop_code = ex_priv_addr[4:0];
    wire ex_cacop_supported = (ex_cacop_code[2:0] <= 3'd1)
                            & (ex_cacop_code[4:3] != 2'd3);
    wire ex_cacop_hit = ex_is_cacop & ex_cacop_supported
                      & (ex_cacop_code[4:3] == 2'd2);
    wire ex_is_tlbsrch = ex_is_tlb && (ex_priv_addr == TLB_CMD_SEARCH);
    wire ex_is_tlbrd = ex_is_tlb && (ex_priv_addr == TLB_CMD_READ);
    wire ex_is_tlbwr = ex_is_tlb && (ex_priv_addr == TLB_CMD_WRITE);
    wire ex_is_tlbfill = ex_is_tlb && (ex_priv_addr == TLB_CMD_FILL);
    wire ex_is_invtlb = ex_is_tlb && (ex_priv_addr[15:8] == 8'h01);

    function automatic logic csr_address_supported(input logic [13:0] addr);
        begin
            case (addr)
                CSR_CRMD, CSR_PRMD, CSR_EUEN, CSR_ECFG, CSR_ESTAT,
                CSR_ERA, CSR_BADV, CSR_EENTRY, CSR_TLBIDX, CSR_TLBEHI,
                CSR_TLBELO0, CSR_TLBELO1, CSR_ASID, CSR_PGDL, CSR_PGDH,
                CSR_PGD, CSR_CPUID, CSR_PRCFG1, CSR_PRCFG2, CSR_PRCFG3,
                CSR_SAVE0, CSR_SAVE1, CSR_SAVE2,
                CSR_SAVE3, CSR_TID, CSR_TCFG, CSR_TVAL, CSR_CNTC,
                CSR_TICLR, CSR_LLBCTL, CSR_TLBRENTRY, CSR_DMW0, CSR_DMW1,
                CSR_DISABLE_CACHE: csr_address_supported = 1'b1;
                default: csr_address_supported = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [31:0] csr_read(input logic [13:0] addr);
        begin
            case (addr)
                CSR_CRMD:      csr_read = csr_crmd;
                CSR_PRMD:      csr_read = csr_prmd;
                CSR_EUEN:      csr_read = csr_euen;
                CSR_ECFG:      csr_read = csr_ecfg;
                CSR_ESTAT:     csr_read = csr_estat;
                CSR_ERA:       csr_read = csr_era;
                CSR_BADV:      csr_read = csr_badv;
                CSR_EENTRY:    csr_read = csr_eentry;
                CSR_TLBIDX:    csr_read = csr_tlbidx;
                CSR_TLBEHI:    csr_read = csr_tlbehi;
                CSR_TLBELO0:   csr_read = csr_tlbelo0;
                CSR_TLBELO1:   csr_read = csr_tlbelo1;
                CSR_ASID:      csr_read = csr_asid;
                CSR_PGDL:      csr_read = csr_pgdl;
                CSR_PGDH:      csr_read = csr_pgdh;
                CSR_PGD:       csr_read = csr_badv[31] ? csr_pgdh : csr_pgdl;
                CSR_CPUID:     csr_read = 32'd0;
                // Four SAVE CSRs, a 32-bit timer and no vectored spacing.
                CSR_PRCFG1:    csr_read = 32'h0000_01f4;
                // This implementation verifies 4KB and 2MB page entries.
                CSR_PRCFG2:    csr_read = 32'h0020_1000;
                // One fully-associative MTLB. Bits [11:4] report entries-1.
                CSR_PRCFG3:    csr_read = 32'h0000_0001
                                         | ((TLB_ENTRIES - 1) << 4);
                CSR_SAVE0:     csr_read = csr_save0;
                CSR_SAVE1:     csr_read = csr_save1;
                CSR_SAVE2:     csr_read = csr_save2;
                CSR_SAVE3:     csr_read = csr_save3;
                CSR_TID:       csr_read = csr_tid;
                CSR_TCFG:      csr_read = csr_tcfg;
                CSR_TVAL:      csr_read = csr_tval;
                CSR_CNTC:      csr_read = csr_cntc;
                CSR_TICLR:     csr_read = 32'd0;
                CSR_LLBCTL:    csr_read = csr_llbctl;
                CSR_TLBRENTRY: csr_read = csr_tlbrentry;
                CSR_DMW0:      csr_read = csr_dmw0;
                CSR_DMW1:      csr_read = csr_dmw1;
                CSR_DISABLE_CACHE: csr_read = csr_disable_cache;
                default:       csr_read = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] cpucfg_read(
        input logic [31:0] word_index
    );
        begin
            case (word_index)
                // Simplified LA32, 32-bit physical/virtual addresses and a
                // page-mapping MMU; IOCSR and unaligned access are absent.
                32'h0000_0001: cpucfg_read = 32'h0001_f1f4;
                32'h0000_0010: cpucfg_read = CPUCFG_CACHE_PRESENT;
                32'h0000_0011: cpucfg_read = CPUCFG_ICACHE;
                32'h0000_0012: cpucfg_read = CPUCFG_DCACHE;
                // Undefined configuration words architecturally read as zero.
                default:       cpucfg_read = 32'd0;
            endcase
        end
    endfunction

    wire ex_csr_supported = ~|ex_priv_addr[PRIV_ADDR_W-1:14]
                          & csr_address_supported(csr_addr);
    wire ex_privileged_mode = csr_crmd[1:0] == 2'd0;
    // CACOP Hit operations are explicitly legal at PLV3. StoreTag and Index
    // operations remain privileged, matching the OpenLA500 software contract.
    wire ex_priv_violation = (ex_is_csr | ex_is_return | ex_is_tlb
                              | ex_is_idle
                              | (ex_is_cacop & ex_cacop_supported
                                 & ~ex_cacop_hit))
                           & ~ex_privileged_mode;
    wire ex_bad_csr = ex_is_csr & ~ex_csr_supported;
    wire ex_fetch_misaligned = |ex_pc[1:0];
    wire ex_data_misaligned = (ex_mem_read_en | ex_mem_write_en)
                            & (((ex_mem_size == MEM_HALF) & ex_mem_addr_low[0])
                               | ((ex_mem_size == MEM_WORD)
                                  & (|ex_mem_addr_low)));
    wire ex_s1_data_misaligned = (ex_s1_mem_read_en
                                  | ex_s1_mem_write_en)
                               & (((ex_s1_mem_size == MEM_HALF)
                                   & ex_s1_mem_addr_low[0])
                                  | ((ex_s1_mem_size == MEM_WORD)
                                     & (|ex_s1_mem_addr_low)));
    wire ex_has_decode_exception = ex_exception != EXCEPTION_NONE;
    wire ex_s0_lsu = ex_mem_read_en | ex_mem_write_en;
    wire ex_s1_lsu = ex_s1_valid
                   & (ex_s1_mem_read_en | ex_s1_mem_write_en);
    wire ex_fetch_tlbr = ex_exception == EXCEPTION_FETCH_TLBR;
    wire ex_fetch_pif = ex_exception == EXCEPTION_FETCH_PIF;
    wire ex_fetch_ppi = ex_exception == EXCEPTION_FETCH_PPI;
    // Hit CACOP translates like a load and may raise TLBR/PIL. It deliberately
    // does not raise PPI: LA32R permits Hit-class CACOP from PLV3.
    wire ex_s0_data_tlbr = (ex_s0_lsu | ex_cacop_hit) & mmu_data_tlbr;
    wire ex_s0_data_pil = (ex_s0_lsu | ex_cacop_hit) & mmu_data_pil;
    wire ex_s0_data_pis = ex_s0_lsu & mmu_data_pis;
    wire ex_s0_data_pme = ex_s0_lsu & mmu_data_pme;
    wire ex_s0_data_ppi = ex_s0_lsu & mmu_data_ppi;
    wire ex_s0_page_fault = ex_s0_data_tlbr | ex_s0_data_pil
                          | ex_s0_data_pis | ex_s0_data_pme
                          | ex_s0_data_ppi;
    wire ex_s1_page_fault = ex_s1_lsu
                          & (mmu_data_tlbr | mmu_data_pil | mmu_data_pis
                             | mmu_data_pme | mmu_data_ppi);
    wire ex_tlb_refill = ex_fetch_tlbr | ex_s0_data_tlbr;
    wire ex_fetch_page_fault = ex_fetch_tlbr | ex_fetch_pif | ex_fetch_ppi;
    wire ex_sync_trap = ex_is_syscall | ex_has_decode_exception
                      | ex_priv_violation | ex_bad_csr
                      | ex_fetch_misaligned | ex_data_misaligned
                      | ex_s0_page_fault;
    wire ex_valid_return = ex_is_return & ~ex_priv_violation;
    // A privileged flow reaches EX only after older backend tokens are gone;
    // address faults discovered in EX wait for that same condition.  Commit
    // directly from the registered token cone so AXI/DCache readiness cannot
    // enter trap, ERTN, or CSR register enables.
    wire ex_priv_stage_fire = ex_valid & ex_priv_commit_ready
                            & ~mem_branch_flush;
    wire ex_sync_trap_fire = ex_priv_stage_fire & ex_sync_trap;
    wire ex_return_fire = ex_priv_stage_fire & ex_valid_return;
    assign idle_enter = ex_priv_stage_fire & ex_is_idle
                      & ~ex_priv_violation & ~ex_sync_trap;

    logic [5:0] ex_sync_cause;
    always_comb begin
        if (ex_fetch_misaligned)
            ex_sync_cause = ECODE_ADE;
        else if (ex_data_misaligned)
            ex_sync_cause = ECODE_ALE;
        else if (ex_tlb_refill)
            ex_sync_cause = ECODE_TLBR;
        else if (ex_fetch_pif)
            ex_sync_cause = ECODE_PIF;
        else if (ex_s0_data_pil)
            ex_sync_cause = ECODE_PIL;
        else if (ex_s0_data_pis)
            ex_sync_cause = ECODE_PIS;
        else if (ex_s0_data_pme)
            ex_sync_cause = ECODE_PME;
        else if (ex_fetch_ppi | ex_s0_data_ppi)
            ex_sync_cause = ECODE_PPI;
        else if (ex_is_syscall)
            ex_sync_cause = ECODE_SYS;
        else if (ex_priv_violation | ex_bad_csr)
            ex_sync_cause = ECODE_IPE;
        else if (ex_exception == EXCEPTION_BREAKPOINT)
            ex_sync_cause = ECODE_BRK;
        else
            ex_sync_cause = ECODE_INE;
    end

    // Side effects must follow the exception that won the architectural
    // priority encoder above.  Raw TLB/page-fault indications may coexist
    // with a higher-priority ADEF/ALE and must not select the refill vector or
    // mutate refill state in that case.
    wire ex_tlb_refill_wins = ex_sync_cause == ECODE_TLBR;
    wire ex_page_fault_wins = (ex_sync_cause == ECODE_TLBR)
                            | (ex_sync_cause == ECODE_PIF)
                            | (ex_sync_cause == ECODE_PIL)
                            | (ex_sync_cause == ECODE_PIS)
                            | (ex_sync_cause == ECODE_PME)
                            | (ex_sync_cause == ECODE_PPI);

    wire [63:0] compensated_counter = stable_counter
                                    + {{32{csr_cntc[31]}}, csr_cntc};
    assign ex_priv_rdata = ex_is_cpucfg
                         ? cpucfg_read(ex_src0_data)
                         : ex_is_counter
                         ? (ex_priv_addr == 16'hffff) ? csr_tid
                         : (ex_priv_addr == 16'hfffe)
                             ? compensated_counter[63:32]
                             : compensated_counter[31:0]
                         : csr_read(csr_addr);
    wire [31:0] ex_csr_src = ex_priv_uses_imm
                           ? {27'd0, ex_priv_imm} : ex_src0_data;
    wire [31:0] ex_csr_wdata =
        (ex_priv_cmd == PRIV_CMD_WRITE) ? ex_csr_src :
        (ex_priv_cmd == PRIV_CMD_SET) ? (ex_priv_rdata | ex_csr_src) :
        (ex_priv_cmd == PRIV_CMD_CLEAR) ? (ex_priv_rdata & ~ex_csr_src) :
        (ex_priv_cmd == PRIV_CMD_EXCHANGE)
            ? ((ex_priv_rdata & ~ex_src1_data)
               | (ex_csr_src & ex_src1_data)) : ex_priv_rdata;
    wire ex_csr_write_req = (ex_priv_cmd == PRIV_CMD_WRITE)
                          | (ex_priv_cmd == PRIV_CMD_EXCHANGE)
                          | (((ex_priv_cmd == PRIV_CMD_SET)
                              | (ex_priv_cmd == PRIV_CMD_CLEAR))
                             & (|ex_csr_src));
    // CSR writes are serialized behind older MEM/WB tokens before entering EX.
    // Use that registered class-specific readiness directly: the generic
    // ex_ready_go also contains address-fault, LSU, and MulDiv conditions which
    // are mutually exclusive with a decoded CSR but otherwise enter every CSR
    // register enable.
    wire ex_csr_write_fire = ex_priv_stage_fire
                           & ex_is_csr
                           & ex_csr_supported & ~ex_priv_violation
                           & ex_csr_write_req;

    wire ex_tlb_fire = ex_priv_stage_fire & ex_is_tlb
                     & ~ex_priv_violation;

    wire mmu_tlbsrch_found;
    wire [4:0] mmu_tlbsrch_index;
    wire mmu_tlbrd_e;
    wire [18:0] mmu_tlbrd_vppn;
    wire [5:0] mmu_tlbrd_ps;
    wire [9:0] mmu_tlbrd_asid;
    wire mmu_tlbrd_g;
    wire [31:0] mmu_tlbrd_elo0;
    wire [31:0] mmu_tlbrd_elo1;
    wire [4:0] mmu_tlbfill_index;
    wire mmu_tlb_write_e = (csr_estat[21:16] == ECODE_TLBR)
                         | ~csr_tlbidx[31];

    loongarch_mmu #(
        .TLB_ENTRIES(TLB_ENTRIES),
        .TLB_INDEX_W(5)
    ) u_mmu (
        .clk              (clk),
        .rst_n            (rst_n),
        .crmd_da          (csr_crmd[3]),
        .crmd_pg          (csr_crmd[4]),
        .crmd_plv         (csr_crmd[1:0]),
        .crmd_datf        (csr_crmd[6:5]),
        .crmd_datm        (csr_crmd[8:7]),
        .csr_asid         (csr_asid[9:0]),
        .csr_dmw0         (csr_dmw0),
        .csr_dmw1         (csr_dmw1),
        .inst_valid       (mmu_inst_valid),
        .inst_vaddr       (mmu_inst_vaddr),
        .inst_paddr       (mmu_inst_paddr),
        .inst_mat         (mmu_inst_mat),
        .inst_tlbr        (mmu_inst_tlbr),
        .inst_pif         (mmu_inst_pif),
        .inst_ppi         (mmu_inst_ppi),
        .inst_tlb_hit     (),
        .inst_tlb_index   (),
        .data_valid       (mmu_data_valid),
        .data_store       (mmu_data_store),
        .data_vaddr       (mmu_data_vaddr),
        .data_ready       (mmu_data_ready),
        .data_paddr       (mmu_data_paddr),
        .data_mat         (mmu_data_mat),
        .data_tlbr        (mmu_data_tlbr),
        .data_pil         (mmu_data_pil),
        .data_pis         (mmu_data_pis),
        .data_pme         (mmu_data_pme),
        .data_ppi         (mmu_data_ppi),
        .data_tlb_hit     (),
        .data_tlb_index   (),
        .tlbsrch_valid    (ex_tlb_fire & ex_is_tlbsrch),
        .tlbsrch_vaddr    (csr_tlbehi),
        .tlbsrch_found    (mmu_tlbsrch_found),
        .tlbsrch_index    (mmu_tlbsrch_index),
        .tlbrd_valid      (ex_tlb_fire & ex_is_tlbrd),
        .tlbrd_index      (csr_tlbidx[4:0]),
        .tlbrd_e          (mmu_tlbrd_e),
        .tlbrd_vppn       (mmu_tlbrd_vppn),
        .tlbrd_ps         (mmu_tlbrd_ps),
        .tlbrd_asid       (mmu_tlbrd_asid),
        .tlbrd_g          (mmu_tlbrd_g),
        .tlbrd_elo0       (mmu_tlbrd_elo0),
        .tlbrd_elo1       (mmu_tlbrd_elo1),
        .tlbwr_valid      (ex_tlb_fire & ex_is_tlbwr),
        .tlbwr_index      (csr_tlbidx[4:0]),
        .tlbwr_e          (mmu_tlb_write_e),
        .tlbwr_vppn       (csr_tlbehi[31:13]),
        .tlbwr_ps         (csr_tlbidx[29:24]),
        .tlbwr_asid       (csr_asid[9:0]),
        .tlbwr_g          (csr_tlbelo0[6] & csr_tlbelo1[6]),
        .tlbwr_elo0       (csr_tlbelo0),
        .tlbwr_elo1       (csr_tlbelo1),
        .tlbfill_valid    (ex_tlb_fire & ex_is_tlbfill),
        .tlbfill_e        (mmu_tlb_write_e),
        .tlbfill_vppn     (csr_tlbehi[31:13]),
        .tlbfill_ps       (csr_tlbidx[29:24]),
        .tlbfill_asid     (csr_asid[9:0]),
        .tlbfill_g        (csr_tlbelo0[6] & csr_tlbelo1[6]),
        .tlbfill_elo0     (csr_tlbelo0),
        .tlbfill_elo1     (csr_tlbelo1),
        .tlbfill_index    (mmu_tlbfill_index),
        .invtlb_valid     (ex_tlb_fire & ex_is_invtlb),
        .invtlb_op        (ex_priv_addr[4:0]),
        .invtlb_asid      (ex_src0_data[9:0]),
        .invtlb_vaddr     (ex_src1_data)
    );

`ifndef SYNTHESIS
    // Retain the original expression as an executable equivalence check.  The
    // serializing decoder guarantees that the two readiness terms agree for a
    // CSR write without putting the old cone back into the synthesized design.
    wire ex_csr_write_fire_reference =
        ex_valid & ex_ready_go & ~mem_branch_flush
        & ex_is_csr & ex_csr_supported & ~ex_priv_violation
        & ex_csr_write_req;
    wire ex_sync_trap_fire_reference = ex_valid & ex_redirect_fire
                                     & ex_sync_trap;
    wire ex_return_fire_reference = ex_valid & ex_redirect_fire
                                  & ex_valid_return;
    always_ff @(posedge clk) begin
        if (rst_n
            && (ex_csr_write_fire !== ex_csr_write_fire_reference))
            $fatal(1, "Class-specific CSR write readiness changed commit timing");
        if (rst_n
            && ((ex_sync_trap_fire !== ex_sync_trap_fire_reference)
                || (ex_return_fire !== ex_return_fire_reference)))
            $fatal(1, "Class-specific privileged readiness changed redirect timing");
        if (rst_n && ex_priv_stage_fire
            && (ex_sync_trap | ex_valid_return)
            && (!ex_ready_go || !mem_allowin))
            $fatal(1, "Privileged commit fired before the generic pipeline was ready");
    end
`endif

    assign ex_priv_flow = ex_valid & (ex_sync_trap | ex_valid_return);
    assign ex_priv_redirect = ex_sync_trap_fire | ex_return_fire;
    assign ex_priv_target = ex_valid_return ? csr_era
                          : ex_tlb_refill_wins ? csr_tlbrentry : csr_eentry;
    assign ex_priv_trap = ex_valid & ex_sync_trap;
    // Unlike decoded system instructions, address faults are discovered only
    // after the address adder in EX.  Ask the common pipeline to hold them
    // until every older MEM/WB token has retired, so CSR state and the
    // Difftest exception event share one precise architectural boundary.
    assign ex_priv_wait_older = ex_valid
                              & (ex_fetch_misaligned | ex_data_misaligned
                                 | ex_fetch_page_fault | ex_s0_page_fault
                                 | ex_is_tlb | ex_is_idle
                                 | ex_is_cacop
                                 | (ex_is_csr & ex_csr_write_req));
    assign ex_s1_addr_replay = ex_valid & ex_s1_valid
                             & (ex_s1_data_misaligned | ex_s1_page_fault);

    // External level IRQs remain level-sensitive. Platform-declared pulse
    // sources are additionally edge-latched so a one-CPU-cycle DMA/NAND event
    // cannot lose its ESTAT source while timer_irq_ctrl drains the pipeline.
    // At interrupt entry, preserve the enabled source bits for the entire
    // handler; ERTN releases that service snapshot, while a new pulse arriving
    // during the handler remains pending for the next entry.
    wire [ 7:0] irq_rise = irq_pending & ~irq_pending_d;
    wire [ 7:0] irq_event_rise = irq_rise & IRQ_EDGE_MASK;
    wire [ 7:0] external_irq_pending = irq_pending | irq_event_pending;
    wire [ 7:0] irq_take_bits = external_irq_pending & csr_ecfg[9:2];
    wire [ 7:0] external_irq_effective = external_irq_pending
                                       | ({8{irq_service_active}}
                                          & irq_service_pending);
    wire [12:0] effective_is = {
        csr_estat[12:10], external_irq_effective, csr_estat[1:0]
    };
    assign timer_irq_request = csr_crmd[2]
                             & (|(csr_ecfg[12:0] & effective_is));
    assign timer_irq_redirect = timer_irq_take;
    assign timer_irq_target = csr_eentry;

    assign debug_excp_valid = ex_sync_trap_fire | timer_irq_take;
    assign debug_ertn = ex_return_fire;
    assign debug_intr_no = {21'd0, effective_is[12:2]};
    assign debug_cause = timer_irq_take ? ECODE_INT : ex_sync_cause;
    assign debug_exception_pc = timer_irq_take ? timer_irq_mepc : ex_pc;
    assign debug_exception_inst = timer_irq_take ? 32'd0 : ex_inst;
    assign debug_tlbfill_index = last_tlbfill_index;

    always_comb begin
        debug_priv_state = '0;
        debug_priv_state[ 0*32 +: 32] = csr_crmd;
        debug_priv_state[ 1*32 +: 32] = csr_prmd;
        debug_priv_state[ 2*32 +: 32] = csr_euen;
        debug_priv_state[ 3*32 +: 32] = csr_ecfg;
        debug_priv_state[ 4*32 +: 32] = csr_estat;
        debug_priv_state[ 5*32 +: 32] = csr_era;
        debug_priv_state[ 6*32 +: 32] = csr_badv;
        debug_priv_state[ 7*32 +: 32] = csr_eentry;
        debug_priv_state[ 8*32 +: 32] = csr_tlbidx;
        debug_priv_state[ 9*32 +: 32] = csr_tlbehi;
        debug_priv_state[10*32 +: 32] = csr_tlbelo0;
        debug_priv_state[11*32 +: 32] = csr_tlbelo1;
        debug_priv_state[12*32 +: 32] = csr_asid;
        debug_priv_state[13*32 +: 32] = csr_pgdl;
        debug_priv_state[14*32 +: 32] = csr_pgdh;
        debug_priv_state[15*32 +: 32] = csr_save0;
        debug_priv_state[16*32 +: 32] = csr_save1;
        debug_priv_state[17*32 +: 32] = csr_save2;
        debug_priv_state[18*32 +: 32] = csr_save3;
        debug_priv_state[19*32 +: 32] = csr_tid;
        debug_priv_state[20*32 +: 32] = csr_tcfg;
        debug_priv_state[21*32 +: 32] = csr_tval;
        debug_priv_state[22*32 +: 32] = 32'd0;
        debug_priv_state[23*32 +: 32] = csr_llbctl;
        debug_priv_state[24*32 +: 32] = csr_tlbrentry;
        debug_priv_state[25*32 +: 32] = csr_dmw0;
        debug_priv_state[26*32 +: 32] = csr_dmw1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            irq_pending_d       <= 8'd0;
            irq_event_pending   <= 8'd0;
            irq_service_pending <= 8'd0;
            irq_service_active  <= 1'b0;
        end else begin
            irq_pending_d <= irq_pending;

            if (timer_irq_take) begin
                irq_service_pending <= irq_take_bits;
                irq_service_active  <= |irq_take_bits;
                irq_event_pending   <= (irq_event_pending | irq_event_rise)
                                     & ~irq_take_bits;
            end else begin
                irq_event_pending <= irq_event_pending | irq_event_rise;
                if (ex_return_fire) begin
                    irq_service_pending <= 8'd0;
                    irq_service_active  <= 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            csr_crmd          <= 32'h0000_0008;
            csr_prmd          <= 32'd0;
            csr_euen          <= 32'd0;
            csr_ecfg          <= 32'd0;
            csr_estat         <= 32'd0;
            csr_era           <= 32'd0;
            csr_badv          <= 32'd0;
            csr_eentry        <= 32'd0;
            csr_tlbidx        <= 32'd0;
            csr_tlbehi        <= 32'd0;
            csr_tlbelo0       <= 32'd0;
            csr_tlbelo1       <= 32'd0;
            csr_asid          <= 32'h000a_0000;
            csr_pgdl          <= 32'd0;
            csr_pgdh          <= 32'd0;
            csr_save0         <= 32'd0;
            csr_save1         <= 32'd0;
            csr_save2         <= 32'd0;
            csr_save3         <= 32'd0;
            csr_tid           <= 32'd0;
            csr_tcfg          <= 32'd0;
            csr_tval          <= 32'd0;
            csr_cntc          <= 32'd0;
            csr_llbctl        <= 32'd0;
            csr_tlbrentry     <= 32'd0;
            csr_dmw0          <= 32'd0;
            csr_dmw1          <= 32'd0;
            csr_disable_cache <= 32'd0;
            last_tlbfill_index <= 5'd0;
            stable_counter    <= 64'd0;
            timer_active      <= 1'b0;
        end else begin
            stable_counter <= stable_counter + 64'd1;
            // Drop the just-serviced snapshot on the ERTN edge itself so a
            // vanished pulse cannot spuriously retrigger after CRMD.IE is
            // restored. New/live events remain visible.
            csr_estat[9:2] <= ex_return_fire
                            ? external_irq_pending
                            : external_irq_effective;
            csr_estat[12] <= 1'b0;

            if (timer_active) begin
                if (csr_tval != 32'd0)
                    csr_tval <= csr_tval - 32'd1;
                else begin
                    csr_estat[11] <= 1'b1;
                    if (csr_tcfg[1])
                        csr_tval <= {csr_tcfg[31:2], 2'b00};
                    else begin
                        csr_tval <= 32'hffff_ffff;
                        timer_active <= 1'b0;
                    end
                end
            end

            if (ex_csr_write_fire) begin
                case (csr_addr)
                    CSR_CRMD:      csr_crmd <= ex_csr_wdata & 32'h0000_01ff;
                    CSR_PRMD:      csr_prmd <= ex_csr_wdata & 32'h0000_0007;
                    CSR_EUEN:      csr_euen <= ex_csr_wdata & 32'h0000_0001;
                    // ECFG.LIE has no bit 10; bits 0..9 and 11..12 are
                    // writable in LA32R.
                    CSR_ECFG:      csr_ecfg <= ex_csr_wdata & 32'h0000_1bff;
                    CSR_ESTAT:     csr_estat[1:0] <= ex_csr_wdata[1:0];
                    CSR_ERA:       csr_era <= ex_csr_wdata;
                    CSR_BADV:      csr_badv <= ex_csr_wdata;
                    CSR_EENTRY:    csr_eentry <= {ex_csr_wdata[31:6], 6'd0};
                    CSR_TLBIDX:    csr_tlbidx <= ex_csr_wdata
                                                    & 32'hbf00_001f;
                    CSR_TLBEHI:    csr_tlbehi <= ex_csr_wdata
                                                    & 32'hffff_e000;
                    CSR_TLBELO0:   csr_tlbelo0 <= ex_csr_wdata
                                                     & 32'h0fff_ff7f;
                    CSR_TLBELO1:   csr_tlbelo1 <= ex_csr_wdata
                                                     & 32'h0fff_ff7f;
                    CSR_ASID:      csr_asid <= 32'h000a_0000
                                              | (ex_csr_wdata & 32'h0000_03ff);
                    CSR_PGDL:      csr_pgdl <= ex_csr_wdata & 32'hffff_f000;
                    CSR_PGDH:      csr_pgdh <= ex_csr_wdata & 32'hffff_f000;
                    CSR_SAVE0:     csr_save0 <= ex_csr_wdata;
                    CSR_SAVE1:     csr_save1 <= ex_csr_wdata;
                    CSR_SAVE2:     csr_save2 <= ex_csr_wdata;
                    CSR_SAVE3:     csr_save3 <= ex_csr_wdata;
                    CSR_TID:       csr_tid <= ex_csr_wdata;
                    CSR_TCFG: begin
                        csr_tcfg <= ex_csr_wdata;
                        csr_tval <= {ex_csr_wdata[31:2], 2'b00};
                        timer_active <= ex_csr_wdata[0];
                    end
                    CSR_CNTC:      csr_cntc <= ex_csr_wdata;
                    CSR_TICLR: begin
                        if (ex_csr_wdata[0])
                            csr_estat[11] <= 1'b0;
                    end
                    CSR_LLBCTL: begin
                        // ROLLB (bit 0) reflects the architectural LLBit and
                        // is read-only. WCLLB (bit 1) is write-one-to-clear
                        // and always reads zero. KLO (bit 2) is retained.
                        csr_llbctl[2] <= ex_csr_wdata[2];
                        csr_llbctl[1] <= 1'b0;
                        if (ex_csr_wdata[1])
                            csr_llbctl[0] <= 1'b0;
                    end
                    CSR_TLBRENTRY: csr_tlbrentry <= {ex_csr_wdata[31:6], 6'd0};
                    CSR_DMW0:      csr_dmw0 <= ex_csr_wdata & 32'hee00_0039;
                    CSR_DMW1:      csr_dmw1 <= ex_csr_wdata & 32'hee00_0039;
                    CSR_DISABLE_CACHE: csr_disable_cache <= ex_csr_wdata;
                    default: ;
                endcase
            end

            if (ex_tlb_fire) begin
                if (ex_is_tlbfill)
                    last_tlbfill_index <= mmu_tlbfill_index;
                if (ex_is_tlbsrch) begin
                    csr_tlbidx[31] <= ~mmu_tlbsrch_found;
                    if (mmu_tlbsrch_found)
                        csr_tlbidx[4:0] <= mmu_tlbsrch_index;
                end else if (ex_is_tlbrd) begin
                    if (mmu_tlbrd_e) begin
                        csr_tlbidx <= {2'd0, mmu_tlbrd_ps, 19'd0,
                                       csr_tlbidx[4:0]};
                        csr_tlbehi <= {mmu_tlbrd_vppn, 13'd0};
                        csr_tlbelo0 <= mmu_tlbrd_elo0;
                        csr_tlbelo1 <= mmu_tlbrd_elo1;
                        csr_asid <= 32'h000a_0000
                                  | {22'd0, mmu_tlbrd_asid};
                    end else begin
                        csr_tlbidx <= {1'b1, 26'd0, csr_tlbidx[4:0]};
                        csr_tlbehi <= 32'd0;
                        csr_tlbelo0 <= 32'd0;
                        csr_tlbelo1 <= 32'd0;
                        csr_asid <= 32'h000a_0000;
                    end
                end
            end

            if (timer_irq_take) begin
                csr_prmd[1:0] <= csr_crmd[1:0];
                csr_prmd[2] <= csr_crmd[2];
                csr_crmd[1:0] <= 2'd0;
                csr_crmd[2] <= 1'b0;
                csr_era <= timer_irq_mepc;
                csr_estat[21:16] <= ECODE_INT;
                csr_estat[30:22] <= 9'd0;
            end else if (ex_sync_trap_fire) begin
                csr_prmd[1:0] <= csr_crmd[1:0];
                csr_prmd[2] <= csr_crmd[2];
                csr_crmd[1:0] <= 2'd0;
                csr_crmd[2] <= 1'b0;
                csr_era <= ex_pc;
                csr_estat[21:16] <= ex_sync_cause;
                csr_estat[30:22] <= 9'd0;
                if (ex_tlb_refill_wins) begin
                    csr_crmd[3] <= 1'b1;
                    csr_crmd[4] <= 1'b0;
                end
                if (ex_fetch_misaligned | ex_fetch_page_fault)
                    csr_badv <= ex_pc;
                else if (ex_data_misaligned | ex_s0_page_fault)
                    csr_badv <= ex_mem_addr;
                if (ex_page_fault_wins) begin
                    if (ex_fetch_page_fault)
                        csr_tlbehi <= {ex_pc[31:13], 13'd0};
                    else if (ex_s0_page_fault)
                        csr_tlbehi <= {ex_mem_addr[31:13], 13'd0};
                end
            end else if (ex_return_fire) begin
                csr_crmd[1:0] <= csr_prmd[1:0];
                csr_crmd[2] <= csr_prmd[2];
                if (csr_estat[21:16] == ECODE_TLBR) begin
                    csr_crmd[3] <= 1'b0;
                    csr_crmd[4] <= 1'b1;
                end
                if (!csr_llbctl[2])
                    csr_llbctl[0] <= 1'b0;
                csr_llbctl[2] <= 1'b0;
            end

            // A completed SC always consumes the reservation. A completed LL
            // establishes it. These mutually exclusive WB events are applied
            // after CSR/ERTN handling so the architectural atomic instruction
            // itself owns the final LLBit value for this edge.
            if (llbit_clear)
                csr_llbctl[0] <= 1'b0;
            else if (llbit_set)
                csr_llbctl[0] <= 1'b1;
        end
    end

endmodule

module isa_priv_unit
    import cpu_defs::*;
#(
    parameter integer TLB_ENTRIES = 32,
    parameter logic [31:0] CPUCFG_CACHE_PRESENT = 32'd0,
    parameter logic [31:0] CPUCFG_ICACHE = 32'd0,
    parameter logic [31:0] CPUCFG_DCACHE = 32'd0,
    parameter logic [ 7:0] IRQ_EDGE_MASK = 8'd0
)
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        ex_priv_commit_ready,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_inst,
    input  logic [31:0] ex_src0_data,
    input  logic [31:0] ex_src1_data,
    input  priv_op_t    ex_priv_op,
    input  logic        ex_priv_uses_imm,
    input  priv_cmd_t   ex_priv_cmd,
    input  logic [PRIV_ADDR_W-1:0] ex_priv_addr,
    input  logic [ 4:0] ex_priv_imm,
    input  decode_exception_t ex_exception,
    input  logic        ex_mem_read_en,
    input  logic        ex_mem_write_en,
    input  mem_size_t   ex_mem_size,
    input  logic [31:0] ex_mem_addr,
    input  logic [ 1:0] ex_mem_addr_low,
    input  logic        ex_s1_valid,
    input  logic        ex_s1_mem_read_en,
    input  logic        ex_s1_mem_write_en,
    input  mem_size_t   ex_s1_mem_size,
    input  logic [31:0] ex_s1_mem_addr,
    input  logic [ 1:0] ex_s1_mem_addr_low,
    input  logic [ 7:0] irq_pending,
    input  logic        timer_irq_take,
    input  logic [31:0] timer_irq_mepc,
    input  logic        llbit_set,
    input  logic        llbit_clear,
    output logic        llbit,
    input  logic        mmu_inst_valid,
    input  logic [31:0] mmu_inst_vaddr,
    output logic [31:0] mmu_inst_paddr,
    output logic [ 1:0] mmu_inst_mat,
    output logic        mmu_inst_tlbr,
    output logic        mmu_inst_pif,
    output logic        mmu_inst_ppi,
    input  logic        mmu_data_valid,
    input  logic        mmu_data_store,
    input  logic [31:0] mmu_data_vaddr,
    output logic        mmu_data_ready,
    output logic [31:0] mmu_data_paddr,
    output logic [ 1:0] mmu_data_mat,
    output logic        mmu_data_mat_valid,
    output logic        mmu_data_tlbr,
    output logic        mmu_data_pil,
    output logic        mmu_data_pis,
    output logic        mmu_data_pme,
    output logic        mmu_data_ppi,
    output logic        ex_priv_flow,
    output logic        ex_priv_redirect,
    output logic [31:0] ex_priv_target,
    output logic        ex_priv_trap,
    output logic        ex_priv_wait_older,
    output logic        ex_s1_addr_replay,
    output logic        idle_enter,
    output logic        timer_irq_request,
    output logic        timer_irq_redirect,
    output logic [31:0] timer_irq_target,
    output logic [31:0] ex_priv_rdata,
    output logic        debug_excp_valid,
    output logic        debug_ertn,
    output logic [31:0] debug_intr_no,
    output logic [ 5:0] debug_cause,
    output logic [31:0] debug_exception_pc,
    output logic [31:0] debug_exception_inst,
    output logic [ 4:0] debug_tlbfill_index,
    output logic [PRIV_DEBUG_STATE_W-1:0] debug_priv_state
);
    loongarch_priv_unit #(
        .TLB_ENTRIES(TLB_ENTRIES),
        .CPUCFG_CACHE_PRESENT(CPUCFG_CACHE_PRESENT),
        .CPUCFG_ICACHE(CPUCFG_ICACHE),
        .CPUCFG_DCACHE(CPUCFG_DCACHE),
        .IRQ_EDGE_MASK(IRQ_EDGE_MASK)
    ) u_impl (.*);
endmodule
