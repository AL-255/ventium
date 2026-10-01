# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Guest assembly ONLY. No RTL, QEMU, or simulator build is reachable.
CC := /usr/bin/gcc
OBJCOPY := /usr/bin/objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
OUTDIR ?= obj_dir_prfcompletion_guest
CASES := 1 2 3 4 5 6 7
.SECONDARY:
.PHONY: all
all: $(addprefix $(OUTDIR)/rf-c,$(addsuffix .bin,$(CASES)))
$(OUTDIR):
	/usr/bin/mkdir -p -- "$@"
$(OUTDIR)/rf-c%.o: prfcompletion.S | $(OUTDIR)
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/rf-c%.elf: $(OUTDIR)/rf-c%.o prfcompletion.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,prfcompletion.ld -Wl,--build-id=none $< -o $@
$(OUTDIR)/rf-c%.bin: $(OUTDIR)/rf-c%.elf
	$(OBJCOPY) -O binary $< $@
	truncate -s 65536 $@
