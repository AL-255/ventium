# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psoclseg.bin
psoclseg.o: psoclseg.S
	$(CC) $(CFLAGS) -c $< -o $@
psoclseg.elf: psoclseg.o psoclseg.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psoclseg.ld -Wl,--build-id=none psoclseg.o -o psoclseg.elf
psoclseg.bin: psoclseg.elf
	$(OBJCOPY) -O binary psoclseg.elf psoclseg.bin
	@truncate -s $(IMG_BYTES) psoclseg.bin
	@echo "psoclseg.bin: $$(stat -c%s psoclseg.bin) bytes"
clean:
	rm -f psoclseg.o psoclseg.elf psoclseg.bin
.PHONY: all clean
