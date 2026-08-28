# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug4 A4-H03 — build the bare-metal 16-bit-PM interrupt-frame
# image. See pint16f.S / pint16f.ld. Same toolchain and image layout as
# pintr16/pjmpgate: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pint16f.bin

pint16f.o: pint16f.S
	$(CC) $(CFLAGS) -c $< -o $@

pint16f.elf: pint16f.o pint16f.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pint16f.ld -Wl,--build-id=none \
	    pint16f.o -o pint16f.elf

pint16f.bin: pint16f.elf
	$(OBJCOPY) -O binary pint16f.elf pint16f.bin
	@truncate -s $(IMG_BYTES) pint16f.bin
	@echo "pint16f.bin: $$(stat -c%s pint16f.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pint16f.o pint16f.elf pint16f.bin

.PHONY: all clean
