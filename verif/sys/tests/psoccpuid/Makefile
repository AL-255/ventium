# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M9.5 — build the CPUID real-mode firmware (-bios image).
#   psoccpuid.bin — a flat 64 KiB -bios image; its reset vector (F000:FFF0) enters
#   16-bit real mode and executes CPUID for four leaves, then isa-debug-exits.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # the -bios image is exactly 64 KiB (reset vector F000:FFF0)

all: psoccpuid.bin

psoccpuid.o: psoccpuid.S
	$(CC) $(CFLAGS) -c $< -o $@

psoccpuid.elf: psoccpuid.o psoccpuid.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psoccpuid.ld -Wl,--build-id=none \
	    psoccpuid.o -o psoccpuid.elf

psoccpuid.bin: psoccpuid.elf
	$(OBJCOPY) -O binary psoccpuid.elf psoccpuid.bin
	@truncate -s $(IMG_BYTES) psoccpuid.bin
	@echo "psoccpuid.bin: $$(stat -c%s psoccpuid.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psoccpuid.o psoccpuid.elf psoccpuid.bin

.PHONY: all clean
