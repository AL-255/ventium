# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psocsregmem.bin
psocsregmem.o: psocsregmem.S
	$(CC) $(CFLAGS) -c $< -o $@
psocsregmem.elf: psocsregmem.o psocsregmem.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocsregmem.ld -Wl,--build-id=none psocsregmem.o -o psocsregmem.elf
psocsregmem.bin: psocsregmem.elf
	$(OBJCOPY) -O binary psocsregmem.elf psocsregmem.bin
	@truncate -s $(IMG_BYTES) psocsregmem.bin
	@echo "psocsregmem.bin: $$(stat -c%s psocsregmem.bin) bytes"
clean:
	rm -f psocsregmem.o psocsregmem.elf psocsregmem.bin
.PHONY: all clean
