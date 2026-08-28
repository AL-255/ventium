# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug4 A4-H05 — build the descriptor fault PRECEDENCE image.
# See pdescprec.S / pdescprec.ld. Same toolchain and image layout as
# pjmpgate/pselnull: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pdescprec.bin

pdescprec.o: pdescprec.S
	$(CC) $(CFLAGS) -c $< -o $@

pdescprec.elf: pdescprec.o pdescprec.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pdescprec.ld -Wl,--build-id=none \
	    pdescprec.o -o pdescprec.elf

pdescprec.bin: pdescprec.elf
	$(OBJCOPY) -O binary pdescprec.elf pdescprec.bin
	@truncate -s $(IMG_BYTES) pdescprec.bin
	@echo "pdescprec.bin: $$(stat -c%s pdescprec.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pdescprec.o pdescprec.elf pdescprec.bin

.PHONY: all clean
