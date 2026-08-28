# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 M-01 — build the bare-metal I/O-bitmap-wrap image.
# See piopermwrap.S / piopermwrap.ld. Same toolchain and image layout as
# pioperm: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: piopermwrap.bin

piopermwrap.o: piopermwrap.S
	$(CC) $(CFLAGS) -c $< -o $@

piopermwrap.elf: piopermwrap.o piopermwrap.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,piopermwrap.ld -Wl,--build-id=none \
	    piopermwrap.o -o piopermwrap.elf

piopermwrap.bin: piopermwrap.elf
	$(OBJCOPY) -O binary piopermwrap.elf piopermwrap.bin
	@truncate -s $(IMG_BYTES) piopermwrap.bin
	@echo "piopermwrap.bin: $$(stat -c%s piopermwrap.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f piopermwrap.o piopermwrap.elf piopermwrap.bin

.PHONY: all clean
