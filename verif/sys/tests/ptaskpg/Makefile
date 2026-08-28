# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW_Aug3 C-02 — build the PAGED hardware task switch image
# (non-identity mappings, differing LDTs, TI=1 incoming selectors).
# See ptaskpg.S / ptaskpg.ld. Same toolchain/image layout as ptask + ppage.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: ptaskpg.bin

ptaskpg.o: ptaskpg.S
	$(CC) $(CFLAGS) -c $< -o $@

ptaskpg.elf: ptaskpg.o ptaskpg.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,ptaskpg.ld -Wl,--build-id=none \
	    ptaskpg.o -o ptaskpg.elf

ptaskpg.bin: ptaskpg.elf
	$(OBJCOPY) -O binary ptaskpg.elf ptaskpg.bin
	@truncate -s $(IMG_BYTES) ptaskpg.bin
	@echo "ptaskpg.bin: $$(stat -c%s ptaskpg.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f ptaskpg.o ptaskpg.elf ptaskpg.bin

.PHONY: all clean
