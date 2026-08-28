# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug4 A4-H06 — build the bare-metal same-privilege partial-
# frame image. See psamepf.S / psamepf.ld. Same toolchain and image layout as
# pjmpgate: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psamepf.bin

psamepf.o: psamepf.S
	$(CC) $(CFLAGS) -c $< -o $@

psamepf.elf: psamepf.o psamepf.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psamepf.ld -Wl,--build-id=none \
	    psamepf.o -o psamepf.elf

psamepf.bin: psamepf.elf
	$(OBJCOPY) -O binary psamepf.elf psamepf.bin
	@truncate -s $(IMG_BYTES) psamepf.bin
	@echo "psamepf.bin: $$(stat -c%s psamepf.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psamepf.o psamepf.elf psamepf.bin

.PHONY: all clean
