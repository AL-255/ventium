# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.3 — build the bare-metal HARDWARE-FAULT demonstrator.
#
# Output: pxfrag.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pxfrag.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING (reusing the
# M2S.2 ppage bootstrap), stands up an IDT with #PF / #GP / #UD interrupt gates,
# deliberately triggers each hardware fault (a not-present page; a selector past
# the GDT limit; UD2) so the M2S.1/.2 fault DECISIONS now DELIVER through the IDT,
# and exits via isa-debug-exit.  See pxfrag.S / pxfrag.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pxfrag.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxfrag.bin

pxfrag.o: pxfrag.S
	$(CC) $(CFLAGS) -c $< -o $@

pxfrag.elf: pxfrag.o pxfrag.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxfrag.ld -Wl,--build-id=none \
	    pxfrag.o -o pxfrag.elf

pxfrag.bin: pxfrag.elf
	$(OBJCOPY) -O binary pxfrag.elf pxfrag.bin
	@truncate -s $(IMG_BYTES) pxfrag.bin
	@echo "pxfrag.bin: $$(stat -c%s pxfrag.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxfrag.o pxfrag.elf pxfrag.bin

.PHONY: all clean
