// ----------------------------------------------------------------------------
// 3. Weight Buffer
// [升级]：144-bit 双通道装载 + 页级双缓冲 (active 计算 / dma 写入)
//
// [Step 15.3 重构 2026-05-02]
// 原版使用单一 reg [71:0] weight_page [0:1][0:511] + always@* 组合 16 路读，
// 国产 EDA (Quartus 系) 无法将其推断为 BRAM（原因：异步读 + 16 路并行）,
// 全部展开为寄存器 + 9-bit×16 路 MUX 树 ≈ 10万 LE，使 LE 资源严重溢出。
//
// 重构思路：把原本的 reg [0:1][0:511][72b] (= 2 页×16 cin×16 ch) 拆为
//   16 个独立 bank（按 ch_idx 划分），每 bank = reg [0:63][72b]
//   (=2 页×32 cin)，以 Quartus 友好的同步读模板推断为 M9K BRAM。
//   - 读：16 banks 同拍同步读，每 bank 1× 读口不存在处理冲突。
//   - 写：weight_in_addr[3:0] 选中主 bank，同拍还写入 (主 bank+1) 以
//          接纳 144-bit 双通道 (奇偶 ch 对)。两块不同 bank、不同物理 RAM,
//          同拍写 OK。
//
// 外部接口不变：i_current_cin 输入到1 拍后 wb 输出权重总线，与原版 1 拍
// 延迟等价。原版 conv_engine_top 里为对齐 line_buffer 1 拍所加的
// r_current_cin_d1 现在凗余，需同步删除。
//
// 保留 active_page / dma_page 名字供现有 cocotb 诊断探针使用。
// ----------------------------------------------------------------------------
module weight_buffer #(
    parameter NUM_CHANNELS  = 16,
    parameter MAX_CIN       = 32    // 支持 Conv 层最大 Cin（FC 层需外部分组流式加载）
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [1:0]                   kernel_size,

    // DMA 写入接口（144-bit 双通道，flat 地址）
    input  wire [143:0]                 weight_in_data,
    input  wire                         weight_in_valid,
    input  wire [9:0]                   weight_in_addr,  // flat 写入地址，每拍写 2 条目

    // 组边界翻页：DMA 完成一页写入后拉低 update_weights_en 触发切换
    input  wire                         update_weights_en,

    // 计算侧读接口：按当前 Cin 索引读出 16 路权重
    input  wire [7:0]                   i_current_cin,

    // 输出权重总线
    output wire [NUM_CHANNELS*72-1:0]   weights_bus_out
);
    // bank 内部地址安排: {page[1], cin_idx[4:0]} → 6 bit
    localparam BANK_AW   = $clog2(2 * MAX_CIN); // 6

    // ------------------------------------------------------------------------
    // 页 / 握手状态 (保留 active_page / dma_page 名供 cocotb 探针)
    // ------------------------------------------------------------------------
    reg        active_page; // 当前计算页
    reg        dma_page;    // DMA 写入页 (= ~active_page after commit)
    reg        update_en_d;

    wire update_fall = update_en_d && !update_weights_en; // 末沿表示一页写满

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_page <= 1'b0;
            dma_page    <= 1'b0;
            update_en_d <= 1'b0;
        end else begin
            update_en_d <= update_weights_en;
            if (update_fall) begin
                active_page <= dma_page;   // 计算页切换
                dma_page    <= ~dma_page;  // 预留下一页供 DMA
            end
        end
    end

    // ------------------------------------------------------------------------
    // 页 / cin / ch 拆分
    //   原本 weight_in_addr = cin_local * 16 + oc_pair  (oc_pair ∈ {0,2,..,14})
    //   本拍写 oc_pair (主 bank) 与 oc_pair+1 (右邻 bank) 两个 72-bit 条目。
    // ------------------------------------------------------------------------
    wire [3:0] wr_bank_lo = weight_in_addr[3:0];                // 主 bank (偶 ch)
    wire [3:0] wr_bank_hi = weight_in_addr[3:0] + 4'd1;          // 邻 bank (奇 ch)
    wire [4:0] wr_cin     = weight_in_addr[8:4];                // cin_local (页内)
    wire [BANK_AW-1:0] wr_addr = {dma_page, wr_cin};            // bank 内部地址 = {page, cin_local}
    wire [BANK_AW-1:0] rd_addr = {active_page, i_current_cin[4:0]};

    // ------------------------------------------------------------------------
    // 16 个独立 bank。**关键修复 v2 (2026-05-02)**:
    //   把 mem 声明下沉到 generate 块内, 每个 bank 是独立的 1D reg 数组,
    //   仿照 fm_bank_array.v 已被验证可推 BRAM 的模板。原先用二维数组
    //   reg [71:0] weight_bank [0:15][0:63] 在 Quartus 系下无法推 M9K
    //   (Cannot regroup multidimensional array) → 全部退化为寄存器。
    //   每 bank 容纳 2 页 × MAX_CIN cin = 64 条 72-bit 词 ≈ 4.6 Kbit ≈ 1×M9K。
    // ------------------------------------------------------------------------
    wire [71:0] wb_rd_data_w [0:NUM_CHANNELS-1];

    genvar gw;
    generate
        for (gw = 0; gw < NUM_CHANNELS; gw = gw + 1) begin : G_BANK
            // 单维 1D RAM, 声明于 generate 内, 匹配多 EDA 系 RAM 推断模板。
            // Xilinx build 下每 bank 只有 64x72, 强推 BRAM 会浪费 1 个 RAMB36；
            // 改用 LUTRAM 可释放足够 BRAM 给 channel_accumulator 深 PSUM。
