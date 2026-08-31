# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536

all: psysfpload.bin

psysfpload.o: psysfpload.S
	$(CC) $(CFLAGS) -c $< -o $@

psysfpload.elf: psysfpload.o psysfpload.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psysfpload.ld -Wl,--build-id=none \
	    psysfpload.o -o $@

psysfpload.bin: psysfpload.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s $(IMG_BYTES) $@
	@echo "$@: $$(stat -c%s $@) bytes (want $(IMG_BYTES))"

clean:
	rm -f psysfpload.o psysfpload.elf psysfpload.bin

.PHONY: all clean
