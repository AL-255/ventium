# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium task #102 — build the data-store-under-paging micro-TLB regression
# image (pdtlbw.bin), a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pdtlbw.bin
# or run directly on the Verilator TB in --system mode.  Self-checking via
# isa-debug-exit: status 133 on PASS, 67 on FAIL.  See pdtlbw.S / pdtlbw.ld.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536

all: pdtlbw.bin

pdtlbw.o: pdtlbw.S
	$(CC) $(CFLAGS) -c $< -o $@

pdtlbw.elf: pdtlbw.o pdtlbw.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pdtlbw.ld -Wl,--build-id=none \
	    pdtlbw.o -o pdtlbw.elf

pdtlbw.bin: pdtlbw.elf
	$(OBJCOPY) -O binary pdtlbw.elf pdtlbw.bin
	@truncate -s $(IMG_BYTES) pdtlbw.bin
	@echo "pdtlbw.bin: $$(stat -c%s pdtlbw.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pdtlbw.o pdtlbw.elf pdtlbw.bin

.PHONY: all clean
