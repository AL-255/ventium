# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.4 — build the bare-metal CROSS-PRIVILEGE (TSS / stack-switch)
# demonstrator.
#
# Output: pstk16.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pstk16.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.1
# pseg bootstrap), stands up a GDT with CPL0 + CPL3 segments + a TSS, loads TR
# (LTR), builds an IDT with two DPL=3 interrupt gates targeting CPL0 handlers,
# transfers DOWN to a CPL3 user task (inter-priv IRET), fires INT 0x80 from CPL3
# (cross-privilege delivery: stack switch to TSS.SS0:ESP0 + the 5-word frame +
# CPL0 handler + inter-priv IRET back to CPL3), then traps to CPL0 via INT 0x40
# to perform the isa-debug-exit.  NO paging (the M2S.4 cross-privilege gate).
# See pstk16.S / pstk16.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pstk16.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pstk16.bin

pstk16.o: pstk16.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pstk16.elf: pstk16.o pstk16.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pstk16.ld -Wl,--build-id=none \
	    pstk16.o -o pstk16.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pstk16.bin: pstk16.elf
	$(OBJCOPY) -O binary pstk16.elf pstk16.bin
	@truncate -s $(IMG_BYTES) pstk16.bin
	@echo "pstk16.bin: $$(stat -c%s pstk16.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pstk16.o pstk16.elf pstk16.bin

.PHONY: all clean
