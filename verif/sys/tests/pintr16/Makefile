# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — build the bare-metal 16-bit-PM INT/IRETW demonstrator (pintr16).
# Output: pintr16.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pintr16.bin
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536

all: pintr16.bin

pintr16.o: pintr16.S
	$(CC) $(CFLAGS) -c $< -o $@

pintr16.elf: pintr16.o pintr16.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pintr16.ld -Wl,--build-id=none \
	    pintr16.o -o pintr16.elf

pintr16.bin: pintr16.elf
	$(OBJCOPY) -O binary pintr16.elf pintr16.bin
	@truncate -s $(IMG_BYTES) pintr16.bin
	@echo "pintr16.bin: $$(stat -c%s pintr16.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pintr16.o pintr16.elf pintr16.bin

.PHONY: all clean
