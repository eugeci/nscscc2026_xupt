CROSS_COMPILE ?= loongarch32r-linux-gnusf-
ENTRY ?= 0xa07b06e0
BOOTPARAM_ENV ?= 0xa4f00040
BOOTARGS ?= console=ttyS0,115200 rdinit=/bin/sh print-fatal-signals=1 -- -i

CC := $(CROSS_COMPILE)gcc
READELF := $(CROSS_COMPILE)readelf
OBJDUMP := $(CROSS_COMPILE)objdump
ELF := obj/linux_handoff_trampoline.elf

.PHONY: all clean inspect
all: $(ELF)

$(ELF): start.S link.lds Makefile
	mkdir -p obj
	$(CC) -nostdlib -nostartfiles -static \
		-Wl,--build-id=none,-s,-z,max-page-size=4096 \
		-DLINUX_ENTRY=$(ENTRY) -DBOOTPARAM_ENV=$(BOOTPARAM_ENV) \
		-DLINUX_BOOTARGS='"$(BOOTARGS)"' -T link.lds -o $@ start.S

inspect: $(ELF)
	$(READELF) -h -l $(ELF)
	$(OBJDUMP) -d $(ELF)

clean:
	rm -f $(ELF)
