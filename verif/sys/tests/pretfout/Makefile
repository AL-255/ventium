# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.1 — build the bare-metal SEGMENTATION-only demonstrator.
#
# Output: pretfout.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pretfout.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, sets up a flat GDT
# (+ one based + one read-only descriptor), does segment-relative loads/stores
# and a couple of benign limit/type cases, then exits via isa-debug-exit.  NO
# paging (that is the M2S.2 pmode test).  See pretfout.S / pretfout.ld for the details.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pretfout.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pretfout.bin

pretfout.o: pretfout.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pretfout.elf: pretfout.o pretfout.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pretfout.ld -Wl,--build-id=none \
	    pretfout.o -o pretfout.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pretfout.bin: pretfout.elf
	$(OBJCOPY) -O binary pretfout.elf pretfout.bin
	@truncate -s $(IMG_BYTES) pretfout.bin
	@echo "pretfout.bin: $$(stat -c%s pretfout.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pretfout.o pretfout.elf pretfout.bin

.PHONY: all clean
