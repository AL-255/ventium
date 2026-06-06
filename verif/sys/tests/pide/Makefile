# Ventium M8.2 — build the bare-metal SoC IDE/ATA primary-master PIO image.
#
# Output: pide.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pide.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, then synchronously
# exercises the MC146818 RTC (0x70/0x71 time-invariant regs), port-92 fast-A20
# (0x92), and the 8042 A20 commands (0x60/0x64), plus a cross-device A20-mask
# wraparound test, and exits via isa-debug-exit. NO interrupts: the whole run is
# per-record differentiable under qemu-system single-step (unlike pirqsoc).
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy (GNU-as syntax).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pide.bin

pide.o: pide.S
	$(CC) $(CFLAGS) -c $< -o $@

pide.elf: pide.o pide.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pide.ld -Wl,--build-id=none \
	    pide.o -o pide.elf

pide.bin: pide.elf
	$(OBJCOPY) -O binary pide.elf pide.bin
	@truncate -s $(IMG_BYTES) pide.bin
	@echo "pide.bin: $$(stat -c%s pide.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pide.o pide.elf pide.bin

.PHONY: all clean
