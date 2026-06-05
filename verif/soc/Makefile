# verif/soc/Makefile — standalone Verilator unit tests for Ventium SoC PC
# peripheral device modules (rtl/soc/ven_*.sv). Each device is built + run
# independently of the main Ventium build; this Makefile does NOT touch
# rtl/ventium.f or any core/bus/top file.
#
# Usage:
#   make port92        # build + run the ven_port92 directed unit self-check
#   make lint-port92   # verilator --lint-only on rtl/soc/ven_port92.sv
#   make clean

VERILATOR ?= verilator
RTL_DIR   := $(abspath ../../rtl/soc)

# Strict, CI-style lint/build flags. NOTE: -Mdir is set PER-TARGET (obj_dir_$@)
# so port92 and acpipm build into separate dirs and never race under `make -j`.
VFLAGS := --cc --exe --build -j 0 \
          -Wall -Wno-fatal \
          --x-assign unique --x-initial unique

.PHONY: all port92 lint-port92 acpipm lint-acpipm clean

all: port92 acpipm

# ---- ven_port92 ----------------------------------------------------------
port92:
	$(VERILATOR) $(VFLAGS) -Mdir obj_dir_port92 \
	  --top-module ven_port92 \
	  $(RTL_DIR)/ven_port92.sv \
	  tb_ven_port92.cpp \
	  -o Vven_port92
	@echo "---- running ven_port92 unit self-check ----"
	./obj_dir_port92/Vven_port92

lint-port92:
	$(VERILATOR) --lint-only -Wall --top-module ven_port92 $(RTL_DIR)/ven_port92.sv
	@echo "lint-port92: clean"

# ---- ven_acpipm (ACPI PM timer, port 0x608) ------------------------------
# Built with a TINY clock ratio (CLK_HZ=7, PM_TIMER_FREQ=3) via -G overrides so
# the free-running cadence is exercisable in feasible cycle counts; the divider
# arithmetic is identical at the real 33MHz/3.579545MHz rate (structural).
acpipm:
	$(VERILATOR) $(VFLAGS) -Mdir obj_dir_acpipm \
	  -GCLK_HZ=7 -GPM_TIMER_FREQ=3 \
	  --top-module ven_acpipm \
	  $(RTL_DIR)/ven_acpipm.sv \
	  tb_ven_acpipm.cpp \
	  -o Vven_acpipm
	@echo "---- running ven_acpipm unit self-check ----"
	./obj_dir_acpipm/Vven_acpipm

lint-acpipm:
	$(VERILATOR) --lint-only -Wall --top-module ven_acpipm $(RTL_DIR)/ven_acpipm.sv
	@echo "lint-acpipm: clean"

clean:
	rm -rf obj_dir obj_dir_port92 obj_dir_acpipm
