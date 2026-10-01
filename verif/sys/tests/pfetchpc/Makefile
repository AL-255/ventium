# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC ?= gcc
OBJCOPY ?= objcopy
OUTDIR ?= .
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

all: $(OUTDIR)/pfetchpc.bin
$(OUTDIR):
	mkdir -p "$@"
$(OUTDIR)/pfetchpc.o: pfetchpc.S | $(OUTDIR)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUTDIR)/pfetchpc.elf: $(OUTDIR)/pfetchpc.o pfetchpc.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pfetchpc.ld -Wl,--build-id=none -o $@ $<
$(OUTDIR)/pfetchpc.bin: $(OUTDIR)/pfetchpc.elf
	$(OBJCOPY) -O binary $< $@
	truncate -s 65536 $@
.PHONY: all
