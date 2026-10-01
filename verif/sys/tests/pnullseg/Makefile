# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Build only: no DUT/QEMU launched and no canonical model rebuilt.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

all: pnullseg.bin

pnullseg.o: pnullseg.S
	$(CC) $(CFLAGS) -c $< -o $@

pnullseg.elf: pnullseg.o pnullseg.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,pnullseg.ld -Wl,--build-id=none $< -o $@

pnullseg.bin: pnullseg.elf
	$(OBJCOPY) -O binary $< $@

.PHONY: all
