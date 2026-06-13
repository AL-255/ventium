# sw/ps/ven_soc_app/Makefile — PS apps for the KV260 Ventium SoC.
#   ven_soc_app : F2 boot/console bring-up + F3 --dos (i8042/PIC/VGA C models,
#                 USB HID keyboard -> IRQ1 injection through R_INTR) + F4 --quake
#                 (int-0x80 userspace proxy: the ported syscall emulator + Quake
#                 image loader, backed by the DDR carveout)
#   ven_fb_vnc  : RFB 3.3 framebuffer bridge (mode-13h VRAM in the carveout)
# Cross (Kria Ubuntu / PetaLinux):  make CROSS_COMPILE=aarch64-linux-gnu- STATIC=1
# Host build (compile-check only; mmap of /dev/mem won't work off-board):  make
CROSS_COMPILE ?=
STATIC  ?=
CC      := $(CROSS_COMPILE)gcc
CXX     := $(CROSS_COMPILE)g++
CFLAGS  := -O2 -Wall -Wextra -std=c11
CXXFLAGS:= -O2 -Wall -Wextra -std=c++17
LDFLAGS :=
ifneq ($(STATIC),)
CFLAGS   += -static
CXXFLAGS += -static
LDFLAGS  += -static
endif

PERIPH  := ../../ps_periph
# the shared (unmodified) syscall emulator + Quake image loader live in verif/tb
TBDIR   := ../../../verif/tb
OBJDIR  := build

# C sources (control app + the F3 peripheral C models).
C_SRC   := ven_soc_app.c hid_kbd.c \
           $(PERIPH)/ven_i8042.c $(PERIPH)/ven_pic.c $(PERIPH)/ven_vgaregs.c \
           $(PERIPH)/ven_pit.c $(PERIPH)/ven_rtc.c $(PERIPH)/ven_ide.c
# C++ sources (F4 Quake proxy: board glue + g_ddr-backed MemModel + the ported
# verif/tb emulator/loader, compiled with -I$(TBDIR) so they pick up that header
# set; the board MemModel bodies in mem_carveout.cpp are the ones that link).
CXX_SRC := ven_quake.cpp mem_carveout.cpp $(TBDIR)/syscall_emu.cpp $(TBDIR)/quake_image.cpp

C_OBJ   := $(addprefix $(OBJDIR)/, $(notdir $(C_SRC:.c=.o)))
CXX_OBJ := $(addprefix $(OBJDIR)/, $(notdir $(CXX_SRC:.cpp=.o)))

vpath %.c   $(PERIPH)
vpath %.cpp $(TBDIR)

all: ven_soc_app ven_fb_vnc

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/%.o: %.c ven_soc_regs.h | $(OBJDIR)
	$(CC) $(CFLAGS) -I$(PERIPH) -c $< -o $@

$(OBJDIR)/%.o: %.cpp | $(OBJDIR)
	$(CXX) $(CXXFLAGS) -I. -I$(TBDIR) -c $< -o $@

# link with the C++ driver so libstdc++ is pulled in.
ven_soc_app: $(C_OBJ) $(CXX_OBJ)
	$(CXX) $(LDFLAGS) -o $@ $^

ven_fb_vnc: fb_vnc.c ven_soc_regs.h
	$(CC) $(CFLAGS) -o $@ fb_vnc.c

clean:
	rm -f ven_soc_app ven_fb_vnc
	rm -rf $(OBJDIR)
.PHONY: all clean
