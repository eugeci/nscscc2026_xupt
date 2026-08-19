// -----------------------------------------------------------------------------
// Module      : npu_core_top
// Description : NPU 纯硬件自动化推理顶层 (No-CPU Architecture)
//               集成了 Microcode Sequencer, BCU_v2, Ping-Pong RAM, Compute Engine
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module npu_core_top #(
    parameter NUM_CHANNELS  = 16,
    parameter PIXEL_W       = 8,
    parameter WEIGHT_W      = 8,
    parameter ACC_WIDTH     = 32,
    parameter DSP_MAC_LANES = 9,
    parameter USE_DESC_RAM  = 1'b0,
    parameter USE_POOL_REORDER_AXI = 1'b0,
    parameter POOL_AXI_BURST_BEATS = 4,
    // Full per-layer history is useful during RTL bring-up but costs about
    // 7.3k LUT / 17k FF on the SoC FPGA and creates severe routing pressure.
    parameter ENABLE_LAYER_DEBUG = 1'b1
)(
    input  wire         clk,
    input  wire         rst_n,

    // ==========================================
    // 1. External LBP Sensor Interface (前端摄像头像流)
    // ==========================================
    input  wire         i_frame_valid,
    input  wire         i_lbp_valid,
    input  wire [7:0]   i_lbp_pixel,

    // ==========================================
    // 1a. Layer-0 input preload bypass
    // ==========================================
    input  wire         i_l0_input_preload_en,
    input  wire         i_l0_input_packed_en,
    input  wire         i_preload_wr_en,
    input  wire         i_preload_target,      // 第一版仅支持 0=PING
    input  wire [12:0]  i_preload_wr_addr,
    input  wire [15:0]  i_preload_wr_mask,
    input  wire [127:0] i_preload_wr_data,
    input  wire         i_skip_lbp_load,

    // ==========================================
    // 1b. Descriptor RAM Configuration Interface (软件可编程网络结构)
    // ==========================================
    input  wire         i_desc_we,
    input  wire [4:0]   i_desc_layer,
    input  wire [2:0]   i_desc_word,
    input  wire [31:0]  i_desc_wdata,
    input  wire [4:0]   i_layer_count,

    // ==========================================
    // 2. DMA Weight Controller Interface (去往片外 DDR/Flash 搬运器)
    // ==========================================
    output wire         o_dma_req,
    output wire [15:0]  o_dma_base_addr,
    output wire [15:0]  o_bias_base_addr,
    output wire [15:0]  o_dma_length,
    input  wire         i_dma_ack,
    input  wire         i_dma_done,

    // 数据面: DMA 权重灌入总线
    input  wire[WEIGHT_W*9*2-1:0] weight_in_data,
    input  wire                  weight_in_valid,
    input  wire[9:0]            weight_in_addr,
    input  wire                  update_weights_en,

    // 数据面: DMA 偏置灌入总线
    input  wire [31:0]          bias_in_data,
    input  wire                 bias_in_valid,
    input  wire [4:0]           bias_in_addr,
    input  wire                 update_bias_en,

    // ==========================================
    // 2c. Pool reorder scratch memory AXI master
    // ==========================================
    input  wire [31:0]  i_pool_scratch_base_addr,
    output wire         o_pool_reorder_error,
    output wire [31:0]  o_pool_reorder_dbg0,
    output wire [31:0]  o_pool_reorder_dbg1,
    output wire [31:0]  o_pool_reorder_dbg2,
    output wire [31:0]  o_pool_reorder_dbg3,
    output wire [31:0]  o_pool_reorder_dbg4,
    output wire [31:0]  o_pool_reorder_dbg5,
    output wire [31:0]  o_pool_reorder_dbg6,
    output wire [31:0]  o_pool_reorder_dbg7,
    output wire [31:0]  o_pool_reorder_dbg8,
    output wire [31:0]  o_pool_reorder_dbg9,
    output wire [31:0]  o_pool_reorder_dbg10,
    output wire [31:0]  o_pool_reorder_dbg11,
    output wire [31:0]  o_pool_reorder_dbg12,
    output wire [31:0]  o_pool_reorder_dbg13,
    output wire [31:0]  o_pool_reorder_dbg14,
    output wire [31:0]  o_pool_reorder_dbg15,
    output wire [31:0]  o_pool_reorder_dbg16,
    output wire [31:0]  o_pool_reorder_dbg17,
    output wire [31:0]  o_pool_reorder_dbg18,

    input  wire [6:0]   i_layer_dbg_sel,
    output wire [31:0]  o_layer_dbg0,
    output wire [31:0]  o_layer_dbg1,
    output wire [31:0]  o_layer_dbg2,
    output wire [31:0]  o_layer_dbg3,
    output wire [31:0]  o_layer_dbg4,
    output wire [31:0]  o_layer_dbg5,
    output wire [31:0]  o_layer_dbg6,
    output wire [31:0]  o_layer_dbg7,

    output wire [3:0]   m_axi_arid,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [2:0]   m_axi_arprot,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [3:0]   m_axi_rid,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    output wire [3:0]   m_axi_awid,
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [2:0]   m_axi_awprot,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [3:0]   m_axi_wid,
    output wire [31:0]  m_axi_wdata,
    output wire [3:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [3:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,

    // ==========================================
    // 2b. Sequencer 控制面 snoop 输出 (供外部 DMA 适配器使用, Step 16.3 M3 新增)
    // ==========================================
    output wire [1:0]   o_kernel_size,     // 00=1x1 / 01=2x2 / 10=3x3

    // ==========================================
    // 3. Final Result Interface
    // ==========================================
    output wire         o_result_stream_valid,
    output wire [127:0] o_result_stream_data,
    output wire         o_inference_done,
    output wire         o_bbox_valid,
    output wire[39:0]  o_bbox_data
);

    // ==========================================
    // 内部互连信号声明
    // ==========================================
    
    // ---- Sequencer 控制流与配置广播 ----
    wire        w_is_init_phase;
    wire        w_layer_start, w_layer_done, w_pingpong_sel;
    wire        w_is_fc_mode;
    wire [1:0]  w_activation_type;
    wire        w_pool_en;
    wire        w_padding_en_uc;   // 微码位 [13]: 显式 padding 开关
    wire [1:0]  w_kernel_size;
    assign o_kernel_size = w_kernel_size;
    wire [9:0]  w_cin_total, w_cout_total;
    wire [9:0]  w_img_width, w_img_height;
    wire [3:0]  w_shift_bits;
    wire [3:0]  w_oc_group_idx;
    wire [4:0]  w_oc_block_size;

    // ---- Cin Group 信号 (Step 14.1b) ----
    wire [5:0]  w_cin_group_idx;
    wire [4:0]  w_cin_block_size;
    wire        w_is_first_cin_group;
    wire        w_is_last_cin_group;

    // LBP 直通写入控制 (地址 15b 对应 lbp_input_buffer 20K 深度)
    wire        w_lbp_wr_en;
    wire [14:0] w_lbp_wr_addr;
    wire [7:0]  w_lbp_wr_data;
    wire [4:0]  w_layer_id;          // 当前层 PC，用于 layer-0 读取路由

    // ---- BCU 读写控制网格 ----
    // 读地址 15b：fm_bank_array 取低 13b，lbp_input_buffer 使用全 15b
    // 写地址 13b：对应 fm_bank_array 深度 8K
    wire [14:0] w_bcu_rd_addr;
    wire [12:0] w_bcu_wr_addr;
    wire        w_bcu_rd_en;
    wire [3:0]  w_bcu_cin_idx;      // FM bank 选择
    wire [7:0]  w_bcu_cin_idx_full; // 完整 Cin 索引 (供 weight_buffer)
    // [Step 14.1l] BCU r_cin_idx -> SRAM 读取 (1 拍 BRAM 延迟) 后, 数据才到达 conv_engine_top.
    //   在此处对 cin_idx_full 加 1 拍寄存器, 使其与 SRAM 输出数据相位对齐;
    //   conv_engine_top 内部还会再加 1 拍以匹配 line_buffer p11 寄存器, 总共 2 拍延迟。
    //   这样 mac_tree 同时收到 cin K 的数据和 cin K 的权重, 修正最后 2 个像素的 off-by-one bug。
    reg [7:0]   r_bcu_cin_idx_full_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_bcu_cin_idx_full_d1 <= 8'd0;
        else        r_bcu_cin_idx_full_d1 <= w_bcu_cin_idx_full;
    end

    // ---- LBP Input Buffer (layer-0 专用) ----
    wire [7:0]  w_lbp_buf_read_data;
    wire        w_use_lbp_buf = (w_layer_id == 5'd0) && !i_l0_input_preload_en;
    wire        w_use_l0_packed_ping = (w_layer_id == 5'd0) &&
                                       i_l0_input_preload_en &&
                                       i_l0_input_packed_en &&
                                       !i_preload_target;
    
    // ---- NPU 数据流与握手 ----
    wire        w_npu_in_valid, w_npu_out_valid;
    wire        w_npu_in_ready;
    wire        w_npu_is_first_cin, w_npu_is_last_cin;
    wire [127:0] w_npu_out_bus;
    wire [7:0]  w_npu_out_x, w_npu_out_y;  // [Step 14.1m] conv 实际输出坐标 → BCU 写地址
    // [Step 14.1k 方案A] conv_engine_top 流水排空标志 -> BCU
    wire        w_pipeline_idle;
    wire [31:0] w_dbg_pe_fold;
    wire [31:0] w_dbg_bias_fold;
    wire [31:0] w_dbg_quant_fold;
    wire [31:0] w_dbg_wt_fold;
    wire [7:0]  w_dbg_valid_flags;
    wire [31:0] w_bcu_dbg0;
    wire [31:0] w_bcu_dbg1;
    wire [31:0] w_bcu_dbg2;
    wire [31:0] w_bcu_dbg3;

    // ---- 缓存阵列数据总线 ----
    wire [7:0]  w_ping_read_data, w_pong_read_data;

    // ==========================================
    // 1. NPU Sequencer 实例化
    // ==========================================
    npu_sequencer #(
        .USE_DESC_RAM   (USE_DESC_RAM)
    ) u_sequencer (
        .clk                (clk),
        .rst_n              (rst_n),

        .i_frame_valid      (i_frame_valid),
        .i_lbp_valid        (i_lbp_valid),
        .i_lbp_pixel        (i_lbp_pixel),
        .i_skip_lbp_load    (i_skip_lbp_load),

        .o_lbp_wr_en        (w_lbp_wr_en),
        .o_lbp_wr_addr      (w_lbp_wr_addr),
        .o_lbp_wr_data      (w_lbp_wr_data),
        .o_is_init_phase    (w_is_init_phase), // [C组微调] 导出 PC==0 标识供 A 组路由使用
        .o_layer_id         (w_layer_id),

        .i_desc_we          (i_desc_we),
        .i_desc_layer       (i_desc_layer),
        .i_desc_word        (i_desc_word),
        .i_desc_wdata       (i_desc_wdata),
        .i_layer_count      (i_layer_count),

        .o_dma_req          (o_dma_req),
        .o_dma_base_addr    (o_dma_base_addr),
        .o_bias_base_addr   (o_bias_base_addr),
        .o_dma_length       (o_dma_length),
        .i_dma_ack          (i_dma_ack),
        .i_dma_done         (i_dma_done),

        .o_is_fc_mode       (w_is_fc_mode),
        .o_activation_type  (w_activation_type),
        .o_pool_en          (w_pool_en),
        .o_padding_en       (w_padding_en_uc),
        .o_kernel_size      (w_kernel_size),
        .o_cin_total        (w_cin_total),
        .o_cout_total       (w_cout_total),
        .o_img_width        (w_img_width),
        .o_img_height       (w_img_height),
        .o_shift_bits       (w_shift_bits),
        .o_pingpong_sel     (w_pingpong_sel),
        .o_oc_group_idx     (w_oc_group_idx),
        .o_oc_block_size    (w_oc_block_size),

        // Cin 分组输出 (Step 14.1b)
        .o_cin_group_idx        (w_cin_group_idx),
        .o_cin_block_size       (w_cin_block_size),
        .o_is_first_cin_group   (w_is_first_cin_group),
        .o_is_last_cin_group    (w_is_last_cin_group),

        .o_layer_start      (w_layer_start),
        .i_layer_done       (w_layer_done),
        .i_npu_out_valid    (w_npu_out_valid),
        .i_npu_out_bus      (w_npu_out_bus),

        .o_result_stream_valid(o_result_stream_valid),
        .o_result_stream_data(o_result_stream_data),
        .o_inference_done   (o_inference_done),
        .o_bbox_valid       (o_bbox_valid),
        .o_bbox_data        (o_bbox_data)
    );

    // ==========================================
    // 2. 跨组协定: FC 地址欺骗适配逻辑 (Address Deception)
    // ==========================================
    // BCU 获得真实的特征图宽高，用于完整遍历 768 个特征值
    wire[7:0] w_bcu_cfg_width  = w_img_width[7:0];
    wire[7:0] w_bcu_cfg_height = w_img_height[7:0];
    
    // NPU 被欺骗为 1x1 分辨率，迫使其将 48 个周期的输入全部累加到 (X=0, Y=0) 位置
    wire [7:0] w_npu_cfg_width  = w_is_fc_mode ? 8'd1 : w_img_width[7:0];
    wire [7:0] w_npu_cfg_height = w_is_fc_mode ? 8'd1 : w_img_height[7:0];

    // Padding 配置：统一由 sequencer 译码输出。
    // - legacy 模式: sequencer 内部处理 (显式 bit[13] OR kernel==3×3 隐式)
    // - descriptor 模式: sequencer 从 pad_mode 字段译码 (VALID→0, SAME_ZERO→1)
    wire w_cfg_padding_en = w_padding_en_uc;

    // ==========================================
    // 3. BCU_v2 缓存调度中心实例化
    // ==========================================
    bcu u_bcu (
        .clk              (clk), 
        .rst_n            (rst_n),
        .layer_start      (w_layer_start), 
        .layer_done       (w_layer_done),
        .i_is_fc_mode     (w_is_fc_mode),      // [新增] 接入 FC 模式
        .i_cfg_width      (w_bcu_cfg_width),   // [输入真实维度]
        .i_cfg_height     (w_bcu_cfg_height),
        .i_cfg_kernel     (w_kernel_size), 
        .i_cfg_pool_en    (w_pool_en),
        .i_cfg_padding_en (w_cfg_padding_en), 
        .i_cfg_cin_total  (w_cin_total[7:0]),
        .i_oc_group_idx   (w_oc_group_idx),

        // Cin 分组输入 (Step 14.1b)
        .i_cin_group_idx        (w_cin_group_idx),
        .i_cin_block_size       (w_cin_block_size),
        .i_is_first_cin_group   (w_is_first_cin_group),
        .i_is_last_cin_group    (w_is_last_cin_group),
        .i_is_layer0            (w_layer_id == 5'd0),
        .i_l0_packed_read_en    (w_use_l0_packed_ping),
        
        .o_sram_rd_addr   (w_bcu_rd_addr), 
        .o_sram_rd_en     (w_bcu_rd_en),
        .o_sram_cin_idx   (w_bcu_cin_idx),
        .o_cin_idx_full   (w_bcu_cin_idx_full),
        .o_sram_wr_addr   (w_bcu_wr_addr),
        
        .i_npu_in_ready    (w_npu_in_ready),
        .o_npu_in_valid     (w_npu_in_valid), 
        .o_npu_is_first_cin (w_npu_is_first_cin), 
        .o_npu_is_last_cin  (w_npu_is_last_cin),  
        .i_npu_out_valid    (w_npu_out_valid),
        // [Step 14.1m] conv 实际输出坐标接入 BCU, 用于 SRAM 写地址精确寻址
        .i_conv_out_x       (w_npu_out_x),
        .i_conv_out_y       (w_npu_out_y),

        // [Step 14.1k 方案A] 来自 conv_engine_top, 闸控 layer_done
        .i_pipeline_idle    (w_pipeline_idle),
        .o_dbg0             (w_bcu_dbg0),
        .o_dbg1             (w_bcu_dbg1),
        .o_dbg2             (w_bcu_dbg2),
        .o_dbg3             (w_bcu_dbg3)
    );

    // ==========================================
    // 4. Memory Crossbar (PING/PONG + LBP Buffer Routing)
    // ==========================================
    // ---- LBP Input Buffer 读写路由 ----
    // 写：ST_LOAD_IMG 期间 LBP 串行写入专用缓冲区（不再占用 PING bank 0）
    // 读：layer-0 ST_CALC 期间 BCU 顺序读出 LBP image
    wire        w_lbp_buf_wr_en   = w_is_init_phase & w_lbp_wr_en;
    wire [14:0] w_lbp_buf_wr_addr = w_lbp_wr_addr;
    wire [7:0]  w_lbp_buf_wr_data = w_lbp_wr_data;
    wire        w_lbp_buf_rd_en   = w_use_lbp_buf & w_bcu_rd_en;
    wire [14:0] w_lbp_buf_rd_addr = w_bcu_rd_addr;

    // ---- PING 阵列读写路由 ----
    // layer-0 读从 LBP buffer，不再读 PING；layer-0 也不再写 PING (原本只写 bank 0)
    wire w_l0_packed_rd_ping = w_use_l0_packed_ping & w_bcu_rd_en;
    wire w_mid_rd_ping = (w_layer_id != 5'd0) & w_bcu_rd_en & (~w_pingpong_sel);
    wire w_ping_rd_en = w_l0_packed_rd_ping | w_mid_rd_ping;
    wire w_ping_compute_wr_en = (!w_is_init_phase) & w_npu_out_valid & w_pingpong_sel;
    wire w_ping_preload_wr_en = i_preload_wr_en & !i_preload_target;
    wire w_ping_wr_en = w_ping_preload_wr_en | w_ping_compute_wr_en;
    wire [12:0] w_ping_wr_addr = w_ping_preload_wr_en ? i_preload_wr_addr : w_bcu_wr_addr;
    wire [127:0] w_ping_wr_data = w_ping_preload_wr_en ? i_preload_wr_data : w_npu_out_bus;
    wire [15:0] w_ping_wr_mask = w_ping_preload_wr_en ? i_preload_wr_mask : 16'hffff;

    // ---- PONG 阵列读写路由 ----
    wire w_pong_rd_en   = (w_layer_id != 5'd0) & w_bcu_rd_en & (w_pingpong_sel);
    wire w_pong_wr_en   = (!w_is_init_phase) & w_npu_out_valid & (~w_pingpong_sel);
    wire [12:0] w_pong_wr_addr = w_bcu_wr_addr;
    wire [127:0] w_pong_wr_data = w_npu_out_bus;
    wire [15:0] w_pong_wr_mask = 16'hffff;

    // ---- 送入 NPU 的统一数据流 ----
    // layer-0 默认选 LBP buffer；packed preload 模式下选 PING；layer-1+ 按 ping-pong 选 PING/PONG。
    wire [7:0] w_npu_pixel_in = w_use_lbp_buf ? w_lbp_buf_read_data :
                                w_use_l0_packed_ping ? w_ping_read_data :
                                (w_pingpong_sel ? w_pong_read_data : w_ping_read_data);

    // ==========================================
    // 5. 特征图存储阵列 (PING / PONG, 非对称深度)
    //    读地址取低 13 位（BCU 输出 15b 高 2 位仅 LBP buffer 使用）
    //
    // [Step 15.8 · Plan G 非对称深度 · 2026-05-03]
    //   背景: Quartus/eLinx 把 M9K 物理深度对齐到 ceil(log2(声明深度))，
    //         5120 与 8192 都跨到 NUMWORDS=8192 (WIDTHAD=13)，物理等价。
    //         必须让数组声明深度 ≤ 2^k 边界才能真正节省 M9K。
    //
    //   ping / pong 读写分工（见同文件 w_*_rd_en / w_*_wr_en 路由）:
    //     pingpong_sel=0 (L0/L2/L4): 读 ping, 写 pong
    //     pingpong_sel=1 (L1/L3)  : 写 ping, 读 pong
    //   => ping 存 L1/L3 output : max = L1 C2 output 40×30 = 1200 entries
    //   => pong 存 L0/L2/L4 output: max = L0 C1 output 80×60 = 4800 entries
    //
    //   非对称深度覆盖方案 (此阶段性决策基于 FaceNet 模型):
    //     ping  BANK_DEPTH = 2048 → 物理 2 M9K/bank × 16 = 32 M9K
    //     pong  BANK_DEPTH = 5120 → 物理 8 M9K/bank × 16 = 128 M9K (跨到 8192)
    //   节省: 原 ping+pong 共 256 M9K → 160 M9K，净省 96 M9K (~8%)
    //
    //   注意: ping 参数硬编码为 2048 对 sim 和 synth 都生效 (覆盖 fm_bank_array
    //         内部的 ifdef 默认 5120)。因 max 1199 < 2048, sim 不会触发 OOB X。
    //
    //   风险: 仅对 FaceNet 模型成立。若将来换模型导致奇数层 output > 1200,
    //         必须把 ping 深度提到能覆盖的最小 2^k 值 (2048→4096→8192)。
    // ==========================================
    fm_bank_array #(.BANK_DEPTH(2048)) u_ping_array (
        .clk            (clk),
        .i_write_bus    (w_ping_wr_data), 
        .i_write_en     (w_ping_wr_en), 
        .i_write_mask   (w_ping_wr_mask),
        .i_write_addr   (w_ping_wr_addr),
        .i_read_cin_idx (w_bcu_cin_idx), 
        .i_read_en      (w_ping_rd_en), 
        .i_read_addr    (w_bcu_rd_addr[12:0]),
        .o_read_data    (w_ping_read_data)
    );

    fm_bank_array u_pong_array (                  // 默认 BANK_DEPTH=5120 (物理 8192)
        .clk            (clk),
        .i_write_bus    (w_pong_wr_data), 
        .i_write_en     (w_pong_wr_en), 
        .i_write_mask   (w_pong_wr_mask),
        .i_write_addr   (w_pong_wr_addr),
        .i_read_cin_idx (w_bcu_cin_idx), 
        .i_read_en      (w_pong_rd_en), 
        .i_read_addr    (w_bcu_rd_addr[12:0]),
        .o_read_data    (w_pong_read_data)
    );

    // ==========================================
    // 5b. LBP Input Buffer (layer-0 专用, 20K 深)
    // ==========================================
    lbp_input_buffer u_lbp_input_buf (
        .clk          (clk),
        .i_write_en   (w_lbp_buf_wr_en),
        .i_write_addr (w_lbp_buf_wr_addr),
        .i_write_data (w_lbp_buf_wr_data),
        .i_read_en    (w_lbp_buf_rd_en),
        .i_read_addr  (w_lbp_buf_rd_addr),
        .o_read_data  (w_lbp_buf_read_data)
    );

    // ==========================================
    // 6. Compute Engine (算力引擎)
    // ==========================================
    conv_engine_top #(
        .PIXEL_W      (PIXEL_W),
        .WEIGHT_W     (WEIGHT_W),
        .ACC_WIDTH    (ACC_WIDTH),
        .NUM_CHANNELS (NUM_CHANNELS),
        .DSP_MAC_LANES(DSP_MAC_LANES),
        .USE_POOL_REORDER_AXI(USE_POOL_REORDER_AXI),
        .POOL_AXI_BURST_BEATS(POOL_AXI_BURST_BEATS)
    ) u_conv_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .layer_start_clr    (w_layer_start),

        // 静态配置接入 (接收欺骗后的伪装分辨率)
        .cfg_width          (w_npu_cfg_width),
        .cfg_height         (w_npu_cfg_height),
        .kernel_size        (w_kernel_size),
        .padding_en         (w_cfg_padding_en),
        .shift_bits         (w_shift_bits),
        .cfg_pool_en        (w_pool_en),
        .cfg_activation_type(w_activation_type), // [新增] B 组需要的激活路选

        // 动态通道控制
        .is_first_cin       (w_npu_is_first_cin),
        .is_last_cin        (w_npu_is_last_cin),

        // DMA 权重更新机制
        .weight_in_data     (weight_in_data),
        .weight_in_valid    (weight_in_valid),
        .weight_in_addr     (weight_in_addr),
        .update_weights_en  (update_weights_en),

        // DMA 偏置更新机制
        .bias_in_data       (bias_in_data),
        .bias_in_valid      (bias_in_valid),
        .bias_in_addr       (bias_in_addr),
        .update_bias_en     (update_bias_en),

        // 当前 Cout 组有效 lane 数 (末组 lane 掩码)
        .i_oc_block_size    (w_oc_block_size),

        // 当前 Cin 索引（供 weight_buffer 按页深度读出对应权重）
        .i_current_cin      (r_bcu_cin_idx_full_d1),

        // 核心像素数据流
        .pixel_in_data      (w_npu_pixel_in),
        .pixel_in_valid     (w_npu_in_valid),
        .pixel_in_ready     (w_npu_in_ready),
        .out_pixel_bus      (w_npu_out_bus),
        .out_valid          (w_npu_out_valid),
        
        .out_x              (w_npu_out_x), 
        .out_y              (w_npu_out_y),

        // [Step 14.1k 方案A] pipeline 排空标志, 直接送给 BCU
        .o_dbg_pe_fold      (w_dbg_pe_fold),
        .o_dbg_bias_fold    (w_dbg_bias_fold),
        .o_dbg_quant_fold   (w_dbg_quant_fold),
        .o_dbg_wt_fold      (w_dbg_wt_fold),
        .o_dbg_valid_flags  (w_dbg_valid_flags),
        .o_pipeline_idle    (w_pipeline_idle),

        .i_pool_scratch_base_addr(i_pool_scratch_base_addr),
        .o_pool_reorder_error(o_pool_reorder_error),
        .o_pool_reorder_dbg0(o_pool_reorder_dbg0),
        .o_pool_reorder_dbg1(o_pool_reorder_dbg1),
        .o_pool_reorder_dbg2(o_pool_reorder_dbg2),
        .o_pool_reorder_dbg3(o_pool_reorder_dbg3),
        .o_pool_reorder_dbg4(o_pool_reorder_dbg4),
        .o_pool_reorder_dbg5(o_pool_reorder_dbg5),
        .o_pool_reorder_dbg6(o_pool_reorder_dbg6),
        .o_pool_reorder_dbg7(o_pool_reorder_dbg7),
        .o_pool_reorder_dbg8(o_pool_reorder_dbg8),
        .o_pool_reorder_dbg9(o_pool_reorder_dbg9),
        .o_pool_reorder_dbg10(o_pool_reorder_dbg10),
        .o_pool_reorder_dbg11(o_pool_reorder_dbg11),
        .o_pool_reorder_dbg12(o_pool_reorder_dbg12),
        .o_pool_reorder_dbg13(o_pool_reorder_dbg13),
        .o_pool_reorder_dbg14(o_pool_reorder_dbg14),
        .o_pool_reorder_dbg15(o_pool_reorder_dbg15),
        .o_pool_reorder_dbg16(o_pool_reorder_dbg16),
        .o_pool_reorder_dbg17(o_pool_reorder_dbg17),
        .o_pool_reorder_dbg18(o_pool_reorder_dbg18),
        .m_axi_arid         (m_axi_arid),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arlock       (m_axi_arlock),
        .m_axi_arcache      (m_axi_arcache),
        .m_axi_arprot       (m_axi_arprot),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rid          (m_axi_rid),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready),
        .m_axi_awid         (m_axi_awid),
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awlock       (m_axi_awlock),
        .m_axi_awcache      (m_axi_awcache),
        .m_axi_awprot       (m_axi_awprot),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wid          (m_axi_wid),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bid          (m_axi_bid),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready)
    );

    // ==========================================
    // 7. Layer-level feature-map debug
    // ==========================================
    generate
    if (ENABLE_LAYER_DEBUG) begin : gen_layer_debug
        npu_layer_debug #(
            .NUM_CHANNELS(NUM_CHANNELS)
        ) u_layer_debug (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_layer_dbg_sel  (i_layer_dbg_sel),
        .i_layer_start    (w_layer_start),
        .i_layer_done     (w_layer_done),
        .i_layer_id       (w_layer_id),
        .i_is_init_phase  (w_is_init_phase),
        .i_oc_group_idx   (w_oc_group_idx),
        .i_cin_group_idx  (w_cin_group_idx),
        .i_pool_en        (w_pool_en),
        .i_is_fc_mode     (w_is_fc_mode),
        .i_cfg_padding_en (w_cfg_padding_en),
        .i_kernel_size    (w_kernel_size),
        .i_pingpong_sel   (w_pingpong_sel),
        .i_pipeline_idle  (w_pipeline_idle),
        .i_npu_in_valid   (w_npu_in_valid),
        .i_npu_pixel_in   (w_npu_pixel_in),
        .i_npu_out_valid  (w_npu_out_valid),
        .i_npu_out_bus    (w_npu_out_bus),
        .i_npu_out_x      (w_npu_out_x),
        .i_npu_out_y      (w_npu_out_y),
        .i_bcu_wr_addr    (w_bcu_wr_addr),
        .i_bcu_dbg0       (w_bcu_dbg0),
        .i_bcu_dbg2       (w_bcu_dbg2),
        .i_dbg_pe_fold    (w_dbg_pe_fold),
        .i_dbg_bias_fold  (w_dbg_bias_fold),
        .i_dbg_quant_fold (w_dbg_quant_fold),
        .i_dbg_wt_fold    (w_dbg_wt_fold),
        .i_dbg_valid_flags(w_dbg_valid_flags),
        .o_layer_dbg0     (o_layer_dbg0),
        .o_layer_dbg1     (o_layer_dbg1),
        .o_layer_dbg2     (o_layer_dbg2),
        .o_layer_dbg3     (o_layer_dbg3),
        .o_layer_dbg4     (o_layer_dbg4),
        .o_layer_dbg5     (o_layer_dbg5),
        .o_layer_dbg6     (o_layer_dbg6),
            .o_layer_dbg7     (o_layer_dbg7)
        );
    end else begin : gen_no_layer_debug
        // Preserve the software-visible register map in timing-optimized builds.
        // These optional diagnostic registers read as zero; inference is unchanged.
        assign o_layer_dbg0 = 32'd0;
        assign o_layer_dbg1 = 32'd0;
        assign o_layer_dbg2 = 32'd0;
        assign o_layer_dbg3 = 32'd0;
        assign o_layer_dbg4 = 32'd0;
        assign o_layer_dbg5 = 32'd0;
        assign o_layer_dbg6 = 32'd0;
        assign o_layer_dbg7 = 32'd0;
    end
    endgenerate

`ifndef NO_VCD_DUMP
    initial begin
        $dumpfile("npu_core_top.vcd");
        $dumpvars(0, npu_core_top);
    end
`endif
endmodule
