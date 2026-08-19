import random
from typing import Any, Dict
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

# ==============================================================================
# 模块一验证支持类：FM Bank Array
# ==============================================================================
class FMBankEnv:
    """FM Bank Array 存储体仿真环境类。"""

    def __init__(self, dut: Any, clock_period_ns: int = 10) -> None:
        self.dut = dut
        self.clk_period = clock_period_ns

    async def reset(self) -> None:
        """重置存储体输入总线。"""
        self.dut.i_write_en.value = 0
        self.dut.i_write_mask.value = 0
        self.dut.i_write_addr.value = 0
        self.dut.i_write_bus.value = 0
        self.dut.i_read_en.value = 0
        self.dut.i_read_addr.value = 0
        self.dut.i_read_cin_idx.value = 0
        # 修复 Warning: units -> unit
        await Timer(self.clk_period * 2, unit="ns")
        await RisingEdge(self.dut.clk)

    async def write_broadcast(self, addr: int, data_128b: int) -> None:
        """驱动 128-bit 广播写入操作。"""
        self.dut.i_write_en.value = 1
        self.dut.i_write_mask.value = 0xFFFF
        self.dut.i_write_addr.value = addr
        self.dut.i_write_bus.value = data_128b
        await RisingEdge(self.dut.clk)
        self.dut.i_write_en.value = 0
        self.dut.i_write_mask.value = 0

    async def write_masked(self, addr: int, data_128b: int, mask: int) -> None:
        """驱动带 per-bank mask 的 128-bit 写入操作。"""
        self.dut.i_write_en.value = 1
        self.dut.i_write_mask.value = mask
        self.dut.i_write_addr.value = addr
        self.dut.i_write_bus.value = data_128b
        await RisingEdge(self.dut.clk)
        self.dut.i_write_en.value = 0
        self.dut.i_write_mask.value = 0

    async def read_channel(self, addr: int, cin_idx: int) -> int:
        """挂起其他通道，读取特定通道的 8-bit 数据（包含1拍延迟模拟）。"""
        self.dut.i_read_en.value = 1
        self.dut.i_read_addr.value = addr
        self.dut.i_read_cin_idx.value = cin_idx
        await RisingEdge(self.dut.clk)
        self.dut.i_read_en.value = 0
        
        # 硬件设计中具有一拍延迟，必须再等一个上升沿数据才从 BRAM 吐出
        await RisingEdge(self.dut.clk)
        
        # 修复 ReadOnly 报错：在时钟下降沿采样数据，既稳定又能推动仿真时间脱离只读锁定状态
        await FallingEdge(self.dut.clk)
        return int(self.dut.o_read_data.value)

