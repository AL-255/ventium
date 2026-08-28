# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-C04 — build the bare-metal cross-privilege
# frame-extent-probe WITNESS image. See pcg16.S / pcg16.ld. Same toolchain
# and image layout as piretgp0: gcc -m32 + GNU ld + objcopy, a flat 64 KiB
# -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pcg16.bin

pcg16.o: pcg16.S
	$(CC) $(CFLAGS) -c $< -o $@

pcg16.elf: pcg16.o pcg16.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pcg16.ld -Wl,--build-id=none \
	    pcg16.o -o pcg16.elf

pcg16.bin: pcg16.elf
	$(OBJCOPY) -O binary pcg16.elf pcg16.bin
	@truncate -s $(IMG_BYTES) pcg16.bin
	@echo "pcg16.bin: $$(stat -c%s pcg16.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pcg16.o pcg16.elf pcg16.bin

.PHONY: all clean
