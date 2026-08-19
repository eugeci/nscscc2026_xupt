SIM ?= vcs
TOPLEVEL_LANG ?= verilog
# 加入所有编译文件
VERILOG_SOURCES += $(PWD)/../npu_team_a_top.v $(PWD)/../dummy_npu.v $(PWD)/../../gcu/gcu.v $(PWD)/../../bcu/bcu.v $(PWD)/../../bcu/fm_bank_array.v 
TOPLEVEL = npu_team_a_top
MODULE = test_npu_system
include $(shell cocotb-config --makefiles)/Makefile.sim