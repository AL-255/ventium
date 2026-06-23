# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — build the paged store->load RAW regression-guard image.
#
# Output: psldram.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios psldram.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, enables a
# non-identity paging map, runs the back-to-back store -> same-address RMW-load
# sequence through the fresh paged page, and exits via isa-debug-exit. NO
# interrupts: the whole run is per-record differentiable under qemu-system
# single-step.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psldram.bin

psldram.o: psldram.S
	$(CC) $(CFLAGS) -c $< -o $@

psldram.elf: psldram.o psldram.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psldram.ld -Wl,--build-id=none \
	    psldram.o -o psldram.elf

psldram.bin: psldram.elf
	$(OBJCOPY) -O binary psldram.elf psldram.bin
	@truncate -s $(IMG_BYTES) psldram.bin
	@echo "psldram.bin: $$(stat -c%s psldram.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psldram.o psldram.elf psldram.bin

.PHONY: all clean
