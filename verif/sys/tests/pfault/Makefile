# Ventium M2S.3 — build the bare-metal HARDWARE-FAULT demonstrator.
#
# Output: pfault.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pfault.bin
# whose reset vector (F000:FFF0) bootstraps real->protected + PAGING (reusing the
# M2S.2 ppage bootstrap), stands up an IDT with #PF / #GP / #UD interrupt gates,
# deliberately triggers each hardware fault (a not-present page; a selector past
# the GDT limit; UD2) so the M2S.1/.2 fault DECISIONS now DELIVER through the IDT,
# and exits via isa-debug-exit.  See pfault.S / pfault.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside pfault.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pfault.bin

pfault.o: pfault.S
	$(CC) $(CFLAGS) -c $< -o $@

pfault.elf: pfault.o pfault.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pfault.ld -Wl,--build-id=none \
	    pfault.o -o pfault.elf

pfault.bin: pfault.elf
	$(OBJCOPY) -O binary pfault.elf pfault.bin
	@truncate -s $(IMG_BYTES) pfault.bin
	@echo "pfault.bin: $$(stat -c%s pfault.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pfault.o pfault.elf pfault.bin

.PHONY: all clean
