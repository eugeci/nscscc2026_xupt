CC ?= cc
XNPU_DIR ?= ../../../linux/npu/userspace
BUILD_DIR ?= build
CPPFLAGS += -I$(XNPU_DIR)/include -I$(XNPU_DIR)/lib -I$(XNPU_DIR)/../kernel/include/uapi
CFLAGS ?= -O2
CFLAGS += -std=c99 -Wall -Wextra -Werror

.PHONY: all clean test
all: $(BUILD_DIR)/visionarm-block
$(BUILD_DIR):
	mkdir -p $@
$(BUILD_DIR)/visionarm-block: visionarm_block.c calibration.c calibration.h \
		$(XNPU_DIR)/lib/xnpu.c $(XNPU_DIR)/lib/sha256.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) visionarm_block.c calibration.c \
		$(XNPU_DIR)/lib/xnpu.c $(XNPU_DIR)/lib/sha256.c \
		$(LDFLAGS) -o $@
test: $(BUILD_DIR)/visionarm-block
	$(BUILD_DIR)/visionarm-block --self-test
	$(BUILD_DIR)/visionarm-block --calibration tests/valid_calibration.ini \
		--check-calibration
clean:
	rm -rf $(BUILD_DIR)
