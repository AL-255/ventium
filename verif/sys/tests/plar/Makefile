# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

all: plar.bin

plar.o: plar.S
	$(CC) $(CFLAGS) -c $< -o $@

plar.elf: plar.o plar.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,plar.ld \
	    -Wl,--build-id=none plar.o -o $@

plar.bin: plar.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s 65536 $@

clean:
	rm -f plar.o plar.elf plar.bin

.PHONY: all clean
