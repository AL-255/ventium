# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# HOST BUILD ONLY. No DUT/QEMU launch and no canonical-model rebuild.
CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
CASES := 1 2 3 4 5 6 7
IMAGES := $(addprefix pverrw-c,$(addsuffix .bin,$(CASES)))
.SECONDARY:
all: $(IMAGES)
pverrw-c%.o: pverrw.S
	$(CC) $(CFLAGS) -DCASE=$* -c $< -o $@
pverrw-c%.elf: pverrw-c%.o pverrw.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,pverrw.ld -Wl,--build-id=none $< -o $@
pverrw-c%.bin: pverrw-c%.elf
	$(OBJCOPY) -O binary $< $@
check-host: all
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_build_contract.py
.PHONY: all check-host
