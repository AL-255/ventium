# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium Producer B — QEMU TCG cycle-trace plugin build.
#
# Mirrors ventium-refs/07-p5-emulation-harness/scripts/30-build-plugin.sh:
# compile p5trace.c -fPIC against the QEMU plugin headers + glib, then link the
# static capstone into a shared object.
#
# The top-level Makefile invokes this as:
#   make -C verif/qemu-plugins QEMU_SRC=<abspath> CAPSTONE=<abspath>
# and expects the artifact at <repo>/build/p5trace.so. This directory is
# verif/qemu-plugins/, so the repo build/ dir is ../../build.
#
# QEMU_SRC / CAPSTONE default to the in-tree submodule paths so the plugin also
# builds standalone (just `make` in this directory).

# --- locate the repo root + submodule (overridable on the command line) ------
HERE       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO       := $(abspath $(HERE)/../..)
REFS       := $(REPO)/ventium-refs/07-p5-emulation-harness
QEMU_SRC   ?= $(REFS)/build/qemu
CAPSTONE   ?= $(REFS)/build/capstone

BUILD      := $(REPO)/build
OUT        := $(BUILD)/p5trace.so
OBJ        := $(BUILD)/p5trace.o
SRC        := $(HERE)/p5trace.c

CC         ?= gcc
CFLAGS     := -O2 -fPIC -Wall -Wno-unused-parameter -g
CFLAGS     += $(shell pkg-config --cflags glib-2.0)
CFLAGS     += -I$(QEMU_SRC)/include/qemu -I$(CAPSTONE)/include
LDLIBS     := $(CAPSTONE)/libcapstone.a

.PHONY: all clean
all: $(OUT)

$(OUT): $(SRC) | check
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $(SRC) -o $(OBJ)
	$(CC) -shared -o $(OUT) $(OBJ) $(LDLIBS)
	@echo "built: $(OUT)"
	@file $(OUT) | sed 's/^[^:]*:/  /'

# Fail early with a clear message if the QEMU/capstone prerequisites are missing.
.PHONY: check
check:
	@[ -d "$(QEMU_SRC)/include/qemu" ] || { \
	  echo "ERROR: QEMU plugin headers not found at $(QEMU_SRC)/include/qemu"; \
	  echo "       build the harness (10-build-emulator.sh) or pass QEMU_SRC=<path>"; exit 1; }
	@[ -f "$(CAPSTONE)/libcapstone.a" ] || { \
	  echo "ERROR: static capstone not found at $(CAPSTONE)/libcapstone.a"; \
	  echo "       build the harness (10-build-emulator.sh) or pass CAPSTONE=<path>"; exit 1; }

clean:
	rm -f $(OUT) $(OBJ)
