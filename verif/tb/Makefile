# verif/tb/Makefile — Producer C: Verilator C++ testbench + bus-functional model
#
# Default target verilates+builds the testbench against the REAL core sources in
# rtl/ (this is what the integration phase uses). The 'selftest' target builds
# against the throwaway stub in verif/tb/selftest/ so this component can be
# proven in isolation while rtl/ is authored in parallel.
#
# Contracts: docs/rtl-interface.md (ports + vtm_retire DPI), docs/trace-format.md
# (the emitted .vtrace), PLAN.md §4.2.

# ---- paths ------------------------------------------------------------------
VENTIUM_ROOT := $(abspath $(CURDIR)/../..)
RTL_DIR      := $(VENTIUM_ROOT)/rtl
SELFTEST_DIR := $(CURDIR)/selftest
TB_DIR       := $(CURDIR)

# Real RTL sources: an EXPLICIT filelist (rtl/ventium.f) listing PACKAGES before
# the modules that import their types (R1 modularization, deterministic compile
# order; the old $(wildcard rtl/*.sv rtl/**/*.sv) ordered packages alphabetically
# AFTER their consumers, tripping IEEE 1800 "reference before declaration").
# Verilator resolves -f paths relative to the .f file's own directory ($(RTL_DIR)).
RTL_FILELIST := $(RTL_DIR)/ventium.f
RTL_SRCS     := $(RTL_FILELIST)

# M8.1 SoC integration filelist: the core set + ventium_soc + ven_pic + ven_pit
# (ventium_top REPLACED by ventium_soc as the top). Used by the `soc` target.
SOC_FILELIST := $(RTL_DIR)/ventium_soc.f

