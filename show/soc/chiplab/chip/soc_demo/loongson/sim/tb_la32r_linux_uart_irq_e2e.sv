`timescale 1ns/1ps

// End-to-end replay of the Linux console receive path:
//
//   serial RX -> UART FIFO/IIR -> uart0_int -> two-flop CPU-clock CDC
//     -> ESTAT.IS3 -> Linux IDLE wake/plat_irq_dispatch
//     -> real CPU uncached AXI read -> axi2apb_misc -> IIR/LSR/RBR -> ERTN
//
// The FPGA-only AXI clock-converter IP is replaced by a single-outstanding
// toggle bridge.  All functional blocks on either side are the production RTL:
// core_top (including caches and the NSCSCC AXI master), axi2apb_misc, and
// UART_TOP.  The instruction stream reuses the released Linux IDLE and
// plat_irq_dispatch words; the bounded 8250 service tail performs the same
// IIR/LSR/RBR byte accesses as the Linux 8250 handler.
module tb_la32r_linux_uart_irq_e2e;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h1c00_0000;
    localparam logic [31:0] UART_BASE = 32'h1fe0_01e0;
    localparam logic [31:0] NOP = 32'h0340_0000;
    localparam int ROM_WORDS = 256;

    localparam logic [31:0] LINUX_IRQ_ENABLE_LI       = 32'h0280_100c;
    localparam logic [31:0] LINUX_IRQ_ENABLE_CSRXCHG = 32'h0400_018c;
    localparam logic [31:0] LINUX_IDLE_LOAD_FLAGS    = 32'h2880_104c;
    localparam logic [31:0] LINUX_IDLE_AND_RESCHED   = 32'h0340_118c;
    localparam logic [31:0] LINUX_IDLE_BNE_RESCHED   = 32'h5c00_1580;
    localparam logic [31:0] LINUX_IDLE               = 32'h0648_8000;
    localparam logic [31:0] LINUX_RETURN             = 32'h4c00_0020;
    localparam logic [31:0] LINUX_READ_ESTAT         = 32'h0400_1404;
    localparam logic [31:0] LINUX_READ_ECFG          = 32'h0400_100c;
    localparam logic [31:0] LINUX_MASK_PENDING       = 32'h0014_b084;
    localparam logic [31:0] ERTN                     = 32'h0648_3800;

    logic cpu_clk;
    logic uncore_clk;
    logic cpu_aresetn;
    logic uncore_rst_n;
    integer uncore_half_ns;
    integer uncore_phase_ns;
    integer rx_start_delay;
    integer uart_divisor;
    integer uart_fcr;
    integer expected_iir;
    integer bit_cycles;
    bit trace_uart;
    bit expect_first_byte_loss;

    logic [31:0] rom [0:ROM_WORDS-1];

    // core_top AXI master
    wire [3:0]  m_arid;
    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire [1:0]  m_arlock;
    wire [3:0]  m_arcache;
    wire [2:0]  m_arprot;
    wire        m_arvalid;
    wire        m_arready;
    wire [3:0]  m_rid;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rlast;
    wire        m_rvalid;
    wire        m_rready;

    wire [3:0]  m_awid;
    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire [1:0]  m_awlock;
    wire [3:0]  m_awcache;
    wire [2:0]  m_awprot;
    wire        m_awvalid;
    wire        m_awready;
    wire [3:0]  m_wid;
    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wlast;
    wire        m_wvalid;
    wire        m_wready;
    wire [3:0]  m_bid;
    wire [1:0]  m_bresp;
    wire        m_bvalid;
    wire        m_bready;

    wire        ws_valid;
    wire [31:0] debug0_wb_pc;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;
    wire [31:0] debug0_wb_rf_wdata;
    wire        debug_exception_valid;
    wire [5:0]  debug_exception_cause;
    wire [31:0] debug_exception_pc;
    wire        debug_ertn;
    wire [31:0] debug_gpr4;
    wire [31:0] debug_gpr7;
    wire [31:0] debug_gpr8;

    // Production-equivalent Loongson interrupt ordering and two-flop CDC.
    wire uart0_int;
    wire [5:0] int_async = {4'b0000, uart0_int, 1'b0};
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [5:0] int_sync_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [5:0] int_sync_cpu;
    wire [7:0] cpu_intrpt = {2'b00, int_sync_cpu};

    always_ff @(posedge cpu_clk or negedge cpu_aresetn) begin
        if (!cpu_aresetn) begin
            int_sync_meta <= 6'b0;
            int_sync_cpu <= 6'b0;
        end else begin
            int_sync_meta <= int_async;
            int_sync_cpu <= int_sync_meta;
        end
    end

    core_top u_core (
        .aclk(cpu_clk),
        .aresetn(cpu_aresetn),
        .intrpt(cpu_intrpt),

        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen),
        .arsize(m_arsize), .arburst(m_arburst), .arlock(m_arlock),
        .arcache(m_arcache), .arprot(m_arprot), .arvalid(m_arvalid),
        .arready(m_arready), .rid(m_rid), .rdata(m_rdata),
        .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid),
        .rready(m_rready),

        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen),
        .awsize(m_awsize), .awburst(m_awburst), .awlock(m_awlock),
        .awcache(m_awcache), .awprot(m_awprot), .awvalid(m_awvalid),
        .awready(m_awready), .wid(m_wid), .wdata(m_wdata),
        .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid),
        .wready(m_wready), .bid(m_bid), .bresp(m_bresp),
        .bvalid(m_bvalid), .bready(m_bready),

        .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0),
        .ws_valid(ws_valid),
        .debug0_wb_pc(debug0_wb_pc),
        .debug0_wb_rf_wen(debug0_wb_rf_wen),
        .debug0_wb_rf_wnum(debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata(debug0_wb_rf_wdata),
        .debug_exception_valid(debug_exception_valid),
        .debug_exception_cause(debug_exception_cause),
        .debug_exception_pc(debug_exception_pc),
        .debug_ertn(debug_ertn),
        .debug_gpr4(debug_gpr4), .debug_gpr7(debug_gpr7),
        .debug_gpr8(debug_gpr8)
    );

    // ------------------------------------------------------------------
    // CPU-clock ROM AXI slave. ICache refill requests use four-beat WRAP
    // bursts, while the Linux thread-info flags load is returned as zero.
    // ------------------------------------------------------------------
    logic rom_active;
    logic rom_rvalid;
    logic [3:0] rom_rid;
    logic [31:0] rom_rdata;
    logic [1:0] rom_rresp;
    logic rom_rlast;
    logic [31:0] rom_addr_q;
    logic [7:0] rom_beats_left;
    logic [1:0] rom_burst_q;
    logic [2:0] rom_size_q;
    logic [7:0] rom_len_q;
    wire rom_rready;
    wire rom_arready = !rom_active;
    wire ar_targets_uart = (m_araddr[31:16] == UART_BASE[31:16]);

    function automatic logic [31:0] rom_word(input logic [31:0] address);
        integer word_index;
        begin
            if (address >= RESET_PC
                && address < RESET_PC + ROM_WORDS * 4) begin
                word_index = (address - RESET_PC) >> 2;
                rom_word = rom[word_index];
            end else begin
                rom_word = 32'd0;
            end
        end
    endfunction

    function automatic logic [31:0] next_axi_addr(
        input logic [31:0] address,
        input logic [1:0] burst,
        input logic [7:0] len,
        input logic [2:0] size
    );
        logic [31:0] beat_bytes;
        logic [31:0] wrap_bytes;
        logic [31:0] wrap_mask;
        begin
            beat_bytes = 32'd1 << size;
            wrap_bytes = (len + 1'b1) << size;
            wrap_mask = wrap_bytes - 1'b1;
            case (burst)
                2'b00: next_axi_addr = address;
                2'b10: next_axi_addr = (address & ~wrap_mask)
                                           | ((address + beat_bytes) & wrap_mask);
                default: next_axi_addr = address + beat_bytes;
            endcase
        end
    endfunction

    always_ff @(posedge cpu_clk) begin
        if (!cpu_aresetn) begin
            rom_active <= 1'b0;
            rom_rvalid <= 1'b0;
            rom_rid <= 4'd0;
            rom_rdata <= 32'd0;
            rom_rresp <= 2'b00;
            rom_rlast <= 1'b0;
            rom_addr_q <= 32'd0;
            rom_beats_left <= 8'd0;
            rom_burst_q <= 2'b01;
            rom_size_q <= 3'd2;
            rom_len_q <= 8'd0;
        end else begin
            if (!rom_active && m_arvalid && m_arready
                && !ar_targets_uart) begin
                rom_active <= 1'b1;
                rom_rvalid <= 1'b0;
                rom_rid <= m_arid;
                rom_addr_q <= m_araddr;
                rom_beats_left <= m_arlen + 1'b1;
                rom_burst_q <= m_arburst;
                rom_size_q <= m_arsize;
                rom_len_q <= m_arlen;
            end

            if (rom_active && !rom_rvalid) begin
                rom_rvalid <= 1'b1;
                rom_rdata <= rom_word(rom_addr_q);
                rom_rresp <= 2'b00;
                rom_rlast <= rom_beats_left == 8'd1;
            end else if (rom_rvalid && rom_rready) begin
                if (rom_beats_left == 8'd1) begin
                    rom_active <= 1'b0;
                    rom_rvalid <= 1'b0;
                    rom_rlast <= 1'b0;
                end else begin
                    rom_addr_q <= next_axi_addr(
                        rom_addr_q, rom_burst_q, rom_len_q, rom_size_q);
                    rom_beats_left <= rom_beats_left - 1'b1;
                    rom_rdata <= rom_word(next_axi_addr(
                        rom_addr_q, rom_burst_q, rom_len_q, rom_size_q));
                    rom_rlast <= rom_beats_left == 8'd2;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Single-outstanding functional replacement for the FPGA AXI clock
    // converter. Only reads are needed by this bounded Linux replay.
    // ------------------------------------------------------------------
    logic uart_req_busy_cpu;
    logic uart_req_toggle_cpu;
    logic [3:0] uart_req_id_cpu;
    logic [31:0] uart_req_addr_cpu;
    logic [7:0] uart_req_len_cpu;
    logic [2:0] uart_req_size_cpu;
    logic [1:0] uart_req_burst_cpu;
    logic [1:0] uart_req_lock_cpu;
    logic [3:0] uart_req_cache_cpu;
    logic [2:0] uart_req_prot_cpu;

    logic uart_resp_toggle_uncore;
    logic [3:0] uart_resp_id_uncore;
    logic [31:0] uart_resp_data_uncore;
    logic [1:0] uart_resp_resp_uncore;
    logic uart_resp_last_uncore;
    logic uart_resp_meta_cpu;
    logic uart_resp_sync_cpu;
    logic uart_resp_seen_cpu;
    logic uart_rvalid_cpu;
    logic [3:0] uart_rid_cpu;
    logic [31:0] uart_rdata_cpu;
    logic [1:0] uart_rresp_cpu;
    logic uart_rlast_cpu;
    wire uart_rready_cpu;
    wire uart_arready_cpu = !uart_req_busy_cpu && !uart_rvalid_cpu;

    always_ff @(posedge cpu_clk or negedge cpu_aresetn) begin
        if (!cpu_aresetn) begin
            uart_req_busy_cpu <= 1'b0;
            uart_req_toggle_cpu <= 1'b0;
            uart_resp_meta_cpu <= 1'b0;
            uart_resp_sync_cpu <= 1'b0;
            uart_resp_seen_cpu <= 1'b0;
            uart_rvalid_cpu <= 1'b0;
            uart_rid_cpu <= 4'd0;
            uart_rdata_cpu <= 32'd0;
            uart_rresp_cpu <= 2'b00;
            uart_rlast_cpu <= 1'b0;
        end else begin
            uart_resp_meta_cpu <= uart_resp_toggle_uncore;
            uart_resp_sync_cpu <= uart_resp_meta_cpu;

            if (m_arvalid && m_arready && ar_targets_uart) begin
                uart_req_busy_cpu <= 1'b1;
                uart_req_id_cpu <= m_arid;
                uart_req_addr_cpu <= m_araddr;
                uart_req_len_cpu <= m_arlen;
                uart_req_size_cpu <= m_arsize;
                uart_req_burst_cpu <= m_arburst;
                uart_req_lock_cpu <= m_arlock;
                uart_req_cache_cpu <= m_arcache;
                uart_req_prot_cpu <= m_arprot;
                uart_req_toggle_cpu <= ~uart_req_toggle_cpu;
                if (m_arlen != 8'd0)
                    $fatal(1, "[FAIL] UART AXI read must be single-beat");
            end

            if (uart_resp_sync_cpu != uart_resp_seen_cpu) begin
                uart_resp_seen_cpu <= uart_resp_sync_cpu;
                uart_rvalid_cpu <= 1'b1;
                uart_rid_cpu <= uart_resp_id_uncore;
                uart_rdata_cpu <= uart_resp_data_uncore;
                uart_rresp_cpu <= uart_resp_resp_uncore;
                uart_rlast_cpu <= uart_resp_last_uncore;
            end

            if (uart_rvalid_cpu && uart_rready_cpu) begin
                uart_rvalid_cpu <= 1'b0;
                uart_req_busy_cpu <= 1'b0;
            end
        end
    end

    logic uart_req_meta_uncore;
    logic uart_req_sync_uncore;
    logic uart_req_seen_uncore;
    typedef enum logic [1:0] {UART_CDC_IDLE, UART_CDC_AR, UART_CDC_R}
        uart_cdc_state_t;
    uart_cdc_state_t uart_cdc_state;

    logic [3:0] p_arid;
    logic [31:0] p_araddr;
    logic [3:0] p_arlen;
    logic [2:0] p_arsize;
    logic [1:0] p_arburst;
    logic [1:0] p_arlock;
    logic [3:0] p_arcache;
    logic [2:0] p_arprot;
    logic p_arvalid;
    wire p_arready;
    wire [3:0] p_rid;
    wire [31:0] p_rdata;
    wire [1:0] p_rresp;
    wire p_rlast;
    wire p_rvalid;
    logic p_rready;

    always_ff @(posedge uncore_clk or negedge uncore_rst_n) begin
        if (!uncore_rst_n) begin
            uart_req_meta_uncore <= 1'b0;
            uart_req_sync_uncore <= 1'b0;
            uart_req_seen_uncore <= 1'b0;
            uart_resp_toggle_uncore <= 1'b0;
            uart_resp_id_uncore <= 4'd0;
            uart_resp_data_uncore <= 32'd0;
            uart_resp_resp_uncore <= 2'b00;
            uart_resp_last_uncore <= 1'b0;
            uart_cdc_state <= UART_CDC_IDLE;
            p_arvalid <= 1'b0;
            p_rready <= 1'b0;
        end else begin
            uart_req_meta_uncore <= uart_req_toggle_cpu;
            uart_req_sync_uncore <= uart_req_meta_uncore;

            case (uart_cdc_state)
                UART_CDC_IDLE: begin
                    if (uart_req_sync_uncore != uart_req_seen_uncore) begin
                        uart_req_seen_uncore <= uart_req_sync_uncore;
                        p_arid <= uart_req_id_cpu;
                        p_araddr <= uart_req_addr_cpu;
                        p_arlen <= uart_req_len_cpu[3:0];
                        p_arsize <= uart_req_size_cpu;
                        p_arburst <= uart_req_burst_cpu;
                        p_arlock <= uart_req_lock_cpu;
                        p_arcache <= uart_req_cache_cpu;
                        p_arprot <= uart_req_prot_cpu;
                        p_arvalid <= 1'b1;
                        uart_cdc_state <= UART_CDC_AR;
                    end
                end

                UART_CDC_AR: begin
                    if (p_arvalid && p_arready) begin
                        p_arvalid <= 1'b0;
                        p_rready <= 1'b1;
                        uart_cdc_state <= UART_CDC_R;
                    end
                end

                UART_CDC_R: begin
                    if (p_rvalid && p_rready) begin
                        uart_resp_id_uncore <= p_rid;
                        uart_resp_data_uncore <= p_rdata;
                        uart_resp_resp_uncore <= p_rresp;
                        uart_resp_last_uncore <= p_rlast;
                        uart_resp_toggle_uncore <= ~uart_resp_toggle_uncore;
                        p_rready <= 1'b0;
                        uart_cdc_state <= UART_CDC_IDLE;
                    end
                end

                default: uart_cdc_state <= UART_CDC_IDLE;
            endcase
        end
    end

    assign m_arready = ar_targets_uart ? uart_arready_cpu : rom_arready;
    assign m_rvalid = uart_rvalid_cpu | rom_rvalid;
    assign m_rid = uart_rvalid_cpu ? uart_rid_cpu : rom_rid;
    assign m_rdata = uart_rvalid_cpu ? uart_rdata_cpu : rom_rdata;
    assign m_rresp = uart_rvalid_cpu ? uart_rresp_cpu : rom_rresp;
    assign m_rlast = uart_rvalid_cpu ? uart_rlast_cpu : rom_rlast;
    assign uart_rready_cpu = m_rready & uart_rvalid_cpu;
    assign rom_rready = m_rready & rom_rvalid & !uart_rvalid_cpu;

    // This replay contains no stores. Any AXI write is a test/program bug.
    assign m_awready = 1'b0;
    assign m_wready = 1'b0;
    assign m_bid = 4'd0;
    assign m_bresp = 2'b00;
    assign m_bvalid = 1'b0;

    // ------------------------------------------------------------------
    // Actual uncore AXI-to-APB/UART path. DMA APB access is used only for
    // pre-boot UART setup; all interrupt-service reads come from the CPU AXI.
    // ------------------------------------------------------------------
    logic dma_rw;
    logic dma_psel;
    logic dma_enab;
    logic [19:0] dma_addr;
    logic dma_valid;
    logic [31:0] dma_wdata;
    wire [31:0] dma_rdata;
    wire dma_ready;
    wire dma_grant;
    logic serial_rx;

    axi2apb_misc u_apb (
        .clk(uncore_clk), .rst_n(uncore_rst_n),
        .axi_s_awid(4'd0), .axi_s_awaddr(32'd0), .axi_s_awlen(4'd0),
        .axi_s_awsize(3'd0), .axi_s_awburst(2'd0),
        .axi_s_awlock(2'd0), .axi_s_awcache(4'd0),
        .axi_s_awprot(3'd0), .axi_s_awvalid(1'b0),
        .axi_s_wid(4'd0), .axi_s_wdata(32'd0), .axi_s_wstrb(4'd0),
        .axi_s_wlast(1'b0), .axi_s_wvalid(1'b0),
        .axi_s_bready(1'b1),
        .axi_s_arid(p_arid), .axi_s_araddr(p_araddr),
        .axi_s_arlen(p_arlen), .axi_s_arsize(p_arsize),
        .axi_s_arburst(p_arburst), .axi_s_arlock(p_arlock),
        .axi_s_arcache(p_arcache), .axi_s_arprot(p_arprot),
        .axi_s_arvalid(p_arvalid), .axi_s_arready(p_arready),
        .axi_s_rid(p_rid), .axi_s_rdata(p_rdata), .axi_s_rresp(p_rresp),
        .axi_s_rlast(p_rlast), .axi_s_rvalid(p_rvalid),
        .axi_s_rready(p_rready),

        .apb_rw_dma(dma_rw), .apb_psel_dma(dma_psel),
        .apb_enab_dma(dma_enab), .apb_addr_dma(dma_addr),
        .apb_valid_dma(dma_valid), .apb_wdata_dma(dma_wdata),
        .apb_rdata_dma(dma_rdata), .apb_ready_dma(dma_ready),
        .dma_grant(dma_grant), .dma_req_o(), .dma_ack_i(1'b0),

        .uart0_txd_i(1'b1), .uart0_txd_o(), .uart0_txd_oe(),
        .uart0_rxd_i(serial_rx), .uart0_rxd_o(), .uart0_rxd_oe(),
        .uart0_rts_o(), .uart0_dtr_o(), .uart0_cts_i(1'b0),
        .uart0_dsr_i(1'b0), .uart0_dcd_i(1'b0), .uart0_ri_i(1'b0),
        .uart0_int(uart0_int)
    );

    task automatic dma_write_uart(
        input logic [2:0] reg_addr,
        input logic [7:0] value
    );
        begin
            @(negedge uncore_clk);
            dma_valid = 1'b1;
            dma_rw = 1'b1;
            dma_addr = UART_BASE[19:0] + reg_addr;
            dma_wdata = {24'd0, value};
            while (!dma_grant)
                @(negedge uncore_clk);
            dma_psel = 1'b1;
            dma_enab = 1'b1;
            @(posedge uncore_clk);
            @(negedge uncore_clk);
            if (!dma_ready)
                $fatal(1, "[FAIL] DMA APB UART setup did not complete");
            dma_valid = 1'b0;
            dma_psel = 1'b0;
            dma_enab = 1'b0;
            dma_rw = 1'b0;
            repeat (2) @(posedge uncore_clk);
        end
    endtask

    task automatic send_serial_byte(input logic [7:0] value);
        begin
            serial_rx = 1'b0;
            repeat (bit_cycles) @(posedge uncore_clk);
            for (int bit_index = 0; bit_index < 8; bit_index++) begin
                serial_rx = value[bit_index];
                repeat (bit_cycles) @(posedge uncore_clk);
            end
            serial_rx = 1'b1;
            repeat (bit_cycles) @(posedge uncore_clk);
        end
    endtask

    function automatic logic [31:0] enc_i12(
        input logic [11:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i12 = {6'h00, 4'ha, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_lu12i(
        input logic [19:0] immediate,
        input logic [4:0] rd
    );
        enc_lu12i = {6'h05, 1'b0, immediate, rd};
    endfunction

    function automatic logic [31:0] enc_csr(
        input logic [13:0] address,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_csr = {8'h04, address, rj, rd};
    endfunction

    function automatic logic [31:0] enc_ld_bu(
        input logic [11:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_ld_bu = {6'h0a, 4'h8, immediate, rj, rd};
    endfunction

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "[FAIL] %s", message);
    endtask

    integer exception_count;
    integer ertn_count;
    logic idle_seen;
    logic fifo_seen;
    logic uart_irq_seen;
    logic meta_seen;
    logic cpu_irq_seen;
    logic estat_seen;
    logic uart_irq_cleared;
    logic cpu_irq_cleared;
    integer cpu_uart_ar_count;
    integer cpu_uart_wb_count;
    integer uart_apb_read_count;
    integer uart_rbr_read_count;
    logic [31:0] first_uart_araddr;
    logic [2:0] first_uart_arsize;
    logic [31:0] first_uart_wb_paddr;
    logic [1:0] first_uart_wb_size;
    logic [7:0] first_uart_apb_addr;
    logic [7:0] first_uart_apb_data;
    logic [4:0] first_uart_apb_fifo_count;
    logic [7:0] first_uart_apb_fifo_head;
    time fifo_time;
    time uart_irq_time;
    time meta_time;
    time cpu_irq_time;
    time estat_time;
    time exception_time;

    always_ff @(posedge uncore_clk) begin
        if (!uncore_rst_n) begin
            fifo_seen <= 1'b0;
            uart_irq_seen <= 1'b0;
            uart_irq_cleared <= 1'b0;
            uart_apb_read_count <= 0;
            uart_rbr_read_count <= 0;
            first_uart_apb_addr <= 8'd0;
            first_uart_apb_data <= 8'd0;
            first_uart_apb_fifo_count <= 5'd0;
            first_uart_apb_fifo_head <= 8'd0;
            fifo_time <= 0;
            uart_irq_time <= 0;
        end else begin
            if (!fifo_seen && u_apb.uart0.regs.receiver.rf_count != 0) begin
                fifo_seen <= 1'b1;
                fifo_time <= $time;
            end
            if (!uart_irq_seen && uart0_int) begin
                uart_irq_seen <= 1'b1;
                uart_irq_time <= $time;
            end
            if (uart_irq_seen && !uart0_int)
                uart_irq_cleared <= 1'b1;

            // apb_uart0_* is after the production APB mux.  A completed
            // read at address zero is therefore the exact event that makes
            // uart_regs assert rf_pop/fifo_read.
            if (u_apb.apb_uart0_psel && u_apb.apb_uart0_enab
                && !u_apb.apb_uart0_rw) begin
                uart_apb_read_count <= uart_apb_read_count + 1;
                if (uart_apb_read_count == 0) begin
                    first_uart_apb_addr <= u_apb.apb_uart0_addr[7:0];
                    first_uart_apb_data <= u_apb.apb_uart0_datao[7:0];
                    first_uart_apb_fifo_count
                        <= u_apb.uart0.regs.receiver.rf_count;
                    first_uart_apb_fifo_head
                        <= u_apb.uart0.regs.rf_data_out[10:3];
                end
                if (u_apb.apb_uart0_addr[2:0] == 3'd0)
                    uart_rbr_read_count <= uart_rbr_read_count + 1;
                if (trace_uart)
                    $display("[TRACE][APB] t=%0t read addr=%02x data=%02x fifo_count=%0d fifo_head=%02x fifo_read=%0b rf_pop=%0b iir=%02x",
                             $time, u_apb.apb_uart0_addr[7:0],
                             u_apb.apb_uart0_datao[7:0],
                             u_apb.uart0.regs.receiver.rf_count,
                             u_apb.uart0.regs.rf_data_out[10:3],
                             u_apb.uart0.regs.fifo_read,
                             u_apb.uart0.regs.rf_pop,
                             {4'hc, u_apb.uart0.regs.iir});
            end
        end
    end

    always_ff @(posedge cpu_clk) begin
        if (!cpu_aresetn) begin
            exception_count <= 0;
            ertn_count <= 0;
            idle_seen <= 1'b0;
            meta_seen <= 1'b0;
            cpu_irq_seen <= 1'b0;
            estat_seen <= 1'b0;
            cpu_irq_cleared <= 1'b0;
            cpu_uart_ar_count <= 0;
            cpu_uart_wb_count <= 0;
            first_uart_araddr <= 32'd0;
            first_uart_arsize <= 3'd0;
            first_uart_wb_paddr <= 32'd0;
            first_uart_wb_size <= 2'd0;
            meta_time <= 0;
            cpu_irq_time <= 0;
            estat_time <= 0;
            exception_time <= 0;
        end else begin
            if (u_core.u_cpu.idle_waiting)
                idle_seen <= 1'b1;
            if (!meta_seen && int_sync_meta[1]) begin
                meta_seen <= 1'b1;
                meta_time <= $time;
            end
            if (!cpu_irq_seen && int_sync_cpu[1]) begin
                cpu_irq_seen <= 1'b1;
                cpu_irq_time <= $time;
            end
            if (!estat_seen && u_core.debug_priv_state_i[4*32 + 3]) begin
                estat_seen <= 1'b1;
                estat_time <= $time;
            end
            if (cpu_irq_seen && !int_sync_cpu[1])
                cpu_irq_cleared <= 1'b1;

            if (m_arvalid && m_arready && ar_targets_uart) begin
                cpu_uart_ar_count <= cpu_uart_ar_count + 1;
                if (cpu_uart_ar_count == 0) begin
                    first_uart_araddr <= m_araddr;
                    first_uart_arsize <= m_arsize;
                end
                if (trace_uart)
                    $display("[TRACE][AXI] t=%0t UART AR index=%0d addr=%08x size=%0d len=%0d",
                             $time, cpu_uart_ar_count, m_araddr,
                             m_arsize, m_arlen);
            end

            if (u_core.debug0_wb_valid_i
                && u_core.debug0_wb_mem_read_i
                && u_core.debug0_wb_mem_paddr_i[31:3]
                   == UART_BASE[31:3]) begin
                cpu_uart_wb_count <= cpu_uart_wb_count + 1;
                if (cpu_uart_wb_count == 0) begin
                    first_uart_wb_paddr <= u_core.debug0_wb_mem_paddr_i;
                    first_uart_wb_size <= u_core.debug0_wb_mem_size_i;
                end
                if (trace_uart)
                    $display("[TRACE][WB] t=%0t UART load index=%0d paddr=%08x size=%0d data=%08x",
                             $time, cpu_uart_wb_count,
                             u_core.debug0_wb_mem_paddr_i,
                             u_core.debug0_wb_mem_size_i,
                             debug0_wb_rf_wdata);
            end

            if (debug_exception_valid) begin
                exception_count <= exception_count + 1;
                if (exception_count == 0)
                    exception_time <= $time;
                if (debug_exception_cause !== 6'h00)
                    $fatal(1, "[FAIL] UART request did not enter as INT");
                if (u_core.debug_intr_no_i !== 32'h0000_0002)
                    $fatal(1, "[FAIL] UART request has the wrong intrNo");
                if (!u_core.debug_priv_state_i[4*32 + 3])
                    $fatal(1, "[FAIL] ESTAT.IS3 absent at interrupt entry");
                if (debug_exception_pc !== RESET_PC + 32'h60)
                    $fatal(1, "[FAIL] Linux IDLE wake saved the wrong ERA");
            end
            if (debug_ertn)
                ertn_count <= ertn_count + 1;

            if (m_awvalid || m_wvalid)
                $fatal(1, "[FAIL] bounded UART replay unexpectedly issued AXI write");
        end
    end

    initial begin
        cpu_clk = 1'b0;
        forever #5 cpu_clk = ~cpu_clk;
    end

    initial begin
        uncore_clk = 1'b0;
        uncore_half_ns = 7;
        uncore_phase_ns = 0;
        void'($value$plusargs("UNCORE_HALF_NS=%d", uncore_half_ns));
        void'($value$plusargs("UNCORE_PHASE_NS=%d", uncore_phase_ns));
        #(uncore_phase_ns);
        forever #(uncore_half_ns) uncore_clk = ~uncore_clk;
    end

    initial begin
        bit completed;
        logic [7:0] received_byte;

        uart_divisor = 4;
        uart_fcr = 8'h01;
        expected_iir = 8'hc4;
        rx_start_delay = 0;
        void'($value$plusargs("UART_DIVISOR=%d", uart_divisor));
        void'($value$plusargs("UART_FCR=%h", uart_fcr));
        void'($value$plusargs("EXPECTED_IIR=%h", expected_iir));
        void'($value$plusargs("RX_START_DELAY=%d", rx_start_delay));
        bit_cycles = uart_divisor * 16;

        cpu_aresetn = 1'b0;
        uncore_rst_n = 1'b0;
        serial_rx = 1'b1;
        dma_rw = 1'b0;
        dma_psel = 1'b0;
        dma_enab = 1'b0;
        dma_addr = 20'd0;
        dma_valid = 1'b0;
        dma_wdata = 32'd0;
        for (int index = 0; index < ROM_WORDS; index++)
            rom[index] = NOP;

        // Harness setup: EENTRY=RESET_PC+0x100, ECFG.HWI1 enabled, and
        // Linux's return address/thread-info state prepared.
        rom['h00 >> 2] = enc_lu12i(20'h1c000, 5'd10);
        rom['h04 >> 2] = enc_i12(12'h100, 5'd10, 5'd10);
        rom['h08 >> 2] = enc_csr(14'h00c, 5'd1, 5'd10);
        rom['h0c >> 2] = enc_i12(12'd8, 5'd0, 5'd5);
        rom['h10 >> 2] = enc_csr(14'h004, 5'd1, 5'd5);
        rom['h14 >> 2] = enc_lu12i(20'h1c000, 5'd1);
        rom['h18 >> 2] = enc_i12(12'h080, 5'd1, 5'd1);
        rom['h1c >> 2] = enc_i12(12'd0, 5'd0, 5'd2);
        rom['h20 >> 2] = LINUX_IRQ_ENABLE_LI;
        rom['h24 >> 2] = LINUX_IRQ_ENABLE_CSRXCHG;

        rom['h40 >> 2] = LINUX_IDLE_LOAD_FLAGS;
        rom['h44 >> 2] = NOP;
        rom['h48 >> 2] = LINUX_IDLE_AND_RESCHED;
        rom['h4c >> 2] = LINUX_IDLE_BNE_RESCHED;
        rom['h50 >> 2] = NOP;
        rom['h54 >> 2] = NOP;
        rom['h58 >> 2] = NOP;
        rom['h5c >> 2] = LINUX_IDLE;
        rom['h60 >> 2] = LINUX_RETURN;
        rom['h80 >> 2] = enc_i12(12'd1, 5'd0, 5'd31);
        rom['h84 >> 2] = 32'h5000_0000;

        // Exact Linux plat_irq_dispatch prefix followed by the minimal 8250
        // byte-read sequence used to classify and drain an RX interrupt.
        // Four RBR loads make the SecureCRT " ls\n" experiment observable
        // directly in GPR9..GPR12.
        rom['h100 >> 2] = LINUX_READ_ESTAT;
        rom['h104 >> 2] = LINUX_READ_ECFG;
        rom['h108 >> 2] = LINUX_MASK_PENDING;
        rom['h10c >> 2] = enc_lu12i(20'h1fe00, 5'd6);
        rom['h110 >> 2] = enc_i12(12'h1e0, 5'd6, 5'd6);
        rom['h114 >> 2] = enc_ld_bu(12'd2, 5'd6, 5'd7); // IIR
        rom['h118 >> 2] = enc_ld_bu(12'd5, 5'd6, 5'd8); // LSR
        rom['h11c >> 2] = enc_ld_bu(12'd0, 5'd6, 5'd9); // RBR
        rom['h120 >> 2] = enc_ld_bu(12'd0, 5'd6, 5'd10); // RBR
        rom['h124 >> 2] = enc_ld_bu(12'd0, 5'd6, 5'd11); // RBR
        rom['h128 >> 2] = enc_ld_bu(12'd0, 5'd6, 5'd12); // RBR
        for (int index = 'h12c >> 2; index < ('h140 >> 2); index++)
            rom[index] = NOP;
        rom['h140 >> 2] = ERTN;

        repeat (8) @(posedge uncore_clk);
        @(negedge uncore_clk);
        uncore_rst_n = 1'b1;

        trace_uart = $test$plusargs("TRACE_UART");
        expect_first_byte_loss
            = $test$plusargs("EXPECT_FIRST_BYTE_LOSS");

        // 8N1, programmable divisor and FIFO/trigger selection. Keep IER
        // masked while receiving the four-byte terminal burst, then enable
        // it only after all bytes are resident. This removes handler/serial
        // timing as a variable while preserving the real RX/FIFO datapath.
        dma_write_uart(3'd3, 8'h83);
        dma_write_uart(3'd0, uart_divisor[7:0]);
        dma_write_uart(3'd1, 8'h00);
        dma_write_uart(3'd3, 8'h03);
        dma_write_uart(3'd2, uart_fcr[7:0]);
        dma_write_uart(3'd1, 8'h00);

        repeat (4) @(posedge cpu_clk);
        @(negedge cpu_clk);
        cpu_aresetn = 1'b1;

        for (int cycle = 0; cycle < 5000; cycle++) begin
            @(posedge cpu_clk);
            if (u_core.u_cpu.idle_waiting)
                break;
        end
        check(u_core.u_cpu.idle_waiting,
              "released Linux instruction stream did not enter IDLE");

        repeat (rx_start_delay) @(posedge uncore_clk);
        send_serial_byte(8'h20);
        send_serial_byte(8'h6c);
        send_serial_byte(8'h73);
        send_serial_byte(8'h0a);
        check(u_apb.uart0.regs.receiver.rf_count == 4,
              "four-byte terminal burst was not fully resident in RX FIFO");
        dma_write_uart(3'd1, 8'h05);

        completed = 1'b0;
        for (int cycle = 0; cycle < 100000; cycle++) begin
            @(posedge cpu_clk);
            if (u_core.u_cpu.u_regfile.regs[31] == 32'd1
                && ertn_count == 1) begin
                completed = 1'b1;
                break;
            end
        end
        check(completed, "end-to-end Linux UART IRQ replay timed out");
        repeat (200) @(posedge cpu_clk);

        received_byte = u_core.u_cpu.u_regfile.regs[9][7:0];
        check(fifo_seen, "serial byte never reached UART RX FIFO");
        check(uart_irq_seen, "UART never asserted uart0_int");
        check(meta_seen, "uart0_int never reached int_sync_meta[1]");
        check(cpu_irq_seen, "uart0_int never reached int_sync_cpu[1]");
        check(estat_seen, "synchronized UART IRQ never reached ESTAT.IS3");
        check(exception_count == 1,
              "UART level must cause exactly one CPU interrupt entry");
        check(debug_gpr4 == 32'h0000_0008,
              "Linux plat_irq_dispatch did not isolate ESTAT.IS3");
        check(debug_gpr7[7:0] == expected_iir[7:0],
              "Linux 8250 IIR read returned the wrong cause");
        check(debug_gpr8[0], "Linux 8250 LSR read lost Data Ready");

        if (expect_first_byte_loss) begin
            check(first_uart_wb_paddr == UART_BASE + 32'd2
                  && first_uart_wb_size == 2'd0,
                  "architectural IIR operation was not the expected byte load");
            check(first_uart_araddr == UART_BASE,
                  "first UART AXI read was not silently word-aligned");
            check(first_uart_arsize == 3'd2,
                  "first UART AXI read was not expanded to a word");
            check(first_uart_apb_addr == UART_BASE[7:0],
                  "expanded IIR transaction did not start at RBR");
            check(first_uart_apb_fifo_count == 5'd4,
                  "expanded IIR transaction did not see all four bytes");
            check(first_uart_apb_fifo_head == 8'h20,
                  "expanded IIR transaction did not consume the padding byte");
            check(u_core.u_cpu.u_regfile.regs[9][7:0] == 8'h6c
                  && u_core.u_cpu.u_regfile.regs[10][7:0] == 8'h73
                  && u_core.u_cpu.u_regfile.regs[11][7:0] == 8'h0a,
                  "CPU did not reproduce the one-byte-left-shift signature");
            $display("[OBSERVED] UART_FIRST_BYTE_LOSS_BY_IIR wb_addr=%08x wb_size=%0d axi_addr=%08x axi_size=%0d first_apb_addr=%02x fifo_before=%0d head=%02x rbr=%02x,%02x,%02x,%02x",
                     first_uart_wb_paddr, first_uart_wb_size,
                     first_uart_araddr, first_uart_arsize,
                     first_uart_apb_addr, first_uart_apb_fifo_count,
                     first_uart_apb_fifo_head,
                     u_core.u_cpu.u_regfile.regs[9][7:0],
                     u_core.u_cpu.u_regfile.regs[10][7:0],
                     u_core.u_cpu.u_regfile.regs[11][7:0],
                     u_core.u_cpu.u_regfile.regs[12][7:0]);
        end else begin
            check(first_uart_araddr == UART_BASE + 32'd2,
                  "IIR byte load lost its byte address before AXI");
            check(first_uart_arsize == 3'd0,
                  "IIR byte load lost its byte size before AXI");
            check(received_byte == 8'h20
                  && u_core.u_cpu.u_regfile.regs[10][7:0] == 8'h6c
                  && u_core.u_cpu.u_regfile.regs[11][7:0] == 8'h73
                  && u_core.u_cpu.u_regfile.regs[12][7:0] == 8'h0a,
                  "Linux 8250 RBR reads did not preserve the four-byte burst");
        end
        check(uart_irq_cleared, "RBR service did not clear uart0_int");
        check(cpu_irq_cleared,
              "cleared UART level did not propagate through CPU CDC");
        check(!uart0_int && !int_sync_meta[1] && !int_sync_cpu[1],
              "UART IRQ path remained asserted after handler service");
        check(ertn_count == 1, "Linux handler must execute exactly one ERTN");
        check(u_core.u_cpu.u_regfile.regs[31] == 32'd1,
              "ERTN did not resume the Linux idle caller");
        check(fifo_time <= uart_irq_time,
              "UART interrupt preceded RX FIFO data");
        // uart_irq_time is observed on uncore_clk, so the CPU-side meta flop
        // can legitimately see the already-raised level before that monitor's
        // next sample. Allow one uncore cycle of observer skew while still
        // requiring the two CPU CDC stages to be ordered.
        check(uart_irq_time <= meta_time + 2 * uncore_half_ns
              && meta_time <= cpu_irq_time,
              "external IRQ did not traverse the CDC stages in order");
        check(cpu_irq_time <= estat_time && estat_time <= exception_time,
              "CPU IRQ did not reach ESTAT and interrupt entry in order");

        if (!expect_first_byte_loss)
            $display("[PASS] LA32R Linux UART IRQ end-to-end replay fcr=%02x iir=%02x phase=%0dns rx_delay=%0d",
                     uart_fcr[7:0], debug_gpr7[7:0],
                     uncore_phase_ns, rx_start_delay);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "[FAIL] global simulation timeout");
    end
endmodule
