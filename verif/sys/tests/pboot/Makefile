# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M9 — build the boot-firmware STUB (-bios) + the BOOT SECTOR (disk LBA0).
#
# Outputs:
#   pboot_stub.bin      — a flat 64 KiB -bios image; its reset vector (F000:FFF0)
#                         boots real->protected, reads disk LBA0 via IDE PIO into RAM
#                         0x8000, and far-jmps into it.
#   pboot_dma_stub.bin  — M9b variant: identical boot, but chain-loads the boot sector
#                         with bus-master DMA (single-PRD READ DMA into 0x8000) instead
#                         of PIO, then far-jmps into it. Same pboot.ld layout.
#   pboot_mbr.bin       — exactly 512 bytes (the boot sector), placed at disk LBA0 by
#                         gen_disk.py; ends in the 0x55 0xAA boot signature. SHARED by
#                         both the PIO (M9) and DMA (M9b) stubs.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy (GNU-as syntax).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # the -bios image is exactly 64 KiB (reset vector F000:FFF0)
MBR_BYTES := 512        # one sector

all: pboot_stub.bin pboot_dma_stub.bin pboot_rm_stub.bin pboot_mbr.bin pboot_rm_mbr.bin

pboot_stub.o: pboot_stub.S
	$(CC) $(CFLAGS) -c $< -o $@

pboot_stub.elf: pboot_stub.o pboot.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pboot.ld -Wl,--build-id=none \
	    pboot_stub.o -o pboot_stub.elf

pboot_stub.bin: pboot_stub.elf
	$(OBJCOPY) -O binary pboot_stub.elf pboot_stub.bin
	@truncate -s $(IMG_BYTES) pboot_stub.bin
	@echo "pboot_stub.bin: $$(stat -c%s pboot_stub.bin) bytes (want $(IMG_BYTES))"

# --- M9b: the DMA chain-load firmware (same pboot.ld layout as the PIO stub) -------
pboot_dma_stub.o: pboot_dma_stub.S
	$(CC) $(CFLAGS) -c $< -o $@

pboot_dma_stub.elf: pboot_dma_stub.o pboot.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pboot.ld -Wl,--build-id=none \
	    pboot_dma_stub.o -o pboot_dma_stub.elf

pboot_dma_stub.bin: pboot_dma_stub.elf
	$(OBJCOPY) -O binary pboot_dma_stub.elf pboot_dma_stub.bin
	@truncate -s $(IMG_BYTES) pboot_dma_stub.bin
	@echo "pboot_dma_stub.bin: $$(stat -c%s pboot_dma_stub.bin) bytes (want $(IMG_BYTES))"

# --- M9-rm: the real-mode firmware (stays 16-bit real mode) + its 16-bit boot sector
pboot_rm_stub.o: pboot_rm_stub.S
	$(CC) $(CFLAGS) -c $< -o $@

pboot_rm_stub.elf: pboot_rm_stub.o pboot.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pboot.ld -Wl,--build-id=none \
	    pboot_rm_stub.o -o pboot_rm_stub.elf

pboot_rm_stub.bin: pboot_rm_stub.elf
	$(OBJCOPY) -O binary pboot_rm_stub.elf pboot_rm_stub.bin
	@truncate -s $(IMG_BYTES) pboot_rm_stub.bin
	@echo "pboot_rm_stub.bin: $$(stat -c%s pboot_rm_stub.bin) bytes (want $(IMG_BYTES))"

pboot_rm_mbr.o: pboot_rm_mbr.S
	$(CC) $(CFLAGS) -c $< -o $@

pboot_rm_mbr.elf: pboot_rm_mbr.o pboot_mbr.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pboot_mbr.ld -Wl,--build-id=none \
	    pboot_rm_mbr.o -o pboot_rm_mbr.elf

pboot_rm_mbr.bin: pboot_rm_mbr.elf
	$(OBJCOPY) -O binary pboot_rm_mbr.elf pboot_rm_mbr.bin
	@echo "pboot_rm_mbr.bin: $$(stat -c%s pboot_rm_mbr.bin) bytes (want $(MBR_BYTES))"

pboot_mbr.o: pboot_mbr.S
	$(CC) $(CFLAGS) -c $< -o $@

pboot_mbr.elf: pboot_mbr.o pboot_mbr.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pboot_mbr.ld -Wl,--build-id=none \
	    pboot_mbr.o -o pboot_mbr.elf

pboot_mbr.bin: pboot_mbr.elf
	$(OBJCOPY) -O binary pboot_mbr.elf pboot_mbr.bin
	@echo "pboot_mbr.bin: $$(stat -c%s pboot_mbr.bin) bytes (want $(MBR_BYTES))"

clean:
	rm -f pboot_stub.o pboot_stub.elf pboot_stub.bin \
	      pboot_dma_stub.o pboot_dma_stub.elf pboot_dma_stub.bin \
	      pboot_rm_stub.o pboot_rm_stub.elf pboot_rm_stub.bin \
	      pboot_mbr.o pboot_mbr.elf pboot_mbr.bin \
	      pboot_rm_mbr.o pboot_rm_mbr.elf pboot_rm_mbr.bin

.PHONY: all clean
