# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M7.2 — build the bare-metal VIRTUAL-8086 (V86) demonstrator.
#
# Output: pv86.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pv86.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING + a TSS, then
# ENTERS virtual-8086 mode by IRET-ing with EFLAGS.VM=1 into a 16-bit V86 task.
# The V86 task runs sel<<4 segmentation and executes IOPL-sensitive ops (CLI/STI/
# PUSHF/POPF/INT n) which, at IOPL<3, #GP to the CPL0 monitor (method-1 / VME-OFF);
# the monitor records each event, emulates/advances it, and IRETs back into V86.
# Exits via isa-debug-exit.  See pv86.S / pv86.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pv86.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pv86.bin

pv86.o: pv86.S
	$(CC) $(CFLAGS) -c $< -o $@

pv86.elf: pv86.o pv86.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pv86.ld -Wl,--build-id=none \
	    pv86.o -o pv86.elf

pv86.bin: pv86.elf
	$(OBJCOPY) -O binary pv86.elf pv86.bin
	@truncate -s $(IMG_BYTES) pv86.bin
	@echo "pv86.bin: $$(stat -c%s pv86.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pv86.o pv86.elf pv86.bin

.PHONY: all clean
