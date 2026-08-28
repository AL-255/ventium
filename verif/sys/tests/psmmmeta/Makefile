# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Build the psmmmeta bare-metal image: the SMM/RSM hidden-metadata restore
# regression (seg_pm_loaded[] / seg_b[] / ss_b must come back with their
# PRE-SMI values, not the SMM handler's). WITNESS-graded -- no differential
# golden is possible (the qemu gdbstub single-step path masks SMI and has no
# SMM awareness -- see manifest.json). gcc -m32 + GNU ld + objcopy, flat
# 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psmmmeta.bin

psmmmeta.o: psmmmeta.S
	$(CC) $(CFLAGS) -c $< -o $@

psmmmeta.elf: psmmmeta.o psmmmeta.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psmmmeta.ld -Wl,--build-id=none \
	    psmmmeta.o -o psmmmeta.elf

psmmmeta.bin: psmmmeta.elf
	$(OBJCOPY) -O binary psmmmeta.elf psmmmeta.bin
	@truncate -s $(IMG_BYTES) psmmmeta.bin
	@echo "psmmmeta.bin: $$(stat -c%s psmmmeta.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psmmmeta.o psmmmeta.elf psmmmeta.bin

.PHONY: all clean
