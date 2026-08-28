# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# REVIEW1_Aug3 R2-H07 — build the decoded-extent instruction-fetch limit test.
#
# Output: pfetchlim.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pfetchlim.bin
# (QEMU is NOT the oracle here -- its translator checks only the instruction's
# start address, so the straddling cases execute there. This is a self-checked
# witness gate for the +define+VEN_SEG_ENFORCE build; see pfetchlim.S.)
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pfetchlim.bin

pfetchlim.o: pfetchlim.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pfetchlim.elf: pfetchlim.o pfetchlim.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pfetchlim.ld -Wl,--build-id=none \
	    pfetchlim.o -o pfetchlim.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pfetchlim.bin: pfetchlim.elf
	$(OBJCOPY) -O binary pfetchlim.elf pfetchlim.bin
	@truncate -s $(IMG_BYTES) pfetchlim.bin
	@echo "pfetchlim.bin: $$(stat -c%s pfetchlim.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pfetchlim.o pfetchlim.elf pfetchlim.bin

.PHONY: all clean
