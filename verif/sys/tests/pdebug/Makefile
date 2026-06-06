# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.6 — build the bare-metal DEBUG-REGISTER / #DB demonstrator.
#
# Output: pdebug.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pdebug.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.3
# pfault bootstrap, NO paging), stands up an IDT with a #DB trap gate at vector 1
# (db_handler), and exercises the M2S.6 debug machinery: MOV DRn<->GPR round-trips
# (always differential), the TF single-step #DB (differential), and the DR0/DR1
# hardware breakpoints (structural — the gdbstub single-step path suppresses them).
# Exits via isa-debug-exit.  See pdebug.S / pdebug.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pdebug.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pdebug.bin

pdebug.o: pdebug.S
	$(CC) $(CFLAGS) -c $< -o $@

pdebug.elf: pdebug.o pdebug.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pdebug.ld -Wl,--build-id=none \
	    pdebug.o -o pdebug.elf

pdebug.bin: pdebug.elf
	$(OBJCOPY) -O binary pdebug.elf pdebug.bin
	@truncate -s $(IMG_BYTES) pdebug.bin
	@echo "pdebug.bin: $$(stat -c%s pdebug.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pdebug.o pdebug.elf pdebug.bin

.PHONY: all clean
