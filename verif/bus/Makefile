# ============================================================================
# Ventium M5B -- standalone Makefile for the pin-level Bus Interface Unit.
#
# ISOLATION: builds ONLY verif/bus/ sources into verif/bus/obj/. Never invokes
# any rtl/ or verif/tb build. The DUT (biu_p5) is self-contained (no ventium_pkg).
#
# Targets:
#   make lint   -- verilator --lint-only on biu_p5 (standalone, -Wall clean)
#   make build  -- build the SVA + self-consistency testbench (verilator --binary)
#   make run    -- run the testbench (alias: make / make all)
#   make clean  -- remove obj/
# iverilog 12 here does not parse SVA `property`; Verilator is used (it does).
# ============================================================================
VERILATOR ?= verilator
HERE      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ       := $(HERE)/obj
VTB       := $(OBJ)/vtb
DUT       := $(HERE)/biu_p5.sv
TB        := $(HERE)/tb_biu_p5.sv

# testbench-only stylistic waivers (DUT is -Wall clean on its own)
TB_WAIVERS := -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ \
              -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD

.PHONY: all run build lint clean
all: run

lint:
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME --top-module biu_p5 $(DUT)
	@echo "lint OK"

build: lint
	@mkdir -p $(VTB)
	$(VERILATOR) --binary --assert --timing -Wall $(TB_WAIVERS) \
	  --top-module tb_biu_p5 --Mdir $(VTB) $(DUT) $(TB) -o tb_biu_p5

run: build
	$(VTB)/tb_biu_p5

clean:
	rm -rf $(OBJ)
