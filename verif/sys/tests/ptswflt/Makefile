# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug4 A4-H09 — build the bare-metal same-privilege partial-
# frame image. See ptswflt.S / ptswflt.ld. Same toolchain and image layout as
# pjmpgate: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: ptswflt.bin

ptswflt.o: ptswflt.S
	$(CC) $(CFLAGS) -c $< -o $@

ptswflt.elf: ptswflt.o ptswflt.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,ptswflt.ld -Wl,--build-id=none \
	    ptswflt.o -o ptswflt.elf

ptswflt.bin: ptswflt.elf
	$(OBJCOPY) -O binary ptswflt.elf ptswflt.bin
	@truncate -s $(IMG_BYTES) ptswflt.bin
	@echo "ptswflt.bin: $$(stat -c%s ptswflt.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f ptswflt.o ptswflt.elf ptswflt.bin

.PHONY: all clean