# ==============================================================================
# 模块二验证支持类：BCU
# ==============================================================================
class BCUEnv:
    """BCU 控制单元仿真环境类。"""

    def __init__(self, dut: Any) -> None:
        self.dut = dut
        self.timeout_limit = 50000  # 防止死锁的安全阈值

    async def reset(self) -> None:
        """执行异步全局复位。"""
        self.dut.rst_n.value = 0
        self.dut.layer_start.value = 0
        self.dut.i_is_fc_mode.value = 0
        self.dut.i_cfg_width.value = 0
        self.dut.i_cfg_height.value = 0
        self.dut.i_cfg_kernel.value = 0
        self.dut.i_cfg_pool_en.value = 0
        self.dut.i_cfg_padding_en.value = 0
        self.dut.i_cfg_cin_total.value = 0
        self.dut.i_oc_group_idx.value = 0
        self.dut.i_cin_group_idx.value = 0
        self.dut.i_cin_block_size.value = 1
        self.dut.i_is_first_cin_group.value = 1
        self.dut.i_is_last_cin_group.value = 1
        self.dut.i_is_layer0.value = 0
        self.dut.i_l0_packed_read_en.value = 0
        self.dut.i_npu_in_ready.value = 1
        self.dut.i_npu_out_valid.value = 0
        self.dut.i_conv_out_x.value = 0
        self.dut.i_conv_out_y.value = 0
        self.dut.i_pipeline_idle.value = 1
        # 修复 Warning: units -> unit
        await Timer(20, unit="ns")
        self.dut.rst_n.value = 1
        await RisingEdge(self.dut.clk)

    async def start_layer(self, cfg: Dict[str, int]) -> None:
        """下发静态配置并触发计算层启动脉冲。"""
        self.dut.i_cfg_width.value = cfg.get("width", 16)
        self.dut.i_cfg_height.value = cfg.get("height", 16)
        self.dut.i_cfg_kernel.value = cfg.get("kernel", 2)       # 2 -> 3x3
        self.dut.i_cfg_padding_en.value = cfg.get("padding", 1)  # 1 -> SAME
        self.dut.i_cfg_pool_en.value = cfg.get("pool", 0)
        self.dut.i_cfg_cin_total.value = cfg.get("cin", 4)
        self.dut.i_cin_group_idx.value = cfg.get("cin_group", 0)
        self.dut.i_cin_block_size.value = cfg.get("cin_block", cfg.get("cin", 4))
        self.dut.i_is_layer0.value = cfg.get("is_layer0", 0)
        self.dut.i_l0_packed_read_en.value = cfg.get("packed", 0)
        
        await RisingEdge(self.dut.clk)
        self.dut.layer_start.value = 1
        await RisingEdge(self.dut.clk)
        self.dut.layer_start.value = 0

    async def dummy_npu_responder(self, expected_writes: int) -> None:
        """模拟 NPU 在计算完毕后，随机且断续地吐出 out_valid。"""
        writes_done = 0
        while writes_done < expected_writes:
            await RisingEdge(self.dut.clk)
            # 随机模拟流水线的反压与停顿
            if random.random() > 0.5:
                self.dut.i_npu_out_valid.value = 1
                writes_done += 1
            else:
                self.dut.i_npu_out_valid.value = 0
        
        # 释放有效信号
        await RisingEdge(self.dut.clk)
        self.dut.i_npu_out_valid.value = 0

    async def wait_for_done(self) -> int:
        """等待层计算完成，附带硬件级看门狗。"""
        cycles = 0
        while int(self.dut.layer_done.value) == 0:
            await RisingEdge(self.dut.clk)
            cycles += 1
            assert cycles <= self.timeout_limit, f"Timeout in {cycles} cycles! layer_done never triggered. Potential deadlock."
        return cycles

# ==============================================================================
# Cocotb 测试用例 (Test Cases)
# ==============================================================================

@cocotb.test()
async def test_fm_bank_write_read(dut: Any) -> None:
    """[Phase 1] 验证 SRAM 阵列的 128-bit 广播写入与 8-bit 精准通道读取。"""
    if dut._name != "fm_bank_array":
        return

    # 修复 Warning: units -> unit
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    env = FMBankEnv(dut)
    await env.reset()

    test_addr = 14
    # 生成 16 个不同的 8-bit 数据组合成 128-bit
    test_data_bytes = [random.randint(0, 255) for _ in range(16)]
    test_128b_word = sum([val << (i * 8) for i, val in enumerate(test_data_bytes)])

    # 1. 广播写入
    await env.write_broadcast(test_addr, test_128b_word)

    # 2. 逐通道单次读取校验 (检查门控和延迟是否工作)
    for cin in range(16):
        read_val = await env.read_channel(test_addr, cin)
        assert read_val == test_data_bytes[cin], \
            f"Data mismatch at cin_idx={cin}. Expected {test_data_bytes[cin]}, got {read_val}."
    
    dut._log.info("FM Bank Array RW validation passed.")


@cocotb.test()
async def test_fm_bank_write_mask(dut: Any) -> None:
    """[Phase A] 验证 per-bank write mask 只更新被选中的 bank。"""
    if dut._name != "fm_bank_array":
        return

    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    env = FMBankEnv(dut)
    await env.reset()

    test_addr = 7
    base_bytes = [0x10 + i for i in range(16)]
    base_word = sum(val << (i * 8) for i, val in enumerate(base_bytes))
    await env.write_broadcast(test_addr, base_word)

    update_bytes = [0x80 + i for i in range(16)]
    update_word = sum(val << (i * 8) for i, val in enumerate(update_bytes))
    update_mask = (1 << 0) | (1 << 3) | (1 << 15)
    await env.write_masked(test_addr, update_word, update_mask)

    for cin in range(16):
        expected = update_bytes[cin] if (update_mask >> cin) & 1 else base_bytes[cin]
        read_val = await env.read_channel(test_addr, cin)
        assert read_val == expected, \
            f"Masked write mismatch at cin_idx={cin}. Expected {expected}, got {read_val}."

    dut._log.info("FM Bank Array write-mask validation passed.")


