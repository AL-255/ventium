# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-C04 — build the bare-metal cross-privilege
# frame-extent-probe WITNESS image. See pcgpg.S / pcgpg.ld. Same toolchain
# and image layout as piretgp0: gcc -m32 + GNU ld + objcopy, a flat 64 KiB
# -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pcgpg.bin

pcgpg.o: pcgpg.S
	$(CC) $(CFLAGS) -c $< -o $@

pcgpg.elf: pcgpg.o pcgpg.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pcgpg.ld -Wl,--build-id=none \
	    pcgpg.o -o pcgpg.elf

pcgpg.bin: pcgpg.elf
	$(OBJCOPY) -O binary pcgpg.elf pcgpg.bin
	@truncate -s $(IMG_BYTES) pcgpg.bin
	@echo "pcgpg.bin: $$(stat -c%s pcgpg.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pcgpg.o pcgpg.elf pcgpg.bin

.PHONY: all clean
