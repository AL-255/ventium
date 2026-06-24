# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.3 — build the bare-metal SOFTWARE-INTERRUPT demonstrator.
#
# Output: psoftvga.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios psoftvga.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.1
# pseg bootstrap), stands up an IDT with 32-bit interrupt-/trap-gate descriptors,
# fires INT n / INT3 / INTO into handlers that record markers and IRET, then
# exits via isa-debug-exit.  NO paging (the M2S.3 software-interrupt gate; the
# hardware-fault delivery is exercised by the sibling pfault test).  See
# psoftvga.S / psoftvga.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside psoftvga.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psoftvga.bin

psoftvga.o: psoftvga.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
psoftvga.elf: psoftvga.o psoftvga.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psoftvga.ld -Wl,--build-id=none \
	    psoftvga.o -o psoftvga.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
psoftvga.bin: psoftvga.elf
	$(OBJCOPY) -O binary psoftvga.elf psoftvga.bin
	@truncate -s $(IMG_BYTES) psoftvga.bin
	@echo "psoftvga.bin: $$(stat -c%s psoftvga.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psoftvga.o psoftvga.elf psoftvga.bin

.PHONY: all clean
