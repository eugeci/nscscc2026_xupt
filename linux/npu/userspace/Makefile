CC ?= cc
AR ?= ar
BUILD_DIR ?= build
UAPI_DIR ?= ../kernel/include/uapi
CPPFLAGS += -Iinclude -Ilib -I$(UAPI_DIR)
CFLAGS ?= -O2
CFLAGS += -std=c99 -Wall -Wextra -Werror

LIB_OBJECTS := $(BUILD_DIR)/xnpu.o $(BUILD_DIR)/sha256.o
TOOLS := $(BUILD_DIR)/xnpu-inspect $(BUILD_DIR)/xnpu-run \
	$(BUILD_DIR)/xnpu-regress

.PHONY: all clean test

all: $(TOOLS)

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/xnpu.o: lib/xnpu.c include/xnpu.h lib/sha256.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/sha256.o: lib/sha256.c lib/sha256.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/libxnpu.a: $(LIB_OBJECTS)
	$(AR) rcs $@ $^

$(BUILD_DIR)/xnpu-inspect: xnpu_inspect.c $(BUILD_DIR)/libxnpu.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD_DIR)/libxnpu.a \
		$(LDFLAGS) -o $@

$(BUILD_DIR)/xnpu-run: xnpu_run.c $(BUILD_DIR)/libxnpu.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD_DIR)/libxnpu.a \
		$(LDFLAGS) -o $@

$(BUILD_DIR)/xnpu-regress: xnpu_regress.c $(BUILD_DIR)/libxnpu.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD_DIR)/libxnpu.a \
		$(LDFLAGS) -o $@

$(BUILD_DIR)/xnpu-stage4-smoke: xnpu_stage4_smoke.c $(BUILD_DIR)/libxnpu.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD_DIR)/libxnpu.a \
		$(LDFLAGS) -o $@

$(BUILD_DIR)/test-xnpu-format: tests/test_xnpu_format.c \
		$(BUILD_DIR)/libxnpu.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD_DIR)/libxnpu.a \
		$(LDFLAGS) -o $@

test: $(BUILD_DIR)/test-xnpu-format
	@test -n "$(PACKAGES_DIR)" || \
		{ echo "set PACKAGES_DIR to the package directory" >&2; exit 2; }
	$(BUILD_DIR)/test-xnpu-format $(PACKAGES_DIR)/*.xnpu

clean:
	rm -rf $(BUILD_DIR)
