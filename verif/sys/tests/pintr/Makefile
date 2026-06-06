# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.3 — build the bare-metal SOFTWARE-INTERRUPT demonstrator.
#
# Output: pintr.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pintr.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.1
# pseg bootstrap), stands up an IDT with 32-bit interrupt-/trap-gate descriptors,
# fires INT n / INT3 / INTO into handlers that record markers and IRET, then
# exits via isa-debug-exit.  NO paging (the M2S.3 software-interrupt gate; the
# hardware-fault delivery is exercised by the sibling pfault test).  See
# pintr.S / pintr.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pintr.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pintr.bin

pintr.o: pintr.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pintr.elf: pintr.o pintr.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pintr.ld -Wl,--build-id=none \
	    pintr.o -o pintr.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pintr.bin: pintr.elf
	$(OBJCOPY) -O binary pintr.elf pintr.bin
	@truncate -s $(IMG_BYTES) pintr.bin
	@echo "pintr.bin: $$(stat -c%s pintr.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pintr.o pintr.elf pintr.bin

.PHONY: all clean
