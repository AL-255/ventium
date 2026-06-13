# sw/ps/ven_soc_app/Makefile — PS apps for the KV260 Ventium SoC.
#   ven_soc_app : F2 boot/console bring-up + F3 --dos (i8042/PIC/VGA C models,
#                 USB HID keyboard -> IRQ1 injection through R_INTR)
#   ven_fb_vnc  : RFB 3.3 framebuffer bridge (mode-13h VRAM in the carveout)
# Cross (Kria Ubuntu / PetaLinux):  make CROSS_COMPILE=aarch64-linux-gnu- STATIC=1
# Host build (compile-check only; mmap of /dev/mem won't work off-board):  make
CROSS_COMPILE ?=
STATIC  ?=
CC      := $(CROSS_COMPILE)gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
ifneq ($(STATIC),)
CFLAGS  += -static
endif

PERIPH  := ../../ps_periph
APP_SRC := ven_soc_app.c hid_kbd.c \
           $(PERIPH)/ven_i8042.c $(PERIPH)/ven_pic.c $(PERIPH)/ven_vgaregs.c \
           $(PERIPH)/ven_pit.c $(PERIPH)/ven_rtc.c $(PERIPH)/ven_ide.c

all: ven_soc_app ven_fb_vnc

ven_soc_app: $(APP_SRC) ven_soc_regs.h hid_kbd.h $(PERIPH)/ven_periph.h
	$(CC) $(CFLAGS) -I$(PERIPH) -o $@ $(APP_SRC)

ven_fb_vnc: fb_vnc.c ven_soc_regs.h
	$(CC) $(CFLAGS) -o $@ fb_vnc.c

clean:
	rm -f ven_soc_app ven_fb_vnc
.PHONY: all clean
