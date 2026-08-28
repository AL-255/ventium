# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-C04 — build the bare-metal cross-privilege
# frame-extent-probe WITNESS image. See pcgparam.S / pcgparam.ld. Same toolchain
# and image layout as piretgp0: gcc -m32 + GNU ld + objcopy, a flat 64 KiB
# -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pcgparam.bin

pcgparam.o: pcgparam.S
	$(CC) $(CFLAGS) -c $< -o $@

pcgparam.elf: pcgparam.o pcgparam.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pcgparam.ld -Wl,--build-id=none \
	    pcgparam.o -o pcgparam.elf

pcgparam.bin: pcgparam.elf
	$(OBJCOPY) -O binary pcgparam.elf pcgparam.bin
	@truncate -s $(IMG_BYTES) pcgparam.bin
	@echo "pcgparam.bin: $$(stat -c%s pcgparam.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pcgparam.o pcgparam.elf pcgparam.bin

.PHONY: all clean
