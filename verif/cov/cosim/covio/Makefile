# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# RDTSC/INVD/WBINVD coverage firmware (-bios image), run under --cosim.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
all: covio.bin
covio.o: covio.S
	$(CC) $(CFLAGS) -c $< -o $@
covio.elf: covio.o covio.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,covio.ld -Wl,--build-id=none covio.o -o covio.elf
covio.bin: covio.elf
	$(OBJCOPY) -O binary covio.elf covio.bin
	@truncate -s 65536 covio.bin
	@echo "covio.bin: $$(stat -c%s covio.bin) bytes"
clean:
	rm -f covio.o covio.elf covio.bin
.PHONY: all clean
