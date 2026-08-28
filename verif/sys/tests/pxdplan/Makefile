# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.3 — build the bare-metal HARDWARE-FAULT demonstrator.
#
# Output: pxdplan.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pxdplan.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING (reusing the
# M2S.2 ppage bootstrap), stands up an IDT with #PF / #GP / #UD interrupt gates,
# deliberately triggers each hardware fault (a not-present page; a selector past
# the GDT limit; UD2) so the M2S.1/.2 fault DECISIONS now DELIVER through the IDT,
# and exits via isa-debug-exit.  See pxdplan.S / pxdplan.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pxdplan.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxdplan.bin

pxdplan.o: pxdplan.S
	$(CC) $(CFLAGS) -c $< -o $@

pxdplan.elf: pxdplan.o pxdplan.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxdplan.ld -Wl,--build-id=none \
	    pxdplan.o -o pxdplan.elf

pxdplan.bin: pxdplan.elf
	$(OBJCOPY) -O binary pxdplan.elf pxdplan.bin
	@truncate -s $(IMG_BYTES) pxdplan.bin
	@echo "pxdplan.bin: $$(stat -c%s pxdplan.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxdplan.o pxdplan.elf pxdplan.bin

.PHONY: all clean