`ifdef NPU_USE_XPM_BRAM
            (* ram_style = "distributed" *)
`else
            (* syn_ramstyle = "block_ram", ram_style = "block", ramstyle = "no_rw_check" *)
`endif
            reg [71:0] mem [0:(2*MAX_CIN)-1];

            // ----------------------------------------------------------------
            // **关键修复 v3 (2026-05-02)**: 标准 1R1W 单写口模板
            //   原先用两个独立 if (wr_bank_lo==gw) / if (wr_bank_hi==gw) 都写
            //   mem[wr_addr], 虽然条件互斥 (hi=lo+1), 但 Quartus 静态分析
            //   器识别为 "多驱动" 模式 → 拒绝 BRAM 推断。
            //   改为合并一个 we 信号 + data MUX 的标准写法, 与 fm_bank_array
            //   成功推断的模板一致。
            // ----------------------------------------------------------------
            wire we_lo  = weight_in_valid && (wr_bank_lo == gw[3:0]);
            wire we_hi  = weight_in_valid && (wr_bank_hi == gw[3:0]);
            wire bank_we = we_lo | we_hi;
            // we_lo / we_hi 互斥 (hi = lo + 1), 选择写哪 72-bit 字段
            wire [71:0] bank_wd = we_hi ? weight_in_data[143:72] : weight_in_data[71:0];

            always @(posedge clk) begin
                if (bank_we)
                    mem[wr_addr] <= bank_wd;
            end

            // 读口: 同步读 (BRAM 必须同步读), 1 拍延迟
            reg [71:0] mem_rd_data;
            always @(posedge clk) begin
                mem_rd_data <= mem[rd_addr];
            end
            assign wb_rd_data_w[gw] = mem_rd_data;
        end
    endgenerate

    // 与读出对齐的 kernel_size 推迟 1 拍
    reg [1:0] kernel_size_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) kernel_size_d1 <= 2'b00;
        else        kernel_size_d1 <= kernel_size;
    end

    genvar gm;
    generate
        for (gm = 0; gm < NUM_CHANNELS; gm = gm + 1) begin : G_BANK_MAP
            weight_kernel_mapper u_weight_kernel_mapper (
                .i_raw_w      (wb_rd_data_w[gm]),
                .i_kernel_size(kernel_size_d1),
                .o_mapped_w   (weights_bus_out[gm*72 +: 72])
            );
        end
    endgenerate

endmodule
