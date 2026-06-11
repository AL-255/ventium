CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psocfw.bin
psocfw.o: psocfw.S
	$(CC) $(CFLAGS) -c $< -o $@
psocfw.elf: psocfw.o psocfw.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocfw.ld -Wl,--build-id=none psocfw.o -o psocfw.elf
psocfw.bin: psocfw.elf
	$(OBJCOPY) -O binary psocfw.elf psocfw.bin
	@truncate -s $(IMG_BYTES) psocfw.bin
	@echo "psocfw.bin: $$(stat -c%s psocfw.bin) bytes"
clean:
	rm -f psocfw.o psocfw.elf psocfw.bin
.PHONY: all clean
