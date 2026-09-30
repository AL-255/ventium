CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
# Require an explicit scratch destination. The gate never writes generated
# images into this source directory or uses the canonical model build.
ifndef OUTDIR
$(error Set OUTDIR to a unique /tmp artifact directory)
endif
CASE ?= 1
IMAGE := $(OUTDIR)/pv86movrestart_$(CASE)

all: $(IMAGE).bin

$(IMAGE).o: pv86movrestart.S
	$(CC) $(CFLAGS) -DCASE=$(CASE) -c $< -o $@

$(IMAGE).elf: $(IMAGE).o ../pv86/pv86.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,../pv86/pv86.ld -Wl,--build-id=none $< -o $@

$(IMAGE).bin: $(IMAGE).elf
	$(OBJCOPY) -O binary $< $@
	truncate -s 65536 $@

.PHONY: all
