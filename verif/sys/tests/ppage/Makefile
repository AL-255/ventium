# Ventium M2S.2 — build the bare-metal 2-level PAGING demonstrator.
#
# Output: ppage.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios ppage.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.1
# pseg bootstrap), builds a 2-level page directory + page tables with a
# NON-IDENTITY mapping (linear != physical), sets CR3, sets CR0.PG, then does
# loads/stores through the mapped linear addresses (plus distinct-permission
# read-only / supervisor pages), and exits via isa-debug-exit.  4 KiB pages (the
# core M2S.2 path; PSE 4 MiB pages are a deferred corner).  See ppage.S / ppage.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside ppage.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: ppage.bin

ppage.o: ppage.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
ppage.elf: ppage.o ppage.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,ppage.ld -Wl,--build-id=none \
	    ppage.o -o ppage.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
ppage.bin: ppage.elf
	$(OBJCOPY) -O binary ppage.elf ppage.bin
	@truncate -s $(IMG_BYTES) ppage.bin
	@echo "ppage.bin: $$(stat -c%s ppage.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f ppage.o ppage.elf ppage.bin

.PHONY: all clean
