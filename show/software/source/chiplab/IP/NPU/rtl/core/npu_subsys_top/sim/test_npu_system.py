import random
import logging
from typing import Any, List
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.handle import Force, Release

# ==============================================================================
# 1. SoC 总线驱动器 (Bus Driver)
# ==============================================================================
class SoCAXILiteDriver:
    """模拟 CPU 总线访问 GCU 寄存器的驱动类。"""
    def __init__(self, dut: Any):
        self.dut = dut

    async def reset_system(self) -> None:
        self.dut.rst_n.value = 0
        self.dut.cfg_wen.value = 0
        self.dut.cfg_addr.value = 0
        self.dut.cfg_wdata.value = 0
        await Timer(30, unit="ns")
        self.dut.rst_n.value = 1
        await RisingEdge(self.dut.clk)

    async def write_reg(self, addr: int, data: int) -> None:
        await RisingEdge(self.dut.clk)
        self.dut.cfg_addr.value = addr
        self.dut.cfg_wdata.value = data
        self.dut.cfg_wen.value = 1
        await RisingEdge(self.dut.clk)
        self.dut.cfg_wen.value = 0
        await FallingEdge(self.dut.clk)

    async def read_reg(self, addr: int) -> int:
        await RisingEdge(self.dut.clk)
        self.dut.cfg_addr.value = addr
        self.dut.cfg_wen.value = 0
        await RisingEdge(self.dut.clk)
        await FallingEdge(self.dut.clk)
        return int(self.dut.cfg_rdata.value)

    async def wait_for_irq(self, timeout: int = 100000) -> int:
        cycles = 0
        while int(self.dut.irq_layer_done.value) == 0:
            await RisingEdge(self.dut.clk)
            cycles += 1
            assert cycles <= timeout, f"System Deadlock! IRQ missing after {timeout} cycles."
        return cycles

# ==============================================================================
# 2. 存储器混合注入模型 (SRAM Hybrid Access Model) - 完美兼容 VCS
# ==============================================================================
class SRAMHybridAccess:
    """双模式 SRAM 驱动：优先尝试 VPI 零延时后门，失败则自动回退至管脚 Force 硬件注入。"""
    def __init__(self, sram_module: Any, clk: Any):
        self.sram = sram_module
        self.clk = clk
        self._log = logging.getLogger(f"cocotb.{sram_module._name}")

    def _get_mem_handle(self, channel: int):
        """兼容性极佳的底层数组句柄探针"""
        try:
            # 尝试标准 Iverilog 层级
            if hasattr(self.sram, "gen_sram_bank"):
                return self.sram.gen_sram_bank[channel].mem
            # 尝试 VCS 扁平化映射
            if hasattr(self.sram, f"gen_sram_bank[{channel}]"):
                return getattr(self.sram, f"gen_sram_bank[{channel}]").mem
            if hasattr(self.sram, f"gen_sram_bank_{channel}"):
                return getattr(self.sram, f"gen_sram_bank_{channel}").mem
        except AttributeError:
            pass
        return None  # 彻底被 VCS 优化掉

    async def load_image(self, channel: int, data_array: List[int]) -> None:
        mem_handle = self._get_mem_handle(channel)
        if mem_handle is not None:
            # [方案 A] VPI 瞬间注入
            for addr, val in enumerate(data_array):
                mem_handle[addr].value = val
            await RisingEdge(self.clk)
        else:
            # [方案 B] 管脚强制驱动 (解决 VCS +memcbk 缺失问题)
            # 模拟真实的 DMA 控制器逐周期写入
            for addr, val in enumerate(data_array):
                bus_val = (val & 0xFF) << (channel * 8)
                self.sram.i_write_bus.value = Force(bus_val)
                self.sram.i_write_addr.value = Force(addr)
                self.sram.i_write_en.value = Force(1)
                await RisingEdge(self.clk)
            
            # 释放管脚，交回 NPU 控制权
            self.sram.i_write_bus.value = Release()
            self.sram.i_write_addr.value = Release()
            self.sram.i_write_en.value = Release()
            await RisingEdge(self.clk)

    async def read_image(self, channel: int, length: int) -> List[int]:
        mem_handle = self._get_mem_handle(channel)
        if mem_handle is not None:
            await RisingEdge(self.clk)
            return [int(mem_handle[addr].value) for addr in range(length)]
        else:
            result = []
            for addr in range(length):
                # 强制驱动读控制信号
                self.sram.i_read_cin_idx.value = Force(channel)
                self.sram.i_read_addr.value = Force(addr)
                self.sram.i_read_en.value = Force(1)
                await RisingEdge(self.clk)          # 地址和使能生效
                await RisingEdge(self.clk)          # SRAM 读延迟（典型 1 周期）
                
                val = self.sram.o_read_data.value
                try:
                    data = int(val)
                except ValueError:
                    # 非二进制值（X/Z），记录警告并置 0
                    self._log.warning(
                        f"Read backdoor failed: channel {channel} addr {addr} "
                        f"got {val.binstr}, forced to 0"
                    )
                    data = 0
                result.append(data)
                
                # 释放强制驱动
                self.sram.i_read_cin_idx.value = Release()
                self.sram.i_read_addr.value = Release()
                self.sram.i_read_en.value = Release()
                await RisingEdge(self.clk)          # 等待释放稳定
            return result

