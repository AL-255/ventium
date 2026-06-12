# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psocrmexc.bin
psocrmexc.o: psocrmexc.S
	$(CC) $(CFLAGS) -c $< -o $@
psocrmexc.elf: psocrmexc.o psocrmexc.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocrmexc.ld -Wl,--build-id=none psocrmexc.o -o psocrmexc.elf
psocrmexc.bin: psocrmexc.elf
	$(OBJCOPY) -O binary psocrmexc.elf psocrmexc.bin
	@truncate -s $(IMG_BYTES) psocrmexc.bin
	@echo "psocrmexc.bin: $$(stat -c%s psocrmexc.bin) bytes"
clean:
	rm -f psocrmexc.o psocrmexc.elf psocrmexc.bin
.PHONY: all clean
