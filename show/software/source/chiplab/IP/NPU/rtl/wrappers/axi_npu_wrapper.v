// -----------------------------------------------------------------------------
// AXI slave wrapper for npu_top_with_dma.
//
// Address window is supplied by the SoC crossbar. This wrapper uses low offsets:
//   0x0000 CTRL        bit0=start, bit1=soft_reset, bit2=irq_en,
//                      bit3=clear_frame, bit4=clear_status
//   0x0004 STATUS      bit0=busy, bit1=done, bit2=error, bit3=frame_full,
//                      bit4=irq_pending, bits[10:8]=stream_state,
//                      bits[31:16]=frame byte count
//   0x0008 FRAME_DATA  write-only FIFO style input, one 32-bit word = 4 pixels
//   0x000c FRAME_COUNT current frame byte count; write 0 to clear when idle
//   0x0010 BBOX0       bbox[31:0]
//   0x0014 BBOX1       {frame_id[15:0], 7'b0, bbox_valid, bbox[39:32]}
//   0x0018 IRQ_STATUS  bit0=done_irq
//   0x001c IRQ_CLR     write bit0=1 to clear irq_pending
//   0x0020 DMA_DEBUG0  {dma_base_addr[15:0], dma_length[15:0]}
//   0x0024 DMA_DEBUG1  {29'b0, dma_error_seen, dma_done_seen, dma_req_seen}
//   0x0028 PERF_CYCLE  cycles from accepted start to bbox_valid
//   0x002c SCRATCH_BASE physical byte base of NPU scratch buffer
//   0x0030 PARAM_BASE  physical byte base of packed NPU parameter image
//   0x0034 LAYER_COUNT number of network layers (1..32, descriptor mode)
//   0x0038 DESC_CTRL   bit0=desc_mode_en, write 1 before loading descriptors
//   0x003c DESC_STATUS {desc_write_count[15:0], 5'b0, last_layer[4:0],
//                       1'b0, last_word[2:0], desc_error, desc_ready}
//   0x0040 AXI_DBG0    {pool_aw_count[15:0], pool_ar_count[15:0]}
//   0x0044 AXI_DBG1    {weight_ar_count[15:0], b_count[15:0]}
//   0x0048 AXI_DBG2    {wlast_count[15:0], rlast_count[15:0]}
//   0x004c AXI_LAST_AW last accepted AXI master AW address
//   0x0050 AXI_LAST_AR last accepted AXI master AR address
//   0x0054 AXI_LAST_W  last accepted AXI master W data
//   0x0058 AXI_LAST_R  last accepted AXI master R data
//   0x005c AXI_DBG3    last response/len/error snapshot
//   0x0060 AXI_DBG4    live AXI master handshake snapshot
//   0x0064 POOL_DBG0   {capture_sessions[15:0], replay_sessions[15:0]}
//   0x0068 POOL_DBG1   pool reorder enabled input-valid count
//   0x006c POOL_DBG2   pool reorder accepted-write count
//   0x0070 POOL_DBG3   pool reorder replay-output count
//   0x0074 POOL_DBG4   input-valid while input_ready=0 count
//   0x0078 POOL_DBG5   input-valid dropped by backend/replay count
//   0x007c POOL_DBG6   {fifo_max[15:0], fifo_level[15:0]}
//   0x0080 POOL_DBG7   first drop {width,height,x,y}
//   0x0084 POOL_DBG8   {first_drop_cap_cnt[15:0], last_cap_total[15:0]}
//   0x0088 POOL_DBG9   live pool reorder flags
//   0x008c POOL_DBG10  last capture session XOR checksum
//   0x0090 POOL_DBG11  last replay session XOR checksum
//   0x0094 POOL_DBG12  last session {width,height,total}
//   0x0098 POOL_DBG13  last capture {first_addr,last_addr}
//   0x009c POOL_DBG14  last replay {first_addr,last_addr}
//   0x00a0 POOL_DBG15  last capture first record data XOR
//   0x00a4 POOL_DBG16  last capture last record data XOR
//   0x00a8 POOL_DBG17  last replay first record data XOR
//   0x00ac POOL_DBG18  last replay last record data XOR
//   0x00b0 PARAM_DBG0  {param_dma_req_count[15:0], done_count[15:0]}
//   0x00b4 PARAM_DBG1  {last_weight_base[15:0], last_weight_length[15:0]}
//   0x00b8 PARAM_DBG2  {last_bias_base[15:0], 14'b0, last_kernel_size[1:0]}
//   0x00bc PARAM_DBG3  {last_weight_words[15:0], last_bias_words[15:0]}
//   0x00c0 PARAM_DBG4  total weight AXI R data XOR
//   0x00c4 PARAM_DBG5  total bias AXI R data XOR
//   0x00c8 PARAM_DBG6  last request weight AXI R data XOR
//   0x00cc PARAM_DBG7  last request bias AXI R data XOR
//   0x00d0 PARAM_DBG8  last request emitted weight-buffer XOR
//   0x00d4 PARAM_DBG9  last request emitted bias-buffer XOR
//   0x00d8 PARAM_DBG10 last request first weight AXI data
//   0x00dc PARAM_DBG11 last request last weight AXI data
//   0x00e0 PARAM_DBG12 last request first bias AXI data
//   0x00e4 PARAM_DBG13 last request last bias AXI data
//   0x00e8 PARAM_DBG14 last request first weight AXI address
//   0x00ec PARAM_DBG15 last request last weight AXI address
//   0x00f0 PARAM_DBG16 last request first bias AXI address
//   0x00f4 PARAM_DBG17 last request last bias AXI address
//   0x00f8 PARAM_DBG18 live DMA state snapshot
//   0x00fc LAYER_DBG_SEL selected layer for LAYER_DBG readback
//   0x0100 LAYER_DBG0  selected layer output record count
//   0x0104 LAYER_DBG1  selected layer folded output XOR
//   0x0108 LAYER_DBG2  selected layer output byte sum
//   0x010c LAYER_DBG3  selected layer first folded output sample
//   0x0110 LAYER_DBG4  selected layer first {oc_group,y,x,wr_addr}
//   0x0114 LAYER_DBG5  selected layer last folded output sample
//   0x0118 LAYER_DBG6  selected layer last {oc_group,y,x,wr_addr}
//   0x011c LAYER_DBG7  selected layer live state snapshot
//     LAYER_DBG_SEL[5:4]=1: DBG0=input count, DBG1=input XOR, DBG2=first, DBG3=last
//     LAYER_DBG_SEL[5:4]=2: DBG1=PE/MAC XOR
//     LAYER_DBG_SEL[5:4]=3: DBG0=bias XOR, DBG1=quant XOR
//     LAYER_DBG_SEL=0x40|L: DBG0=weight count, DBG1=weight XOR, DBG2=first, DBG3=last
//     LAYER_DBG_SEL=0x50|L: DBG0..5=input/linebuf/PE/bias/quant/output counts,
//                          DBG6/7=live BCU state/progress
//   0x0120 RESULT_CTRL bit0=enable, bit1=clear_status
//   0x0124 RESULT_STATUS {write_error, done, busy}
//   0x0128 RESULT_BASE physical byte base of final tensor result
//   0x012c RESULT_BYTES max result bytes to write
//   0x0130 RESULT_WRITE_BYTES actual bytes written
//   0x0134 RESULT_CHECKSUM folded XOR of written 32-bit words
//   0x0138 RESULT_LAST_ADDR last result AXI AW address
//   0x013c RESULT_SHAPE0 {height[15:0], width[15:0]}
//   0x0140 RESULT_SHAPE1 {dtype[31:24], layout[23:16], channels[15:0]}
//   0x0144 INPUT_PRELOAD_CTRL bit0=enable, bit1=target_buffer, bit2=clear_count,
//                             bit3=packed_cross_bank, bit4=skip_lbp_load
//   0x0148 INPUT_PRELOAD_STATUS bit0=idle_allowed, bit1=done, bit2=error,
//                               bit3=target_unsupported, bit4=overflow,
//                               bits[31:16]=written_bytes_low16
//   0x014c INPUT_PRELOAD_BYTES expected preload bytes
//   0x0150 INPUT_PRELOAD_COUNT written preload bytes
//   0x0154 INPUT_PRELOAD_DATA write-only FIFO style packed input data
//   0x0158 HW_CAPS bit0=AXI DMA, bit1=packed preload,
//                  bit2=result writeback, bit3=descriptor RAM
//   0x015c HW_ABI current hardware ABI version
//
// Descriptor RAM aperture at 0x6000..0x63ff:
//   address = 0x6000 + layer * 32 + word * 4
//   layer = (addr - 0x6000) >> 5, word = ((addr - 0x6000) >> 2) & 0x7
//   Total: 32 layers × 8 words × 4 bytes = 1024 bytes
//
// The frame memory aperture at 0x1000..0x5aff accepts packed 32-bit LBP words.
// Software should write 4800 words for one 160x120 frame, then set CTRL.start.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef NPU_PARAMS_HEX
  `define NPU_PARAMS_HEX "rtl/ip/npu_ip/params/npu_params.hex"
`endif

