# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M9.5 — build the real-mode far CALL / RETF firmware (-bios image).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # the -bios image is exactly 64 KiB (reset vector F000:FFF0)

all: psocfarcall.bin

psocfarcall.o: psocfarcall.S
	$(CC) $(CFLAGS) -c $< -o $@

psocfarcall.elf: psocfarcall.o psocfarcall.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocfarcall.ld -Wl,--build-id=none \
	    psocfarcall.o -o psocfarcall.elf

psocfarcall.bin: psocfarcall.elf
	$(OBJCOPY) -O binary psocfarcall.elf psocfarcall.bin
	@truncate -s $(IMG_BYTES) psocfarcall.bin
	@echo "psocfarcall.bin: $$(stat -c%s psocfarcall.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psocfarcall.o psocfarcall.elf psocfarcall.bin

.PHONY: all clean
