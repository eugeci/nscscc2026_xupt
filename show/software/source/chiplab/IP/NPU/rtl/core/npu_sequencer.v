// -----------------------------------------------------------------------------
// Module      : npu_sequencer
// Description : NPU 全局微码定序器。替代 CPU 接管全流程推理调度，内置只读微码 ROM。
//               [C组实现] 支持 LBP 写入直通、自动 DMA 握手、FC 展平伪装与结果捕获。
//
//               [Descriptor 扩展] 新增 USE_DESC_RAM 参数，支持软件可编程的网络结构描述。
//               descriptor 模式下，由 desc_ram[32][8] 替代 microcode_rom + npu_param_rom。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "npu_descriptor_defs.vh"

module npu_sequencer #(
    // 微码层数 (必须 ≤ microcode_rom 容量 32)。默认 10 对齐 FPGALightFaceNet。
    parameter [4:0] TOTAL_LAYERS_P = 5'd10,
    // descriptor 模式开关 (0=legacy microcode_rom, 1=desc_ram)
    parameter         USE_DESC_RAM   = 1'b0,
    // descriptor RAM 最大层数 (不要声明位宽，避免 32 > 5bit 溢出)
    parameter         MAX_LAYERS     = 32
)(
    input  wire         clk,
    input  wire         rst_n,

    // ==========================================
    // 1. External LBP Sensor Interface (前端摄像头流)
    // ==========================================
    input  wire         i_frame_valid,     // 脉冲：新一帧图像到来
    input  wire         i_lbp_valid,       // 像素有效
    input  wire[7:0]   i_lbp_pixel,       // 单像素输入
    input  wire         i_skip_lbp_load,   // layer-0 preload 模式跳过 LBP load

    // ==========================================
    // 2. LBP to lbp_input_buffer Direct Write Interface (写往 LBP 专用缓冲区)
    //    地址 15b：遵 160x120=19200 LBP 输入尺寸 (>14b)
    // ==========================================
    output wire         o_lbp_wr_en,
    output wire [14:0]  o_lbp_wr_addr,
    output wire [7:0]   o_lbp_wr_data,

    output wire o_is_init_phase, // 供外部监测是否处于初始化阶段（加载图像）
    output wire [4:0]   o_layer_id,  // 当前层 PC（供外部路由 layer-0 LBP buffer 读取）

    // ==========================================
    // 2b. Descriptor RAM Write Interface (软件配置网络结构)
    // ==========================================
    input  wire         i_desc_we,         // descriptor 写使能
    input  wire [4:0]   i_desc_layer,      // 目标层号 [0..MAX_LAYERS-1]
    input  wire [2:0]   i_desc_word,       // 目标 word [0..7]
    input  wire [31:0]  i_desc_wdata,      // 写数据
    input  wire [4:0]   i_layer_count,     // descriptor 模式有效层数 (1..MAX_LAYERS)

    // ==========================================
    // 3. DMA Weight Controller Interface (去往片外 DDR/Flash 搬运器)
    // ==========================================
    output reg          o_dma_req,
    output wire [15:0]  o_dma_base_addr,   // 权重基址（参数 ROM 或 descriptor）
    output wire [15:0]  o_bias_base_addr,  // 偏置基址（参数 ROM 或 descriptor）
    output wire [15:0]  o_dma_length,      // 需要搬运的字长 (根据 Cin/Cout 推算)
    input  wire         i_dma_ack,         // DMA 握手确认
    input  wire         i_dma_done,        // DMA 搬运完成脉冲

    // ==========================================
    // 4. BCU / NPU Static Config Broadcast (全局静态配置广播)
    // ==========================================
    output reg          o_is_fc_mode,
    output reg  [1:0]   o_activation_type, // 00: ReLU, 01: HardSigmoid
    output reg          o_pool_en,
    output reg          o_padding_en,      // 微码位 [13]: 显式 padding 开关 (与 kernel==3x3 OR 派生组合在 npu_core_top)
    output reg[1:0]   o_kernel_size,     // 00: 1x1, 10: 3x3
    output reg  [9:0]   o_cin_total,
    output reg[9:0]   o_cout_total,
    output reg  [9:0]   o_img_width,
    output reg  [9:0]   o_img_height,
    output reg  [3:0]   o_shift_bits,
    output wire         o_pingpong_sel,    // 0: Read PING, 1: Read PONG

    // ==========================================
    // 4.1 Cout Group Broadcast (Cout 分组控制)
    // ==========================================
    output wire [3:0]   o_oc_group_idx,    // 当前输出分组索引 (0..oc_group_total-1)
    output wire [4:0]   o_oc_block_size,   // 当前组有效 Cout 通道数 (1..16)

    // ==========================================
    // 4.2 Cin Group Broadcast (Cin 分组控制, Step 14.1b)
    // 详见 spec_v0.1.md §2.5: 分组路径在 BCU/PE 侧 PSUM 跨组累加。
    // ==========================================
    output wire [5:0]   o_cin_group_idx,        // 当前输入分组索引 (0..63, 6-bit 支持 ≤ 1024 cin)
    output wire [4:0]   o_cin_block_size,       // 当前组有效 Cin 通道数 (1..16)
    output wire         o_is_first_cin_group,   // 是否 cin_group=0 (拉高后 BCU 才会在本组首拍发 is_first_cin)
    output wire         o_is_last_cin_group,    // 是否 cin_group=last (拉高后 BCU 才会在本组末拍发 is_last_cin，触发 PSUM 输出)

    // ==========================================
    // 5. BCU Handshake & Snoop Interface (控制流与截获)
    // ==========================================
    output reg          o_layer_start,
    input  wire         i_layer_done,
    input  wire         i_npu_out_valid,   // Snoop: 用于抓取最终输出
    input  wire[127:0] i_npu_out_bus,     // Snoop: 16路 NPU 吐出总线

    // ==========================================
    // 6. Final Result Interface
    // ==========================================
    output reg          o_result_stream_valid,
    output reg  [127:0] o_result_stream_data,
    output reg          o_inference_done,
    output reg          o_bbox_valid,
    output reg  [39:0]  o_bbox_data        // {Conf[7:0], X[7:0], Y[7:0], W[7:0], H[7:0]}
);

    // -------------------------------------------------------------------------
    // 参数与状态机定义
    // -------------------------------------------------------------------------

    // descriptor 模式用软件写入的 i_layer_count，legacy 用编译期参数。
    // 若 descriptor 模式但 i_layer_count==0（如 unconnected port），回退到 TOTAL_LAYERS_P。
    wire [4:0] w_total_layers;
    assign w_total_layers = (USE_DESC_RAM && i_layer_count != 5'd0) ? i_layer_count : TOTAL_LAYERS_P;

    localparam ST_IDLE       = 3'd0;
    localparam ST_LOAD_IMG   = 3'd1;
    localparam ST_FETCH      = 3'd2;
    localparam ST_WAIT_DMA   = 3'd3;
    localparam ST_CALC       = 3'd4;
    localparam ST_CHECK_END  = 3'd5;
    localparam ST_DONE       = 3'd6;

    reg [2:0] state, next_state;
    reg [4:0] r_pc; // Program Counter (0~31)

    // ---- Cout 分组循环计数 (外层) ----
    reg [3:0] r_oc_group_idx;   // 当前组号
    reg [3:0] r_oc_group_total; // ceil(cout_total / 16)
    wire      w_is_last_oc_group = (r_oc_group_idx == r_oc_group_total - 4'd1);
    wire [9:0] w_oc_remainder   = o_cout_total - {6'd0, r_oc_group_idx, 4'd0}; // cout_total - group*16
    wire [4:0] w_oc_block_size  = (w_oc_remainder >= 10'd16) ? 5'd16 : w_oc_remainder[4:0];
    assign o_oc_group_idx  = r_oc_group_idx;
    assign o_oc_block_size = w_oc_block_size;

    // ---- Cin 分组循环计数 (内层, Step 14.1b) ----
    // 嵌套顺序：for oc_g in 0..oc_total-1: for cin_g in 0..cin_total-1: { DMA + compute }
    // PSUM 在同一 oc_g 的多个 cin_g 之间跨 BCU 启动持久保留 (channel_accumulator.psum_ram)。
    reg [5:0] r_cin_group_idx;   // 当前输入组号 (6-bit 支持 ≤ 1024 cin = 64 组)
    reg [5:0] r_cin_group_total; // ceil(cin_total / 16)
    wire      w_is_last_cin_group  = (r_cin_group_idx == r_cin_group_total - 6'd1);
    wire      w_is_first_cin_group = (r_cin_group_idx == 6'd0);
    wire [9:0] w_cin_remainder   = o_cin_total - {4'd0, r_cin_group_idx, 4'd0};
    wire [4:0] w_cin_block_size  = (w_cin_remainder >= 10'd16) ? 5'd16 : w_cin_remainder[4:0];
    assign o_cin_group_idx      = r_cin_group_idx;
    assign o_cin_block_size     = w_cin_block_size;
    assign o_is_first_cin_group = w_is_first_cin_group;
    assign o_is_last_cin_group  = w_is_last_cin_group;

    wire [15:0] w_weight_base_addr;
    wire [15:0] w_bias_base_addr;

    // -------------------------------------------------------------------------
    // Microcode ROM 例化 (64-bit x 32) — legacy 路径保留
    // -------------------------------------------------------------------------
    (* rom_style = "block" *) reg [63:0] microcode_rom [0:31];

    // 初始化 ROM (默认从工作目录加载 microcode.hex；可由编译宏 MICROCODE_FILE 覆盖)
`ifndef MICROCODE_FILE
  `define MICROCODE_FILE "microcode.hex"
`endif
    initial begin
        $readmemh(`MICROCODE_FILE, microcode_rom);
    end

    // -------------------------------------------------------------------------
    // Descriptor RAM (32 层 × 8 word × 32-bit = 1 KB)
    // 仅 descriptor 模式使用，legacy 模式保留但不消耗额外逻辑 (综合优化)
    // -------------------------------------------------------------------------
    reg [31:0] desc_ram [0:MAX_LAYERS-1][0:7];

    // Descriptor RAM simulation preload (合成时由 DC/Vivado 忽略)
`ifndef NPU_DESC_FILE
  `define NPU_DESC_FILE "npu_desc.hex"
`endif
    // 无条件读取 desc_ram，即使 USE_DESC_RAM=0 也预载。
    // 综合工具会忽略 $readmemh，不影响面积。
    initial begin
        $readmemh(`NPU_DESC_FILE, desc_ram);
    end

    // Descriptor RAM write port
    always @(posedge clk) begin
        if (i_desc_we && (i_desc_layer < MAX_LAYERS)) begin
            desc_ram[i_desc_layer][i_desc_word] <= i_desc_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // Descriptor Decode: 从 desc_ram 提取控制信号 (combinational)
    // -------------------------------------------------------------------------
    wire [3:0] w_desc_op_type    = desc_ram[r_pc][`DESC_WORD0][`DESC_WORD0_OP_TYPE];
    wire [3:0] w_desc_activation = desc_ram[r_pc][`DESC_WORD0][`DESC_WORD0_ACTIVATION];
    wire [3:0] w_desc_kernel_h   = desc_ram[r_pc][`DESC_WORD0][`DESC_WORD0_KERNEL_H];
    wire [3:0] w_desc_kernel_w   = desc_ram[r_pc][`DESC_WORD0][`DESC_WORD0_KERNEL_W];
    wire [3:0] w_desc_pool_type  = desc_ram[r_pc][`DESC_WORD1][`DESC_WORD1_POOL_TYPE];
    wire [3:0] w_desc_pad_mode   = desc_ram[r_pc][`DESC_WORD1][`DESC_WORD1_PAD_MODE];

    // Descriptor → legacy 控制信号映射
    wire        w_desc_is_fc_mode;
    wire [1:0]  w_desc_kernel_size;
    wire        w_desc_pool_en;
    wire        w_desc_padding_en;

    assign w_desc_is_fc_mode  = (w_desc_op_type == `OP_TYPE_FC);
    assign w_desc_pool_en     = (w_desc_pool_type != `POOL_NONE);
    assign w_desc_padding_en  = (w_desc_pad_mode != `PAD_VALID);

    // Activation 编码转换: descriptor 语义编码 → 硬件内部编码
    // Hardware: 2'b00=ReLU, 2'b01=HardSigmoid
    // Descriptor: 0=NONE, 1=RELU, 2=RELU6, 3=LEAKY_RELU, 4=HARDSIGMOID
    wire [1:0] w_desc_activation_hw;
    assign w_desc_activation_hw = (w_desc_activation == `ACT_HARDSIGMOID) ? 2'b01 : 2'b00;

    // kernel_size 编码: 00=1×1, 01=2×2, 10=3×3
    assign w_desc_kernel_size = (w_desc_kernel_h >= 4'd3 && w_desc_kernel_w >= 4'd3) ? 2'b10 :
                                (w_desc_kernel_h >= 4'd2 && w_desc_kernel_w >= 4'd2) ? 2'b01 : 2'b00;

    // Descriptor 派生 weight/bias offset (32-bit → 16-bit 截断，后续可扩展到 32-bit)
    wire [15:0] w_desc_weight_offset = desc_ram[r_pc][`DESC_WORD5][15:0];
    wire [15:0] w_desc_bias_offset   = desc_ram[r_pc][`DESC_WORD6][15:0];

    // -------------------------------------------------------------------------
    // Legacy param ROM (仅 legacy 模式使用, descriptor 模式 bypass)
    // -------------------------------------------------------------------------
    wire [15:0] w_rom_weight_base;
    wire [15:0] w_rom_bias_base;

    npu_param_rom u_param_rom (
        .i_layer_id         (r_pc),
        .o_weight_base_addr (w_rom_weight_base),
        .o_bias_base_addr   (w_rom_bias_base)
    );

    // Mux: descriptor 模式使用 desc_ram offset，legacy 使用 param_rom offset
    assign w_weight_base_addr = USE_DESC_RAM ? w_desc_weight_offset : w_rom_weight_base;
    assign w_bias_base_addr   = USE_DESC_RAM ? w_desc_bias_offset   : w_rom_bias_base;

    reg [63:0] r_current_inst;

    // -------------------------------------------------------------------------
    // FSM: State Register
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // -------------------------------------------------------------------------
    // FSM: Next State Logic
    // -------------------------------------------------------------------------
    reg [15:0] r_lbp_pixel_cnt; // 用于跟踪传感器写入数量
    wire [15:0] w_expected_lbp_pixels = o_img_width * o_img_height;

    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (i_frame_valid)
                    next_state = ST_FETCH; // 先 Fetch Layer 0 拿到长宽，再进 LOAD_IMG
            end
            ST_FETCH: begin
                if (r_pc == 5'd0 && r_lbp_pixel_cnt == 0 && !i_skip_lbp_load) // 如果是首层且没加载过图
                    next_state = ST_LOAD_IMG;
                else
                    next_state = ST_WAIT_DMA;
            end
            ST_LOAD_IMG: begin
                // LBP 数据写入完成
                if (r_lbp_pixel_cnt >= w_expected_lbp_pixels)
                    next_state = ST_WAIT_DMA;
            end
            ST_WAIT_DMA: begin
                if (i_dma_done)
                    next_state = ST_CALC;
            end
            ST_CALC: begin
                if (i_layer_done) begin
                    // 嵌套分组转移 (Step 14.1b):
                    // 1. 如果还有后续 cin_group，同 oc_group 内接着跑下一个 cin_group (重取权重)
                    // 2. 否则如果还有后续 oc_group，进入下一个 oc_group (cin_group=0 重启)
                    // 3. 否则本层完成
                    if (!w_is_last_cin_group || !w_is_last_oc_group)
                        next_state = ST_WAIT_DMA;
                    else
                        next_state = ST_CHECK_END;
                end
            end
            ST_CHECK_END: begin
                if (r_pc == w_total_layers - 1)
                    next_state = ST_DONE;
                else
                    next_state = ST_FETCH;
            end
            ST_DONE: begin
                next_state = ST_IDLE;
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // FSM: Output & Datapath Control
    // -------------------------------------------------------------------------

    // PC 递增与指令译码
    // descriptor 模式下，译码来源为 desc_ram；legacy 模式下为 microcode_rom。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_pc <= 5'd0;
            o_is_fc_mode <= 1'b0;
            o_activation_type <= 2'b00;
            o_pool_en <= 1'b0;
            o_padding_en <= 1'b0;
            o_kernel_size <= 2'b00;
            o_cin_total <= 10'd0;
            o_cout_total <= 10'd0;
            o_img_width <= 10'd0;
            o_img_height <= 10'd0;
            o_shift_bits <= 4'd0;
            r_current_inst <= 64'd0;
            r_oc_group_idx    <= 4'd0;
            r_oc_group_total  <= 4'd1;
            r_cin_group_idx   <= 6'd0;
            r_cin_group_total <= 6'd1;
        end else begin
            if (state == ST_IDLE) begin
                r_pc <= 5'd0;
                r_oc_group_idx  <= 4'd0;
                r_cin_group_idx <= 6'd0;
            end else if (state == ST_CHECK_END && next_state == ST_FETCH) begin
                r_pc <= r_pc + 1'b1;
                r_oc_group_idx  <= 4'd0; // 进入下一层时复位组索引
                r_cin_group_idx <= 6'd0;
            end else if (state == ST_CALC && i_layer_done) begin
                // 嵌套循环递增 (Step 14.1b)。二重状态机独立推进：
                if (!w_is_last_cin_group) begin
                    // 同 oc_group 内进入下一 cin_group：oc_group 保持，cin_group ++
                    r_cin_group_idx <= r_cin_group_idx + 6'd1;
                end else if (!w_is_last_oc_group) begin
                    // cin_group 已走到头，oc_group ++，cin_group 重置
                    r_oc_group_idx  <= r_oc_group_idx + 4'd1;
                    r_cin_group_idx <= 6'd0;
                end
                // 全部完成时什么也不动，交由 ST_CHECK_END 处理
            end else if (state == ST_FETCH) begin
                if (USE_DESC_RAM) begin
                    // ---- descriptor 译码路径 ----
                    r_current_inst <= 64'd0; // desc mode 无 microcode
                    o_is_fc_mode      <= w_desc_is_fc_mode;
                    o_activation_type <= w_desc_activation_hw;
                    o_pool_en         <= w_desc_pool_en;
                    o_kernel_size     <= w_desc_kernel_size;
                    o_padding_en      <= w_desc_padding_en;
                    o_cin_total       <= desc_ram[r_pc][`DESC_WORD2][`DESC_WORD2_CIN_TOTAL];
                    o_cout_total      <= desc_ram[r_pc][`DESC_WORD2][`DESC_WORD2_COUT_TOTAL];
                    o_img_width       <= desc_ram[r_pc][`DESC_WORD3][`DESC_WORD3_INPUT_WIDTH];
                    o_img_height      <= desc_ram[r_pc][`DESC_WORD3][`DESC_WORD3_INPUT_HEIGHT];
                    o_shift_bits      <= desc_ram[r_pc][`DESC_WORD7][`DESC_WORD7_SHIFT_BITS];
                    // 计算分组数：ceil(N / 16) = (N + 15) >> 4
                    r_oc_group_total  <= ((desc_ram[r_pc][`DESC_WORD2][`DESC_WORD2_COUT_TOTAL] + 10'd15) >> 4);
                    r_cin_group_total <= ((desc_ram[r_pc][`DESC_WORD2][`DESC_WORD2_CIN_TOTAL] + 10'd15) >> 4);
                end else begin
                    // ---- legacy microcode 译码路径 ----
                    r_current_inst <= microcode_rom[r_pc];
                    // 译码级联
                    o_is_fc_mode      <= microcode_rom[r_pc][63];
                    o_activation_type <= microcode_rom[r_pc][62:61];
                    o_pool_en         <= microcode_rom[r_pc][60];
                    o_kernel_size     <= microcode_rom[r_pc][59:58];
                    // [Padding 统一] legacy 3×3 隐式 padding OR 显式 bit[13]
                    o_padding_en      <= microcode_rom[r_pc][13] || (microcode_rom[r_pc][59:58] == 2'b10);
                    o_cin_total       <= microcode_rom[r_pc][57:48];
                    o_cout_total      <= microcode_rom[r_pc][47:38];
                    o_img_width       <= microcode_rom[r_pc][37:28];
                    o_img_height      <= microcode_rom[r_pc][27:18];
                    o_shift_bits      <= microcode_rom[r_pc][17:14];
                    // 计算分组数：ceil(N / 16) = (N + 15) >> 4
                    r_oc_group_total   <= ((microcode_rom[r_pc][47:38] + 10'd15) >> 4); // cout
                    r_cin_group_total  <= ((microcode_rom[r_pc][57:48] + 10'd15) >> 4); // cin (Step 14.1b)
                end
                r_oc_group_idx     <= 4'd0;
                r_cin_group_idx    <= 6'd0;
            end
        end
    end

    // Ping-Pong 映射 (偶数层读PING写PONG, 奇数层反之)
    assign o_pingpong_sel = r_pc[0];

    // LBP 写入控制器 (ST_LOAD_IMG)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_lbp_pixel_cnt <= 16'd0;
        end else if (state == ST_IDLE) begin
            r_lbp_pixel_cnt <= 16'd0;
        end else if (state == ST_LOAD_IMG && i_lbp_valid) begin
            r_lbp_pixel_cnt <= r_lbp_pixel_cnt + 1'b1;
        end
    end

    assign o_lbp_wr_en   = (state == ST_LOAD_IMG) ? i_lbp_valid : 1'b0;
    assign o_lbp_wr_addr = r_lbp_pixel_cnt[14:0];
    assign o_lbp_wr_data = i_lbp_pixel;

    assign o_is_init_phase = (r_pc == 5'd0 && state == ST_LOAD_IMG); // 导出 PC==0 且正在加载图像的标识供外部使用
    assign o_layer_id      = r_pc;                                     // 当前层 PC，layer-0 需要路由到 lbp_input_buffer 读取

    // =========================================================================
    // DMA 控制器交互 — [Step 16.3 / Path B M3] 字单位重构 (RPT-3 决议)
    // =========================================================================
    // 权重存储布局: [oc_g][cin_g][16 cout × 16 cin × k²] (oc-major, 每块均 pad 到 16×16)
    //   → 每 cin_g 块 = 16 cin × 16 cout × K² 字节 = 256×K² 字节 = 64×K² 字 (cin_stride)
    //   → 每 oc_g 块 = cin_groups × cin_stride (oc_stride, Step 16.3 修复)
    //   → DMA length = 4 × cin_block × K² 字 (effective 字节数 = 16 × cin_block × K²)
    //
    // [Step 16.3 修复的 latent bug]：
    //   旧：w_oc_group_bytes = 16 × cin_total × K² (仅当 cin_total % 16 == 0 时正确)
    //   新：w_oc_group_words = cin_groups × w_cin_group_words (通用正确)
    //   C5 (cin=24) 是唒一暴露例；M2 cocotb T2 首次触发。
    //
    // 地址单位：字 (32-bit word) — 全链路统一，详见 docs/weight_rom_dma_设计_PathB.md §3.6
    // K² 因子：00=1×1→1, 01=2×2→4, 10=3×3→9 (与 weight_rom_dma decode_k2 / face/quant_int8 一致)
    // [Bug fix M3-f]：原版漏掉 k=2 分支 (落入 else=1)，导致 C8 (kernel=2) DMA 长度仅 1/4，
    // 触发 e2e 推理 layer-7 后激活 67% mismatch。
    wire [3:0] w_k_factor = (o_kernel_size == 2'b10) ? 4'd9 :
                            (o_kernel_size == 2'b01) ? 4'd4 : 4'd1;

    // 时序优化：先把二维 (oc_group, cin_group) 展平成组号，再乘固定 K² 和 64。
    // 这与原公式完全等价：
    //   oc_g * cin_groups * (64*K²) + cin_g * (64*K²)
    // = (oc_g * cin_groups + cin_g) * K² * 64
    // 原实现会级联 3 个 DSP48 和一个 32-bit 加法链；固定因子用移位/加法后只剩
    // 一个很小的组号乘法器，同时保持 DMA 请求边沿的原始采样语义。
    wire [9:0] w_dma_group_linear =
        (r_oc_group_idx * r_cin_group_total) + r_cin_group_idx;
    wire [13:0] w_dma_group_kernel_scaled =
        (w_k_factor == 4'd9) ? ((w_dma_group_linear << 3) + w_dma_group_linear) :
        (w_k_factor == 4'd4) ?  (w_dma_group_linear << 2) :
                               w_dma_group_linear;
    wire [19:0] w_dma_group_offset_words = {w_dma_group_kernel_scaled, 6'b0};

    wire [15:0] w_dma_length_words =
        (w_k_factor == 4'd9) ? (({11'd0, w_cin_block_size} << 5) +
                                ({11'd0, w_cin_block_size} << 2)) :
        (w_k_factor == 4'd4) ?  ({11'd0, w_cin_block_size} << 4) :
                               ({11'd0, w_cin_block_size} << 2);
    wire [15:0] w_dma_base_addr_next =
        w_weight_base_addr + w_dma_group_offset_words[15:0];
    wire [15:0] w_bias_base_addr_next =
        w_bias_base_addr + {8'd0, r_oc_group_idx, 4'b0};

    // Keep the original handshake semantics: the DMA side samples these
    // parameters on the same edge that observes o_dma_req.  Registering them
    // in that edge would expose the preceding group's values to the receiver.
    assign o_dma_base_addr  = w_dma_base_addr_next;
    assign o_bias_base_addr = w_bias_base_addr_next;
    assign o_dma_length     = w_dma_length_words;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            o_dma_req <= 1'b0;
        // 只要下一个状态是 ST_WAIT_DMA，并且当前状态不是它，就立即发出请求
        else if (next_state == ST_WAIT_DMA && state != ST_WAIT_DMA)
            o_dma_req <= 1'b1;
        else if (i_dma_ack)
            o_dma_req <= 1'b0;
    end

    // Layer 启动控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_layer_start <= 1'b0;
        else if (state == ST_WAIT_DMA && next_state == ST_CALC) o_layer_start <= 1'b1;
        else o_layer_start <= 1'b0;
    end

`ifdef NPU_SEQ_TRACE
    reg [2:0] trace_state_d1;
    reg       trace_dma_req_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_state_d1   <= ST_IDLE;
            trace_dma_req_d1 <= 1'b0;
        end else begin
            if (state != trace_state_d1) begin
                $display("[NPU_SEQ] t=%0t state %0d->%0d pc=%0d oc=%0d/%0d cin=%0d/%0d dma_done=%0b layer_done=%0b bbox=%0b",
                         $time, trace_state_d1, state, r_pc, r_oc_group_idx,
                         r_oc_group_total, r_cin_group_idx, r_cin_group_total,
                         i_dma_done, i_layer_done, o_bbox_valid);
            end
            if (o_dma_req && !trace_dma_req_d1) begin
                $display("[NPU_SEQ] t=%0t dma_req pc=%0d oc=%0d cin=%0d wbase=%0d bbase=%0d len=%0d",
                         $time, r_pc, r_oc_group_idx, r_cin_group_idx,
                         o_dma_base_addr, o_bias_base_addr, o_dma_length);
            end
            if (i_dma_done) begin
                $display("[NPU_SEQ] t=%0t dma_done pc=%0d oc=%0d cin=%0d",
                         $time, r_pc, r_oc_group_idx, r_cin_group_idx);
            end
            if (o_layer_start) begin
                $display("[NPU_SEQ] t=%0t layer_start pc=%0d oc=%0d cin=%0d kernel=%0d pool=%0b pad=%0b size=%0dx%0d cin_total=%0d cout_total=%0d",
                         $time, r_pc, r_oc_group_idx, r_cin_group_idx,
                         o_kernel_size, o_pool_en, o_padding_en, o_img_width,
                         o_img_height, o_cin_total, o_cout_total);
            end
            if (i_layer_done) begin
                $display("[NPU_SEQ] t=%0t layer_done pc=%0d oc=%0d/%0d cin=%0d/%0d",
                         $time, r_pc, r_oc_group_idx, r_oc_group_total,
                         r_cin_group_idx, r_cin_group_total);
            end
            if (o_bbox_valid) begin
                $display("[NPU_SEQ] t=%0t bbox data=%010h", $time, o_bbox_data);
            end
            trace_state_d1   <= state;
            trace_dma_req_d1 <= o_dma_req;
        end
    end
`endif

    // -------------------------------------------------------------------------
    // Final tensor snooper + legacy BBox capture
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_result_stream_valid <= 1'b0;
            o_result_stream_data <= 128'd0;
            o_inference_done <= 1'b0;
            o_bbox_valid <= 1'b0;
            o_bbox_data <= 40'd0;
        end else begin
            o_result_stream_valid <= 1'b0;
            o_inference_done <= 1'b0;
            o_bbox_valid <= 1'b0; // Default pulse
            if (state == ST_DONE)
                o_inference_done <= 1'b1;
            // 当处于最后一条指令，且嗅探到 NPU 的有效输出脉冲时
            if (state == ST_CALC && r_pc == w_total_layers - 1 && i_npu_out_valid) begin
                o_result_stream_data <= i_npu_out_bus;
                o_result_stream_valid <= 1'b1;
                // FC 映射后，前 5 个输出通道承载了置信度与坐标 {H, W, Y, X, Conf}
                // i_npu_out_bus 格式：Ch15...Ch0
                // 我们截取低 40 位 (Ch4~Ch0)
                o_bbox_data <= i_npu_out_bus[39:0];
                o_bbox_valid <= 1'b1;
            end
        end
    end

endmodule
