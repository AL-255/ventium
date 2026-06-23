# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — build the bare-metal POPF EFLAGS-mask demonstrator (ppopf).
# Output: ppopf.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios ppopf.bin
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536

all: ppopf.bin

ppopf.o: ppopf.S
	$(CC) $(CFLAGS) -c $< -o $@

ppopf.elf: ppopf.o ppopf.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,ppopf.ld -Wl,--build-id=none \
	    ppopf.o -o ppopf.elf

ppopf.bin: ppopf.elf
	$(OBJCOPY) -O binary ppopf.elf ppopf.bin
	@truncate -s $(IMG_BYTES) ppopf.bin
	@echo "ppopf.bin: $$(stat -c%s ppopf.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f ppopf.o ppopf.elf ppopf.bin

.PHONY: all clean
