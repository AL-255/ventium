# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# RDTSC/INVD/WBINVD coverage firmware (-bios image), run under --cosim.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
all: covtsc.bin
covtsc.o: covtsc.S
	$(CC) $(CFLAGS) -c $< -o $@
covtsc.elf: covtsc.o covtsc.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,covtsc.ld -Wl,--build-id=none covtsc.o -o covtsc.elf
covtsc.bin: covtsc.elf
	$(OBJCOPY) -O binary covtsc.elf covtsc.bin
	@truncate -s 65536 covtsc.bin
	@echo "covtsc.bin: $$(stat -c%s covtsc.bin) bytes"
clean:
	rm -f covtsc.o covtsc.elf covtsc.bin
.PHONY: all clean
