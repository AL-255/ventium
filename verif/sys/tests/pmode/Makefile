# Ventium M2S.0 — build the bare-metal protected-mode + paging demonstrator.
#
# Output: pmode.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pmode.bin
# whose reset vector (F000:FFF0) bootstraps real->protected->paging and exits via
# isa-debug-exit.  See pmode.S for the flow and pmode.ld for the memory layout.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pmode.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pmode.bin

pmode.o: pmode.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
pmode.elf: pmode.o pmode.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pmode.ld -Wl,--build-id=none \
	    pmode.o -o pmode.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
pmode.bin: pmode.elf
	$(OBJCOPY) -O binary pmode.elf pmode.bin
	@truncate -s $(IMG_BYTES) pmode.bin
	@echo "pmode.bin: $$(stat -c%s pmode.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pmode.o pmode.elf pmode.bin

.PHONY: all clean
