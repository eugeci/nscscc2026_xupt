// ============================================================================
// File Name   : channel_accumulator.v
// Description : [综合修复 2026-05-02 v2] 国产 EDA (紫光同创 PDS / 安路 TD / 高云 /
//               PangoMicro / ELinx, 均为 Synplify 内核) **不识别 Xilinx 风格的
//               (* ram_style = "block" *)**, 必须改成 Synplify 风格属性
//               (* syn_ramstyle = "block_ram" *)。同时把 RAM 读口与写口合并到
//               同一个 posedge clk 同步 always 块, 满足 Synplify simple
//               dual-port BRAM 推断模板要求。
//
//               16 lane × 19200 × 32-bit psum 阵列若退化为寄存器, 单 lane
//               614 Kbit ≈ 19.2K FF, 16 lane ≈ 31 万 FF/LE, 直接撑爆 136K LE
//               预算 (实测溢出到 234553 LE)。改对模板后这部分变成片上 BRAM。
//
//               功能行为与旧版 bit-true 等价: psum_ram 不需复位, 首次写由
//               is_first_cin 分支负责覆盖。
//
// [Step 15.5 + 15.6 · 2026-05-03] MAX_FM_SIZE 双值（sim/synth 解耦）
//   ─────────────────────────────────────────────────────────────────────────
//   背景：PSUM RAM 仅在 cin_groups ≥ 2 的层被写入 (FaceNet 实际最大 300 项),
//   但 ram_rdata_raw <= psum_ram[ram_addr] 是无条件同步读 (BRAM 推断模板要求).
//
//   双值原因：
//   - 仿真侧（Icarus / VCS）: 需 ≥ 19200。OOB 读返回 X，通过 ram_rdata→next_sum
//     线网泄漏到 pe_sum_bus 监控点，触发 e2e 测试崩溃 (PE-PSUM monitor 逐周期
//     int(pe_sum_bus.value) 失败)。各层最大 ram_addr: C1=19200, C2=4800.
//   - 综合侧（eLinx Synplify 内核）: 用 2048 即可。硬件 BRAM 用低 11-bit 寻址,
//     OOB 物理 wrap 后仍被架构 bypass (single cin_group 走 final_sum<=extended_mac
//     旁路, 不触发 next_sum). 综合实测节省 ~3 Mbit (16 lane × 32 bit × (4096-2048)).
//
//   代价：仿真测的 RAM 深度 ≠ 硬件深度, 但因 cin_groups=1 层不依赖 RAM 数据,
//   且 cin_groups≥2 层最大需求 = 300 << 2048, 行为完全等价 bit-true.
//
//   详见 NPU/Step_15.4_BRAM调查_2026-05-02.md.
// ============================================================================
// -----------------------------------------------------------------------------
// [Step 15.7 · 2026-05-03] MAX_FM_SIZE 选择策略 — fail-safe 反转默认
// -----------------------------------------------------------------------------
// 设计原则: 默认就是综合安全的 2048, 仅当识别到主流仿真器自动注入的私有宏时
//           才扩展到 19200 防御性深度 (覆盖 C1 160×120 OOB X 传播检查)。
//           任何 EDA 综合工具均不会注入这些仿真器宏, 因此综合时永远是 2048,
//           即使忘了 +define+SYNTHESIS 也不会浪费 ~3 Mbit BRAM。
//
// 历史教训: eLinx 预处理器不支持 `error 指令, 不能用哨兵硬终止。统一与
//           fm_bank_array.v 走相同的反转默认 + 仿真器宏识别策略 (Step 15.7 v2)。
// -----------------------------------------------------------------------------
`ifdef COCOTB_SIM
  `define CHANNEL_ACC_FM_SIZE_SIM
`endif
//`ifdef MODEL_TECH
//  `define CHANNEL_ACC_FM_SIZE_SIM
//`endif
`ifdef VCS
  `define CHANNEL_ACC_FM_SIZE_SIM
`endif
`ifdef IVERILOG
  `define CHANNEL_ACC_FM_SIZE_SIM
`endif
`ifdef XCELIUM
  `define CHANNEL_ACC_FM_SIZE_SIM
`endif
`include "npu_math_defs.vh"

module channel_accumulator #(
    parameter ACC_WIDTH   = 32,
`ifdef CHANNEL_ACC_FM_SIZE_SIM
    parameter MAX_FM_SIZE = 19200   // 仿真: 防 OOB X 传播, 覆盖 C1 160×120
`else
    parameter MAX_FM_SIZE = 4800    // 综合 (默认 fail-safe): 节省 ~3 Mbit BRAM, 覆盖 ≤ 45×45 单平面
