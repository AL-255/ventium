# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HOST ASSEMBLY ONLY. An explicit fresh nonsymlink output leaf is mandatory.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -Wa,--fatal-warnings
CASES ?= 1 2 3 4 5 6 7 8
OUTDIR ?=
ifeq ($(strip $(OUTDIR)),)
$(error Set OUTDIR to a fresh absolute root-filesystem artifact leaf)
endif
IMAGES := $(addprefix $(OUTDIR)/pintstackwrap-c,$(addsuffix .bin,$(CASES)))
.SECONDARY:
all: $(IMAGES)
validate-out:
	test "$(OUTDIR)" = "$$(realpath -m '$(OUTDIR)')"
	test "$(OUTDIR)" != "$$(pwd)"
	test ! -e '$(OUTDIR)' && test ! -L '$(OUTDIR)'
$(OUTDIR): validate-out
	mkdir -m 700 '$(OUTDIR)'
$(OUTDIR)/pintstackwrap-c%.o: pintstackwrap.S | $(OUTDIR)
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/pintstackwrap-c%.elf: $(OUTDIR)/pintstackwrap-c%.o pintstackwrap.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,pintstackwrap.ld -Wl,--build-id=none $< -o $@
$(OUTDIR)/pintstackwrap-c%.bin: $(OUTDIR)/pintstackwrap-c%.elf
	$(OBJCOPY) -O binary $< $@
	test "$$(stat -c%s '$@')" = 65536
check-host: all
	PYTHONDONTWRITEBYTECODE=1 PINTSTACKWRAP_IMAGES='$(OUTDIR)' python3 -B -m unittest -v test_check_witness.py
.PHONY: all check-host validate-out
