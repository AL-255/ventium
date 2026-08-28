# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-C04 — build the bare-metal cross-privilege
# frame-extent-probe WITNESS image. See pxprobe.S / pxprobe.ld. Same toolchain
# and image layout as piretgp0: gcc -m32 + GNU ld + objcopy, a flat 64 KiB
# -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pxprobe.bin

pxprobe.o: pxprobe.S
	$(CC) $(CFLAGS) -c $< -o $@

pxprobe.elf: pxprobe.o pxprobe.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pxprobe.ld -Wl,--build-id=none \
	    pxprobe.o -o pxprobe.elf

pxprobe.bin: pxprobe.elf
	$(OBJCOPY) -O binary pxprobe.elf pxprobe.bin
	@truncate -s $(IMG_BYTES) pxprobe.bin
	@echo "pxprobe.bin: $$(stat -c%s pxprobe.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pxprobe.o pxprobe.elf pxprobe.bin

.PHONY: all clean
