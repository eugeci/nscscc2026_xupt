SIM ?= vcs
TOPLEVEL_LANG ?= verilog

# 指定你要编译的 RTL 源文件
VERILOG_SOURCES += $(PWD)/../$(TOPLEVEL).v

# 测试哪个顶层就修改 TOPLEVEL 变量
# 测试 FM Bank Array:
TOPLEVEL ?= fm_bank_array
# 测试 BCU:
# make TOPLEVEL=bcu

MODULE = test_npu_modules
SIM_BUILD ?= sim_build/$(TOPLEVEL)

include $(shell cocotb-config --makefiles)/Makefile.sim
