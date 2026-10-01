# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HOST ASSEMBLY ONLY; never writes generated files into this source directory.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -Wa,--fatal-warnings
CASES ?= 1 2 3 4
OUTDIR ?=
ifeq ($(strip $(OUTDIR)),)
$(error Set OUTDIR to a fresh absolute root-filesystem artifact leaf)
endif
IMAGES := $(addprefix $(OUTDIR)/ppopwatch-c,$(addsuffix .bin,$(CASES)))
.SECONDARY:
all: validate-output $(IMAGES)
validate-output:
	test "$(OUTDIR)" = "$$(realpath -m '$(OUTDIR)')"
	test "$(OUTDIR)" != "$$(pwd)"
	test ! -e '$(OUTDIR)' && test ! -L '$(OUTDIR)'
	test -d "$$(dirname '$(OUTDIR)')"
	test "$$(stat -c%u "$$(dirname '$(OUTDIR)')")" = "$$(id -u)"
	mkdir -m 700 '$(OUTDIR)'
$(OUTDIR)/ppopwatch-c%.o: ppopwatch.S | validate-output
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/ppopwatch-c%.elf: $(OUTDIR)/ppopwatch-c%.o ppopwatch.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,ppopwatch.ld -Wl,--build-id=none $< -o $@
$(OUTDIR)/ppopwatch-c%.bin: $(OUTDIR)/ppopwatch-c%.elf
	$(OBJCOPY) -O binary $< $@
	test "$$(stat -c%s '$@')" = 65536
.PHONY: all validate-output
