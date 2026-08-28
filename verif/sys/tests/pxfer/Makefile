# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-C01 — build the bare-metal far-transfer privilege/
# type validation image. See pxfer.S / pxfer.ld. Same toolchain and image
# layout as pjmpgate: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxfer.bin

pxfer.o: pxfer.S
	$(CC) $(CFLAGS) -c $< -o $@

pxfer.elf: pxfer.o pxfer.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxfer.ld -Wl,--build-id=none \
	    pxfer.o -o pxfer.elf

pxfer.bin: pxfer.elf
	$(OBJCOPY) -O binary pxfer.elf pxfer.bin
	@truncate -s $(IMG_BYTES) pxfer.bin
	@echo "pxfer.bin: $$(stat -c%s pxfer.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxfer.o pxfer.elf pxfer.bin

.PHONY: all clean
