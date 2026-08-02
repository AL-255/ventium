# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.4 — build the bare-metal CROSS-PRIVILEGE (TSS / stack-switch)
# demonstrator.
#
# Output: ppriv.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios ppriv.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.1
# pseg bootstrap), stands up a GDT with CPL0 + CPL3 segments + a TSS, loads TR
# (LTR), builds an IDT with two DPL=3 interrupt gates targeting CPL0 handlers,
# transfers DOWN to a CPL3 user task (inter-priv IRET), fires INT 0x80 from CPL3
# (cross-privilege delivery: stack switch to TSS.SS0:ESP0 + the 5-word frame +
# CPL0 handler + inter-priv IRET back to CPL3), then traps to CPL0 via INT 0x40
# to perform the isa-debug-exit.  NO paging (the M2S.4 cross-privilege gate).
# See ppriv.S / ppriv.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside ppriv.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: ppriv.bin

ppriv.o: ppriv.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
ppriv.elf: ppriv.o ppriv.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,ppriv.ld -Wl,--build-id=none \
	    ppriv.o -o ppriv.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
ppriv.bin: ppriv.elf
	$(OBJCOPY) -O binary ppriv.elf ppriv.bin
	@truncate -s $(IMG_BYTES) ppriv.bin
	@echo "ppriv.bin: $$(stat -c%s ppriv.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f ppriv.o ppriv.elf ppriv.bin

.PHONY: all clean
