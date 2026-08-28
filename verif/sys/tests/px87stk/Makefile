# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium REVIEW1_Aug3 R2-H06 / REVIEW_Aug4 A4-H01 — build the bare-metal x87
# stack-fault matrix images. See px87stk.S / px87stk2.S / px87stk.ld. Same
# toolchain and image layout as pselnull: gcc -m32 + GNU ld + objcopy, a flat
# 64 KiB -bios image. px87stk2 shares px87stk.ld (identical generic layout).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: px87stk.bin px87stk2.bin px87stk3.bin

px87stk.o: px87stk.S
	$(CC) $(CFLAGS) -c $< -o $@

px87stk.elf: px87stk.o px87stk.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,px87stk.ld -Wl,--build-id=none \
	    px87stk.o -o px87stk.elf

px87stk.bin: px87stk.elf
	$(OBJCOPY) -O binary px87stk.elf px87stk.bin
	@truncate -s $(IMG_BYTES) px87stk.bin
	@echo "px87stk.bin: $$(stat -c%s px87stk.bin) bytes (want $(IMG_BYTES))"

# The variant-only cases (transcendental fixed-ST1 + deferred divide/sqrt) --
# run on obj_dir_x87stk_tr
px87stk2.o: px87stk2.S
	$(CC) $(CFLAGS) -c $< -o $@

px87stk2.elf: px87stk2.o px87stk.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,px87stk.ld -Wl,--build-id=none \
	    px87stk2.o -o px87stk2.elf

px87stk2.bin: px87stk2.elf
	$(OBJCOPY) -O binary px87stk2.elf px87stk2.bin
	@truncate -s $(IMG_BYTES) px87stk2.bin
	@echo "px87stk2.bin: $$(stat -c%s px87stk2.bin) bytes (want $(IMG_BYTES))"

# The full narrowing-store stack-fault matrix (every decoded store form x
# {masked,unmasked}) -- run on the canonical build and on the obj_dir_x87stk_bcd
# / obj_dir_x87stk_psall variants
px87stk3.o: px87stk3.S
	$(CC) $(CFLAGS) -c $< -o $@

px87stk3.elf: px87stk3.o px87stk.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,px87stk.ld -Wl,--build-id=none \
	    px87stk3.o -o px87stk3.elf

px87stk3.bin: px87stk3.elf
	$(OBJCOPY) -O binary px87stk3.elf px87stk3.bin
	@truncate -s $(IMG_BYTES) px87stk3.bin
	@echo "px87stk3.bin: $$(stat -c%s px87stk3.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f px87stk.o px87stk.elf px87stk.bin px87stk2.o px87stk2.elf px87stk2.bin \
	      px87stk3.o px87stk3.elf px87stk3.bin

.PHONY: all clean
