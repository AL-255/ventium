# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Build only; this target does not launch a DUT or QEMU.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
CASES := 1 2 3 4 5 6 7 8
IMAGES := $(addprefix pbitmem-c,$(addsuffix .bin,$(CASES)))

all: $(IMAGES)

pbitmem-c%.o: pbitmem.S
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@

pbitmem-c%.elf: pbitmem-c%.o pbitmem.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,pbitmem.ld -Wl,--build-id=none $< -o $@

pbitmem-c%.bin: pbitmem-c%.elf
	$(OBJCOPY) -O binary $< $@

.PHONY: all
