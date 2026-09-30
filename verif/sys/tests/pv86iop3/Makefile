CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
ifndef OUTDIR
$(error Set OUTDIR to a unique artifact directory)
endif
CASE ?= 1
IMAGE := $(OUTDIR)/pv86iop3_$(CASE)
all: $(IMAGE).bin
$(IMAGE).o: pv86iop3.S
	$(CC) $(CFLAGS) -DCASE=$(CASE) -c $< -o $@
$(IMAGE).elf: $(IMAGE).o ../pv86/pv86.ld
	$(CC) $(CFLAGS) -static -no-pie -Wl,-T,../pv86/pv86.ld -Wl,--build-id=none $< -o $@
$(IMAGE).bin: $(IMAGE).elf
	$(OBJCOPY) -O binary $< $@
	truncate -s 65536 $@
.PHONY: all