# ==============================================================================
# 3. 验证测试用例 (Test Cases)
# ==============================================================================

@cocotb.test()
async def test_reg_access_and_safety(dut: Any) -> None:
    """[维度一 & 二] 测试寄存器读写、中断清除以及防呆互锁设计。"""
    if dut._name != "npu_team_a_top": return
    
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    bus = SoCAXILiteDriver(dut)
    await bus.reset_system()

    # 1. 寄存器读写比对
    test_width = 123
    await bus.write_reg(0x08, (200 << 8) | test_width)
    rdata = await bus.read_reg(0x08)
    assert (rdata & 0xFF) == test_width, "Register RW mismatch!"

    # 2. 启动并测试防呆
    await bus.write_reg(0x0C, (1 << 8) | (2 << 4))
    await bus.write_reg(0x00, 1) 
    await bus.write_reg(0x00, 1) # 非法重入测试
    
    status = await bus.read_reg(0x04)
    assert (status & 0x01) == 1, "Busy bit should be 1."
    
    await bus.wait_for_irq()
    
    # 3. 验证 W1C
    await bus.write_reg(0x04, 0x00)
    assert int(dut.irq_layer_done.value) == 1
    
    await bus.write_reg(0x04, 0x02)
    await FallingEdge(dut.clk)
    assert int(dut.irq_layer_done.value) == 0
    dut._log.info("Register safety and IRQ protocol passed.")


@cocotb.test()
async def test_ping_pong_dataflow(dut: Any) -> None:
    """[维度三] 测试双缓冲交替数据流，采用 Hybrid 模型兼容底层读取。"""
    if dut._name != "npu_team_a_top": return

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    bus = SoCAXILiteDriver(dut)
    ping_bram = SRAMHybridAccess(dut.ping_array, dut.clk)
    pong_bram = SRAMHybridAccess(dut.pong_array, dut.clk)
    
    await bus.reset_system()

    img_size = 16 * 16
    cin = 0

    # ---------- Layer 1 (PING -> NPU -> PONG) ----------
    dut._log.info("=== Layer 1: PING -> PONG ===")
    layer1_in_data = [random.randint(0, 254) for _ in range(img_size)]
    
    # 因为变成了异步混合模式，必须加 await
    await ping_bram.load_image(cin, layer1_in_data)
    
    await bus.write_reg(0x08, (16 << 8) | 16)
    await bus.write_reg(0x0C, (1 << 8) | (2 << 4) | 0)
    await bus.write_reg(0x14, (1 << 16))
    await bus.write_reg(0x00, 1)
    
    await bus.wait_for_irq()
    await bus.write_reg(0x04, 0x02)
    
    for target_ch in [0, 15]:
        layer1_out_data = await pong_bram.read_image(target_ch, img_size)
        for i in range(img_size):
            expected = (layer1_in_data[i] + 1) & 0xFF
            assert layer1_out_data[i] == expected, f"Layer 1 mismatch at addr {i}, ch {target_ch}"
    
    # ---------- Layer 2 (PONG -> NPU -> PING) ----------
    dut._log.info("=== Layer 2: PONG -> PING ===")
    await bus.write_reg(0x00, 1)
    await bus.wait_for_irq()
    
    layer2_out_data = await ping_bram.read_image(5, img_size)
    layer1_out_ch0 = await pong_bram.read_image(0, img_size)
    
    for i in range(img_size):
        expected = (layer1_out_ch0[i] + 1) & 0xFF
        assert layer2_out_data[i] == expected, f"Layer 2 mismatch at addr {i}"

    dut._log.info("Ping-Pong multi-layer dataflow bit-accurate match passed!")