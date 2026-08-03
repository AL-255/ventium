# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.1 — build the bare-metal SEGMENTATION-only demonstrator.
#
# Output: pcslim.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pcslim.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, sets up a flat GDT
# (+ one based + one read-only descriptor), does segment-relative loads/stores
# and a couple of benign limit/type cases, then exits via isa-debug-exit.  NO
# paging (that is the M2S.2 pmode test).  See pcslim.S / pcslim.ld for the details.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pcslim.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pcslim.bin

pcslim.o: pcslim.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pcslim.elf: pcslim.o pcslim.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pcslim.ld -Wl,--build-id=none \
	    pcslim.o -o pcslim.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pcslim.bin: pcslim.elf
	$(OBJCOPY) -O binary pcslim.elf pcslim.bin
	@truncate -s $(IMG_BYTES) pcslim.bin
	@echo "pcslim.bin: $$(stat -c%s pcslim.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pcslim.o pcslim.elf pcslim.bin

.PHONY: all clean
