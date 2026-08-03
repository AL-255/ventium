# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.3 — build the bare-metal HARDWARE-FAULT demonstrator.
#
# Output: pxc04i.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pxc04i.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING (reusing the
# M2S.2 ppage bootstrap), stands up an IDT with #PF / #GP / #UD interrupt gates,
# deliberately triggers each hardware fault (a not-present page; a selector past
# the GDT limit; UD2) so the M2S.1/.2 fault DECISIONS now DELIVER through the IDT,
# and exits via isa-debug-exit.  See pxc04i.S / pxc04i.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pxc04i.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxc04i.bin

pxc04i.o: pxc04i.S
	$(CC) $(CFLAGS) -c $< -o $@

pxc04i.elf: pxc04i.o pxc04i.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxc04i.ld -Wl,--build-id=none \
	    pxc04i.o -o pxc04i.elf

pxc04i.bin: pxc04i.elf
	$(OBJCOPY) -O binary pxc04i.elf pxc04i.bin
	@truncate -s $(IMG_BYTES) pxc04i.bin
	@echo "pxc04i.bin: $$(stat -c%s pxc04i.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxc04i.o pxc04i.elf pxc04i.bin

.PHONY: all clean
