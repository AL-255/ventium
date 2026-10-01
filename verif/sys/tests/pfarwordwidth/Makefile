# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HOST ASSEMBLY ONLY. OUTDIR must be an explicit nonsymlink workspace leaf.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -Wa,--fatal-warnings
CASES ?= $(shell seq 1 32)
OUTDIR ?=
ifeq ($(strip $(OUTDIR)),)
$(error Set OUTDIR to a fresh absolute root-filesystem artifact leaf)
endif
IMAGES := $(addprefix $(OUTDIR)/pfarwordwidth-c,$(addsuffix .bin,$(CASES)))
.SECONDARY:
all: $(IMAGES)
$(OUTDIR):
	test "$(OUTDIR)" = "$$(realpath -m '$(OUTDIR)')"
	test "$(OUTDIR)" != "$$(pwd)"
	mkdir -m 700 '$(OUTDIR)'
$(OUTDIR)/pfarwordwidth-c%.o: pfarwordwidth.S | $(OUTDIR)
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/pfarwordwidth-c%.elf: $(OUTDIR)/pfarwordwidth-c%.o pfarwordwidth.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,pfarwordwidth.ld -Wl,--build-id=none $< -o $@
$(OUTDIR)/pfarwordwidth-c%.bin: $(OUTDIR)/pfarwordwidth-c%.elf
	$(OBJCOPY) -O binary $< $@
	test "$$(stat -c%s '$@')" = 65536
check-host: all
	PYTHONDONTWRITEBYTECODE=1 PFARWORDWIDTH_IMAGES='$(OUTDIR)' python3 -B -m unittest -v test_check_witness.py
.PHONY: all check-host
