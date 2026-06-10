# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.8 — build the bare-metal 8237 DMA controller image.
#
# Output: psoc8237b.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios psoc8237b.bin
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

all: psoc8237b.bin

psoc8237b.o: psoc8237b.S
	$(CC) $(CFLAGS) -c $< -o $@

psoc8237b.elf: psoc8237b.o psoc8237b.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psoc8237b.ld -Wl,--build-id=none \
	    psoc8237b.o -o psoc8237b.elf

psoc8237b.bin: psoc8237b.elf
	$(OBJCOPY) -O binary psoc8237b.elf psoc8237b.bin
	@truncate -s $(IMG_BYTES) psoc8237b.bin
	@echo "psoc8237b.bin: $$(stat -c%s psoc8237b.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psoc8237b.o psoc8237b.elf psoc8237b.bin

.PHONY: all clean
