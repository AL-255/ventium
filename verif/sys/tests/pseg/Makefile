# Ventium M2S.1 — build the bare-metal SEGMENTATION-only demonstrator.
#
# Output: pseg.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pseg.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, sets up a flat GDT
# (+ one based + one read-only descriptor), does segment-relative loads/stores
# and a couple of benign limit/type cases, then exits via isa-debug-exit.  NO
# paging (that is the M2S.2 pmode test).  See pseg.S / pseg.ld for the details.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pseg.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pseg.bin

pseg.o: pseg.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pseg.elf: pseg.o pseg.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pseg.ld -Wl,--build-id=none \
	    pseg.o -o pseg.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pseg.bin: pseg.elf
	$(OBJCOPY) -O binary pseg.elf pseg.bin
	@truncate -s $(IMG_BYTES) pseg.bin
	@echo "pseg.bin: $$(stat -c%s pseg.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pseg.o pseg.elf pseg.bin

.PHONY: all clean
