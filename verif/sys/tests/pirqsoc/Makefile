# Ventium M8.1 — build the bare-metal ON-DIE TIMER IRQ (PIC+PIT->IRQ0) image.
#
# Output: pirqsoc.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios pirqsoc.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, builds an IDT with
# one IRQ0 interrupt gate (vector 0x20), remaps + programs the 8259 PIC, programs
# the 8254 PIT ch0 (mode 2), enables IRQs, spins until the IRQ0 handler has
# counted N deliveries (each EOIed), masks IRQ0, reads back the PIC ISR/IMR,
# computes a deterministic result, and exits via isa-debug-exit.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy (GNU-as syntax).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: pirqsoc.bin

pirqsoc.o: pirqsoc.S
	$(CC) $(CFLAGS) -c $< -o $@

pirqsoc.elf: pirqsoc.o pirqsoc.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,pirqsoc.ld -Wl,--build-id=none \
	    pirqsoc.o -o pirqsoc.elf

pirqsoc.bin: pirqsoc.elf
	$(OBJCOPY) -O binary pirqsoc.elf pirqsoc.bin
	@truncate -s $(IMG_BYTES) pirqsoc.bin
	@echo "pirqsoc.bin: $$(stat -c%s pirqsoc.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f pirqsoc.o pirqsoc.elf pirqsoc.bin

.PHONY: all clean
