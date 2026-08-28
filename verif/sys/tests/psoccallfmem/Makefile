# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Build the psoccallfmem bare-metal image: the memory-indirect far CALL
# (FF /3) mode-split regression -- real/V86 far pointers carry a segment
# VALUE (base = sel<<4, no descriptor table), protected selectors keep the
# bounded + descriptor-probed route. Fully differential vs the QEMU golden
# (see manifest.json). gcc -m32 + GNU ld + objcopy, flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psoccallfmem.bin

psoccallfmem.o: psoccallfmem.S
	$(CC) $(CFLAGS) -c $< -o $@

psoccallfmem.elf: psoccallfmem.o psoccallfmem.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psoccallfmem.ld -Wl,--build-id=none \
	    psoccallfmem.o -o psoccallfmem.elf

psoccallfmem.bin: psoccallfmem.elf
	$(OBJCOPY) -O binary psoccallfmem.elf psoccallfmem.bin
	@truncate -s $(IMG_BYTES) psoccallfmem.bin
	@echo "psoccallfmem.bin: $$(stat -c%s psoccallfmem.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psoccallfmem.o psoccallfmem.elf psoccallfmem.bin

.PHONY: all clean