module axi_npu_wrapper #(
    parameter PARAMS_HEX      = `NPU_PARAMS_HEX,
    parameter ROM_DEPTH       = 21098,
    parameter FRAME_PIXELS    = 19200,
    parameter FRAME_WORDS     = 4800,
    parameter FRAME_WORD_AW   = 13,
    parameter START_DELAY_CYC = 4,
    parameter USE_NPU_STUB    = 0,
    parameter USE_AXI_DMA     = 0,
    parameter USE_POOL_REORDER_AXI = 1,
    parameter POOL_AXI_BURST_BEATS = 4,
    parameter [31:0] SCRATCH_BASE_RESET = 32'h1c100000,
    parameter [31:0] RESULT_BASE_RESET = 32'h1c380000,
    parameter [31:0] RESULT_BYTES_RESET = 32'd16
)(
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [4 :0]  s_awid,
    input  wire [31:0]  s_awaddr,
    input  wire [7 :0]  s_awlen,
    input  wire [2 :0]  s_awsize,
    input  wire [1 :0]  s_awburst,
    input  wire         s_awlock,
    input  wire [3 :0]  s_awcache,
    input  wire [2 :0]  s_awprot,
    input  wire         s_awvalid,
    output wire         s_awready,

    input  wire [31:0]  s_wdata,
    input  wire [3 :0]  s_wstrb,
    input  wire         s_wlast,
    input  wire         s_wvalid,
    output wire         s_wready,

    output reg  [4 :0]  s_bid,
    output wire [1 :0]  s_bresp,
    output reg          s_bvalid,
    input  wire         s_bready,

    input  wire [4 :0]  s_arid,
    input  wire [31:0]  s_araddr,
    input  wire [7 :0]  s_arlen,
    input  wire [2 :0]  s_arsize,
    input  wire [1 :0]  s_arburst,
    input  wire         s_arlock,
    input  wire [3 :0]  s_arcache,
    input  wire [2 :0]  s_arprot,
    input  wire         s_arvalid,
    output wire         s_arready,

    output reg  [4 :0]  s_rid,
    output reg  [31:0]  s_rdata,
    output wire [1 :0]  s_rresp,
    output reg          s_rlast,
    output reg          s_rvalid,
    input  wire         s_rready,

    output wire         npu_irq,

    output wire [3 :0]  m_axi_arid,
    output wire [31:0]  m_axi_araddr,
    output wire [7 :0]  m_axi_arlen,
    output wire [2 :0]  m_axi_arsize,
    output wire [1 :0]  m_axi_arburst,
    output wire         m_axi_arlock,
    output wire [3 :0]  m_axi_arcache,
    output wire [2 :0]  m_axi_arprot,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [3 :0]  m_axi_rid,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1 :0]  m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    output wire [3 :0]  m_axi_awid,
    output wire [31:0]  m_axi_awaddr,
    output wire [7 :0]  m_axi_awlen,
    output wire [2 :0]  m_axi_awsize,
    output wire [1 :0]  m_axi_awburst,
    output wire         m_axi_awlock,
    output wire [3 :0]  m_axi_awcache,
    output wire [2 :0]  m_axi_awprot,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [3 :0]  m_axi_wid,
    output wire [31:0]  m_axi_wdata,
    output wire [3 :0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [3 :0]  m_axi_bid,
    input  wire [1 :0]  m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready
);

    localparam [7:0] REG_CTRL        = 8'h00;
    localparam [7:0] REG_STATUS      = 8'h04;
    localparam [7:0] REG_FRAME_DATA  = 8'h08;
    localparam [7:0] REG_FRAME_COUNT = 8'h0c;
    localparam [7:0] REG_BBOX0       = 8'h10;
    localparam [7:0] REG_BBOX1       = 8'h14;
    localparam [7:0] REG_IRQ_STATUS  = 8'h18;
    localparam [7:0] REG_IRQ_CLR     = 8'h1c;
    localparam [7:0] REG_DMA_DEBUG0  = 8'h20;
    localparam [7:0] REG_DMA_DEBUG1  = 8'h24;
    localparam [7:0] REG_PERF_CYCLE  = 8'h28;
    localparam [7:0] REG_SCRATCH_BASE = 8'h2c;
    localparam [7:0] REG_PARAM_BASE  = 8'h30;
    localparam [7:0] REG_LAYER_COUNT = 8'h34;
    localparam [7:0] REG_DESC_CTRL   = 8'h38;
    localparam [7:0] REG_DESC_STATUS = 8'h3c;
    localparam [7:0] REG_AXI_DBG0    = 8'h40;
    localparam [7:0] REG_AXI_DBG1    = 8'h44;
    localparam [7:0] REG_AXI_DBG2    = 8'h48;
    localparam [7:0] REG_AXI_LAST_AW = 8'h4c;
    localparam [7:0] REG_AXI_LAST_AR = 8'h50;
    localparam [7:0] REG_AXI_LAST_W  = 8'h54;
    localparam [7:0] REG_AXI_LAST_R  = 8'h58;
    localparam [7:0] REG_AXI_DBG3    = 8'h5c;
    localparam [7:0] REG_AXI_DBG4    = 8'h60;
    localparam [7:0] REG_POOL_DBG0   = 8'h64;
    localparam [7:0] REG_POOL_DBG1   = 8'h68;
    localparam [7:0] REG_POOL_DBG2   = 8'h6c;
    localparam [7:0] REG_POOL_DBG3   = 8'h70;
    localparam [7:0] REG_POOL_DBG4   = 8'h74;
    localparam [7:0] REG_POOL_DBG5   = 8'h78;
    localparam [7:0] REG_POOL_DBG6   = 8'h7c;
    localparam [7:0] REG_POOL_DBG7   = 8'h80;
    localparam [7:0] REG_POOL_DBG8   = 8'h84;
    localparam [7:0] REG_POOL_DBG9   = 8'h88;
    localparam [7:0] REG_POOL_DBG10  = 8'h8c;
    localparam [7:0] REG_POOL_DBG11  = 8'h90;
    localparam [7:0] REG_POOL_DBG12  = 8'h94;
    localparam [7:0] REG_POOL_DBG13  = 8'h98;
    localparam [7:0] REG_POOL_DBG14  = 8'h9c;
    localparam [7:0] REG_POOL_DBG15  = 8'ha0;
    localparam [7:0] REG_POOL_DBG16  = 8'ha4;
    localparam [7:0] REG_POOL_DBG17  = 8'ha8;
    localparam [7:0] REG_POOL_DBG18  = 8'hac;
    localparam [7:0] REG_PARAM_DBG0  = 8'hb0;
    localparam [7:0] REG_PARAM_DBG1  = 8'hb4;
    localparam [7:0] REG_PARAM_DBG2  = 8'hb8;
    localparam [7:0] REG_PARAM_DBG3  = 8'hbc;
    localparam [7:0] REG_PARAM_DBG4  = 8'hc0;
    localparam [7:0] REG_PARAM_DBG5  = 8'hc4;
    localparam [7:0] REG_PARAM_DBG6  = 8'hc8;
    localparam [7:0] REG_PARAM_DBG7  = 8'hcc;
    localparam [7:0] REG_PARAM_DBG8  = 8'hd0;
    localparam [7:0] REG_PARAM_DBG9  = 8'hd4;
    localparam [7:0] REG_PARAM_DBG10 = 8'hd8;
    localparam [7:0] REG_PARAM_DBG11 = 8'hdc;
    localparam [7:0] REG_PARAM_DBG12 = 8'he0;
    localparam [7:0] REG_PARAM_DBG13 = 8'he4;
    localparam [7:0] REG_PARAM_DBG14 = 8'he8;
    localparam [7:0] REG_PARAM_DBG15 = 8'hec;
    localparam [7:0] REG_PARAM_DBG16 = 8'hf0;
    localparam [7:0] REG_PARAM_DBG17 = 8'hf4;
    localparam [7:0] REG_PARAM_DBG18 = 8'hf8;
    localparam [7:0] REG_LAYER_DBG_SEL = 8'hfc;
    localparam [7:0] REG_RESULT_CTRL  = 8'h20;
    localparam [7:0] REG_RESULT_STATUS = 8'h24;
    localparam [7:0] REG_RESULT_BASE  = 8'h28;
    localparam [7:0] REG_RESULT_BYTES = 8'h2c;
    localparam [7:0] REG_RESULT_WRITE_BYTES = 8'h30;
    localparam [7:0] REG_RESULT_CHECKSUM = 8'h34;
    localparam [7:0] REG_RESULT_LAST_ADDR = 8'h38;
    localparam [7:0] REG_RESULT_SHAPE0 = 8'h3c;
    localparam [7:0] REG_RESULT_SHAPE1 = 8'h40;
    localparam [7:0] REG_INPUT_PRELOAD_CTRL   = 8'h44;
    localparam [7:0] REG_INPUT_PRELOAD_STATUS = 8'h48;
    localparam [7:0] REG_INPUT_PRELOAD_BYTES  = 8'h4c;
    localparam [7:0] REG_INPUT_PRELOAD_COUNT  = 8'h50;
    localparam [7:0] REG_INPUT_PRELOAD_DATA   = 8'h54;
    localparam [7:0] REG_HW_CAPS              = 8'h58;
    localparam [7:0] REG_HW_ABI               = 8'h5c;
    localparam [7:0] REG_LAYER_DBG0  = 8'h00;
    localparam [7:0] REG_LAYER_DBG1  = 8'h04;
    localparam [7:0] REG_LAYER_DBG2  = 8'h08;
    localparam [7:0] REG_LAYER_DBG3  = 8'h0c;
    localparam [7:0] REG_LAYER_DBG4  = 8'h10;
    localparam [7:0] REG_LAYER_DBG5  = 8'h14;
    localparam [7:0] REG_LAYER_DBG6  = 8'h18;
    localparam [7:0] REG_LAYER_DBG7  = 8'h1c;

    localparam [15:0] FRAME_MEM_BASE   = 16'h1000;
    localparam [15:0] FRAME_MEM_LIMIT  = 16'h5b00; // 0x1000 + 19200
    localparam [15:0] DESC_RAM_BASE    = 16'h6000;
    localparam [15:0] DESC_RAM_LIMIT   = 16'h6400; // 0x6000 + 1024
    localparam [15:0] FRAME_PIXELS_L  = FRAME_PIXELS;
    localparam [7:0]  START_DELAY_L   = START_DELAY_CYC;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_PRIME = 3'd1;
    localparam [2:0] ST_LOAD  = 3'd2;
    localparam [2:0] ST_SEND  = 3'd3;
    localparam [2:0] ST_WAIT  = 3'd4;

    wire _unused_axi_inputs = s_awlock ^ s_awcache[0] ^ s_awprot[0] ^
                              s_arlock ^ s_arcache[0] ^ s_arprot[0];

    // -------------------------------------------------------------------------
    // AXI write channel
    // -------------------------------------------------------------------------
    reg        wr_active;
    reg [4:0]  wr_id;
    reg [31:0] wr_addr;
    reg [7:0]  wr_len;
    reg [2:0]  wr_size;
    reg [1:0]  wr_burst;
    reg [7:0]  wr_beat;
    reg        preload_word_busy;
    reg        preload_resp_pending;
    reg [4:0]  preload_resp_id;

    assign s_awready = !wr_active && !s_bvalid && !preload_resp_pending;
    assign s_wready  = wr_active && !s_bvalid && !preload_word_busy;
    assign s_bresp   = 2'b00;

    wire aw_fire = s_awvalid && s_awready;
    wire w_fire  = s_wvalid && s_wready;
    wire b_fire  = s_bvalid && s_bready;
    wire wr_last = (wr_beat == wr_len) || s_wlast;

    wire [31:0] wr_addr_next =
        (wr_burst == 2'b01) ? (wr_addr + (32'd1 << wr_size)) : wr_addr;
    wire w_fire_input_preload_data =
        w_fire &&
        (wr_addr[15:8] == 8'h01) &&
        (wr_addr[7:0] == REG_INPUT_PRELOAD_DATA);

    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_active <= 1'b0;
            wr_id     <= 5'd0;
            wr_addr   <= 32'd0;
            wr_len    <= 8'd0;
            wr_size   <= 3'd0;
            wr_burst  <= 2'd0;
            wr_beat   <= 8'd0;
            s_bid     <= 5'd0;
            s_bvalid  <= 1'b0;
            preload_resp_pending <= 1'b0;
            preload_resp_id      <= 5'd0;
        end else begin
            if (aw_fire) begin
                wr_active <= 1'b1;
                wr_id     <= s_awid;
                wr_addr   <= s_awaddr;
                wr_len    <= s_awlen;
                wr_size   <= s_awsize;
                wr_burst  <= s_awburst;
                wr_beat   <= 8'd0;
            end else if (w_fire && !wr_last) begin
                wr_addr <= wr_addr_next;
                wr_beat <= wr_beat + 8'd1;
            end

            if (w_fire && wr_last) begin
                wr_active <= 1'b0;
                s_bid     <= wr_id;
                if (w_fire_input_preload_data) begin
                    preload_resp_pending <= 1'b1;
                    preload_resp_id      <= wr_id;
                end else begin
                    s_bvalid <= 1'b1;
                end
            end else if (preload_resp_pending && !preload_word_busy && !s_bvalid) begin
                preload_resp_pending <= 1'b0;
                s_bid                <= preload_resp_id;
                s_bvalid             <= 1'b1;
            end else if (b_fire) begin
                s_bvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI read channel
    // -------------------------------------------------------------------------
    reg        rd_active;
    reg [31:0] rd_addr;
    reg [7:0]  rd_len;
    reg [2:0]  rd_size;
    reg [1:0]  rd_burst;
    reg [7:0]  rd_beat;

    assign s_arready = !rd_active && !s_rvalid;
    assign s_rresp   = 2'b00;

    wire ar_fire = s_arvalid && s_arready;
    wire r_fire  = s_rvalid && s_rready;

    wire [31:0] rd_addr_next =
        (rd_burst == 2'b01) ? (rd_addr + (32'd1 << rd_size)) : rd_addr;

    // -------------------------------------------------------------------------
    // Register block, frame input memory, and stream state declarations.
    // Keep these before read_reg for VCS compatibility.
    // -------------------------------------------------------------------------
`ifdef NPU_USE_XPM_BRAM
    wire [31:0] frame_mem_rdata;
