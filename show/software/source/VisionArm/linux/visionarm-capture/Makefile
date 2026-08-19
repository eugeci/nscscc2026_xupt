CC ?= cc
BUILD_DIR ?= build
CFLAGS ?= -O2
CFLAGS += -std=c99 -Wall -Wextra -Werror

.PHONY: all clean test
all: $(BUILD_DIR)/visionarm-capture
$(BUILD_DIR):
	mkdir -p $@
$(BUILD_DIR)/visionarm-capture: visionarm_capture.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@
test: $(BUILD_DIR)/visionarm-capture
	$(BUILD_DIR)/visionarm-capture --self-test
clean:
	rm -rf $(BUILD_DIR)
