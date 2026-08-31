# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# pfaststore reuses pfault's complete protected-mode/paging bootstrap, but puts
# a present/read-only PTE below an ordinary MOV r/m32,r32. It is intentionally
# separate from pfpstore: x87 command precision is not evidence that the
# integer S_PIPE store producer preserves a restartable #PF.

CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -DFASTSTORE_PROBE

all: pfaststore.bin

pfaststore.o: ../pfault/pfault.S

	$(CC) $(CFLAGS) -c $< -o $@

pfaststore.elf: pfaststore.o ../pfault/pfault.ld

	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,../pfault/pfault.ld \
	    -Wl,--build-id=none pfaststore.o -o $@

pfaststore.bin: pfaststore.elf

	$(OBJCOPY) -O binary $< $@
	@truncate -s 65536 $@
	@echo "pfaststore.bin: $$(stat -c%s $@) bytes (want 65536)"

clean:

	rm -f pfaststore.o pfaststore.elf pfaststore.bin

.PHONY: all clean
