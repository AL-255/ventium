# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug4 R1-H02 — build the prsmflush bare-metal images.
#   prsmflush.bin      cases B (TLB remap) + C (A20 edge) -- DIFFERENTIAL
#   prsmflush_smm.bin  case A (SMM/RSM scenario) -- witness-graded (no golden
#                      is possible: the qemu gdbstub single-step path masks
#                      SMI and has no SMM awareness -- see manifest.json)
# Both share prsmflush.ld. gcc -m32 + GNU ld + objcopy, flat 64 KiB -bios.
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: prsmflush.bin prsmflush_smm.bin

prsmflush.o: prsmflush.S
	$(CC) $(CFLAGS) -c $< -o $@

prsmflush.elf: prsmflush.o prsmflush.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,prsmflush.ld -Wl,--build-id=none \
	    prsmflush.o -o prsmflush.elf

prsmflush.bin: prsmflush.elf
	$(OBJCOPY) -O binary prsmflush.elf prsmflush.bin
	@truncate -s $(IMG_BYTES) prsmflush.bin
	@echo "prsmflush.bin: $$(stat -c%s prsmflush.bin) bytes (want $(IMG_BYTES))"

prsmflush_smm.o: prsmflush_smm.S
	$(CC) $(CFLAGS) -c $< -o $@

prsmflush_smm.elf: prsmflush_smm.o prsmflush.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,prsmflush.ld -Wl,--build-id=none \
	    prsmflush_smm.o -o prsmflush_smm.elf

prsmflush_smm.bin: prsmflush_smm.elf
	$(OBJCOPY) -O binary prsmflush_smm.elf prsmflush_smm.bin
	@truncate -s $(IMG_BYTES) prsmflush_smm.bin
	@echo "prsmflush_smm.bin: $$(stat -c%s prsmflush_smm.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f prsmflush.o prsmflush.elf prsmflush.bin \
	      prsmflush_smm.o prsmflush_smm.elf prsmflush_smm.bin

.PHONY: all clean