`else
    (* ram_style = "block" *) reg [31:0] frame_mem [0:FRAME_WORDS-1];
    reg [31:0] frame_mem_rdata;
`endif

    reg        irq_en;
    reg        busy_reg;
    reg        done_reg;
    reg        error_reg;
    reg        irq_pending;
    reg        bbox_valid_latched;
    reg        dma_req_seen;
    reg        dma_done_seen;
    reg        dma_error_seen;
    reg [15:0] frame_count;
    reg [15:0] frame_id;
    reg [39:0] bbox_data;
    reg [31:0] perf_cycle;
    reg [31:0] param_base_addr;
    reg [31:0] scratch_base_addr;
    reg        result_enable;
    reg [31:0] result_base_addr;
    reg [31:0] result_max_bytes;
    reg [31:0] result_shape0;
    reg [31:0] result_shape1;
    reg        input_preload_enable;
    reg        input_preload_target;
    reg        input_preload_packed;
    reg        input_preload_skip_lbp;
    reg        input_preload_error;
    reg        input_preload_target_unsupported;
    reg        input_preload_overflow;
    reg [31:0] input_preload_bytes;
    reg [31:0] input_preload_count;
    reg [31:0] preload_word_data;
    reg [3:0]  preload_word_strb;
    reg [1:0]  preload_byte_idx;
    reg [15:0] axi_dbg_pool_aw_count;
    reg [15:0] axi_dbg_pool_ar_count;
    reg [15:0] axi_dbg_weight_ar_count;
    reg [15:0] axi_dbg_b_count;
    reg [15:0] axi_dbg_wlast_count;
    reg [15:0] axi_dbg_rlast_count;
    reg [31:0] axi_dbg_last_awaddr;
    reg [31:0] axi_dbg_last_araddr;
    reg [31:0] axi_dbg_last_wdata;
    reg [31:0] axi_dbg_last_rdata;
    reg [7:0]  axi_dbg_last_awlen;
    reg [7:0]  axi_dbg_last_arlen;
    reg [1:0]  axi_dbg_last_bresp;
    reg [1:0]  axi_dbg_last_rresp;
    reg        axi_dbg_bresp_error;
    reg        axi_dbg_rresp_error;

