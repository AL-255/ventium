# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 H-02 — build the bare-metal protected-RETF
# restartability + 16-bit outer-ESP image. See pretfres.S / pretfres.ld.
# Same toolchain and image layout as ptask: gcc -m32 + GNU ld + objcopy,
# a flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pretfres.bin

pretfres.o: pretfres.S
	$(CC) $(CFLAGS) -c $< -o $@

pretfres.elf: pretfres.o pretfres.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pretfres.ld -Wl,--build-id=none \
	    pretfres.o -o pretfres.elf

pretfres.bin: pretfres.elf
	$(OBJCOPY) -O binary pretfres.elf pretfres.bin
	@truncate -s $(IMG_BYTES) pretfres.bin
	@echo "pretfres.bin: $$(stat -c%s pretfres.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pretfres.o pretfres.elf pretfres.bin

.PHONY: all clean
