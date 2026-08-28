# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 H-11b — build the bare-metal LTR busy-bit + null-LLDT
# image. See pltr.S / pltr.ld. Same toolchain and image layout as ptask:
# gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pltr.bin

pltr.o: pltr.S
	$(CC) $(CFLAGS) -c $< -o $@

pltr.elf: pltr.o pltr.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pltr.ld -Wl,--build-id=none \
	    pltr.o -o pltr.elf

pltr.bin: pltr.elf
	$(OBJCOPY) -O binary pltr.elf pltr.bin
	@truncate -s $(IMG_BYTES) pltr.bin
	@echo "pltr.bin: $$(stat -c%s pltr.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pltr.o pltr.elf pltr.bin

.PHONY: all clean
