# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# pfpstore is the FP store-precision derivative of pfault.  It compiles the
# common protected-mode/paging bootstrap with FPSTORE_PROBE so the destination
# page is present/read-only, then performs FISTP m32 on it.

CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -DFPSTORE_PROBE

all: pfpstore.bin

pfpstore.o: ../pfault/pfault.S
	$(CC) $(CFLAGS) -c $< -o $@

pfpstore.elf: pfpstore.o ../pfault/pfault.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,../pfault/pfault.ld \
	    -Wl,--build-id=none pfpstore.o -o $@

pfpstore.bin: pfpstore.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s 65536 $@
	@echo "pfpstore.bin: $$(stat -c%s $@) bytes (want 65536)"

clean:
	rm -f pfpstore.o pfpstore.elf pfpstore.bin

.PHONY: all clean
