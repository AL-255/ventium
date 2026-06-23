# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.0 — build the bare-metal protected-mode + paging demonstrator.
#
# Output: psocpmretf.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios psocpmretf.bin
# whose reset vector (F000:FFF0) bootstraps real->protected->paging and exits via
# isa-debug-exit.  See psocpmretf.S for the flow and psocpmretf.ld for the memory layout.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside psocpmretf.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psocpmretf.bin

psocpmretf.o: psocpmretf.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
psocpmretf.elf: psocpmretf.o psocpmretf.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocpmretf.ld -Wl,--build-id=none \
	    psocpmretf.o -o psocpmretf.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
psocpmretf.bin: psocpmretf.elf
	$(OBJCOPY) -O binary psocpmretf.elf psocpmretf.bin
	@truncate -s $(IMG_BYTES) psocpmretf.bin
	@echo "psocpmretf.bin: $$(stat -c%s psocpmretf.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psocpmretf.o psocpmretf.elf psocpmretf.bin

.PHONY: all clean
