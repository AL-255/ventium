# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall -Wa,--fatal-warnings
CASES ?= 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
OUTDIR ?=
ifeq ($(strip $(OUTDIR)),)
$(error Set OUTDIR to a fresh absolute root-filesystem artifact leaf)
endif
IMAGES := $(addprefix $(OUTDIR)/ppopespea-c,$(addsuffix .bin,$(CASES)))
.SECONDARY:
all: validate-output $(IMAGES)
validate-output:
	test "$(OUTDIR)" = "$$(realpath -m '$(OUTDIR)')"
	test ! -e '$(OUTDIR)' && test ! -L '$(OUTDIR)'
	test -d "$$(dirname '$(OUTDIR)')"
	test "$$(stat -c%u "$$(dirname '$(OUTDIR)')")" = "$$(id -u)"
	mkdir -m 700 '$(OUTDIR)'
$(OUTDIR)/ppopespea-c%.o: ppopespea.S ppopespea_corners.S | validate-output
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
$(OUTDIR)/ppopespea-c%.elf: $(OUTDIR)/ppopespea-c%.o ppopespea.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,ppopespea.ld -Wl,--build-id=none $< -o $@
$(OUTDIR)/ppopespea-c%.bin: $(OUTDIR)/ppopespea-c%.elf
	$(OBJCOPY) -O binary $< $@
	test "$$(stat -c%s '$@')" = 65536
.PHONY: all validate-output
