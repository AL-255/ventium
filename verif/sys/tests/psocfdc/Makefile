# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.9 — build the bare-metal floppy disk controller image.
#
# Output: psocfdc.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios psocfdc.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, then synchronously
# exercises the MC146818 RTC (0x70/0x71 time-invariant regs), port-92 fast-A20
# (0x92), and the 8042 A20 commands (0x60/0x64), plus a cross-device A20-mask
# wraparound test, and exits via isa-debug-exit. NO interrupts: the whole run is
# per-record differentiable under qemu-system single-step (unlike pirqsoc).
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy (GNU-as syntax).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psocfdc.bin

psocfdc.o: psocfdc.S
	$(CC) $(CFLAGS) -c $< -o $@

psocfdc.elf: psocfdc.o psocfdc.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocfdc.ld -Wl,--build-id=none \
	    psocfdc.o -o psocfdc.elf

psocfdc.bin: psocfdc.elf
	$(OBJCOPY) -O binary psocfdc.elf psocfdc.bin
	@truncate -s $(IMG_BYTES) psocfdc.bin
	@echo "psocfdc.bin: $$(stat -c%s psocfdc.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psocfdc.o psocfdc.elf psocfdc.bin

.PHONY: all clean
