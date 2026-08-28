# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-C02 — build the bare-metal selector-nullness /
# LDT-entry-0 / error-code-TI image. See pselnull.S / pselnull.ld. Same
# toolchain and image layout as pltr: gcc -m32 + GNU ld + objcopy, a flat
# 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pselnull.bin

pselnull.o: pselnull.S
	$(CC) $(CFLAGS) -c $< -o $@

pselnull.elf: pselnull.o pselnull.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pselnull.ld -Wl,--build-id=none \
	    pselnull.o -o pselnull.elf

pselnull.bin: pselnull.elf
	$(OBJCOPY) -O binary pselnull.elf pselnull.bin
	@truncate -s $(IMG_BYTES) pselnull.bin
	@echo "pselnull.bin: $$(stat -c%s pselnull.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pselnull.o pselnull.elf pselnull.bin

.PHONY: all clean