`ifdef NPU_WRAPPER_TRACE
    reg [31:0] trace_status_reads;
`endif

    // Descriptor configuration registers
    reg        desc_mode_en;
    reg        desc_ready;
    reg        desc_error;
    reg [4:0]  layer_count;
    reg        desc_we;
    reg [4:0]  desc_layer;
    reg [2:0]  desc_word;
    reg [31:0] desc_wdata;
    reg [15:0] desc_write_count;
    reg [4:0]  desc_last_layer;
    reg [2:0]  desc_last_word;
    reg [6:0]  layer_dbg_sel;

    reg [2:0]                 stream_state;
    reg [7:0]                 start_delay;
    reg [FRAME_WORD_AW-1:0]   stream_word_idx;
    reg [1:0]                 stream_byte_sel;
    reg [15:0]                stream_byte_count;
    reg [31:0]                stream_word;
    wire stream_last_byte = (stream_byte_count == (FRAME_PIXELS_L - 16'd1));

    wire        npu_bbox_valid;
    wire [39:0] npu_bbox_data;
    wire        npu_result_stream_valid;
    wire [127:0] npu_result_stream_data;
    wire        npu_inference_done;
    wire        npu_result_busy;
    wire        npu_result_done;
    wire        npu_result_error;
    wire [31:0] npu_result_write_bytes;
    wire [31:0] npu_result_checksum;
    wire [31:0] npu_result_last_addr;
    wire        input_preload_mode;
    wire        input_preload_done;
    wire        input_preload_idle_allowed;
    wire        input_preload_write_allowed;
    wire        preload_core_wr_en;
    wire [12:0] preload_core_wr_addr;
    wire [15:0] preload_core_wr_mask;
    wire [127:0] preload_core_wr_data;
    wire        dma_req_snoop;
    wire        dma_done_snoop;
    wire        dma_error_snoop;
    wire [15:0] dma_base_addr_snoop;
    wire [15:0] dma_length_snoop;
    wire [31:0] pool_reorder_dbg0;
    wire [31:0] pool_reorder_dbg1;
    wire [31:0] pool_reorder_dbg2;
    wire [31:0] pool_reorder_dbg3;
    wire [31:0] pool_reorder_dbg4;
    wire [31:0] pool_reorder_dbg5;
    wire [31:0] pool_reorder_dbg6;
    wire [31:0] pool_reorder_dbg7;
    wire [31:0] pool_reorder_dbg8;
    wire [31:0] pool_reorder_dbg9;
    wire [31:0] pool_reorder_dbg10;
    wire [31:0] pool_reorder_dbg11;
    wire [31:0] pool_reorder_dbg12;
    wire [31:0] pool_reorder_dbg13;
    wire [31:0] pool_reorder_dbg14;
    wire [31:0] pool_reorder_dbg15;
    wire [31:0] pool_reorder_dbg16;
    wire [31:0] pool_reorder_dbg17;
    wire [31:0] pool_reorder_dbg18;
    wire [31:0] param_dma_dbg0;
    wire [31:0] param_dma_dbg1;
    wire [31:0] param_dma_dbg2;
    wire [31:0] param_dma_dbg3;
    wire [31:0] param_dma_dbg4;
    wire [31:0] param_dma_dbg5;
    wire [31:0] param_dma_dbg6;
    wire [31:0] param_dma_dbg7;
    wire [31:0] param_dma_dbg8;
    wire [31:0] param_dma_dbg9;
    wire [31:0] param_dma_dbg10;
    wire [31:0] param_dma_dbg11;
    wire [31:0] param_dma_dbg12;
    wire [31:0] param_dma_dbg13;
    wire [31:0] param_dma_dbg14;
    wire [31:0] param_dma_dbg15;
    wire [31:0] param_dma_dbg16;
    wire [31:0] param_dma_dbg17;
    wire [31:0] param_dma_dbg18;
    wire [31:0] layer_dbg0;
    wire [31:0] layer_dbg1;
    wire [31:0] layer_dbg2;
    wire [31:0] layer_dbg3;
    wire [31:0] layer_dbg4;
    wire [31:0] layer_dbg5;
    wire [31:0] layer_dbg6;
    wire [31:0] layer_dbg7;

    wire frame_full = (frame_count >= FRAME_PIXELS_L);

    reg [31:0] read_reg_addr;
    reg [31:0] read_reg_data;

    always @(*) begin
        read_reg_addr = ar_fire ? s_araddr : rd_addr_next;
            if (read_reg_addr[15:8] == 8'h01) begin
                case (read_reg_addr[7:0])
                    REG_LAYER_DBG0: begin
                        read_reg_data = layer_dbg0;
                    end
                    REG_LAYER_DBG1: begin
                        read_reg_data = layer_dbg1;
                    end
                    REG_LAYER_DBG2: begin
                        read_reg_data = layer_dbg2;
                    end
                    REG_LAYER_DBG3: begin
                        read_reg_data = layer_dbg3;
                    end
                    REG_LAYER_DBG4: begin
                        read_reg_data = layer_dbg4;
                    end
                    REG_LAYER_DBG5: begin
                        read_reg_data = layer_dbg5;
                    end
                    REG_LAYER_DBG6: begin
                        read_reg_data = layer_dbg6;
                    end
                    REG_LAYER_DBG7: begin
                        read_reg_data = layer_dbg7;
                    end
                    REG_RESULT_CTRL: begin
                        read_reg_data = {31'd0, result_enable};
                    end
                    REG_RESULT_STATUS: begin
                        read_reg_data = {29'd0, npu_result_error,
                                    npu_result_done, npu_result_busy};
                    end
                    REG_RESULT_BASE: begin
                        read_reg_data = result_base_addr;
                    end
                    REG_RESULT_BYTES: begin
                        read_reg_data = result_max_bytes;
                    end
                    REG_RESULT_WRITE_BYTES: begin
                        read_reg_data = npu_result_write_bytes;
                    end
                    REG_RESULT_CHECKSUM: begin
                        read_reg_data = npu_result_checksum;
                    end
                    REG_RESULT_LAST_ADDR: begin
                        read_reg_data = npu_result_last_addr;
                    end
                    REG_RESULT_SHAPE0: begin
                        read_reg_data = result_shape0;
                    end
                    REG_RESULT_SHAPE1: begin
                        read_reg_data = result_shape1;
                    end
                    REG_INPUT_PRELOAD_CTRL: begin
                        read_reg_data = {27'd0, input_preload_skip_lbp,
                                         input_preload_packed,
                                         1'b0,
                                         input_preload_target,
                                         input_preload_enable};
                    end
                    REG_INPUT_PRELOAD_STATUS: begin
                        read_reg_data = {input_preload_count[15:0],
                                         11'd0,
                                         input_preload_overflow,
                                         input_preload_target_unsupported,
                                         input_preload_error,
                                         input_preload_done,
                                         input_preload_idle_allowed};
                    end
                    REG_INPUT_PRELOAD_BYTES: begin
                        read_reg_data = input_preload_bytes;
                    end
                    REG_INPUT_PRELOAD_COUNT: begin
                        read_reg_data = input_preload_count;
                    end
                    REG_HW_CAPS: begin
                        read_reg_data = USE_AXI_DMA ? 32'h0000_000f :
                                                     32'h0000_0008;
                    end
                    REG_HW_ABI: begin
                        read_reg_data = 32'd2;
                    end
                    default: begin
                        read_reg_data = 32'd0;
                    end
                endcase
            end else if (read_reg_addr[15:8] != 8'h00) begin
                read_reg_data = 32'd0;
            end else begin
                case (read_reg_addr[7:0])
                    REG_CTRL: begin
                        read_reg_data = {29'd0, irq_en, 2'd0};
                    end
                    REG_STATUS: begin
                        read_reg_data = {frame_count, 5'd0, stream_state, 3'd0,
                                    irq_pending, frame_full, error_reg,
                                    done_reg, busy_reg};
                    end
                    REG_FRAME_COUNT: begin
                        read_reg_data = {16'd0, frame_count};
                    end
                    REG_BBOX0: begin
                        read_reg_data = bbox_data[31:0];
                    end
                    REG_BBOX1: begin
                        read_reg_data = {frame_id, 7'd0, bbox_valid_latched,
                                    bbox_data[39:32]};
                    end
                    REG_IRQ_STATUS: begin
                        read_reg_data = {31'd0, irq_pending};
                    end
                    REG_DMA_DEBUG0: begin
                        read_reg_data = {dma_base_addr_snoop, dma_length_snoop};
                    end
                    REG_DMA_DEBUG1: begin
                        read_reg_data = {29'd0, dma_error_seen, dma_done_seen,
                                    dma_req_seen};
                    end
                    REG_PERF_CYCLE: begin
                        read_reg_data = perf_cycle;
                    end
                    REG_SCRATCH_BASE: begin
                        read_reg_data = scratch_base_addr;
                    end
                    REG_PARAM_BASE: begin
                        read_reg_data = param_base_addr;
                    end
                    REG_LAYER_COUNT: begin
                        read_reg_data = {27'd0, layer_count};
                    end
                    REG_DESC_CTRL: begin
                        read_reg_data = {31'd0, desc_mode_en};
                    end
                    REG_DESC_STATUS: begin
                        read_reg_data = {desc_write_count, 5'd0, desc_last_layer,
                                    1'b0, desc_last_word, desc_error,
                                    desc_ready};
                    end
                    REG_AXI_DBG0: begin
                        read_reg_data = {axi_dbg_pool_aw_count,
                                    axi_dbg_pool_ar_count};
                    end
                    REG_AXI_DBG1: begin
                        read_reg_data = {axi_dbg_weight_ar_count,
                                    axi_dbg_b_count};
                    end
                    REG_AXI_DBG2: begin
                        read_reg_data = {axi_dbg_wlast_count,
                                    axi_dbg_rlast_count};
                    end
                    REG_AXI_LAST_AW: begin
                        read_reg_data = axi_dbg_last_awaddr;
                    end
                    REG_AXI_LAST_AR: begin
                        read_reg_data = axi_dbg_last_araddr;
                    end
                    REG_AXI_LAST_W: begin
                        read_reg_data = axi_dbg_last_wdata;
                    end
                    REG_AXI_LAST_R: begin
                        read_reg_data = axi_dbg_last_rdata;
                    end
                    REG_AXI_DBG3: begin
                        read_reg_data = {10'd0,
                                    axi_dbg_bresp_error,
                                    axi_dbg_rresp_error,
                                    axi_dbg_last_awlen,
                                    axi_dbg_last_arlen,
                                    axi_dbg_last_bresp,
                                    axi_dbg_last_rresp};
                    end
                    REG_AXI_DBG4: begin
                        read_reg_data = {20'd0,
                                    m_axi_bready,
                                    m_axi_bvalid,
                                    m_axi_wlast,
                                    m_axi_wready,
                                    m_axi_wvalid,
                                    m_axi_awready,
                                    m_axi_awvalid,
                                    m_axi_rlast,
                                    m_axi_rready,
                                    m_axi_rvalid,
                                    m_axi_arready,
                                    m_axi_arvalid};
                    end
                    REG_POOL_DBG0: begin
                        read_reg_data = pool_reorder_dbg0;
                    end
                    REG_POOL_DBG1: begin
                        read_reg_data = pool_reorder_dbg1;
                    end
                    REG_POOL_DBG2: begin
                        read_reg_data = pool_reorder_dbg2;
                    end
                    REG_POOL_DBG3: begin
                        read_reg_data = pool_reorder_dbg3;
                    end
                    REG_POOL_DBG4: begin
                        read_reg_data = pool_reorder_dbg4;
                    end
                    REG_POOL_DBG5: begin
                        read_reg_data = pool_reorder_dbg5;
                    end
                    REG_POOL_DBG6: begin
                        read_reg_data = pool_reorder_dbg6;
                    end
                    REG_POOL_DBG7: begin
                        read_reg_data = pool_reorder_dbg7;
                    end
                    REG_POOL_DBG8: begin
                        read_reg_data = pool_reorder_dbg8;
                    end
                    REG_POOL_DBG9: begin
                        read_reg_data = pool_reorder_dbg9;
                    end
                    REG_POOL_DBG10: begin
                        read_reg_data = pool_reorder_dbg10;
                    end
                    REG_POOL_DBG11: begin
                        read_reg_data = pool_reorder_dbg11;
                    end
                    REG_POOL_DBG12: begin
                        read_reg_data = pool_reorder_dbg12;
                    end
                    REG_POOL_DBG13: begin
                        read_reg_data = pool_reorder_dbg13;
                    end
                    REG_POOL_DBG14: begin
                        read_reg_data = pool_reorder_dbg14;
                    end
                    REG_POOL_DBG15: begin
                        read_reg_data = pool_reorder_dbg15;
                    end
                    REG_POOL_DBG16: begin
                        read_reg_data = pool_reorder_dbg16;
                    end
                    REG_POOL_DBG17: begin
                        read_reg_data = pool_reorder_dbg17;
                    end
                    REG_POOL_DBG18: begin
                        read_reg_data = pool_reorder_dbg18;
                    end
                    REG_PARAM_DBG0: begin
                        read_reg_data = param_dma_dbg0;
                    end
                    REG_PARAM_DBG1: begin
                        read_reg_data = param_dma_dbg1;
                    end
                    REG_PARAM_DBG2: begin
                        read_reg_data = param_dma_dbg2;
                    end
                    REG_PARAM_DBG3: begin
                        read_reg_data = param_dma_dbg3;
                    end
                    REG_PARAM_DBG4: begin
                        read_reg_data = param_dma_dbg4;
                    end
                    REG_PARAM_DBG5: begin
                        read_reg_data = param_dma_dbg5;
                    end
                    REG_PARAM_DBG6: begin
                        read_reg_data = param_dma_dbg6;
                    end
                    REG_PARAM_DBG7: begin
                        read_reg_data = param_dma_dbg7;
                    end
                    REG_PARAM_DBG8: begin
                        read_reg_data = param_dma_dbg8;
                    end
                    REG_PARAM_DBG9: begin
                        read_reg_data = param_dma_dbg9;
                    end
                    REG_PARAM_DBG10: begin
                        read_reg_data = param_dma_dbg10;
                    end
                    REG_PARAM_DBG11: begin
                        read_reg_data = param_dma_dbg11;
                    end
                    REG_PARAM_DBG12: begin
                        read_reg_data = param_dma_dbg12;
                    end
                    REG_PARAM_DBG13: begin
                        read_reg_data = param_dma_dbg13;
                    end
                    REG_PARAM_DBG14: begin
                        read_reg_data = param_dma_dbg14;
                    end
                    REG_PARAM_DBG15: begin
                        read_reg_data = param_dma_dbg15;
                    end
                    REG_PARAM_DBG16: begin
                        read_reg_data = param_dma_dbg16;
                    end
                    REG_PARAM_DBG17: begin
                        read_reg_data = param_dma_dbg17;
                    end
                    REG_PARAM_DBG18: begin
                        read_reg_data = param_dma_dbg18;
                    end
                    REG_LAYER_DBG_SEL: begin
                        read_reg_data = {26'd0, layer_dbg_sel};
                    end
                    default: begin
                        read_reg_data = 32'd0;
                    end
                endcase
            end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            rd_active <= 1'b0;
            rd_addr   <= 32'd0;
            rd_len    <= 8'd0;
            rd_size   <= 3'd0;
            rd_burst  <= 2'd0;
            rd_beat   <= 8'd0;
            s_rid     <= 5'd0;
            s_rdata   <= 32'd0;
            s_rlast   <= 1'b0;
            s_rvalid  <= 1'b0;
`ifdef NPU_WRAPPER_TRACE
            trace_status_reads <= 32'd0;
`endif
        end else begin
            if (ar_fire) begin
                rd_active <= 1'b1;
                rd_addr   <= s_araddr;
                rd_len    <= s_arlen;
                rd_size   <= s_arsize;
                rd_burst  <= s_arburst;
                rd_beat   <= 8'd0;
                s_rid     <= s_arid;
                s_rdata   <= read_reg_data;
                s_rlast   <= (s_arlen == 8'd0);
                s_rvalid  <= 1'b1;
            end else if (r_fire) begin
                if (s_rlast) begin
                    rd_active <= 1'b0;
                    s_rvalid  <= 1'b0;
                    s_rlast   <= 1'b0;
                end else begin
                    rd_addr  <= rd_addr_next;
                    rd_beat  <= rd_beat + 8'd1;
                    s_rdata  <= read_reg_data;
                    s_rlast  <= ((rd_beat + 8'd1) == rd_len);
                    s_rvalid <= 1'b1;
                end
            end

`ifdef NPU_WRAPPER_TRACE
            if (ar_fire && s_araddr[15:8] == 8'h00 && s_araddr[7:0] == REG_STATUS) begin
                if (trace_status_reads < 32'd32 || done_reg || error_reg) begin
                    $display("[NPU_WRAP] t=%0t status_read data=%08h busy=%0b done=%0b error=%0b stream=%0d frame=%0d",
                             $time, read_reg_data, busy_reg, done_reg,
                             error_reg, stream_state, frame_count);
                end
                trace_status_reads <= trace_status_reads + 32'd1;
            end
            if (r_fire && rd_addr[15:8] == 8'h00 && rd_addr[7:0] == REG_STATUS) begin
                if (trace_status_reads < 32'd32 || s_rdata[1] || s_rdata[2]) begin
                    $display("[NPU_WRAP] t=%0t status_resp data=%08h rid=%0d rlast=%0b",
                             $time, s_rdata, s_rid, s_rlast);
                end
            end
`endif
        end
    end

    wire write_reg_page    = w_fire && (wr_addr[15:8] == 8'h00);
    wire write_ctrl        = write_reg_page && (wr_addr[7:0] == REG_CTRL);
    wire write_frame_fifo  = write_reg_page && (wr_addr[7:0] == REG_FRAME_DATA);
    wire write_frame_count = write_reg_page && (wr_addr[7:0] == REG_FRAME_COUNT);
    wire write_irq_clr     = write_reg_page && (wr_addr[7:0] == REG_IRQ_CLR);
    wire write_scratch_base = write_reg_page && (wr_addr[7:0] == REG_SCRATCH_BASE);
    wire write_param_base   = write_reg_page && (wr_addr[7:0] == REG_PARAM_BASE);
    wire write_layer_count  = write_reg_page && (wr_addr[7:0] == REG_LAYER_COUNT);
    wire write_desc_ctrl    = write_reg_page && (wr_addr[7:0] == REG_DESC_CTRL);
    wire write_layer_dbg_sel = write_reg_page && (wr_addr[7:0] == REG_LAYER_DBG_SEL);
    wire write_result_page  = w_fire && (wr_addr[15:8] == 8'h01);
    wire write_result_ctrl  = write_result_page && (wr_addr[7:0] == REG_RESULT_CTRL);
    wire write_result_base  = write_result_page && (wr_addr[7:0] == REG_RESULT_BASE);
    wire write_result_bytes = write_result_page && (wr_addr[7:0] == REG_RESULT_BYTES);
    wire write_result_shape0 = write_result_page && (wr_addr[7:0] == REG_RESULT_SHAPE0);
    wire write_result_shape1 = write_result_page && (wr_addr[7:0] == REG_RESULT_SHAPE1);
    wire write_input_preload_ctrl = write_result_page && (wr_addr[7:0] == REG_INPUT_PRELOAD_CTRL);
    wire write_input_preload_bytes = write_result_page && (wr_addr[7:0] == REG_INPUT_PRELOAD_BYTES);
    wire write_input_preload_data = write_result_page && (wr_addr[7:0] == REG_INPUT_PRELOAD_DATA);
    wire write_desc_ram     = w_fire &&
                              (wr_addr[15:0] >= DESC_RAM_BASE) &&
                              (wr_addr[15:0] <  DESC_RAM_LIMIT);
    wire write_frame_mem   = w_fire &&
                             (wr_addr[15:0] >= FRAME_MEM_BASE) &&
                             (wr_addr[15:0] <  FRAME_MEM_LIMIT);

    wire ctrl_start        = write_ctrl && s_wdata[0];
    wire ctrl_soft_reset   = write_ctrl && s_wdata[1];

    // Descriptor RAM aperture address decode
    wire [15:0] desc_ram_offset = wr_addr[15:0] - DESC_RAM_BASE;
    wire [4:0]  desc_ram_layer  = desc_ram_offset[12:5];  // offset >> 5
    wire [2:0]  desc_ram_word   = desc_ram_offset[4:2];   // (offset >> 2) & 0x7

    wire ctrl_desc_mode_en  = write_desc_ctrl && s_wdata[0];
    wire ctrl_clear_frame  = write_ctrl && s_wdata[3];
    wire ctrl_clear_status = write_ctrl && s_wdata[4];
    wire result_complete = result_enable ? npu_result_done : npu_bbox_valid;

    wire desc_config_ready = desc_mode_en && desc_ready && (layer_count != 5'd0);
    wire npu_config_ready = USE_AXI_DMA ? desc_config_ready : 1'b1;
    assign input_preload_mode = input_preload_enable && input_preload_packed;
    assign input_preload_done = input_preload_mode &&
                                (input_preload_count >= input_preload_bytes) &&
                                (input_preload_bytes != 32'd0) &&
                                !preload_word_busy &&
                                !input_preload_error &&
                                !input_preload_overflow &&
                                !input_preload_target_unsupported;
    assign input_preload_idle_allowed = !busy_reg && !preload_word_busy;
    wire input_ready = input_preload_mode ? input_preload_done : frame_full;
    wire start_accept = ctrl_start && !busy_reg && input_ready && npu_config_ready;
    wire result_start_pulse = start_accept && result_enable;
    wire axi_dbg_ar_fire = m_axi_arvalid && m_axi_arready;
    wire axi_dbg_r_fire  = m_axi_rvalid && m_axi_rready;
    wire axi_dbg_aw_fire = m_axi_awvalid && m_axi_awready;
    wire axi_dbg_w_fire  = m_axi_wvalid && m_axi_wready;
    wire axi_dbg_b_fire  = m_axi_bvalid && m_axi_bready;
    wire axi_dbg_ar_is_scratch =
        m_axi_araddr >= scratch_base_addr &&
        m_axi_araddr < (scratch_base_addr + 32'h0008_0000);
    wire axi_dbg_pool_ar_fire = axi_dbg_ar_fire &&
                                ((m_axi_arlen == 8'd3) || axi_dbg_ar_is_scratch);
    wire axi_dbg_weight_ar_fire = axi_dbg_ar_fire && !axi_dbg_ar_is_scratch &&
                                  (m_axi_arlen == 8'd0);

    wire [15:0] frame_mem_offset = wr_addr[15:0] - FRAME_MEM_BASE;
    wire [FRAME_WORD_AW-1:0] frame_mem_wr_addr =
        frame_mem_offset[FRAME_WORD_AW+1:2];
    wire [FRAME_WORD_AW-1:0] frame_fifo_wr_addr =
        frame_count[FRAME_WORD_AW+1:2];
    wire [15:0] frame_mem_write_end =
        frame_mem_offset + 16'd4;
    wire frame_fifo_accept = write_frame_fifo &&
                             !busy_reg &&
                             !frame_full &&
                             (s_wstrb == 4'hf) &&
                             (frame_count[1:0] == 2'd0);
    wire frame_mem_accept = write_frame_mem && !busy_reg;
    wire frame_mem_we = frame_fifo_accept || frame_mem_accept;
    wire [FRAME_WORD_AW-1:0] frame_mem_write_addr =
        frame_fifo_accept ? frame_fifo_wr_addr : frame_mem_wr_addr;
    wire [3:0] frame_mem_write_strb =
        frame_fifo_accept ? 4'hf : s_wstrb;

    wire [FRAME_WORD_AW-1:0] stream_word_idx_plus1 =
        stream_word_idx + {{(FRAME_WORD_AW-1){1'b0}}, 1'b1};
    wire frame_mem_prefetch_first = (stream_state == ST_IDLE) && start_accept &&
                                    !input_preload_mode;
    wire frame_mem_prefetch_next  = (stream_state == ST_SEND) &&
                                    !stream_last_byte &&
                                    (stream_byte_sel == 2'd3);
    wire frame_mem_rd_en = frame_mem_prefetch_first || frame_mem_prefetch_next;
    wire [FRAME_WORD_AW-1:0] frame_mem_rd_addr =
        frame_mem_prefetch_next ? stream_word_idx_plus1 : stream_word_idx;

`ifdef NPU_USE_XPM_BRAM
    npu_xilinx_sdpram #(
        .DATA_WIDTH      (32),
        .ADDR_WIDTH      (FRAME_WORD_AW),
        .MEMORY_DEPTH    (FRAME_WORDS),
        .BYTE_WRITE_WIDTH(8)
    ) u_frame_mem_bram (
        .clk     (aclk),
        .wr_en   (frame_mem_we),
        .wr_strb (frame_mem_write_strb),
        .wr_addr (frame_mem_write_addr),
        .wr_data (s_wdata),
        .rd_en   (frame_mem_rd_en),
        .rd_addr (frame_mem_rd_addr),
        .rd_data (frame_mem_rdata)
    );
`else
    always @(posedge aclk) begin
        if (frame_mem_we) begin
            if (frame_mem_write_strb[0]) frame_mem[frame_mem_write_addr][7:0]   <= s_wdata[7:0];
            if (frame_mem_write_strb[1]) frame_mem[frame_mem_write_addr][15:8]  <= s_wdata[15:8];
            if (frame_mem_write_strb[2]) frame_mem[frame_mem_write_addr][23:16] <= s_wdata[23:16];
            if (frame_mem_write_strb[3]) frame_mem[frame_mem_write_addr][31:24] <= s_wdata[31:24];
        end
        if (frame_mem_rd_en) begin
            frame_mem_rdata <= frame_mem[frame_mem_rd_addr];
        end
    end
`endif

    assign input_preload_write_allowed =
        !busy_reg &&
        input_preload_enable &&
        input_preload_packed &&
        !input_preload_target &&
        !input_preload_error &&
        !input_preload_overflow &&
        !input_preload_target_unsupported;
    wire input_preload_accept_word =
        input_preload_write_allowed &&
        (input_preload_count < input_preload_bytes);

    wire [7:0] preload_selected_byte =
        (preload_byte_idx == 2'd0) ? preload_word_data[7:0] :
        (preload_byte_idx == 2'd1) ? preload_word_data[15:8] :
        (preload_byte_idx == 2'd2) ? preload_word_data[23:16] :
                                     preload_word_data[31:24];
    wire preload_selected_strobe = preload_word_strb[preload_byte_idx];
    wire [31:0] preload_next_count = input_preload_count + 32'd1;
    wire [3:0] preload_wr_bank = input_preload_count[3:0];

    assign preload_core_wr_en = preload_word_busy &&
                                preload_selected_strobe &&
                                input_preload_write_allowed &&
                                (input_preload_count < input_preload_bytes);
    assign preload_core_wr_addr = input_preload_count[16:4];
    assign preload_core_wr_mask = 16'h0001 << preload_wr_bank;
    assign preload_core_wr_data = {16{preload_selected_byte}};

    always @(posedge aclk) begin
        if (!aresetn) begin
            irq_en             <= 1'b0;
            busy_reg           <= 1'b0;
            done_reg           <= 1'b0;
            error_reg          <= 1'b0;
            irq_pending        <= 1'b0;
            bbox_valid_latched <= 1'b0;
            dma_req_seen       <= 1'b0;
            dma_done_seen      <= 1'b0;
            dma_error_seen     <= 1'b0;
            frame_count        <= 16'd0;
            frame_id           <= 16'd0;
            bbox_data          <= 40'd0;
            perf_cycle         <= 32'd0;
            param_base_addr    <= 32'd0;
            scratch_base_addr  <= SCRATCH_BASE_RESET;
            result_enable      <= 1'b0;
            result_base_addr   <= RESULT_BASE_RESET;
            result_max_bytes   <= RESULT_BYTES_RESET;
            result_shape0      <= 32'd0;
            result_shape1      <= 32'h0000_0005;
            input_preload_enable <= 1'b0;
            input_preload_target <= 1'b0;
            input_preload_packed <= 1'b0;
            input_preload_skip_lbp <= 1'b0;
            input_preload_error <= 1'b0;
            input_preload_target_unsupported <= 1'b0;
            input_preload_overflow <= 1'b0;
            input_preload_bytes <= 32'd0;
            input_preload_count <= 32'd0;
            preload_word_data <= 32'd0;
            preload_word_strb <= 4'd0;
            preload_byte_idx <= 2'd0;
            preload_word_busy <= 1'b0;
            axi_dbg_pool_aw_count   <= 16'd0;
            axi_dbg_pool_ar_count   <= 16'd0;
            axi_dbg_weight_ar_count <= 16'd0;
            axi_dbg_b_count         <= 16'd0;
            axi_dbg_wlast_count     <= 16'd0;
            axi_dbg_rlast_count     <= 16'd0;
            axi_dbg_last_awaddr     <= 32'd0;
            axi_dbg_last_araddr     <= 32'd0;
            axi_dbg_last_wdata      <= 32'd0;
            axi_dbg_last_rdata      <= 32'd0;
            axi_dbg_last_awlen      <= 8'd0;
            axi_dbg_last_arlen      <= 8'd0;
            axi_dbg_last_bresp      <= 2'd0;
            axi_dbg_last_rresp      <= 2'd0;
            axi_dbg_bresp_error     <= 1'b0;
            axi_dbg_rresp_error     <= 1'b0;
            desc_mode_en       <= 1'b0;
            desc_ready         <= 1'b0;
            desc_error         <= 1'b0;
            layer_count        <= 5'd0;
            desc_we            <= 1'b0;
            desc_write_count   <= 16'd0;
            desc_last_layer    <= 5'd0;
            desc_last_word     <= 3'd0;
            layer_dbg_sel      <= 7'd0;
        end else if (ctrl_soft_reset) begin
            busy_reg           <= 1'b0;
            done_reg           <= 1'b0;
            error_reg          <= 1'b0;
            irq_pending        <= 1'b0;
            bbox_valid_latched <= 1'b0;
            dma_req_seen       <= 1'b0;
            dma_done_seen      <= 1'b0;
            dma_error_seen     <= 1'b0;
            frame_count        <= 16'd0;
            bbox_data          <= 40'd0;
            perf_cycle         <= 32'd0;
            scratch_base_addr  <= SCRATCH_BASE_RESET;
            result_enable      <= 1'b0;
            result_base_addr   <= RESULT_BASE_RESET;
            result_max_bytes   <= RESULT_BYTES_RESET;
            result_shape0      <= 32'd0;
            result_shape1      <= 32'h0000_0005;
            input_preload_enable <= 1'b0;
            input_preload_target <= 1'b0;
            input_preload_packed <= 1'b0;
            input_preload_skip_lbp <= 1'b0;
            input_preload_error <= 1'b0;
            input_preload_target_unsupported <= 1'b0;
            input_preload_overflow <= 1'b0;
            input_preload_bytes <= 32'd0;
            input_preload_count <= 32'd0;
            preload_word_data <= 32'd0;
            preload_word_strb <= 4'd0;
            preload_byte_idx <= 2'd0;
            preload_word_busy <= 1'b0;
            axi_dbg_pool_aw_count   <= 16'd0;
            axi_dbg_pool_ar_count   <= 16'd0;
            axi_dbg_weight_ar_count <= 16'd0;
            axi_dbg_b_count         <= 16'd0;
            axi_dbg_wlast_count     <= 16'd0;
            axi_dbg_rlast_count     <= 16'd0;
            axi_dbg_last_awaddr     <= 32'd0;
            axi_dbg_last_araddr     <= 32'd0;
            axi_dbg_last_wdata      <= 32'd0;
            axi_dbg_last_rdata      <= 32'd0;
            axi_dbg_last_awlen      <= 8'd0;
            axi_dbg_last_arlen      <= 8'd0;
            axi_dbg_last_bresp      <= 2'd0;
            axi_dbg_last_rresp      <= 2'd0;
            axi_dbg_bresp_error     <= 1'b0;
            axi_dbg_rresp_error     <= 1'b0;
            desc_mode_en       <= 1'b0;
            desc_ready         <= 1'b0;
            desc_error         <= 1'b0;
            layer_count        <= 5'd0;
            desc_we            <= 1'b0;
            desc_write_count   <= 16'd0;
            desc_last_layer    <= 5'd0;
            desc_last_word     <= 3'd0;
            layer_dbg_sel      <= 7'd0;
        end else begin
`ifdef NPU_WRAPPER_TRACE
            if (write_ctrl) begin
                $display("[NPU_WRAP] t=%0t ctrl_write data=%08h start_accept=%0b frame_full=%0b busy=%0b",
                         $time, s_wdata, start_accept, frame_full, busy_reg);
            end
`endif
            desc_we <= 1'b0;

            if (write_ctrl) begin
                irq_en <= s_wdata[2];
            end

            if (ctrl_clear_status) begin
                done_reg           <= 1'b0;
                error_reg          <= 1'b0;
                irq_pending        <= 1'b0;
                bbox_valid_latched <= 1'b0;
                dma_req_seen       <= 1'b0;
                dma_done_seen      <= 1'b0;
                dma_error_seen     <= 1'b0;
                perf_cycle         <= 32'd0;
                axi_dbg_pool_aw_count   <= 16'd0;
                axi_dbg_pool_ar_count   <= 16'd0;
                axi_dbg_weight_ar_count <= 16'd0;
                axi_dbg_b_count         <= 16'd0;
                axi_dbg_wlast_count     <= 16'd0;
                axi_dbg_rlast_count     <= 16'd0;
                axi_dbg_last_awaddr     <= 32'd0;
                axi_dbg_last_araddr     <= 32'd0;
                axi_dbg_last_wdata      <= 32'd0;
                axi_dbg_last_rdata      <= 32'd0;
                axi_dbg_last_awlen      <= 8'd0;
                axi_dbg_last_arlen      <= 8'd0;
                axi_dbg_last_bresp      <= 2'd0;
                axi_dbg_last_rresp      <= 2'd0;
                axi_dbg_bresp_error     <= 1'b0;
                axi_dbg_rresp_error     <= 1'b0;
            end

            if (ctrl_clear_frame && !busy_reg) begin
                frame_count <= 16'd0;
            end

            if (write_frame_count && !busy_reg && s_wdata[15:0] == 16'd0) begin
                frame_count <= 16'd0;
            end

            if (write_irq_clr && s_wdata[0]) begin
                irq_pending <= 1'b0;
            end

            if (write_param_base && !busy_reg) begin
                param_base_addr <= s_wdata;
            end else if (write_param_base && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_scratch_base && !busy_reg) begin
                scratch_base_addr <= s_wdata;
            end else if (write_scratch_base && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_layer_dbg_sel) begin
                layer_dbg_sel <= s_wdata[6:0];
            end

            if (write_result_ctrl && !busy_reg) begin
                result_enable <= s_wdata[0];
            end else if (write_result_ctrl && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_result_base && !busy_reg) begin
                result_base_addr <= s_wdata;
            end else if (write_result_base && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_result_bytes && !busy_reg) begin
                result_max_bytes <= s_wdata;
            end else if (write_result_bytes && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_result_shape0 && !busy_reg) begin
                result_shape0 <= s_wdata;
            end else if (write_result_shape0 && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_result_shape1 && !busy_reg) begin
                result_shape1 <= s_wdata;
            end else if (write_result_shape1 && busy_reg) begin
                error_reg <= 1'b1;
            end

            if (write_input_preload_ctrl && !busy_reg && !preload_word_busy) begin
                input_preload_enable <= s_wdata[0];
                input_preload_target <= s_wdata[1];
                input_preload_packed <= s_wdata[3];
                input_preload_skip_lbp <= s_wdata[4];
                if (s_wdata[2]) begin
                    input_preload_count <= 32'd0;
                    input_preload_error <= 1'b0;
                    input_preload_target_unsupported <= 1'b0;
                    input_preload_overflow <= 1'b0;
                end
                if (s_wdata[1] && s_wdata[0]) begin
                    input_preload_target_unsupported <= 1'b1;
                    input_preload_error <= 1'b1;
                end
                if (s_wdata[0] && !s_wdata[3]) begin
                    input_preload_error <= 1'b1;
                end
            end else if (write_input_preload_ctrl && (busy_reg || preload_word_busy)) begin
                input_preload_error <= 1'b1;
                error_reg <= 1'b1;
            end

            if (write_input_preload_bytes && !busy_reg && !preload_word_busy) begin
                input_preload_bytes <= s_wdata;
            end else if (write_input_preload_bytes && (busy_reg || preload_word_busy)) begin
                input_preload_error <= 1'b1;
                error_reg <= 1'b1;
            end

            if (write_input_preload_data) begin
                if (input_preload_accept_word && !preload_word_busy && (s_wstrb != 4'd0)) begin
                    preload_word_data <= s_wdata;
                    preload_word_strb <= s_wstrb;
                    preload_byte_idx <= 2'd0;
                    preload_word_busy <= 1'b1;
                end else begin
                    input_preload_error <= 1'b1;
                    error_reg <= 1'b1;
                end
            end

            if (preload_word_busy) begin
                if (preload_selected_strobe) begin
                    if (input_preload_write_allowed && (input_preload_count < input_preload_bytes)) begin
                        input_preload_count <= preload_next_count;
                    end else if (!input_preload_write_allowed) begin
                        input_preload_error <= 1'b1;
                    end
                end

                if (preload_byte_idx == 2'd3) begin
                    preload_word_busy <= 1'b0;
                    preload_word_strb <= 4'd0;
                end else begin
                    preload_byte_idx <= preload_byte_idx + 2'd1;
                end
            end

            // Descriptor control register writes
            if (write_desc_ctrl) begin
                desc_mode_en <= s_wdata[0];
                if (s_wdata[0]) begin
                    desc_ready <= 1'b0;
                    desc_error <= 1'b0;
                    layer_count <= 5'd0;
                    desc_write_count <= 16'd0;
                    desc_last_layer <= 5'd0;
                    desc_last_word <= 3'd0;
                end
            end

            if (write_layer_count && !busy_reg && desc_mode_en && !desc_ready) begin
                layer_count <= s_wdata[4:0];
            end else if (write_layer_count && (busy_reg || !desc_mode_en)) begin
                desc_error <= 1'b1;
            end

            // Descriptor RAM aperture write
            if (write_desc_ram && !busy_reg && desc_mode_en && !desc_ready) begin
                desc_we    <= 1'b1;
                desc_layer <= desc_ram_layer;
                desc_word  <= desc_ram_word;
                desc_wdata <= s_wdata;
                desc_last_layer <= desc_ram_layer;
                desc_last_word  <= desc_ram_word;
                if (desc_write_count != 16'hffff) begin
                    desc_write_count <= desc_write_count + 16'd1;
                end
            end else if (write_desc_ram && (busy_reg || !desc_mode_en)) begin
                desc_error <= 1'b1;
            end

            // Mark descriptor as ready when we enter desc_mode and layer_count is set
            if (desc_mode_en && !desc_ready && layer_count != 5'd0) begin
                desc_ready <= 1'b1;
            end

            if (write_frame_fifo) begin
                if (frame_fifo_accept) begin
                    frame_count <= frame_count + 16'd4;
                end else begin
                    error_reg <= 1'b1;
                end
            end

            if (write_frame_mem) begin
                if (!busy_reg) begin
                    if (frame_mem_write_end > frame_count) begin
                        frame_count <= frame_mem_write_end;
                    end
                end else begin
                    error_reg <= 1'b1;
                end
            end

            if (ctrl_start && !start_accept) begin
                error_reg <= 1'b1;
                if (USE_AXI_DMA && !desc_config_ready) begin
                    desc_error <= 1'b1;
                end
            end

            if (start_accept) begin
                busy_reg           <= 1'b1;
                done_reg           <= 1'b0;
                error_reg          <= 1'b0;
                irq_pending        <= 1'b0;
                bbox_valid_latched <= 1'b0;
                dma_req_seen       <= 1'b0;
                dma_done_seen      <= 1'b0;
                dma_error_seen     <= 1'b0;
                perf_cycle         <= 32'd0;
                axi_dbg_pool_aw_count   <= 16'd0;
                axi_dbg_pool_ar_count   <= 16'd0;
                axi_dbg_weight_ar_count <= 16'd0;
                axi_dbg_b_count         <= 16'd0;
                axi_dbg_wlast_count     <= 16'd0;
                axi_dbg_rlast_count     <= 16'd0;
                axi_dbg_last_awaddr     <= 32'd0;
                axi_dbg_last_araddr     <= 32'd0;
                axi_dbg_last_wdata      <= 32'd0;
                axi_dbg_last_rdata      <= 32'd0;
                axi_dbg_last_awlen      <= 8'd0;
                axi_dbg_last_arlen      <= 8'd0;
                axi_dbg_last_bresp      <= 2'd0;
                axi_dbg_last_rresp      <= 2'd0;
                axi_dbg_bresp_error     <= 1'b0;
                axi_dbg_rresp_error     <= 1'b0;
`ifdef NPU_WRAPPER_TRACE
                $display("[NPU_WRAP] t=%0t start_accept param_base=%08h scratch_base=%08h frame_count=%0d",
                         $time, param_base_addr, scratch_base_addr, frame_count);
`endif
            end else if (busy_reg && perf_cycle != 32'hffffffff) begin
                perf_cycle <= perf_cycle + 32'd1;
            end

            if (dma_req_snoop) begin
                dma_req_seen <= 1'b1;
            end

            if (dma_done_snoop) begin
                dma_done_seen <= 1'b1;
            end

            if (dma_error_snoop) begin
                dma_error_seen <= 1'b1;
                error_reg      <= 1'b1;
            end

            if (npu_result_error) begin
                error_reg <= 1'b1;
            end

            if (axi_dbg_aw_fire) begin
                axi_dbg_last_awaddr <= m_axi_awaddr;
                axi_dbg_last_awlen  <= m_axi_awlen;
                if (axi_dbg_pool_aw_count != 16'hffff)
                    axi_dbg_pool_aw_count <= axi_dbg_pool_aw_count + 16'd1;
            end

            if (axi_dbg_ar_fire) begin
                axi_dbg_last_araddr <= m_axi_araddr;
                axi_dbg_last_arlen  <= m_axi_arlen;
                if (axi_dbg_pool_ar_fire &&
                    axi_dbg_pool_ar_count != 16'hffff)
                    axi_dbg_pool_ar_count <= axi_dbg_pool_ar_count + 16'd1;
                if (axi_dbg_weight_ar_fire &&
                    axi_dbg_weight_ar_count != 16'hffff)
                    axi_dbg_weight_ar_count <= axi_dbg_weight_ar_count + 16'd1;
            end

            if (axi_dbg_w_fire) begin
                axi_dbg_last_wdata <= m_axi_wdata;
                if (m_axi_wlast && axi_dbg_wlast_count != 16'hffff)
                    axi_dbg_wlast_count <= axi_dbg_wlast_count + 16'd1;
            end

            if (axi_dbg_r_fire) begin
                axi_dbg_last_rdata <= m_axi_rdata;
                axi_dbg_last_rresp <= m_axi_rresp;
                if (m_axi_rresp != 2'b00)
                    axi_dbg_rresp_error <= 1'b1;
                if (m_axi_rlast && axi_dbg_rlast_count != 16'hffff)
                    axi_dbg_rlast_count <= axi_dbg_rlast_count + 16'd1;
            end

            if (axi_dbg_b_fire) begin
                axi_dbg_last_bresp <= m_axi_bresp;
                if (m_axi_bresp != 2'b00)
                    axi_dbg_bresp_error <= 1'b1;
                if (axi_dbg_b_count != 16'hffff)
                    axi_dbg_b_count <= axi_dbg_b_count + 16'd1;
            end

            if (busy_reg && npu_bbox_valid && !bbox_valid_latched) begin
                bbox_valid_latched <= 1'b1;
                bbox_data          <= npu_bbox_data;
            end

            if (busy_reg && result_complete) begin
                busy_reg           <= 1'b0;
                done_reg           <= 1'b1;
                irq_pending        <= 1'b1;
                frame_id           <= frame_id + 16'd1;
`ifdef NPU_WRAPPER_TRACE
                $display("[NPU_WRAP] t=%0t done result_en=%0b bbox=%010h result_bytes=%0d checksum=%08h perf=%0d status_next=%08h",
                         $time, result_enable, bbox_data, npu_result_write_bytes,
                         npu_result_checksum, perf_cycle,
                         {frame_count, 5'd0, stream_state, 3'd0,
                          1'b1, frame_full, error_reg, 1'b1, 1'b0});
`endif
            end
        end
    end

    assign npu_irq = irq_pending && irq_en;

    always @(posedge aclk) begin
        if (!aresetn || ctrl_soft_reset) begin
            stream_state      <= ST_IDLE;
            start_delay       <= 8'd0;
            stream_word_idx   <= {FRAME_WORD_AW{1'b0}};
            stream_byte_sel   <= 2'd0;
            stream_byte_count <= 16'd0;
            stream_word       <= 32'd0;
        end else begin
            case (stream_state)
                ST_IDLE: begin
                    if (start_accept && !input_preload_mode) begin
                        stream_state      <= ST_PRIME;
                        start_delay       <= START_DELAY_L;
                        stream_word_idx   <= {FRAME_WORD_AW{1'b0}};
                        stream_byte_sel   <= 2'd0;
                        stream_byte_count <= 16'd0;
                    end
                end
                ST_PRIME: begin
                    if (start_delay == 8'd0) begin
                        stream_state <= ST_LOAD;
                    end else begin
                        start_delay <= start_delay - 8'd1;
                    end
                end
                ST_LOAD: begin
                    stream_word  <= frame_mem_rdata;
                    stream_state <= ST_SEND;
                end
                ST_SEND: begin
                    if (stream_last_byte) begin
                        stream_state <= ST_WAIT;
                    end else begin
                        stream_byte_count <= stream_byte_count + 16'd1;
                        if (stream_byte_sel == 2'd3) begin
                            stream_byte_sel <= 2'd0;
                            stream_word_idx <= stream_word_idx + {{(FRAME_WORD_AW-1){1'b0}}, 1'b1};
                            stream_state    <= ST_LOAD;
                        end else begin
                            stream_byte_sel <= stream_byte_sel + 2'd1;
                        end
                    end
                end
                ST_WAIT: begin
                    if (result_complete) begin
                        stream_state <= ST_IDLE;
                    end
                end
                default: begin
                    stream_state <= ST_IDLE;
                end
            endcase
        end
    end

    /*
     * i_frame_valid is a new-frame pulse, not a lifetime qualifier for the
     * pixel stream.  Holding it high through ST_SEND can retrigger a short
     * network after it returns to IDLE but before the wrapper has emitted the
     * last input byte (LeNet completes quickly enough to expose this).
     */
    wire npu_frame_valid = start_accept;
    wire npu_lbp_valid   = (!input_preload_mode) && (stream_state == ST_SEND);
    wire [7:0] npu_lbp_pixel =
        (stream_byte_sel == 2'd0) ? stream_word[7:0]   :
        (stream_byte_sel == 2'd1) ? stream_word[15:8]  :
        (stream_byte_sel == 2'd2) ? stream_word[23:16] :
                                    stream_word[31:24];

    // -------------------------------------------------------------------------
    // NPU instance
    // -------------------------------------------------------------------------
    generate
        if (USE_NPU_STUB) begin : gen_npu_stub
            assign m_axi_arid    = 4'd0;
            assign m_axi_araddr  = 32'd0;
            assign m_axi_arlen   = 8'd0;
            assign m_axi_arsize  = 3'd0;
            assign m_axi_arburst = 2'd0;
            assign m_axi_arlock  = 1'b0;
            assign m_axi_arcache = 4'd0;
            assign m_axi_arprot  = 3'd0;
            assign m_axi_arvalid = 1'b0;
            assign m_axi_rready  = 1'b1;
            assign m_axi_awid    = 4'd0;
            assign m_axi_awaddr  = 32'd0;
            assign m_axi_awlen   = 8'd0;
            assign m_axi_awsize  = 3'd0;
            assign m_axi_awburst = 2'd0;
            assign m_axi_awlock  = 1'b0;
            assign m_axi_awcache = 4'd0;
            assign m_axi_awprot  = 3'd0;
            assign m_axi_awvalid = 1'b0;
            assign m_axi_wid     = 4'd0;
            assign m_axi_wdata   = 32'd0;
            assign m_axi_wstrb   = 4'd0;
            assign m_axi_wlast   = 1'b0;
            assign m_axi_wvalid  = 1'b0;
            assign m_axi_bready  = 1'b1;
            assign dma_error_snoop = 1'b0;
            assign pool_reorder_dbg0 = 32'd0;
            assign pool_reorder_dbg1 = 32'd0;
            assign pool_reorder_dbg2 = 32'd0;
            assign pool_reorder_dbg3 = 32'd0;
            assign pool_reorder_dbg4 = 32'd0;
            assign pool_reorder_dbg5 = 32'd0;
            assign pool_reorder_dbg6 = 32'd0;
            assign pool_reorder_dbg7 = 32'd0;
            assign pool_reorder_dbg8 = 32'd0;
            assign pool_reorder_dbg9 = 32'd0;
            assign pool_reorder_dbg10 = 32'd0;
            assign pool_reorder_dbg11 = 32'd0;
            assign pool_reorder_dbg12 = 32'd0;
            assign pool_reorder_dbg13 = 32'd0;
            assign pool_reorder_dbg14 = 32'd0;
            assign pool_reorder_dbg15 = 32'd0;
            assign pool_reorder_dbg16 = 32'd0;
            assign pool_reorder_dbg17 = 32'd0;
            assign pool_reorder_dbg18 = 32'd0;
            assign param_dma_dbg0 = 32'd0;
            assign param_dma_dbg1 = 32'd0;
            assign param_dma_dbg2 = 32'd0;
            assign param_dma_dbg3 = 32'd0;
            assign param_dma_dbg4 = 32'd0;
            assign param_dma_dbg5 = 32'd0;
            assign param_dma_dbg6 = 32'd0;
            assign param_dma_dbg7 = 32'd0;
            assign param_dma_dbg8 = 32'd0;
            assign param_dma_dbg9 = 32'd0;
            assign param_dma_dbg10 = 32'd0;
            assign param_dma_dbg11 = 32'd0;
            assign param_dma_dbg12 = 32'd0;
            assign param_dma_dbg13 = 32'd0;
            assign param_dma_dbg14 = 32'd0;
            assign param_dma_dbg15 = 32'd0;
            assign param_dma_dbg16 = 32'd0;
            assign param_dma_dbg17 = 32'd0;
            assign param_dma_dbg18 = 32'd0;
            assign layer_dbg0 = 32'd0;
            assign layer_dbg1 = 32'd0;
            assign layer_dbg2 = 32'd0;
            assign layer_dbg3 = 32'd0;
            assign layer_dbg4 = 32'd0;
            assign layer_dbg5 = 32'd0;
            assign layer_dbg6 = 32'd0;
            assign layer_dbg7 = 32'd0;
            assign npu_result_busy = 1'b0;
            assign npu_result_done = npu_inference_done;
            assign npu_result_error = 1'b0;
            assign npu_result_write_bytes = 32'd0;
            assign npu_result_checksum = 32'd0;
            assign npu_result_last_addr = 32'd0;

            npu_top_with_dma_stub #(
                .FRAME_PIXELS (FRAME_PIXELS)
            ) u_npu_top_with_dma (
                .clk                   (aclk),
                .rst_n                 (aresetn && !ctrl_soft_reset),
                .i_frame_valid         (npu_frame_valid),
                .i_lbp_valid           (npu_lbp_valid),
                .i_lbp_pixel           (npu_lbp_pixel),
                .o_result_stream_valid (npu_result_stream_valid),
                .o_result_stream_data  (npu_result_stream_data),
                .o_inference_done      (npu_inference_done),
                .o_bbox_valid          (npu_bbox_valid),
                .o_bbox_data           (npu_bbox_data),
                .o_dma_req_snoop       (dma_req_snoop),
                .o_dma_done_snoop      (dma_done_snoop),
                .o_dma_base_addr_snoop (dma_base_addr_snoop),
                .o_dma_length_snoop    (dma_length_snoop)
            );
        end else if (USE_AXI_DMA) begin : gen_npu_axi_dma
            npu_top_with_axi_dma #(
                .USE_POOL_REORDER_AXI(USE_POOL_REORDER_AXI),
                .POOL_AXI_BURST_BEATS(POOL_AXI_BURST_BEATS)
            ) u_npu_top_with_axi_dma (
                .clk                   (aclk),
                .rst_n                 (aresetn && !ctrl_soft_reset),
                .i_frame_valid         (npu_frame_valid),
                .i_lbp_valid           (npu_lbp_valid),
                .i_lbp_pixel           (npu_lbp_pixel),
                .i_l0_input_preload_en (input_preload_enable),
                .i_l0_input_packed_en  (input_preload_packed),
                .i_preload_wr_en       (preload_core_wr_en),
                .i_preload_target      (input_preload_target),
                .i_preload_wr_addr     (preload_core_wr_addr),
                .i_preload_wr_mask     (preload_core_wr_mask),
                .i_preload_wr_data     (preload_core_wr_data),
                .i_skip_lbp_load       (input_preload_skip_lbp),
                .i_param_base_addr     (param_base_addr),
                .i_pool_scratch_base_addr(scratch_base_addr),
                .i_result_enable       (result_enable),
                .i_result_start        (result_start_pulse),
                .i_result_base_addr    (result_base_addr),
                .i_result_max_bytes    (result_max_bytes),
                .i_desc_we             (desc_we),
                .i_desc_layer          (desc_layer),
                .i_desc_word           (desc_word),
                .i_desc_wdata          (desc_wdata),
                .i_layer_count         (desc_mode_en ? layer_count : 5'd10),
                .o_result_stream_valid (npu_result_stream_valid),
                .o_result_stream_data  (npu_result_stream_data),
                .o_inference_done      (npu_inference_done),
                .o_result_busy         (npu_result_busy),
                .o_result_done         (npu_result_done),
                .o_result_error        (npu_result_error),
                .o_result_write_bytes  (npu_result_write_bytes),
                .o_result_checksum     (npu_result_checksum),
                .o_result_last_addr    (npu_result_last_addr),
                .o_bbox_valid          (npu_bbox_valid),
                .o_bbox_data           (npu_bbox_data),
                .o_dma_req_snoop       (dma_req_snoop),
                .o_dma_done_snoop      (dma_done_snoop),
                .o_dma_base_addr_snoop (dma_base_addr_snoop),
                .o_dma_length_snoop    (dma_length_snoop),
                .o_dma_error_snoop     (dma_error_snoop),
                .o_pool_reorder_dbg0   (pool_reorder_dbg0),
                .o_pool_reorder_dbg1   (pool_reorder_dbg1),
                .o_pool_reorder_dbg2   (pool_reorder_dbg2),
                .o_pool_reorder_dbg3   (pool_reorder_dbg3),
                .o_pool_reorder_dbg4   (pool_reorder_dbg4),
                .o_pool_reorder_dbg5   (pool_reorder_dbg5),
                .o_pool_reorder_dbg6   (pool_reorder_dbg6),
                .o_pool_reorder_dbg7   (pool_reorder_dbg7),
                .o_pool_reorder_dbg8   (pool_reorder_dbg8),
                .o_pool_reorder_dbg9   (pool_reorder_dbg9),
                .o_pool_reorder_dbg10  (pool_reorder_dbg10),
                .o_pool_reorder_dbg11  (pool_reorder_dbg11),
                .o_pool_reorder_dbg12  (pool_reorder_dbg12),
                .o_pool_reorder_dbg13  (pool_reorder_dbg13),
                .o_pool_reorder_dbg14  (pool_reorder_dbg14),
                .o_pool_reorder_dbg15  (pool_reorder_dbg15),
                .o_pool_reorder_dbg16  (pool_reorder_dbg16),
                .o_pool_reorder_dbg17  (pool_reorder_dbg17),
                .o_pool_reorder_dbg18  (pool_reorder_dbg18),
                .o_param_dma_dbg0      (param_dma_dbg0),
                .o_param_dma_dbg1      (param_dma_dbg1),
                .o_param_dma_dbg2      (param_dma_dbg2),
                .o_param_dma_dbg3      (param_dma_dbg3),
                .o_param_dma_dbg4      (param_dma_dbg4),
                .o_param_dma_dbg5      (param_dma_dbg5),
                .o_param_dma_dbg6      (param_dma_dbg6),
                .o_param_dma_dbg7      (param_dma_dbg7),
                .o_param_dma_dbg8      (param_dma_dbg8),
                .o_param_dma_dbg9      (param_dma_dbg9),
                .o_param_dma_dbg10     (param_dma_dbg10),
                .o_param_dma_dbg11     (param_dma_dbg11),
                .o_param_dma_dbg12     (param_dma_dbg12),
                .o_param_dma_dbg13     (param_dma_dbg13),
                .o_param_dma_dbg14     (param_dma_dbg14),
                .o_param_dma_dbg15     (param_dma_dbg15),
                .o_param_dma_dbg16     (param_dma_dbg16),
                .o_param_dma_dbg17     (param_dma_dbg17),
                .o_param_dma_dbg18     (param_dma_dbg18),
                .i_layer_dbg_sel       (layer_dbg_sel),
                .o_layer_dbg0          (layer_dbg0),
                .o_layer_dbg1          (layer_dbg1),
                .o_layer_dbg2          (layer_dbg2),
                .o_layer_dbg3          (layer_dbg3),
                .o_layer_dbg4          (layer_dbg4),
                .o_layer_dbg5          (layer_dbg5),
                .o_layer_dbg6          (layer_dbg6),
                .o_layer_dbg7          (layer_dbg7),
                .m_axi_arid            (m_axi_arid),
                .m_axi_araddr          (m_axi_araddr),
                .m_axi_arlen           (m_axi_arlen),
                .m_axi_arsize          (m_axi_arsize),
                .m_axi_arburst         (m_axi_arburst),
                .m_axi_arlock          (m_axi_arlock),
                .m_axi_arcache         (m_axi_arcache),
                .m_axi_arprot          (m_axi_arprot),
                .m_axi_arvalid         (m_axi_arvalid),
                .m_axi_arready         (m_axi_arready),
                .m_axi_rid             (m_axi_rid),
                .m_axi_rdata           (m_axi_rdata),
                .m_axi_rresp           (m_axi_rresp),
                .m_axi_rlast           (m_axi_rlast),
                .m_axi_rvalid          (m_axi_rvalid),
                .m_axi_rready          (m_axi_rready),
                .m_axi_awid            (m_axi_awid),
                .m_axi_awaddr          (m_axi_awaddr),
                .m_axi_awlen           (m_axi_awlen),
                .m_axi_awsize          (m_axi_awsize),
                .m_axi_awburst         (m_axi_awburst),
                .m_axi_awlock          (m_axi_awlock),
                .m_axi_awcache         (m_axi_awcache),
                .m_axi_awprot          (m_axi_awprot),
                .m_axi_awvalid         (m_axi_awvalid),
                .m_axi_awready         (m_axi_awready),
                .m_axi_wid             (m_axi_wid),
                .m_axi_wdata           (m_axi_wdata),
                .m_axi_wstrb           (m_axi_wstrb),
                .m_axi_wlast           (m_axi_wlast),
                .m_axi_wvalid          (m_axi_wvalid),
                .m_axi_wready          (m_axi_wready),
                .m_axi_bid             (m_axi_bid),
                .m_axi_bresp           (m_axi_bresp),
                .m_axi_bvalid          (m_axi_bvalid),
                .m_axi_bready          (m_axi_bready)
            );
        end else begin : gen_npu_real
            assign m_axi_arid    = 4'd0;
            assign m_axi_araddr  = 32'd0;
            assign m_axi_arlen   = 8'd0;
            assign m_axi_arsize  = 3'd0;
            assign m_axi_arburst = 2'd0;
            assign m_axi_arlock  = 1'b0;
            assign m_axi_arcache = 4'd0;
            assign m_axi_arprot  = 3'd0;
            assign m_axi_arvalid = 1'b0;
            assign m_axi_rready  = 1'b1;
            assign m_axi_awid    = 4'd0;
            assign m_axi_awaddr  = 32'd0;
            assign m_axi_awlen   = 8'd0;
            assign m_axi_awsize  = 3'd0;
            assign m_axi_awburst = 2'd0;
            assign m_axi_awlock  = 1'b0;
            assign m_axi_awcache = 4'd0;
            assign m_axi_awprot  = 3'd0;
            assign m_axi_awvalid = 1'b0;
            assign m_axi_wid     = 4'd0;
            assign m_axi_wdata   = 32'd0;
            assign m_axi_wstrb   = 4'd0;
            assign m_axi_wlast   = 1'b0;
            assign m_axi_wvalid  = 1'b0;
            assign m_axi_bready  = 1'b1;
            assign dma_error_snoop = 1'b0;
            assign pool_reorder_dbg0 = 32'd0;
            assign pool_reorder_dbg1 = 32'd0;
            assign pool_reorder_dbg2 = 32'd0;
            assign pool_reorder_dbg3 = 32'd0;
            assign pool_reorder_dbg4 = 32'd0;
            assign pool_reorder_dbg5 = 32'd0;
            assign pool_reorder_dbg6 = 32'd0;
            assign pool_reorder_dbg7 = 32'd0;
            assign pool_reorder_dbg8 = 32'd0;
            assign pool_reorder_dbg9 = 32'd0;
            assign pool_reorder_dbg10 = 32'd0;
            assign pool_reorder_dbg11 = 32'd0;
            assign pool_reorder_dbg12 = 32'd0;
            assign pool_reorder_dbg13 = 32'd0;
            assign pool_reorder_dbg14 = 32'd0;
            assign pool_reorder_dbg15 = 32'd0;
            assign pool_reorder_dbg16 = 32'd0;
            assign pool_reorder_dbg17 = 32'd0;
            assign pool_reorder_dbg18 = 32'd0;
            assign param_dma_dbg0 = 32'd0;
            assign param_dma_dbg1 = 32'd0;
            assign param_dma_dbg2 = 32'd0;
            assign param_dma_dbg3 = 32'd0;
            assign param_dma_dbg4 = 32'd0;
            assign param_dma_dbg5 = 32'd0;
            assign param_dma_dbg6 = 32'd0;
            assign param_dma_dbg7 = 32'd0;
            assign param_dma_dbg8 = 32'd0;
            assign param_dma_dbg9 = 32'd0;
            assign param_dma_dbg10 = 32'd0;
            assign param_dma_dbg11 = 32'd0;
            assign param_dma_dbg12 = 32'd0;
            assign param_dma_dbg13 = 32'd0;
            assign param_dma_dbg14 = 32'd0;
            assign param_dma_dbg15 = 32'd0;
            assign param_dma_dbg16 = 32'd0;
            assign param_dma_dbg17 = 32'd0;
            assign param_dma_dbg18 = 32'd0;
            assign layer_dbg0 = 32'd0;
            assign layer_dbg1 = 32'd0;
            assign layer_dbg2 = 32'd0;
            assign layer_dbg3 = 32'd0;
            assign layer_dbg4 = 32'd0;
            assign layer_dbg5 = 32'd0;
            assign layer_dbg6 = 32'd0;
            assign layer_dbg7 = 32'd0;
            assign npu_result_busy = 1'b0;
            assign npu_result_done = npu_inference_done;
            assign npu_result_error = 1'b0;
            assign npu_result_write_bytes = 32'd0;
            assign npu_result_checksum = 32'd0;
            assign npu_result_last_addr = 32'd0;

            npu_top_with_dma #(
                .PARAMS_HEX (PARAMS_HEX),
                .ROM_DEPTH  (ROM_DEPTH)
            ) u_npu_top_with_dma (
                .clk                   (aclk),
                .rst_n                 (aresetn && !ctrl_soft_reset),
                .i_frame_valid         (npu_frame_valid),
                .i_lbp_valid           (npu_lbp_valid),
                .i_lbp_pixel           (npu_lbp_pixel),
                .o_result_stream_valid (npu_result_stream_valid),
                .o_result_stream_data  (npu_result_stream_data),
                .o_inference_done      (npu_inference_done),
                .o_bbox_valid          (npu_bbox_valid),
                .o_bbox_data           (npu_bbox_data),
                .o_dma_req_snoop       (dma_req_snoop),
                .o_dma_done_snoop      (dma_done_snoop),
                .o_dma_base_addr_snoop (dma_base_addr_snoop),
                .o_dma_length_snoop    (dma_length_snoop)
            );
        end
    endgenerate

endmodule
