# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 C-04 — build the bare-metal far-CALL-to-TSS (NESTING
# task switch) image. See pretfoutpg.S / pretfoutpg.ld. Same toolchain and image
# layout as ptask: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pretfoutpg.bin

pretfoutpg.o: pretfoutpg.S
	$(CC) $(CFLAGS) -c $< -o $@

pretfoutpg.elf: pretfoutpg.o pretfoutpg.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pretfoutpg.ld -Wl,--build-id=none \
	    pretfoutpg.o -o pretfoutpg.elf

pretfoutpg.bin: pretfoutpg.elf
	$(OBJCOPY) -O binary pretfoutpg.elf pretfoutpg.bin
	@truncate -s $(IMG_BYTES) pretfoutpg.bin
	@echo "pretfoutpg.bin: $$(stat -c%s pretfoutpg.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pretfoutpg.o pretfoutpg.elf pretfoutpg.bin

.PHONY: all clean
