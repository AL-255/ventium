# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# fxabort — build the fxprog driver image for the fragment-engine abort/reset
# testbench (tb_fxabort.sv). Same toolchain and image layout as pxc04:
# gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536

all: fxprog.bin

fxprog.o: fxprog.S
	$(CC) $(CFLAGS) -c $< -o $@

fxprog.elf: fxprog.o fxprog.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,fxprog.ld -Wl,--build-id=none \
	    fxprog.o -o fxprog.elf

fxprog.bin: fxprog.elf
	$(OBJCOPY) -O binary fxprog.elf fxprog.bin
	@truncate -s $(IMG_BYTES) fxprog.bin
	@echo "fxprog.bin: $$(stat -c%s fxprog.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f fxprog.o fxprog.elf fxprog.bin

.PHONY: all clean
