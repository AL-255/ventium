# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Page-protected, independently translated U/V store microbenchmark.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -DDUALSTORE_PROBE

all: pdualstore.bin

pdualstore.o: ../pfault/pfault.S
	$(CC) $(CFLAGS) -c $< -o $@

pdualstore.elf: pdualstore.o ../pfault/pfault.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,../pfault/pfault.ld \
	    -Wl,--build-id=none pdualstore.o -o $@

pdualstore.bin: pdualstore.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s 65536 $@
	@echo "pdualstore.bin: $$(stat -c%s $@) bytes (want 65536)"

clean:
	rm -f pdualstore.o pdualstore.elf pdualstore.bin

.PHONY: all clean
