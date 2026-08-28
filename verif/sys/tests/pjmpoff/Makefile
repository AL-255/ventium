# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug4 A4-C02 — build the bare-metal far-transfer target-
# offset-vs-limit image. See pjmpoff.S / pjmpoff.ld. Same toolchain and image
# layout as pjmpgate: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pjmpoff.bin

pjmpoff.o: pjmpoff.S
	$(CC) $(CFLAGS) -c $< -o $@

pjmpoff.elf: pjmpoff.o pjmpoff.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pjmpoff.ld -Wl,--build-id=none \
	    pjmpoff.o -o pjmpoff.elf

pjmpoff.bin: pjmpoff.elf
	$(OBJCOPY) -O binary pjmpoff.elf pjmpoff.bin
	@truncate -s $(IMG_BYTES) pjmpoff.bin
	@echo "pjmpoff.bin: $$(stat -c%s pjmpoff.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pjmpoff.o pjmpoff.elf pjmpoff.bin

.PHONY: all clean
