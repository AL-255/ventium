# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536

all: psysfpreloc.bin

psysfpreloc.o: psysfpreloc.S
	$(CC) $(CFLAGS) -c $< -o $@

psysfpreloc.elf: psysfpreloc.o psysfpreloc.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psysfpreloc.ld -Wl,--build-id=none \
	    psysfpreloc.o -o $@

psysfpreloc.bin: psysfpreloc.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s $(IMG_BYTES) $@
	@echo "$@: $$(stat -c%s $@) bytes (want $(IMG_BYTES))"

clean:
	rm -f psysfpreloc.o psysfpreloc.elf psysfpreloc.bin

.PHONY: all clean
