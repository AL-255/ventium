# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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
            $(TB_DIR)/quake_image.cpp $(TB_DIR)/win95_cosim.cpp \
            $(TB_DIR)/syscall_emu.cpp   # M14 free-run emulator (inert unless --emulate-syscalls)

# M8.1 --soc TB: a dedicated driver (tb_soc.cpp) against the ventium_soc top. It
# reuses the shared memory model + DPI retire path; no quake/win95 co-sim.
SOC_CPP_SRCS := $(TB_DIR)/tb_soc.cpp $(TB_DIR)/memmodel.cpp $(TB_DIR)/dpi_retire.cpp \
                $(wildcard $(VENTIUM_ROOT)/sw/ps_periph/*.c)

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

# VL_EXTRA_DEFINES: optional +define+... passthrough (e.g. +define+VEN_SRT_ITER to
# build the core with the iterative SRT FDIV/FSQRT engines wired in).
VL_EXTRA_DEFINES ?=
# OBJDIR: build dir for the `rtl` target. Default obj_dir (the canonical tb used by
# make verify / m1..m5). A define-variant build (e.g. +VEN_FP_OVERLAP for the M5
# fdivint band) passes OBJDIR=obj_dir_<variant> so it never clobbers obj_dir/tb_ventium.
OBJDIR ?= obj_dir
# Host-compiler optimization for the Verilated model. verilated.mk hard-sets
# OPT_FAST=-Os (conservative), which the environment cannot override — only a
# command-line make assignment can, which is exactly what Verilator's -MAKEFLAGS
# injects. We bump the optimisation level (OPT_FAST) and add -march=native via
# OPT (verilated.mk does `CPPFLAGS += $(OPT)`, applied before OPT_FAST, so the
# single -O comes from OPT_FAST with no conflict). Pure sim-speed (~2-3x); the
# results are bit-identical/deterministic — this only changes how the generated
# C++ is compiled. Tokens must be space-free (each -MAKEFLAGS is one make arg).
VL_OPT_FAST  ?= -O3
VL_OPT_MARCH ?= -march=native
VL_MAKEFLAGS := -MAKEFLAGS OPT_FAST=$(VL_OPT_FAST) -MAKEFLAGS OPT=$(VL_OPT_MARCH)
VL_FLAGS := --cc --exe --build -j 0 \
            $(VL_MAKEFLAGS) \
            -sv --top-module $(TOP) \
            -Wall -Wno-UNUSED -Wno-fatal \
            $(VL_TRACE) $(VL_EXTRA_DEFINES) \
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
	$(VERILATOR) $(VL_FLAGS) -Mdir $(OBJDIR) \
	  -F $(RTL_FILELIST) $(CPP_SRCS)
	@echo "built: $(CURDIR)/$(OBJDIR)/$(EXE)  (OPT_FAST=$(VL_OPT_FAST) $(VL_OPT_MARCH))"

# ---- l1axi: P1-1 bus_mode=2 build (+VEN_L1_AXI) -----------------------------
# Routes the core mem port through ventium_l1_axi (ven_l1d + ven_axi_master) to an
# AXI4 master serviced by the TB's behavioral DDR slave (tb_main.cpp, #ifdef'd).
# Built into a SEPARATE obj dir so make verify / every gate keeps using
# obj_dir/tb_ventium (byte-identical default). The L1+AXI leaf modules are appended
# ONLY here (they are not in ventium.f); -DVEN_L1_AXI reaches the C++ TB too.
# Run: make l1axi && ./obj_dir_l1axi/tb_ventium --l1-axi <image> ...
L1AXI_RTL := $(RTL_DIR)/mem/ven_l1d.sv $(RTL_DIR)/mem/ven_axi_master.sv \
             $(RTL_DIR)/mem/ventium_l1_axi.sv
.PHONY: l1axi
l1axi:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI -CFLAGS "-DVEN_L1_AXI" -Mdir obj_dir_l1axi \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI bus_mode=2): $(CURDIR)/obj_dir_l1axi/$(EXE)"

# ---- l1axi_kv: the DEPLOYED KV260 memory config (+VEN_L1_AXI +VEN_KV260_SOC) ---
# Same as l1axi but REMAP_BASE=0x4000_0000 (the carveout) — reproduces the
# deployed-bitstream CALL/RET / interrupt-delivery behavior the on-board build hits.
.PHONY: l1axi_kv
l1axi_kv:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI +define+VEN_KV260_SOC \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC" -Mdir obj_dir_l1axi_kv \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI + KV260 REMAP): $(CURDIR)/obj_dir_l1axi_kv/$(EXE)"

# ---- l1axi_kv_full: the EXACT deployed linux_40 define set ------------------
# L1AXI + KV260 REMAP + ALL fetch/cache/FP features (FE_PIPE, UOPCACHE, BTB_PIPE,
# IC_BRAM, CACHE_HALF, FP_PIPE/2, SRT/IDIV/BCD_ITER). Reproduces the on-board build.
KV_FULL_DEFS := +define+VEN_L1_AXI +define+VEN_KV260_SOC +define+VEN_FE_PIPE \
  +define+VEN_UOPCACHE +define+VEN_BTB_PIPE +define+VEN_IC_BRAM +define+VEN_CACHE_HALF \
  +define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_SRT_ITER +define+VEN_IDIV_ITER \
  +define+VEN_BCD_ITER
.PHONY: l1axi_kv_full
l1axi_kv_full:
	$(VERILATOR) $(VL_FLAGS) $(KV_FULL_DEFS) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC" -Mdir obj_dir_l1axi_kvf \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (deployed linux_40 config): $(CURDIR)/obj_dir_l1axi_kvf/$(EXE)"

# ---- l1axi_cdc: P1-3 dual-clock build (+VEN_L1_AXI +VEN_AXI_CDC) -------------
# Same bus_mode=2 path, but the L1<->AXI backing port crosses through ven_axi_cdc
# (the async-FIFO CDC bridge). In the cosim core_clk==axi_clk==top->clk, so this
# exercises the CDC at the degenerate equal-clock ratio across the FULL 77-program
# suite (the multi-ratio data-integrity proof is verif/l1/run-l1axi-cdc-gate.sh).
# SEPARATE obj dir; default obj_dir/tb_ventium stays byte-identical.
L1AXICDC_RTL := $(RTL_DIR)/mem/ven_cdc_afifo.sv $(RTL_DIR)/mem/ven_reset_sync.sv \
                $(RTL_DIR)/mem/ven_axi_cdc.sv $(L1AXI_RTL)
.PHONY: l1axi_cdc
l1axi_cdc:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI +define+VEN_AXI_CDC \
	  -CFLAGS "-DVEN_L1_AXI" -Mdir obj_dir_l1axi_cdc \
	  -F $(RTL_FILELIST) $(L1AXICDC_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI dual-clock CDC): $(CURDIR)/obj_dir_l1axi_cdc/$(EXE)"

# ---- proxy: F4 PS-bridge int-0x80 STALL build (+VEN_PS_PROXY) ----------------
# Same cosim, but the core parks in S_SYSCALL_WAIT on int-0x80 and commits only on
# syscall_resp_valid (tb_main plays the PS: latch the response, assert resp_valid after
# an 8-clock service latency). Proves the gated stall reproduces the zero-latency proxy
# trace on a real int-0x80 stream (verif/m7/run-quake-lockstep-proxy.sh). SEPARATE obj
# dir; the default obj_dir/tb_ventium stays byte-identical.
.PHONY: proxy
proxy:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_PS_PROXY -CFLAGS "-DVEN_PS_PROXY" \
	  -Mdir obj_dir_proxy -F $(RTL_FILELIST) $(CPP_SRCS)
	@echo "built (F4 PS-proxy stall): $(CURDIR)/obj_dir_proxy/$(EXE)"

# ---- soc: M8.1 SoC-integration build (ventium_soc + ven_pic + ven_pit) ------
# Built into a SEPARATE obj dir so it never clobbers the default `rtl` build
# (make verify / the sys gates keep using obj_dir/tb_ventium). The --soc TB
# (tb_soc.cpp) runs the bare-metal pirqsoc image on ventium_soc and emits the
# system-mode retire trace + the checkpoint memory dump.
SOC_TOP := ventium_soc
SOC_EXE := tb_soc
# M8.4: ven_ide's disk backing store ($readmemh at sim-start). Absolute path so
# tb_soc finds it regardless of CWD; the path is embedded at build time but the
# file is read at runtime (the pide gate's Stage 0 generates it before running).
# ven_ide guards the $readmemh on `ifdef VEN_IDE_DISK_HEX, so non-IDE builds are
# unaffected (disk[] simply stays uninitialized — never read by other tests).
VEN_IDE_DISK_HEX ?= $(abspath $(CURDIR)/../sys/tests/pide/pide.disk.hex)
# SOC_OBJDIR lets a variant build (e.g. a +VEN_<DEV>_PS PS-offload cosim) use its
# own obj dir so it does not clobber the default obj_dir_soc the other gates use.
SOC_OBJDIR ?= obj_dir_soc
.PHONY: soc
soc:
	@if [ ! -f "$(SOC_FILELIST)" ]; then \
	  echo "ERROR: SoC filelist not found: $(SOC_FILELIST)."; exit 1; \
	fi
	$(VERILATOR) --cc --exe --build -j 0 \
	  -sv --top-module $(SOC_TOP) \
	  -Wall -Wno-UNUSED -Wno-fatal \
	  -DVEN_IDE_DISK_HEX='"$(VEN_IDE_DISK_HEX)"' \
	  $(VL_TRACE) $(VL_EXTRA_DEFINES) \
	  -CFLAGS "$(VL_CFLAGS)" \
	  -o $(SOC_EXE) \
	  -Mdir $(SOC_OBJDIR) \
	  -F $(SOC_FILELIST) $(SOC_CPP_SRCS)
	@echo "built: $(CURDIR)/$(SOC_OBJDIR)/$(SOC_EXE)"

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

# ---- emu: M14 free-run build (TB emulates int-0x80 instead of replaying) -----
# SEPARATE obj dir so it never clobbers obj_dir/tb_ventium (make verify keeps
# using that). Same RTL + tb_main; tb_main's --emulate-syscalls path is additive
# and inert by default, so this builds the very same model with the syscall
# emulator linked in (syscall_emu.cpp).
# emu: the SAME build as `rtl` (the emulator is in CPP_SRCS now) but into a
# SEPARATE obj dir, so it can be built while obj_dir/tb_ventium is busy with a run.
.PHONY: emu
emu:
	$(VERILATOR) $(VL_FLAGS) -Mdir obj_dir_emu \
	  -F $(RTL_FILELIST) $(CPP_SRCS)
	@echo "built: $(CURDIR)/obj_dir_emu/$(EXE)"

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
