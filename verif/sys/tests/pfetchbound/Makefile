# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC ?= gcc
OBJCOPY ?= objcopy
OUTDIR ?= .
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
CASES := 1 2 3 4 5 6 7
all: $(foreach case,$(CASES),$(OUTDIR)/pfetchbound_$(case).bin)
$(OUTDIR):
	mkdir -p "$@"
$(OUTDIR)/pfetchbound_%.o: pfetchbound.S | $(OUTDIR)
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/pfetchbound_%.elf: $(OUTDIR)/pfetchbound_%.o pfetchbound.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pfetchbound.ld -Wl,--build-id=none -o $@ $<
$(OUTDIR)/pfetchbound_%.bin: $(OUTDIR)/pfetchbound_%.elf
	$(OBJCOPY) -O binary $< $@
	truncate -s 65536 $@
.SECONDARY:
.PHONY: all
