# sw/ps/kms-draw/Makefile — KMS/DRM display app for the KV260 Ventium SoC.
#   kms-draw : double-buffered, vsync-locked DRM page-flip loop that shows the
#              live Quake framebuffer (P5Q1 stream) scaled into a 1280x960 window
#              plus the active VGA palette + status panel on the right.
#   preview  : host-only offline renderer (no DRM) -> PPM, for checking layout.
#
# Build natively on the Kria (Ubuntu): sudo apt install -y libdrm-dev pkg-config
#   make            # kms-draw
#   sudo ./kms-draw [source.p5q | fifo]      # default source /tmp/quake.p5q
#
# Live from the core:  mkfifo /tmp/q.fifo
#                      sudo ven_soc_app --quake <image.json> --video /tmp/q.fifo &
#                      sudo ./kms-draw /tmp/q.fifo
CC      ?= cc
CFLAGS  ?= -O2 -Wall
DRM_CFLAGS := $(shell pkg-config --cflags libdrm)
DRM_LIBS   := $(shell pkg-config --libs libdrm)

all: kms-draw

kms-draw: kms-draw.c
	$(CC) $(CFLAGS) $(DRM_CFLAGS) -o $@ kms-draw.c $(DRM_LIBS)

# host preview: includes kms-draw.c (main compiled out) + writes a PPM. Needs the
# libdrm *headers* only (the DRM code is unused), so it builds even off-board.
preview: preview.c kms-draw.c
	$(CC) $(CFLAGS) $(DRM_CFLAGS) -o $@ preview.c

clean:
	rm -f kms-draw preview preview.ppm
.PHONY: all clean