@cocotb.test()
async def test_bcu_dimension_reduction(dut: Any) -> None:
    """[Phase 2] 验证 BCU 在开启不同 Padding / Pooling 下，最终的收敛时序。"""
    if dut._name != "bcu":
        return

    # 修复 Warning: units -> unit
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    env = BCUEnv(dut)
    await env.reset()

    # 测试向量字典：配置 -> NPU 应该吐出的总数
    test_vectors = [
        {"cfg": {"width": 16, "height": 16, "kernel": 2, "padding": 1, "pool": 0, "cin": 1}, "expected": 256}, # 3x3 SAME
        {"cfg": {"width": 16, "height": 16, "kernel": 2, "padding": 0, "pool": 0, "cin": 1}, "expected": 196}, # 3x3 VALID (14x14)
        {"cfg": {"width": 16, "height": 16, "kernel": 2, "padding": 0, "pool": 1, "cin": 1}, "expected": 49},  # 3x3 VALID + 2x2 POOL (7x7)
        {"cfg": {"width": 16, "height": 16, "kernel": 0, "padding": 0, "pool": 0, "cin": 1}, "expected": 256}, # 1x1 VALID
    ]

    for idx, tv in enumerate(test_vectors):
        cfg = tv["cfg"]
        expected_writes = tv["expected"]
        dut._log.info(f"Running config {idx}: {cfg}, expecting {expected_writes} writes back.")

        # 1. 启动层
        await env.start_layer(cfg)

        # 2. 启动 NPU 异步回写模拟协程
        cocotb.start_soon(env.dummy_npu_responder(expected_writes))

        # 3. 阻塞等待 layer_done
        elapsed = await env.wait_for_done()
        
        # 4. 校验状态机是否安全回退到 IDLE (3'd0)
        assert int(dut.state.value) == 0, f"Config {idx} failed to return to IDLE."
        dut._log.info(f"Config {idx} passed successfully in {elapsed} cycles.")


async def _collect_bcu_reads(dut: Any, count: int) -> list[tuple[int, int]]:
    reads: list[tuple[int, int]] = []
    timeout = 200
    while len(reads) < count and timeout > 0:
        await FallingEdge(dut.clk)
        if int(dut.o_sram_rd_en.value) == 1:
            reads.append((int(dut.o_sram_rd_addr.value),
                          int(dut.o_sram_cin_idx.value)))
        await RisingEdge(dut.clk)
        timeout -= 1
    assert len(reads) == count, f"Expected {count} reads, captured {len(reads)}"
    return reads


@cocotb.test()
async def test_bcu_default_group_read_addresses(dut: Any) -> None:
    """[Phase B] 默认 group/lane layout 地址保持旧行为。"""
    if dut._name != "bcu":
        return

    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    env = BCUEnv(dut)
    await env.reset()

    await env.start_layer({
        "width": 4,
        "height": 2,
        "kernel": 0,
        "padding": 0,
        "pool": 0,
        "cin": 3,
        "cin_block": 3,
        "cin_group": 2,
        "is_layer0": 1,
        "packed": 0,
    })

    reads = await _collect_bcu_reads(dut, 24)
    expected = []
    for cin in range(3):
        for pixel in range(8):
            expected.append((2 * 8 + pixel, cin))

    assert reads == expected, f"Default group layout mismatch. Expected {expected}, got {reads}"
    dut._log.info("BCU default group-layout read address validation passed.")


@cocotb.test()
async def test_bcu_layer0_packed_read_addresses(dut: Any) -> None:
    """[Phase B] layer-0 packed preload layout 使用 linear[3:0] 选 bank、linear>>4 选 addr。"""
    if dut._name != "bcu":
        return

    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    env = BCUEnv(dut)
    await env.reset()

    await env.start_layer({
        "width": 4,
        "height": 2,
        "kernel": 0,
        "padding": 0,
        "pool": 0,
        "cin": 3,
        "cin_block": 3,
        "cin_group": 0,
        "is_layer0": 1,
        "packed": 1,
    })

    reads = await _collect_bcu_reads(dut, 24)
    expected = []
    for cin in range(3):
        for pixel in range(8):
            linear = cin * 8 + pixel
            expected.append((linear >> 4, linear & 0xF))

    assert reads == expected, f"Packed layer-0 layout mismatch. Expected {expected}, got {reads}"
    dut._log.info("BCU layer-0 packed read address validation passed.")
