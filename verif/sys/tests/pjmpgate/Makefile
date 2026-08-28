# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 C-04 — build the bare-metal far-CALL-to-TSS (NESTING
# task switch) image. See pjmpgate.S / pjmpgate.ld. Same toolchain and image
# layout as ptask: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pjmpgate.bin

pjmpgate.o: pjmpgate.S
	$(CC) $(CFLAGS) -c $< -o $@

pjmpgate.elf: pjmpgate.o pjmpgate.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pjmpgate.ld -Wl,--build-id=none \
	    pjmpgate.o -o pjmpgate.elf

pjmpgate.bin: pjmpgate.elf
	$(OBJCOPY) -O binary pjmpgate.elf pjmpgate.bin
	@truncate -s $(IMG_BYTES) pjmpgate.bin
	@echo "pjmpgate.bin: $$(stat -c%s pjmpgate.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pjmpgate.o pjmpgate.elf pjmpgate.bin

.PHONY: all clean
