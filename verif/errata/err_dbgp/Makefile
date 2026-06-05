# Ventium M6B errata test: err_dbgp — Erratum 79 (erroneous #DB on V86 POPF/IRET
# with a #GP fault).  Builds err_dbgp.bin, a flat 64 KiB -bios image.  Same flow
# as the M7.2 pv86 demonstrator (real->protected + paging + TSS + V86 entry), with
# a #DB gate + an SS:ESP data breakpoint armed so the erratum's erroneous #DB can
# be witnessed.  The erratum self-check (verif/errata/run-m6.sh) runs the RTL
# --system trace BOTH ways (flag ON = the documented defect, OFF = the clean
# result) — there is NO QEMU differential oracle (qemu computes the clean #GP).
CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall

IMG_BYTES := 65536

all: err_dbgp.bin

err_dbgp.o: err_dbgp.S
	$(CC) $(CFLAGS) -c $< -o $@

err_dbgp.elf: err_dbgp.o err_dbgp.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,err_dbgp.ld -Wl,--build-id=none \
	    err_dbgp.o -o err_dbgp.elf

err_dbgp.bin: err_dbgp.elf
	$(OBJCOPY) -O binary err_dbgp.elf err_dbgp.bin
	@truncate -s $(IMG_BYTES) err_dbgp.bin
	@echo "err_dbgp.bin: $$(stat -c%s err_dbgp.bin) bytes (want $(IMG_BYTES))"

clean:
	rm -f err_dbgp.o err_dbgp.elf err_dbgp.bin

.PHONY: all clean
