# sw/ps/ven_soc_app/Makefile — F2 PS bring-up app for the KV260 Ventium SoC.
# On PetaLinux: use the aarch64 cross toolchain (CROSS_COMPILE=aarch64-linux-gnu-).
# Host build (compile-check only; mmap of /dev/mem won't work off-board):  make
CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
TARGET  := ven_soc_app

$(TARGET): ven_soc_app.c ven_soc_regs.h
	$(CC) $(CFLAGS) -o $@ ven_soc_app.c

clean:
	rm -f $(TARGET)
.PHONY: clean
