# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — build the bare-metal HARDWARE-TASK-SWITCH-INTO-V86 demonstrator.
#
# Output: ptaskv86.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios ptaskv86.bin
# whose reset vector (F000:FFF0) bootstraps real->protected, builds two 32-bit
# available-TSS descriptors (sel 0x60 = current TASK-A, sel 0x70 = a V86 incoming
# task with EFLAGS.VM=1 and real-mode-paragraph segments), LTRs TASK-A, then
# `ljmp $0x70` performs the HARDWARE TASK SWITCH into the V86 task.  The V86 task
# runs `mov es,0x2593; mov al,[es:0]` (the exact instruction class that faults in
# the DOS-Quake #DE) and exits via INT 0x20 -> #GP -> the CPL0 monitor ->
# isa-debug-exit.  See ptaskv86.S / ptaskv86.ld.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside ptaskv86.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: ptaskv86.bin

ptaskv86.o: ptaskv86.S
	$(CC) $(CFLAGS) -c $< -o $@

ptaskv86.elf: ptaskv86.o ptaskv86.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,ptaskv86.ld -Wl,--build-id=none \
	    ptaskv86.o -o ptaskv86.elf

ptaskv86.bin: ptaskv86.elf
	$(OBJCOPY) -O binary ptaskv86.elf ptaskv86.bin
	@truncate -s $(IMG_BYTES) ptaskv86.bin
	@echo "ptaskv86.bin: $$(stat -c%s ptaskv86.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f ptaskv86.o ptaskv86.elf ptaskv86.bin

.PHONY: all clean
