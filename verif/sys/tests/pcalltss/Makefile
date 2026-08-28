# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 C-04 — build the bare-metal far-CALL-to-TSS (NESTING
# task switch) image. See pcalltss.S / pcalltss.ld. Same toolchain and image
# layout as ptask: gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pcalltss.bin

pcalltss.o: pcalltss.S
	$(CC) $(CFLAGS) -c $< -o $@

pcalltss.elf: pcalltss.o pcalltss.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pcalltss.ld -Wl,--build-id=none \
	    pcalltss.o -o pcalltss.elf

pcalltss.bin: pcalltss.elf
	$(OBJCOPY) -O binary pcalltss.elf pcalltss.bin
	@truncate -s $(IMG_BYTES) pcalltss.bin
	@echo "pcalltss.bin: $$(stat -c%s pcalltss.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pcalltss.o pcalltss.elf pcalltss.bin

.PHONY: all clean
