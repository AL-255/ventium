CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psocsgdt.bin
psocsgdt.o: psocsgdt.S
	$(CC) $(CFLAGS) -c $< -o $@
psocsgdt.elf: psocsgdt.o psocsgdt.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocsgdt.ld -Wl,--build-id=none psocsgdt.o -o psocsgdt.elf
psocsgdt.bin: psocsgdt.elf
	$(OBJCOPY) -O binary psocsgdt.elf psocsgdt.bin
	@truncate -s $(IMG_BYTES) psocsgdt.bin
	@echo "psocsgdt.bin: $$(stat -c%s psocsgdt.bin) bytes"
clean:
	rm -f psocsgdt.o psocsgdt.elf psocsgdt.bin
.PHONY: all clean