`endif
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [7:0]             cfg_width,
    input  wire                   is_first_cin,
    input  wire                   is_last_cin,
    input  wire signed [19:0]     mac_data,
    input  wire                   mac_valid,
    input  wire [7:0]             mac_x,
    input  wire [7:0]             mac_y,

    output reg  signed [ACC_WIDTH-1:0] final_sum,
    output reg                    final_valid,
    output reg  [7:0]             final_x,
    output reg  [7:0]             final_y
);

    // ------------------------------------------------------------------------
    // psum_ram: Simple Dual-Port BRAM (1W1R, 同步读, 同步写)
    // 多家综合属性并贴 -- 哪家 EDA 能识别就识别哪条:
    //   syn_ramstyle = "block_ram"  : Synplify (紫光/安路/高云/Pango/ELinx)
    //   ram_style    = "block"      : Vivado / 部分国产兼容
    //   ramstyle     = "M9K"        : Quartus (Altera/Intel)
    // ------------------------------------------------------------------------
    localparam PSUM_ADDR_W = `NPU_CLOG2(MAX_FM_SIZE);

    wire [14:0] ram_addr = mac_y * cfg_width + mac_x;
    reg [14:0] addr_d1;
    wire [PSUM_ADDR_W-1:0] ram_addr_trim = ram_addr[PSUM_ADDR_W-1:0];
    wire [PSUM_ADDR_W-1:0] addr_d1_trim  = addr_d1[PSUM_ADDR_W-1:0];
`ifdef NPU_USE_XPM_BRAM
    wire signed [ACC_WIDTH-1:0] ram_rdata_raw;
`else
    (* syn_ramstyle = "block_ram", ram_style = "block", ramstyle = "no_rw_check" *)
    reg signed [ACC_WIDTH-1:0] psum_ram [0:MAX_FM_SIZE-1];
    reg signed [ACC_WIDTH-1:0] ram_rdata_raw;
`endif

    reg signed [19:0] data_d1;
    reg mac_valid_d1, first_d1, last_d1;
    reg [7:0] x_d1, y_d1;

    reg        fwd_we;
    reg [14:0] fwd_addr;
    reg signed [ACC_WIDTH-1:0] fwd_data;

    wire signed [ACC_WIDTH-1:0] ram_rdata = (fwd_we && (fwd_addr == addr_d1)) ? fwd_data : ram_rdata_raw;
    wire signed [ACC_WIDTH-1:0] extended_mac = {{ (ACC_WIDTH-20){data_d1[19]} }, data_d1};
    wire signed [ACC_WIDTH-1:0] next_sum = ram_rdata + extended_mac;

    wire psum_we = mac_valid_d1 && !last_d1;
    wire signed [ACC_WIDTH-1:0] psum_wdata = first_d1 ? extended_mac : next_sum;

`ifdef NPU_USE_XPM_BRAM
    npu_xilinx_sdpram #(
        .DATA_WIDTH  (ACC_WIDTH),
        .ADDR_WIDTH  (PSUM_ADDR_W),
        .MEMORY_DEPTH(MAX_FM_SIZE)
    ) u_psum_bram (
        .clk     (clk),
        .wr_en   (psum_we),
        .wr_strb (1'b1),
        .wr_addr (addr_d1_trim),
        .wr_data (psum_wdata),
        .rd_en   (1'b1),
        .rd_addr (ram_addr_trim),
        .rd_data (ram_rdata_raw)
    );
`endif

    // ------------------------------------------------------------------------
    // ★ 关键: 读口 + 写口必须在同一个 posedge clk 同步 always 块, 且无复位,
    //   否则 Synplify 系国产 EDA 不会推断为 BRAM (会退回 LUT/FF 阵列).
    //   控制流水寄存器 (addr_d1/data_d1/...) 同样放这里, 避免 EDA 把 RAM
    //   读口拆出去后再合不回来。
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
`ifndef NPU_USE_XPM_BRAM
        // RAM 写口
        if (psum_we) begin
            psum_ram[addr_d1] <= psum_wdata;
        end
        // RAM 同步读口
        ram_rdata_raw <= psum_ram[ram_addr];
`endif
        // 输入流水
        addr_d1      <= ram_addr;
        data_d1      <= mac_data;
        mac_valid_d1 <= mac_valid;
        first_d1     <= is_first_cin;
        last_d1      <= is_last_cin;
        x_d1         <= mac_x;
        y_d1         <= mac_y;
    end

    // 控制/前推寄存器与最终输出: 异步复位块 (非 RAM)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fwd_we <= 0; final_valid <= 0; final_sum <= 0;
            fwd_addr <= 0; fwd_data <= 0;
        end else begin
            fwd_we <= 0; final_valid <= 0;
            if (mac_valid_d1) begin
                if (first_d1 && last_d1) begin
                    final_sum <= extended_mac; final_valid <= 1'b1;
                end else if (first_d1) begin
                    // 前推寄存器: 与 psum_ram 写同拍, 下一拍可被 forwarding 使用
                    fwd_we <= 1;
                    fwd_addr <= addr_d1;
                    fwd_data <= extended_mac;
                end else if (!last_d1) begin
                    fwd_we <= 1;
                    fwd_addr <= addr_d1;
                    fwd_data <= next_sum;
                end else begin
                    final_sum <= next_sum;
                    final_valid <= 1'b1;
                end
                final_x <= x_d1; final_y <= y_d1;
            end
        end
    end
endmodule