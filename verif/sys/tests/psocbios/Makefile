CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psocbios.bin
psocbios.o: psocbios.S
	$(CC) $(CFLAGS) -c $< -o $@
psocbios.elf: psocbios.o psocbios.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocbios.ld -Wl,--build-id=none psocbios.o -o psocbios.elf
psocbios.bin: psocbios.elf
	$(OBJCOPY) -O binary psocbios.elf psocbios.bin
	@truncate -s $(IMG_BYTES) psocbios.bin
	@echo "psocbios.bin: $$(stat -c%s psocbios.bin) bytes"
clean:
	rm -f psocbios.o psocbios.elf psocbios.bin
.PHONY: all clean
