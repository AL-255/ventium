# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug4 A4-C01 — build the page-walk Dirty-intent gate image.
#
# Output: pxwalkd.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pxwalkd.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING (+CR4.PSE),
# stands up an IDT with a #PF gate, and exercises the four walk_set_dirty
# cases (clean-leaf probe completion 4 KiB / probe-does-not-dirty-on-fault /
# 4 MiB leaf / W/R=1 on the probe permission fault) before exiting via
# isa-debug-exit.  See pxwalkd.S / pxwalkd.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm
# needed (GNU-as syntax inside pxwalkd.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxwalkd.bin

pxwalkd.o: pxwalkd.S
	$(CC) $(CFLAGS) -c $< -o $@

pxwalkd.elf: pxwalkd.o pxwalkd.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxwalkd.ld -Wl,--build-id=none \
	    pxwalkd.o -o pxwalkd.elf

pxwalkd.bin: pxwalkd.elf
	$(OBJCOPY) -O binary pxwalkd.elf pxwalkd.bin
	@truncate -s $(IMG_BYTES) pxwalkd.bin
	@echo "pxwalkd.bin: $$(stat -c%s pxwalkd.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxwalkd.o pxwalkd.elf pxwalkd.bin

.PHONY: all clean
