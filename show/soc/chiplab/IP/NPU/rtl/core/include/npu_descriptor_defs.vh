// -----------------------------------------------------------------------------
// npu_descriptor_defs.vh — NPU Layer Descriptor 位域定义 (RTL)
//
// 每层 256-bit = 8 × 32-bit word
// 与 BSP npu_descriptor.h 保持同步
// -----------------------------------------------------------------------------

// ---- word0: op_type, activation, kernel, stride ----
`define DESC_WORD0                   0
`define DESC_WORD0_VERSION           31:28
`define DESC_WORD0_OP_TYPE           27:24
`define DESC_WORD0_ACTIVATION        23:20
`define DESC_WORD0_FLAGS             19:16
`define DESC_WORD0_KERNEL_H          15:12
`define DESC_WORD0_KERNEL_W          11:8
`define DESC_WORD0_STRIDE_H          7:4
`define DESC_WORD0_STRIDE_W          3:0

// ---- word1: pool, padding ----
`define DESC_WORD1                   1
`define DESC_WORD1_SRC_BUF           31:28
`define DESC_WORD1_DST_BUF           27:24
`define DESC_WORD1_POOL_TYPE         23:20
`define DESC_WORD1_POOL_K            19:16
`define DESC_WORD1_POOL_STRIDE       15:12
`define DESC_WORD1_PAD_TOP           11:8
`define DESC_WORD1_PAD_BOTTOM        7:4
`define DESC_WORD1_PAD_MODE          3:0

// ---- word2: channel counts ----
`define DESC_WORD2                   2
`define DESC_WORD2_CIN_TOTAL         15:0
`define DESC_WORD2_COUT_TOTAL        31:16

// ---- word3: input spatial dims ----
`define DESC_WORD3                   3
`define DESC_WORD3_INPUT_WIDTH       15:0
`define DESC_WORD3_INPUT_HEIGHT      31:16

// ---- word4: output spatial dims ----
`define DESC_WORD4                   4
`define DESC_WORD4_OUTPUT_WIDTH      15:0
`define DESC_WORD4_OUTPUT_HEIGHT     31:16

// ---- word5: weight offset (32-bit word address) ----
`define DESC_WORD5                   5
`define DESC_WORD5_WEIGHT_OFFSET     31:0

// ---- word6: bias offset (32-bit word address) ----
`define DESC_WORD6                   6
`define DESC_WORD6_BIAS_OFFSET       31:0

// ---- word7: quantization ----
`define DESC_WORD7                   7
`define DESC_WORD7_SHIFT_BITS        3:0
`define DESC_WORD7_INPUT_ZERO_POINT  11:4
`define DESC_WORD7_OUTPUT_ZERO_POINT 19:12
`define DESC_WORD7_QUANT_MODE        23:20
`define DESC_WORD7_RESERVED          31:24

// ---- op_type 枚举 ----
`define OP_TYPE_CONV      4'd0
`define OP_TYPE_FC         4'd1
`define OP_TYPE_POOL_ONLY  4'd2
`define OP_TYPE_DEPTHWISE  4'd3
`define OP_TYPE_ADD        4'd4
`define OP_TYPE_CONCAT     4'd5

// ---- activation 枚举 ----
// 注意：硬件内部编码为 00=ReLU, 01=HardSigmoid，与 descriptor 的语义编码不同。
// Sequencer 中通过 map_activation() 进行转换。
`define ACT_NONE          4'd0
`define ACT_RELU           4'd1
`define ACT_RELU6          4'd2
`define ACT_LEAKY_RELU     4'd3
`define ACT_HARDSIGMOID     4'd4

// ---- pool_type 枚举 ----
`define POOL_NONE    4'd0
`define POOL_MAXPOOL  4'd1
`define POOL_AVGPOOL  4'd2

// ---- pad_mode 枚举 ----
`define PAD_VALID         4'd0
`define PAD_SAME_ZERO      4'd1
`define PAD_EXPLICIT_ZERO  4'd2

// ---- 辅助参数 ----
`define MAX_DESC_LAYERS    32
`define DESC_WORDS_PER_LAYER 8
`define DESC_ADDR_W        7    // 5-bit layer + 3-bit word