# Self-test stub sources.
SELFTEST_SRCS := $(wildcard $(SELFTEST_DIR)/*.sv)

# C++ sources owned by Producer C.
CPP_SRCS := $(TB_DIR)/tb_main.cpp $(TB_DIR)/memmodel.cpp $(TB_DIR)/dpi_retire.cpp \
            $(TB_DIR)/quake_image.cpp $(TB_DIR)/win95_cosim.cpp

# M8.1 --soc TB: a dedicated driver (tb_soc.cpp) against the ventium_soc top. It
# reuses the shared memory model + DPI retire path; no quake/win95 co-sim.
SOC_CPP_SRCS := $(TB_DIR)/tb_soc.cpp $(TB_DIR)/memmodel.cpp $(TB_DIR)/dpi_retire.cpp

# ---- verilator invocation ---------------------------------------------------
VERILATOR ?= verilator
TOP        = ventium_top
EXE        = tb_ventium

# Optional VCD waveform support: `make selftest TRACE=1` (or `make TRACE=1`).
TRACE ?= 0
ifeq ($(TRACE),1)
  VL_TRACE := --trace
else
  VL_TRACE :=
endif

# -I.. so dpi_retire.cpp / tb_main.cpp can find trace_writer.h & memmodel.h, and
# obj_dir on the include path for Vventium_top__Dpi.h (Verilator runs the C++
# compile from inside -Mdir, so "." already resolves there; we add it explicitly
# for clarity). CFLAGS go to the C++ compile of our .cpp files.
VL_CFLAGS := -I$(TB_DIR) -std=c++17

VL_FLAGS := --cc --exe --build -j 0 \
            -sv --top-module $(TOP) \
            -Wall -Wno-UNUSED -Wno-fatal \
            $(VL_TRACE) \
            -CFLAGS "$(VL_CFLAGS)" \
            -o $(EXE)

# ---- default target: build against the real core ---------------------------
.PHONY: all
all: rtl

.PHONY: rtl
rtl:
	@if [ ! -f "$(RTL_FILELIST)" ]; then \
	  echo "ERROR: RTL filelist not found: $(RTL_FILELIST)."; \
	  echo "       The core is authored by a sibling agent; run 'make selftest'"; \
	  echo "       to exercise this testbench in isolation."; \
	  exit 1; \
	fi
	$(VERILATOR) $(VL_FLAGS) -Mdir obj_dir \
	  -F $(RTL_FILELIST) $(CPP_SRCS)
	@echo "built: $(CURDIR)/obj_dir/$(EXE)"

# ---- soc: M8.1 SoC-integration build (ventium_soc + ven_pic + ven_pit) ------
# Built into a SEPARATE obj dir so it never clobbers the default `rtl` build
# (make verify / the sys gates keep using obj_dir/tb_ventium). The --soc TB
# (tb_soc.cpp) runs the bare-metal pirqsoc image on ventium_soc and emits the
# system-mode retire trace + the checkpoint memory dump.
SOC_TOP := ventium_soc
SOC_EXE := tb_soc
.PHONY: soc
soc:
	@if [ ! -f "$(SOC_FILELIST)" ]; then \
	  echo "ERROR: SoC filelist not found: $(SOC_FILELIST)."; exit 1; \
	fi
	$(VERILATOR) --cc --exe --build -j 0 \
	  -sv --top-module $(SOC_TOP) \
	  -Wall -Wno-UNUSED -Wno-fatal \
	  $(VL_TRACE) \
	  -CFLAGS "$(VL_CFLAGS)" \
	  -o $(SOC_EXE) \
	  -Mdir obj_dir_soc \
	  -F $(SOC_FILELIST) $(SOC_CPP_SRCS)
	@echo "built: $(CURDIR)/obj_dir_soc/$(SOC_EXE)"

# ---- rtl-sva: integrated build with the biu_p5 SVA bound + --assert ---------
# M5B-int: build the SAME integrated model into a SEPARATE obj dir, but with
# Verilator SVA enabled (--assert) and the 19 biu_p5 protocol-invariant SVA
# bound into the live biu_p5 instance (verif/bus/biu_p5_sva.sv + its `bind`).
# Used by the bus_mode=1 in-system SVA run: it confirms the SAME mutation-
# validated invariants the standalone gate checks HOLD on real core traffic.
# Kept out of the default `rtl` target so make verify / the normal gate path is
# byte-identical and unburdened by assertion machinery.
SVA_BIND := $(VENTIUM_ROOT)/verif/bus/biu_p5_sva.sv
.PHONY: rtl-sva
rtl-sva:
	$(VERILATOR) $(VL_FLAGS) --assert -Wno-DECLFILENAME -Mdir obj_dir_sva \
	  -F $(RTL_FILELIST) $(SVA_BIND) $(CPP_SRCS)
	@echo "built (SVA): $(CURDIR)/obj_dir_sva/$(EXE)"

# ---- selftest target: build against the throwaway stub ----------------------
# Built into a separate obj dir so it never clobbers a real-core build. ENTRY
# is set via -GENTRY so the stub's deterministic pc values track --entry; the
# selftest run below passes the matching --entry.
SELFTEST_ENTRY ?= 0x08048000
.PHONY: selftest-build
selftest-build:
	$(VERILATOR) $(VL_FLAGS) -Mdir obj_dir_selftest \
	  -GENTRY=$(SELFTEST_ENTRY) \
	  $(SELFTEST_SRCS) $(CPP_SRCS)
	@echo "built: $(CURDIR)/obj_dir_selftest/$(EXE)"

# Build + run the selftest and check the produced trace is well-formed.
.PHONY: selftest
selftest: selftest-build
	./obj_dir_selftest/$(EXE) \
	  --out $(CURDIR)/selftest.vtrace \
	  --entry $(SELFTEST_ENTRY) --load $(SELFTEST_ENTRY) \
	  --max-cycles 1000
	@echo "--- selftest.vtrace ---"
	@cat $(CURDIR)/selftest.vtrace
	@echo "--- parsing with tracefmt.read_trace ---"
	@PYTHONPATH=$(VENTIUM_ROOT)/verif/diff python3 -c \
	  "import tracefmt; t=tracefmt.read_trace('$(CURDIR)/selftest.vtrace'); \
	   print('hdr =', t.hdr); print('records =', len(t.records)); \
	   assert t.hdr.get('vtrace')==1 and t.hdr.get('producer')=='rtl' \
	          and t.hdr.get('mode')=='func', 'bad header'; \
	   assert len(t.records)>=1, 'no records'; \
	   ns=[r['n'] for r in t.records]; \
	   assert ns==sorted(ns) and len(set(ns))==len(ns), 'n not strictly increasing'; \
	   import re; \
	   [ (any(re.fullmatch(r'0x[0-9a-f]{8}', r[k]) for _ in [0]) or (_ for _ in ()).throw(AssertionError('bad '+k))) for r in t.records for k in tracefmt.GPR_KEYS+['eflags','pc'] ]; \
	   [ (re.fullmatch(r'0x[0-9a-f]{4}', r[k]) or (_ for _ in ()).throw(AssertionError('bad seg '+k))) for r in t.records for k in tracefmt.SEG_KEYS ]; \
	   print('OK: well-formed func .vtrace with', len(t.records), 'records')"

# ---- housekeeping -----------------------------------------------------------
.PHONY: clean
clean:
	rm -rf obj_dir obj_dir_selftest obj_dir_sva obj_dir_soc
	rm -f selftest.vtrace
