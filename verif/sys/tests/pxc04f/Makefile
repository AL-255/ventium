# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.3 — build the bare-metal HARDWARE-FAULT demonstrator.
#
# Output: pxc04f.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pxc04f.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING (reusing the
# M2S.2 ppage bootstrap), stands up an IDT with #PF / #GP / #UD interrupt gates,
# deliberately triggers each hardware fault (a not-present page; a selector past
# the GDT limit; UD2) so the M2S.1/.2 fault DECISIONS now DELIVER through the IDT,
# and exits via isa-debug-exit.  See pxc04f.S / pxc04f.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pxc04f.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxc04f.bin

pxc04f.o: pxc04f.S
	$(CC) $(CFLAGS) -c $< -o $@

pxc04f.elf: pxc04f.o pxc04f.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxc04f.ld -Wl,--build-id=none \
	    pxc04f.o -o pxc04f.elf

pxc04f.bin: pxc04f.elf
	$(OBJCOPY) -O binary pxc04f.elf pxc04f.bin
	@truncate -s $(IMG_BYTES) pxc04f.bin
	@echo "pxc04f.bin: $$(stat -c%s pxc04f.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxc04f.o pxc04f.elf pxc04f.bin

.PHONY: all clean
