import torch
import torch.nn as nn
import numpy as np
import math
from typing import Tuple

class FPGALightFaceNet(nn.Module):
    """FPGALightFaceNet 原始网络结构"""
    def __init__(self):
        super(FPGALightFaceNet, self).__init__()
        self.features = nn.Sequential(
            nn.Conv2d(1, 8, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(inplace=True), nn.MaxPool2d(2),
            nn.Conv2d(8, 16, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(inplace=True), nn.MaxPool2d(2),
            nn.Conv2d(16, 16, kernel_size=1, stride=1, padding=0, bias=True),
            nn.ReLU(inplace=True),
            nn.Conv2d(16, 24, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(inplace=True), nn.MaxPool2d(2),
            nn.Conv2d(24, 32, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(inplace=True), nn.MaxPool2d(2),
            nn.Conv2d(32, 32, kernel_size=1, stride=1, padding=0, bias=True),
            nn.ReLU(inplace=True),
            nn.Conv2d(32, 32, kernel_size=3, stride=1, padding=1, bias=True),
            nn.ReLU(inplace=True), nn.MaxPool2d(2),
            nn.Conv2d(32, 32, kernel_size=2, stride=1, padding=1, bias=True),
            nn.ReLU(inplace=True)
        )
        self.fc = nn.Sequential(
            nn.Linear(768, 64),
            nn.ReLU(inplace=True), nn.Dropout(0.3),
            nn.Linear(64, 5)
        )
        self.hard_sigmoid = nn.Hardsigmoid()

    def forward(self, x):
        x = self.features(x)
        x = x.view(x.size(0), -1)
        x = self.fc(x)
        return self.hard_sigmoid(x)

def permute_fc_weights_for_npu(q_weight: np.ndarray, prev_per_oc: int) -> np.ndarray:
    """[Step 14.2a] Permute FC weight columns to match NPU SRAM read order.

    The previous layer wrote OFM into PING/PONG with the physical layout::

        bank b, addr a => (ch = b + 16 * (a // prev_per_oc), pos = a % prev_per_oc)

    where ``prev_per_oc = prev_layer_H_out * prev_layer_W_out`` (1 if prev is FC).

    NPU FC reads ``cin_group g`` (= addr g) across banks 0..15, so the NPU
    cin index ``k = g*16 + b`` corresponds to ``(ch_a, pos_a)`` above. PyTorch
    however stores FC weights as channel-major flat:
        ``q[oc, ch * prev_per_oc + pos]``
    Hence each NPU slot ``k`` must be loaded with ``q[oc, ch*prev_per_oc + pos]``
    where ``(ch, pos)`` is computed from k via the bank/addr layout.

    For prev FC layers (``prev_per_oc=1``) this becomes the identity permutation.

    NOTE: The mirror implementation lives in
    ``sim/test_npu_face_inference.py::_permute_fc_weights``; both must stay in
    sync. Tests load weights directly from the ``.pth`` (not from the exported hex),
    so this host-side permutation only takes effect on the FPGA loading path.
    """
    cout, cin_flat = q_weight.shape
    NUM_LANES = 16
    new_q = np.zeros_like(q_weight)
    for k in range(cin_flat):
        g = k // NUM_LANES
        b = k % NUM_LANES
        ch = b + NUM_LANES * (g // prev_per_oc)
        pos = g % prev_per_oc
        golden_idx = ch * prev_per_oc + pos
        if golden_idx < cin_flat:
            new_q[:, k] = q_weight[:, golden_idx]
    return new_q


def quantize_tensor(tensor: torch.Tensor, num_bits: int = 8) -> Tuple[np.ndarray, float]:
    """对称绝对最大值量化"""
    qmin = -(2 ** (num_bits - 1))
    qmax = (2 ** (num_bits - 1)) - 1
    max_val = tensor.abs().max().item()
    if max_val == 0:
        if num_bits == 8:
            return np.zeros(tensor.shape, dtype=np.int8), 1.0
        else:
            return np.zeros(tensor.shape, dtype=np.int16), 1.0
            
    scale = max_val / qmax
    dtype = torch.int8 if num_bits == 8 else torch.int16
    q_tensor = torch.round(tensor / scale).clamp(qmin, qmax).to(dtype).numpy()
    return q_tensor, scale

def export_full_npu_params(model: nn.Module, export_path: str = "npu_params.hex",
                           input_h: int = 120, input_w: int = 160):
    """
    导出全套信息：
    1. Weights: INT8, 每行 4 个 (32-bit)
    2. Biases: INT16, 每行 2 个 (32-bit)
    3. Shift_N: INT32, 每行 1 个 (32-bit)
    同时在控制台生成 Verilog Address Map

    [Step 14.2a] FC 层权重在平化前需按 NPU SRAM 物理布局重排列;
    本函数追踪每层 (cur_h, cur_w) 推导 ``prev_per_oc = cur_h * cur_w``,
    供 ``permute_fc_weights_for_npu`` 使用。Conv 层权重仍为 oc-major flat,
    不受重排影响 (不同于 FC 的 ch-major flat 语义)。
    """
    model.eval()
    
    current_addr = 0
    verilog_macros =[]
    layer_idx = 1

    # [Step 14.2a] Track running spatial dims to compute prev_per_oc for FC layers.
    cur_h, cur_w = input_h, input_w
    prev_per_oc = cur_h * cur_w
    
    print("="*60)
    print(" 🚀 开始导出 NPU 全套参数 (Weights + Biases + Shift_N) ")
    print("="*60)
    
    with open(export_path, 'w') as f:
        f.write("@00000000\n") 
        
        for name, module in model.named_modules():
            # [Step 14.2a] Maintain running spatial dims through pooling so the
            # next FC layer knows its prev_per_oc.
            if isinstance(module, nn.MaxPool2d):
                k = module.kernel_size if isinstance(module.kernel_size, int) else module.kernel_size[0]
                cur_h //= k
                cur_w //= k
                prev_per_oc = cur_h * cur_w
                continue

            if isinstance(module, (nn.Conv2d, nn.Linear)):
                is_fc = isinstance(module, nn.Linear)
                prefix = f"FC{layer_idx-8}" if is_fc else f"C{layer_idx}"
                
                weight = module.weight.data
                bias = module.bias.data if module.bias is not None else torch.zeros(weight.size(0))

                # Update spatial dims for Conv2d (input -> output).
                if not is_fc:
                    kh, kw = (module.kernel_size if isinstance(module.kernel_size, tuple)
                              else (module.kernel_size, module.kernel_size))
                    ph, pw = (module.padding if isinstance(module.padding, tuple)
                              else (module.padding, module.padding))
                    sh, sw = (module.stride if isinstance(module.stride, tuple)
                              else (module.stride, module.stride))
                    cur_h = (cur_h + 2 * ph - kh) // sh + 1
                    cur_w = (cur_w + 2 * pw - kw) // sw + 1
                    prev_per_oc = cur_h * cur_w
                
                # ----------------------------------------------------
                # 1. 权重 (Weights) - INT8
                # ----------------------------------------------------
                q_weight, w_scale = quantize_tensor(weight, 8)

                # [Step 14.2a] FC 权重列重排 (Conv 不受影响)
                if is_fc:
                    q_weight_pre = q_weight
                    q_weight = permute_fc_weights_for_npu(q_weight, prev_per_oc)
                    if not np.array_equal(q_weight, q_weight_pre):
                        print(f"  [{prefix}] FC permuted with prev_per_oc={prev_per_oc} "
                              f"(prev spatial = {cur_h}x{cur_w})")
                    else:
                        print(f"  [{prefix}] FC permutation = identity (prev_per_oc={prev_per_oc})")
                    # After FC, downstream is 1x1 (flattened scalar per channel).
                    cur_h, cur_w = 1, 1
                    prev_per_oc = 1

                flat_w = q_weight.flatten().view(np.uint8) # 转uint8处理负数补码
                
                start_addr_w = current_addr
                for i in range(0, len(flat_w), 4):
                    chunk = flat_w[i:i+4]
                    if len(chunk) < 4:
                        chunk = np.pad(chunk, (0, 4 - len(chunk)), constant_values=0)
                    hex_val = f"{int(chunk[3]):02X}{int(chunk[2]):02X}{int(chunk[1]):02X}{int(chunk[0]):02X}"
                    f.write(f"{hex_val}\n")
                    current_addr += 1
                stop_addr_w = current_addr - 1
                
                # ----------------------------------------------------
                # 2. 偏置 (Biases) - INT16
                # ----------------------------------------------------
                q_bias, _ = quantize_tensor(bias, 16)
                flat_b = q_bias.flatten().view(np.uint16) # 转uint16处理负数补码
                
                start_addr_b = current_addr
                for i in range(0, len(flat_b), 2):
                    chunk = flat_b[i:i+2]
                    if len(chunk) < 2:
                        chunk = np.pad(chunk, (0, 2 - len(chunk)), constant_values=0)
                    hex_val = f"{int(chunk[1]):04X}{int(chunk[0]):04X}"
                    f.write(f"{hex_val}\n")
                    current_addr += 1
                stop_addr_b = current_addr - 1
                
                # ----------------------------------------------------
                # 3. 反量化移位参数 (Shift_N) - INT32
                # ----------------------------------------------------
                shift_n = int(math.ceil(math.log2(1.0 / (w_scale * 1.0)))) if w_scale > 0 else 0
                
                start_addr_s = current_addr
                f.write(f"{shift_n:08X}\n") # 占一个32-bit字
                current_addr += 1
                stop_addr_s = current_addr - 1
                
                # 记录 Verilog 地址宏
                verilog_macros.append(f"    // {prefix}: {name} ({list(weight.shape)})")
                verilog_macros.append(f"    localparam {prefix}_W_START = 16'd{start_addr_w};  localparam {prefix}_W_STOP = 16'd{stop_addr_w};")
                verilog_macros.append(f"    localparam {prefix}_B_START = 16'd{start_addr_b};  localparam {prefix}_B_STOP = 16'd{stop_addr_b};")
                verilog_macros.append(f"    localparam {prefix}_S_START = 16'd{start_addr_s};\n")
                
                layer_idx += 1
                
    print(f"\n✅ 导出成功！文件已保存至: {export_path}")
    print(f"📦 总共占用 32-bit 内存深度: {current_addr} words")
    
    print("\n" + "="*60)
    print(" 📋 请将以下代码直接复制到 NeuralAcceleratorCTRL.sv 中")
    print("="*60 + "\n")
    for macro in verilog_macros:
        print(macro)

# ===========================================================================
# [M0 / Path B] Blocked byte-stream export for weight_rom_dma
# ===========================================================================
#
# 依据：docs/weight_rom_dma_设计_PathB.md §3 (v1.1冻结)
# 布局：
#   per layer:
#     for oc_g in 0..oc_groups-1:
#       for cin_g in 0..cin_groups-1:
#         16×16×K² 字节块（全 padding 到边界）
#         顺序：for ic_local in 0..15:
#                  for oc_pair in 0..7:
#                    even ch的 K² 字节 (flatten Ky,Kx)
#                    odd  ch的 K² 字节
#       16×INT32 bias（每 oc_g，zero-pad到 16 通道）
#     1×INT32 shift_n
# 寻址单位：32-bit word（每 4 字节打一行 hex）
# 与 sequencer 算术对齐：字单位下 oc_stride_w = 4×cin_total×K², cin_stride_w = 64×K²
# ===========================================================================

_LAYER_SPEC = [
    # (prefix, kind, kernel, has_input_pool_before)  # 与 gen_microcode.py / face_inference_ref.py 的拓扑严格一致
    ("C1",  "conv", 3),
    ("C2",  "conv", 3),
    ("C3",  "conv", 1),
    ("C4",  "conv", 3),
    ("C5",  "conv", 3),
    ("C6",  "conv", 1),
    ("C7",  "conv", 3),
    ("C8",  "conv", 2),
    ("FC1", "fc",   1),
    ("FC2", "fc",   1),
]


def _bytes_to_hex_lines(byte_stream):
    """将字节流（list of int 0..255）打包为 32-bit hex 行 (little-endian)。
    返回 hex 字符串列表。总长必须是 4 的倍数。
    """
    assert len(byte_stream) % 4 == 0, f"byte stream {len(byte_stream)} not 4-aligned"
    lines = []
    for i in range(0, len(byte_stream), 4):
        b0, b1, b2, b3 = byte_stream[i:i+4]
        lines.append(f"{b3 & 0xFF:02X}{b2 & 0xFF:02X}{b1 & 0xFF:02X}{b0 & 0xFF:02X}")
    return lines


def _build_weight_block(q_weight, kernel, oc_g, cin_g):
    """生成单 (oc_g, cin_g) 权重块：16×16×K² 字节，越界补零。
    对应 sim/face_inference_ref.py:repack_conv_weights_for_npu / repack_fc_weights_for_npu 迭代顺序。
    """
    NUM_LANES = 16
    K2 = kernel * kernel
    Cout, Cin = q_weight.shape[0], q_weight.shape[1]
    out = []
    for ic_local in range(NUM_LANES):
        ic_global = cin_g * NUM_LANES + ic_local
        for oc_pair in range(0, NUM_LANES, 2):
            for half in (0, 1):                       # 0 = even, 1 = odd
                oc_global = oc_g * NUM_LANES + oc_pair + half
                if oc_global < Cout and ic_global < Cin:
                    if q_weight.ndim == 4:           # conv [Cout,Cin,Ky,Kx]
                        taps = q_weight[oc_global, ic_global].flatten()  # K² 字节
                    else:                             # fc [Cout, Cin_flat]
                        taps = np.array([q_weight[oc_global, ic_global]], dtype=np.int8)
                    taps_u8 = taps.view(np.uint8)
                    for t in range(K2):
                        out.append(int(taps_u8[t]) if t < len(taps_u8) else 0)
                else:
                    out.extend([0] * K2)
    assert len(out) == NUM_LANES * NUM_LANES * K2
    return out


def _build_bias_block(q_bias, oc_g):
    """生成单 oc_g 偏置块：16×INT32 小端字节 = 64 字节。q_bias 以 INT16 量化后符号扩展到 INT32。越界补零。"""
    NUM_LANES = 16
    out = []
    for ch_local in range(NUM_LANES):
        oc_global = oc_g * NUM_LANES + ch_local
        if oc_global < len(q_bias):
            v = int(q_bias[oc_global])               # 已是带符号 int16
        else:
            v = 0
        u32 = v & 0xFFFFFFFF
        out.extend([
            u32        & 0xFF,
            (u32 >>  8) & 0xFF,
            (u32 >> 16) & 0xFF,
            (u32 >> 24) & 0xFF,
        ])
    assert len(out) == 64
    return out


def export_blocked_npu_params(model: nn.Module, export_path: str = "npu_params.hex",
                              input_h: int = 120, input_w: int = 160):
    """块化导出完整 NPU 参数 (Path B B1)，寻址单位 = 32-bit word。

    同时输出 npu_param_rom.v 表（对应新块状布局的起点地址）供用户粘贴。
    """
    model.eval()

    # ---- 1. 遭历 layer，量化 + 跳过重排 ----
    layers = []
    cur_h, cur_w = input_h, input_w
    layer_idx = 0
    for name, module in model.named_modules():
        if isinstance(module, nn.MaxPool2d):
            k = module.kernel_size if isinstance(module.kernel_size, int) else module.kernel_size[0]
            cur_h //= k
            cur_w //= k
            continue
        if not isinstance(module, (nn.Conv2d, nn.Linear)):
            continue
        prefix, kind, kernel = _LAYER_SPEC[layer_idx]
        is_fc = (kind == "fc")

        weight = module.weight.data
        bias_t = module.bias.data if module.bias is not None else torch.zeros(weight.size(0))

        if not is_fc:
            kh = module.kernel_size[0] if isinstance(module.kernel_size, tuple) else module.kernel_size
            ph = module.padding[0]    if isinstance(module.padding, tuple)    else module.padding
            sh = module.stride[0]     if isinstance(module.stride, tuple)     else module.stride
            cur_h = (cur_h + 2 * ph - kh) // sh + 1
            cur_w = (cur_w + 2 * ph - kh) // sh + 1
            prev_per_oc = cur_h * cur_w
        else:
            prev_per_oc = cur_h * cur_w  # 上一层输出的 H×W（FC1 使用）

        q_weight, w_scale = quantize_tensor(weight, 8)
        if is_fc:
            q_weight = permute_fc_weights_for_npu(q_weight, prev_per_oc)
            cur_h, cur_w = 1, 1
            prev_per_oc = 1

        q_bias, _ = quantize_tensor(bias_t, 16)
        shift_n_raw = int(math.ceil(math.log2(1.0 / w_scale))) if w_scale > 0 else 0
        shift_n = max(0, min(15, shift_n_raw))

        Cout = q_weight.shape[0]
        Cin  = q_weight.shape[1]
        oc_groups  = (Cout + 15) // 16
        cin_groups = (Cin  + 15) // 16

        layers.append(dict(
            prefix=prefix, kind=kind, kernel=kernel,
            q_weight=q_weight, q_bias=q_bias,
            Cout=Cout, Cin=Cin, oc_groups=oc_groups, cin_groups=cin_groups,
            shift_n=shift_n, shift_n_raw=shift_n_raw, w_scale=w_scale,
        ))
        layer_idx += 1

    # ---- 2. 写出 hex，跟踪 base 地址 ----
    rom_macros = []
    cur_word = 0

    print("=" * 72)
    print(" 🚀 [M0/Path B] 块化导出 NPU 参数 (字单位, RPT-3)")
    print("=" * 72)
    print(f"{'layer':>5} | {'shape':>20} | {'k':>2} | oc_g cin_g | {'wW':>6} {'bW':>3} {'sW':>3} | shift_n_raw shift_n_clip")
    print("-" * 96)

    with open(export_path, 'w') as f:
        f.write("@00000000\n")
        for L in layers:
            K2 = L['kernel'] * L['kernel']
            block_bytes = 16 * 16 * K2
            assert block_bytes % 4 == 0
            block_words = block_bytes // 4

            # ---- weights ----
            w_start = cur_word
            for oc_g in range(L['oc_groups']):
                for cin_g in range(L['cin_groups']):
                    block = _build_weight_block(L['q_weight'], L['kernel'], oc_g, cin_g)
                    for line in _bytes_to_hex_lines(block):
                        f.write(line + "\n")
                    cur_word += block_words
            w_words = cur_word - w_start

            # ---- bias (16 INT32 per oc_g) ----
            b_start = cur_word
            for oc_g in range(L['oc_groups']):
                block = _build_bias_block(L['q_bias'], oc_g)
                for line in _bytes_to_hex_lines(block):
                    f.write(line + "\n")
                cur_word += 16
            b_words = cur_word - b_start

            # ---- shift (1 INT32) ----
            s_start = cur_word
            f.write(f"{L['shift_n'] & 0xFFFFFFFF:08X}\n")
            cur_word += 1

            print(f"{L['prefix']:>5} | {str(list(L['q_weight'].shape)):>20} | {L['kernel']:>2} | "
                  f"{L['oc_groups']:>4} {L['cin_groups']:>5} | {w_words:>6} {b_words:>3} {1:>3} | "
                  f"{L['shift_n_raw']:>11} {L['shift_n']:>12}")

            rom_macros.append(
                f"            5'd{layers.index(L)}: begin o_weight_base_addr = 16'd{w_start:>5}; "
                f"o_bias_base_addr = 16'd{b_start:>5}; end // {L['prefix']} (shift @ {s_start})")

    print("-" * 96)
    print(f"总计 32-bit 字深度: {cur_word} words ({cur_word*4/1024:.1f} KB)")
    print(f"需要 ROM 位宽: {(cur_word - 1).bit_length()} bits ({1 << (cur_word - 1).bit_length()} max words)")

    print("\n" + "=" * 72)
    print(" 📋 npu_param_rom.v 新表（复制粘贴到 case 块）")
    print("=" * 72)
    for m in rom_macros:
        print(m)

    # shift 值域安全检查
    raw_max = max(L['shift_n_raw'] for L in layers)
    raw_min = min(L['shift_n_raw'] for L in layers)
    print("\n" + "=" * 72)
    print(f" ⚠️ shift_n 值域检查（RPT-5）：raw range = [{raw_min}, {raw_max}], 4-bit field max = 15")
    if raw_max > 15:
        print(f" ❌ 警告：shift_n_raw {raw_max} > 15，必须扩宽 microcode shift 字段到 5-bit")
    else:
        print(f" ✅ 全部在 4-bit 字段范围内，microcode bit[17:14] 足够")
    print("=" * 72)


if __name__ == "__main__":
    import os
    script_dir = os.path.dirname(__file__)
    params_dir = os.path.abspath(os.path.join(script_dir, "..", "params"))
    os.makedirs(params_dir, exist_ok=True)
    pth = os.path.join(params_dir, "fpga_face_net.pth")
    model = FPGALightFaceNet()
    if os.path.exists(pth):
        model.load_state_dict(torch.load(pth, map_location="cpu"))
        print(f"[quant_int8] loaded weights from {pth}")
    else:
        print(f"[quant_int8] (warn) {pth} not found — exporting random init weights")
    out = os.path.join(params_dir, "npu_params.hex")
    export_blocked_npu_params(model, out)
