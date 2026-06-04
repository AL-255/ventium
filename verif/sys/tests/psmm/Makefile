# Ventium M2S.5 — build the bare-metal SMM / RSM demonstrator.
#
# Output: psmm.bin, a flat 64 KiB image loadable with
#   qemu-system-i386 -bios psmm.bin
# whose reset vector (F000:FFF0) bootstraps real->protected (reusing the M2S.1
# pseg bootstrap), installs an SMM handler at SMBASE+0x8000 (0x38000), enables
# the local APIC and fires a self-IPI with delivery mode = SMI; FREE-RUNNING the
# SMM handler writes a sentinel + RSMs and the mainline resumes, then exits via
# isa-debug-exit.  NO paging.  See psmm.S / psmm.ld.
#
# PARTIAL ORACLE: there is NO psmm.sys.vtrace.golden — the qemu-system gdbstub
# single-step path masks SMI (SSTEP_NOIRQ masks CPU_INTERRUPT_SMI) and has no SMM
# awareness, so the differential golden is infeasible and is NOT fabricated.  The
# image is the STRUCTURAL self-check artifact (run free; proven by post-run
# physical-memory readback). See README.md for the full de-risk findings.
#
# Toolchain: a 32-bit-capable gcc (gcc -m32) + GNU ld + objcopy.  No nasm needed
# (GNU-as syntax inside psmm.S).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536      # exactly 64 KiB (a -bios image's reset vector is F000:FFF0)

all: psmm.bin

psmm.o: psmm.S
	$(CC) $(CFLAGS) -c $< -o $@

# Link with our script; -no-pie/-static keep it flat. The ELF is intermediate.
psmm.elf: psmm.o psmm.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psmm.ld -Wl,--build-id=none \
	    psmm.o -o psmm.elf

# Flatten to a raw binary and pad to exactly 64 KiB so the reset stub lands at
# image offset 0xFFF0 (= linear F:FFF0).
psmm.bin: psmm.elf
	$(OBJCOPY) -O binary psmm.elf psmm.bin
	@truncate -s $(IMG_BYTES) psmm.bin
	@echo "psmm.bin: $$(stat -c%s psmm.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f psmm.o psmm.elf psmm.bin

.PHONY: all clean
