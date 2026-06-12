# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — build the real-mode far-indirect CALL/JMP (FF /3, FF /5) firmware (-bios image).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # the -bios image is exactly 64 KiB (reset vector F000:FFF0)

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
