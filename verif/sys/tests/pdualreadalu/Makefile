# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -DDUALREADALU_PROBE

all: pdualreadalu.bin

pdualreadalu.o: ../pfault/pfault.S
	$(CC) $(CFLAGS) -c $< -o $@

pdualreadalu.elf: pdualreadalu.o ../pfault/pfault.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,../pfault/pfault.ld \
	    -Wl,--build-id=none pdualreadalu.o -o $@

pdualreadalu.bin: pdualreadalu.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s 65536 $@

clean:
	rm -f pdualreadalu.o pdualreadalu.elf pdualreadalu.bin

.PHONY: all clean
