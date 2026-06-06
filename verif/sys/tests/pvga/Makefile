# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M8.2 — build the bare-metal SoC VGA register-file image.
#
# Output: pvga.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pvga.bin
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

all: pvga.bin

pvga.o: pvga.S
	$(CC) $(CFLAGS) -c $< -o $@

pvga.elf: pvga.o pvga.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pvga.ld -Wl,--build-id=none \
	    pvga.o -o pvga.elf

pvga.bin: pvga.elf
	$(OBJCOPY) -O binary pvga.elf pvga.bin
	@truncate -s $(IMG_BYTES) pvga.bin
	@echo "pvga.bin: $$(stat -c%s pvga.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pvga.o pvga.elf pvga.bin

.PHONY: all clean
