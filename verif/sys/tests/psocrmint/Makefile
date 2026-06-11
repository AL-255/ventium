CC      ?= gcc
OBJCOPY ?= objcopy
CFLAGS  := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
IMG_BYTES := 65536
all: psocrmint.bin
psocrmint.o: psocrmint.S
	$(CC) $(CFLAGS) -c $< -o $@
psocrmint.elf: psocrmint.o psocrmint.ld
	$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,psocrmint.ld -Wl,--build-id=none psocrmint.o -o psocrmint.elf
psocrmint.bin: psocrmint.elf
	$(OBJCOPY) -O binary psocrmint.elf psocrmint.bin
	@truncate -s $(IMG_BYTES) psocrmint.bin
	@echo "psocrmint.bin: $$(stat -c%s psocrmint.bin) bytes"
clean:
	rm -f psocrmint.o psocrmint.elf psocrmint.bin
.PHONY: all clean
