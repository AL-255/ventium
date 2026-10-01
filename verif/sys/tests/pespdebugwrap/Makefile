# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HOST ASSEMBLY ONLY. Validate freshness even when image targets already exist.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -Wa,--fatal-warnings
CASES ?= 1 2
OUTDIR ?=
ifeq ($(strip $(OUTDIR)),)
$(error Set OUTDIR to a fresh absolute root-filesystem artifact leaf)
endif
IMAGES := $(addprefix $(OUTDIR)/pespdebugwrap-c,$(addsuffix .bin,$(CASES)))
.SECONDARY:
all: validate-output $(IMAGES)
validate-output:
	test "$(OUTDIR)" = "$$(realpath -m '$(OUTDIR)')"
	test "$(OUTDIR)" != "$$(pwd)"
	test ! -e '$(OUTDIR)' && test ! -L '$(OUTDIR)'
	test -d "$$(dirname '$(OUTDIR)')"
	test "$$(stat -c%u "$$(dirname '$(OUTDIR)')")" = "$$(id -u)"
	mkdir -m 700 '$(OUTDIR)'
$(OUTDIR)/pespdebugwrap-c%.o: pespdebugwrap.S | validate-output
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/pespdebugwrap-c%.elf: $(OUTDIR)/pespdebugwrap-c%.o pespdebugwrap.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,pespdebugwrap.ld -Wl,--build-id=none $< -o $@
$(OUTDIR)/pespdebugwrap-c%.bin: $(OUTDIR)/pespdebugwrap-c%.elf
	$(OBJCOPY) -O binary $< $@
	test "$$(stat -c%s '$@')" = 65536
check-host: all
	PYTHONDONTWRITEBYTECODE=1 PESPDEBUGWRAP_IMAGES='$(OUTDIR)' python3 -B -m unittest -v test_check_witness.py
.PHONY: all check-host validate-output
