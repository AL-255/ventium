# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Build the pintslim bare-metal image: the cross-privilege interrupt-frame
# stack-limit regression (S_INT_PROBE's segment-extent check must use the
# slot's own width). Graded per build: canonical (all 16 cases deliver) vs
# +VEN_SEG_ENFORCE (8 at-bound deliver, 8 one-past #SS pre-commit) -- see
# manifest.json and verif/sys/run-pintslim-gate.sh. gcc -m32 + GNU ld +
# objcopy, flat 64 KiB -bios image.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pintslim.bin

pintslim.o: pintslim.S
	$(CC) $(CFLAGS) -c $< -o $@

pintslim.elf: pintslim.o pintslim.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pintslim.ld -Wl,--build-id=none \
	    pintslim.o -o pintslim.elf

pintslim.bin: pintslim.elf
	$(OBJCOPY) -O binary pintslim.elf pintslim.bin
	@truncate -s $(IMG_BYTES) pintslim.bin
	@echo "pintslim.bin: $$(stat -c%s pintslim.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pintslim.o pintslim.elf pintslim.bin

.PHONY: all clean
