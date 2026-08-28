# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 H-03 (+ the H-02 offset-past-limit half) — build the
# bare-metal IRET/RETF error-code + outer-IRET segment-cleanup WITNESS image.
# See piretgp0.S / piretgp0.ld. Same toolchain and image layout as pcpl:
# gcc -m32 + GNU ld + objcopy, a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: piretgp0.bin

piretgp0.o: piretgp0.S
	$(CC) $(CFLAGS) -c $< -o $@

piretgp0.elf: piretgp0.o piretgp0.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,piretgp0.ld -Wl,--build-id=none \
	    piretgp0.o -o piretgp0.elf

piretgp0.bin: piretgp0.elf
	$(OBJCOPY) -O binary piretgp0.elf piretgp0.bin
	@truncate -s $(IMG_BYTES) piretgp0.bin
	@echo "piretgp0.bin: $$(stat -c%s piretgp0.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f piretgp0.o piretgp0.elf piretgp0.bin

.PHONY: all clean
