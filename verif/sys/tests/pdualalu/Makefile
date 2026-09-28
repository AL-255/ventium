# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall \
           -DDUALREADALU_PROBE -DDUALREADALU_UALU_PROBE

all: pdualalu.bin

pdualalu.o: ../pfault/pfault.S
	$(CC) $(CFLAGS) -c $< -o $@

pdualalu.elf: pdualalu.o ../pfault/pfault.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,../pfault/pfault.ld \
	    -Wl,--build-id=none pdualalu.o -o $@

pdualalu.bin: pdualalu.elf
	$(OBJCOPY) -O binary $< $@
	@truncate -s 65536 $@

clean:
	rm -f pdualalu.o pdualalu.elf pdualalu.bin

.PHONY: all clean
