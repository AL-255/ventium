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

# Self-test stub sources.
SELFTEST_SRCS := $(wildcard $(SELFTEST_DIR)/*.sv)

# C++ sources owned by Producer C.
CPP_SRCS := $(TB_DIR)/tb_main.cpp $(TB_DIR)/memmodel.cpp $(TB_DIR)/dpi_retire.cpp \
            $(TB_DIR)/quake_image.cpp $(TB_DIR)/win95_cosim.cpp \
            $(TB_DIR)/syscall_emu.cpp   # M14 free-run emulator (inert unless --emulate-syscalls)

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
# The RTL-only +define is not visible to tb_main.cpp.  Keep its debug driver in
# lockstep with the generated model, otherwise --dbg-step/--dbg-bp silently
# parse but never drive the corresponding ventium_top ports.
ifneq ($(filter +define+VEN_DBG_CORE,$(VL_EXTRA_DEFINES)),)
VL_CFLAGS += -DVEN_DBG_CORE
endif
# The reset-only checkpoint ports are generated only for this profiler build;
# make the C++ driver see the exact same compile-time configuration.
ifneq ($(filter +define+VEN_SNAPSHOT_RESTORE,$(VL_EXTRA_DEFINES)),)
VL_CFLAGS += -DVEN_SNAPSHOT_RESTORE
endif
# OBJDIR: build dir for the `rtl` target. Default obj_dir (the canonical tb used by
# make verify / m1..m5). A define-variant build (e.g. +VEN_FP_OVERLAP for the M5
# fdivint band) passes OBJDIR=obj_dir_<variant> so it never clobbers obj_dir/tb_ventium.
OBJDIR ?= obj_dir
# The long-lived canonical object directories may be symlinked to a scratch
# volume. Give the L1/AXI variants the same relocatability as `rtl`, so gates
# can build current sources locally when that volume is unavailable/read-only.
L1AXI_OBJDIR     ?= obj_dir_l1axi
L1AXI_CDC_OBJDIR ?= obj_dir_l1axi_cdc
KV_FULL_OBJDIR   ?= obj_dir_l1axi_kvf
KV_PROXY_OBJDIR  ?= obj_dir_l1axi_kvproxy
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
# VL_J: C++ build parallelism (default 0 = all cores). Override (e.g. VL_J=6) to
# cap peak g++ memory on RAM-tight boxes. VL_SPLIT: optional --output-split flags
# to chunk Verilator's generated C++ so each g++ invocation uses far less memory
# (set VL_SPLIT="--output-split 20000 --output-split-cfuncs 20000" for big builds).
VL_J     ?= 0
VL_SPLIT ?=
VL_FLAGS := --cc --exe --build -j $(VL_J) $(VL_SPLIT) \
            $(VL_MAKEFLAGS) \
            -sv --top-module $(TOP) \
            -Wall -Wno-UNUSED -Wno-fatal \
            -Werror-UNOPTFLAT \
            +define+VEN_FPREM \
            $(VL_TRACE) $(VL_EXTRA_DEFINES) \
            -CFLAGS "$(VL_CFLAGS)" \
            -o $(EXE)

# -Werror-UNOPTFLAT (REVIEW1_Aug3 R2-M02): the request-path combinational cycle
# (cur_seg_rel -> acc_usr -> perm_fault -> the bus driver block) was eliminated
# by splitting the segment-identity drive out of the bus driver's always_comb
# (core_bus_driver.svh). Any NEW circular combinational logic is a build error.

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
# REVIEW_Jul29 M-04: L1AXI_RTL used to also list the three northbridge/L2 sources
# (ven_cachemap.sv, ven_l2.sv, ven_northbridge.sv). Those files are ABSENT from this
# checkout, and L1AXI_RTL feeds ~14 targets — so EVERY one of them was handing
# Verilator non-existent paths, not just the L2 target. The northbridge modules are
# only ever instantiated under +VEN_EN_L2, which only `l1axi_l2` defines, so the
# other targets never needed them. Split out: the common list is now buildable, and
# only the L2 target pulls NB_RTL (behind a guard that fails with a clear message).
# REVIEW2_aug2 H-13: ven_cachemap moved from NB_RTL into the COMMON list. It is no
# longer an L2-only module -- the DEFAULT build now instantiates it for the I-side
# memory-type query that drives ic_fill_nocache, outside the EN_L2 generate. That was
# blocker (2) of the finding: an is_code query added inside that generate would have
# been neither built nor tested by anything in verify-all.
L1AXI_RTL := $(RTL_DIR)/mem/ven_l1d.sv $(RTL_DIR)/mem/ven_axi_master.sv \
             $(RTL_DIR)/mem/ventium_l1_axi.sv $(RTL_DIR)/northbridge/ven_cachemap.sv

NB_RTL := $(RTL_DIR)/northbridge/ven_l2.sv \
          $(RTL_DIR)/northbridge/ven_northbridge.sv

.PHONY: check-nb
check-nb:
	@missing=""; for f in $(NB_RTL); do [ -f "$$f" ] || missing="$$missing $$f"; done; \
	 if [ -n "$$missing" ]; then \
	   echo "ERROR: the northbridge/L2 sources are ABSENT from this checkout:"; \
	   for f in $$missing; do echo "         $$f"; done; \
	   echo "       so the L2 target cannot be built here. This is REVIEW_Jul29 M-04"; \
	   echo "       (documented-but-missing sources); tracked in task #43."; \
	   echo "       Every OTHER l1axi* target builds fine — they never needed these."; \
	   exit 1; \
	 fi
.PHONY: l1axi
l1axi:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI -CFLAGS "-DVEN_L1_AXI" -Mdir $(L1AXI_OBJDIR) \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI bus_mode=2): $(CURDIR)/$(L1AXI_OBJDIR)/$(EXE)"

# REVIEW2_aug2 H-13 CONTROL BUILD: identical to l1axi but +VEN_IC_NO_MTYPE, which drops
# the physical-memory-type term from ic_fill_nocache. run-mtype-gate.sh compares the two
# so the effect of honouring the cacheability map is MEASURED, not asserted. A gate that
# cannot build the other side of its comparison is not measuring anything.
.PHONY: l1axi_nomt
l1axi_nomt:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI +define+VEN_IC_NO_MTYPE -CFLAGS "-DVEN_L1_AXI" \
	  -Mdir obj_dir_l1axi_nomt -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI, H-13 memory-type term OFF): $(CURDIR)/obj_dir_l1axi_nomt/$(EXE)"

# EXPERIMENT (task #24): identical to l1axi but +VEN_SINGLE_FILL, which skips ven_axi_master's
# priming burst so a line fill costs ONE burst instead of two. Exists to MEASURE the payoff of
# fixing the HP0 stale-read root cause. NOT a shippable configuration — the priming read is there
# because a stale burst froze the guest. Compare against l1axi at the same AXI_RLAT.
l1axi_sf:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI +define+VEN_SINGLE_FILL -CFLAGS "-DVEN_L1_AXI" -Mdir obj_dir_l1axi_sf \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI, SINGLE FILL experiment): $(CURDIR)/obj_dir_l1axi_sf/$(EXE)"

# ---- l1axi_l2: DISABLED FOR NOW ----------------------------------------------
# The L2/northbridge stack (ven_l2/ven_northbridge under +define+VEN_EN_L2) is
# OFF: the sources are absent from this checkout (check-nb below records that),
# and the configuration is deliberately disabled until they land — do not
# re-enable by removing this stub. Every other l1axi* target is the no-L2 build
# (EN_L2=0), which is what all gates and the deployed KV260 image use.
.PHONY: l1axi_l2
l1axi_l2: check-nb
	@echo "l1axi_l2 is DISABLED FOR NOW: the L2/northbridge sources are absent and"
	@echo "the EN_L2=1 configuration is off (REVIEW_Aug3 H-09; task #43)."
	@exit 1

# ---- l1axi_kv: the DEPLOYED KV260 memory config (+VEN_L1_AXI +VEN_KV260_SOC) ---
# Same as l1axi but REMAP_BASE=0x4000_0000 (the carveout) — reproduces the
# deployed-bitstream CALL/RET / interrupt-delivery behavior the on-board build hits.
.PHONY: l1axi_kv
l1axi_kv:
	$(VERILATOR) $(VL_FLAGS) +define+VEN_L1_AXI +define+VEN_KV260_SOC \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC" -Mdir obj_dir_l1axi_kv \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI + KV260 REMAP): $(CURDIR)/obj_dir_l1axi_kv/$(EXE)"

# ---- l1axi_kv_full: the routed full-P5 core configuration -------------------
# L1AXI + KV260 REMAP + the full 8 KiB P5 L1 configuration (UOPCACHE, BTB_PIPE,
# IC_BRAM, FP_PIPE/2, shared x87, SRT/IDIV/BCD_ITER, and transcendentals).  This
# mirrors the core-relevant defines emitted by create_project_3mhz_wrapper.tcl.
# FE_PIPE is deliberately absent: it is an explicit routing experiment, OFF in
# the deployed default profile, rather than an implicit simulation optimization.
# VEN_FPREM is mandatory in every full-P5 image: without it a decoded FPREM has
# no engine (and no trap route outside FP_PS_ALL), and the unified SRT divider's
# remainder sideband had nowhere to land.
KV_FULL_DEFS := +define+VEN_L1_AXI +define+VEN_L1_HONOR_CD +define+VEN_KV260_SOC \
  +define+VEN_UOPCACHE +define+VEN_UOP_SFETCH +define+VEN_BTB_PIPE +define+VEN_IC_BRAM \
  +define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_SRT_ITER +define+VEN_IDIV_ITER \
  +define+VEN_BCD_ITER +define+VEN_TRANSCENDENTAL +define+VEN_FP_PC_RELAX \
  +define+VEN_FPREM +define+VEN_FP_SHARED +define+VEN_DBG_CORE \
  +define+VEN_SYS_FASTPATH +define+VEN_SYS_FASTPATH_RELOC +define+VEN_SYS_FASTLOAD_FLAT \
  +define+VEN_SYS_FASTSTORE_FLAT +define+VEN_FAST_RETRACE
KV_FULL_CFLAGS := -DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DBG_CORE
.PHONY: l1axi_kv_full
l1axi_kv_full:
	$(VERILATOR) $(VL_FLAGS) $(KV_FULL_DEFS) \
	  -CFLAGS "$(KV_FULL_CFLAGS)" -Mdir $(KV_FULL_OBJDIR) \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (routed full-P5 KV260 configuration): $(CURDIR)/$(KV_FULL_OBJDIR)/$(EXE)"

# ---- l1axi_full_snapshot: identity-addressed runtime instrumentation ---------
# The snapshot loader is a simulation-only diagnostic: it restores a QEMU-captured
# user process at a retirement boundary so profiling an established workload does
# not require replaying BIOS/OS startup. A linux-user snapshot holds virtual stack
# addresses near 0x4000_0000, whereas the KV260 target deliberately rejects such
# out-of-carveout *physical* addresses to prevent fold alias corruption. Profile it
# with the same P5 cache/front-end RTL but an identity-addressed verification fabric;
# board/DOS tests remain on KV_FULL_DEFS. Production FPGA builds never receive
# VEN_SNAPSHOT_RESTORE.
FULL_P5_SNAPSHOT_DEFS := $(filter-out +define+VEN_KV260_SOC,$(KV_FULL_DEFS))
FULL_P5_SNAPSHOT_CFLAGS := -DVEN_L1_AXI -DVEN_DBG_CORE -DVEN_SNAPSHOT_RESTORE
FULL_P5_SNAPSHOT_OBJDIR ?= obj_dir_l1axi_full_snapshot
.PHONY: l1axi_full_snapshot
l1axi_full_snapshot:
	$(VERILATOR) $(VL_FLAGS) $(FULL_P5_SNAPSHOT_DEFS) +define+VEN_SNAPSHOT_RESTORE $(VL_EXTRA_DEFINES) \
	  -CFLAGS "$(FULL_P5_SNAPSHOT_CFLAGS)" \
	  -Mdir $(FULL_P5_SNAPSHOT_OBJDIR) -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (identity-addressed full-P5 snapshot profiler): $(CURDIR)/$(FULL_P5_SNAPSHOT_OBJDIR)/$(EXE)"

# ---- l1axi_kv_full_xinit: KVF + Verilator X-randomization -------------------
# Same defines as l1axi_kv_full but with --x-initial/--x-assign unique so
# uninitialized flops power up to random (not zero) values — this exposes the
# board-only reset-incompleteness fetch bugs that the zero-init `make verify`
# is structurally blind to. Run the board-faithful sweep against it:
#   make l1axi_kv_full_xinit && bash /tmp/xrepro/sweep_kvf.sh   (all seeds must PASS)
XINIT_FLAGS := --x-initial unique --x-assign unique --x-initial-edge
.PHONY: l1axi_kv_full_xinit
l1axi_kv_full_xinit:
	$(VERILATOR) $(VL_FLAGS) $(XINIT_FLAGS) $(KV_FULL_DEFS) \
	  -CFLAGS "$(KV_FULL_CFLAGS)" -Mdir obj_dir_xinit_kvf \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (x-init KVF): $(CURDIR)/obj_dir_xinit_kvf/$(EXE)"

# ---- l1axi_kv_proxy: the EXACT deployed PROXY bitstream config ---------------
# l1axi_kv_full + VEN_PS_PROXY + VEN_DBG_CORE = the kv260_soc_impl_proxy build.
# Reproduces the on-silicon userspace-Quake memory+fetch path so a board-only freeze
# (e.g. the __init_libc jcc fetch wedge) reproduces in sim where the PC + every
# internal signal is visible. Run:
#   ./obj_dir_l1axi_kvproxy/tb_ventium --l1-axi --quake-image image_board.json \
#       --emulate-syscalls --brk-base 0x87c3000 --x87 --max-insn 5000 ...
.PHONY: l1axi_kv_proxy
l1axi_kv_proxy:
	$(VERILATOR) $(VL_FLAGS) $(KV_FULL_DEFS) +define+VEN_PS_PROXY +define+VEN_DBG_CORE +define+VEN_FPTRAP +define+VEN_FPREM $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_PS_PROXY -DVEN_DBG_CORE -DVEN_FPTRAP" \
	  -Mdir $(KV_PROXY_OBJDIR) \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS)
	@echo "built (deployed PROXY config): $(CURDIR)/$(KV_PROXY_OBJDIR)/$(EXE)"

# ---- l1axi_kv_dos: l1axi_kv_full + the PS peripheral C models wired into the io
# bridge (--dos). A FAITHFUL FreeDOS repro — SeaBIOS POST gets the SAME device
# responses ven_soc_app gives on the KV260, so it follows the board's exact path
# through L1/AXI and a board-only memory-path freeze reproduces in sim (where the PC
# IS visible). Links sw/ps_periph/*.c; VEN_DOS_MODELS arms the routing in tb_main.
DOS_PERIPH := $(wildcard $(VENTIUM_ROOT)/sw/ps_periph/*.c)
.PHONY: l1axi_kv_dos
l1axi_kv_dos:
	$(VERILATOR) $(VL_FLAGS) --savable $(KV_FULL_DEFS) +define+VEN_DBG_CORE $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_SAVABLE -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdos \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(DOS_PERIPH)
	@echo "built (deployed config + PS DOS models + VEN_DBG_CORE): $(CURDIR)/obj_dir_l1axi_kvdos/$(EXE)"

# ---- l1axi_kv_dos_q: l1axi_kv_dos + 64 MiB CMOS extended memory (F4A: DOS Quake
# needs the RAM for CWSDPMI's heap). Separate obj dir so the FreeDOS build stays
# byte-identical. Run with --disk quake_ven.img (patched kernel + VGABIOS+vgainit).
.PHONY: l1axi_kv_dos_q
l1axi_kv_dos_q:
	$(VERILATOR) $(VL_FLAGS) --savable $(KV_FULL_DEFS) +define+VEN_DBG_CORE $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_SAVABLE -DVEN_RTC_EXTMEM_KB=64512 -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdosq \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(DOS_PERIPH)
	@echo "built (DOS + 64MiB extmem for Quake): $(CURDIR)/obj_dir_l1axi_kvdosq/$(EXE)"

# ---- l1axi_kv_dos_q_rtlirq: l1axi_kv_dos_q + VEN_RTL_IRQ (the 8254 PIT + 8259 PIC
# moved from the PS C-models INTO the PL/RTL, so the IRQ0 cadence is cycle-deterministic
# and the sim == the board). TICK_DIV (the PIT prescaler) overridable for the cadence
# sweep: make l1axi_kv_dos_q_rtlirq VEN_PIT_TICK_DIV_DEF="+define+VEN_PIT_TICK_DIV=33".
.PHONY: l1axi_kv_dos_q_rtlirq
l1axi_kv_dos_q_rtlirq:
	$(VERILATOR) $(VL_FLAGS) --savable $(KV_FULL_DEFS) +define+VEN_DBG_CORE +define+VEN_RTL_IRQ $(VEN_PIT_TICK_DIV_DEF) $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_RTL_IRQ -DVEN_SAVABLE -DVEN_RTC_EXTMEM_KB=64512 -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdosq_rtlirq \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(DOS_PERIPH)
	@echo "built (RTL-IRQ: in-PL ven_pit/ven_pic, cycle-deterministic IRQ0): $(CURDIR)/obj_dir_l1axi_kvdosq_rtlirq/$(EXE)"

# ---- l1axi_kv_dos_q_rtlirq_fpps: the EXACT deployed FP_PS_ALL=1 RTL_IRQ=1 bitstream
# config. = l1axi_kv_dos_q_rtlirq PLUS the board's FP_PS_ALL area-relief build (the x87
# COMPUTE datapath is REMOVED from the PL and EVERY x87 arithmetic/compare/transcendental
# op is PS-trapped to the A53/SoftFloat via the fptrap seam). Mirrors impl_kv260_soc.tcl
# FP_PS_ALL=1 exactly: ADD VEN_FP_PS_ALL + VEN_FPTRAP, and STRIP the six area-bulk defines
# VEN_TRANSCENDENTAL VEN_FPREM VEN_SRT_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_FP_PIPE2 from
# KV_FULL_DEFS rather than using it wholesale. RTL_IRQ=1 adds BOTH
# VEN_RTL_IRQ and VEN_RTL_IRQ_FIXED (the dense fixed-cycle IR0 = the DOS-Quake #DE fix).
# This is the FP-board-faithful repro: the in-PL-FPU rtlirq sim passed #DE=0 to 13M, but
# the board (FP_PS_ALL) still faults (cs=0x2b eip=0x24e); this build sees if the FP
# divergence is the cause. NOTE: the TB's service_fptrap (-DVEN_FPTRAP) only implements
# FPATAN (atan2l); any other PS-trapped op is serviced as atan2 — a known faithfulness
# gap, reported per-run. Separate obj dir so every other build stays byte-identical.
KV_FPPS_DEFS := $(filter-out +define+VEN_TRANSCENDENTAL +define+VEN_FPREM +define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_SRT_ITER +define+VEN_BCD_ITER,$(KV_FULL_DEFS))
# VL_FLAGS hard-codes +define+VEN_FPREM (shared base, used by every target). FP_PS_ALL
# STRIPS the iterative FPREM engine, so for THIS build the define must be absent —
# filter it out of a target-local copy of the flags (the shared VL_FLAGS is untouched,
# so no other target changes). This is the last of the six FP_PS_ALL-stripped defines.
VL_FLAGS_FPPS := $(filter-out +define+VEN_FPREM,$(VL_FLAGS))
.PHONY: l1axi_kv_dos_q_rtlirq_fpps
l1axi_kv_dos_q_rtlirq_fpps:
	$(VERILATOR) $(VL_FLAGS_FPPS) --savable $(KV_FPPS_DEFS) +define+VEN_FP_PS_ALL +define+VEN_FPTRAP +define+VEN_RTL_IRQ +define+VEN_RTL_IRQ_FIXED +define+VEN_DBG_CORE $(VEN_PIT_TICK_DIV_DEF) $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_RTL_IRQ -DVEN_FPTRAP -DVEN_SAVABLE -DVEN_RTC_EXTMEM_KB=64512 -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdosq_rtlirq_fpps \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(DOS_PERIPH)
	@echo "built (FP_PS_ALL=1 RTL_IRQ=1: x87 compute removed/PS-trapped + fixed-cycle IR0; FP-board-faithful): $(CURDIR)/obj_dir_l1axi_kvdosq_rtlirq_fpps/$(EXE)"

# ---- l1axi_kv_dos_q_xover: l1axi_kv_dos_q + --public-flat-rw (task #102) ------
# IDENTICAL config to l1axi_kv_dos_q, plus Verilator --public-flat-rw so the C++ tb
# can READ and WRITE the core's internal architectural signals directly through the
# Verilated model hierarchy (top->rootp->ventium_top__DOT__u_core__DOT__...). This
# is the state-crossover harness build (--xover-save / --xover-load in tb_main):
# snapshot full arch+mem state at a clean instruction boundary, hand it to the qemu
# oracle for the buggy window, and load the post-state back. NO RTL EDITS — the flag
# alone exposes every signal; the committed RTL stays byte-identical. SEPARATE obj
# dir so l1axi_kv_dos_q and the default build stay untouched. VEN_XOVER arms the
# tb-side hierarchy walkers (compiled in via -DVEN_XOVER).
.PHONY: l1axi_kv_dos_q_xover
l1axi_kv_dos_q_xover:
	$(VERILATOR) $(VL_FLAGS) --savable --public-flat-rw $(KV_FULL_DEFS) +define+VEN_DBG_CORE $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_SAVABLE -DVEN_XOVER -DVEN_RTC_EXTMEM_KB=64512 -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdosq_xover \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(TB_DIR)/xover.cpp $(DOS_PERIPH)
	@echo "built (DOS Quake + public-flat-rw crossover): $(CURDIR)/obj_dir_l1axi_kvdosq_xover/$(EXE)"

# ---- l1axi_kv_dos_q_xover_fp: the crossover build + the IN-RTL x87 transcendental
# engine (+VEN_TRANSCENDENTAL) and the iterative FPREM engine (+VEN_FPREM). The plain
# crossover build HALTs on FSIN (no transcendental engine + no FPTRAP), which Quake's
# per-frame trig hits right after the first blit. VEN_TRANSCENDENTAL routes
# FSIN/FCOS/FSINCOS/FPTAN/F2XM1/FPATAN/FYL2X/FYL2XP1 to the in-RTL iterative engines
# (fpu_fsincos/fpu_f2xm1/fpu_fyl2x), so NO tb-side FP responder + NO RTL edit is needed
# — purely a sim build knob. (TRANSCENDENTAL over-utilizes LUTs on the BOARD, but this
# is a Verilator-only crossover-render harness, so area is irrelevant.) Separate obj dir
# so every other build + `make verify` stays byte-identical.
.PHONY: l1axi_kv_dos_q_xover_fp
l1axi_kv_dos_q_xover_fp:
	$(VERILATOR) $(VL_FLAGS) --savable --public-flat-rw $(KV_FULL_DEFS) \
	  +define+VEN_DBG_CORE +define+VEN_TRANSCENDENTAL +define+VEN_FPREM $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_SAVABLE -DVEN_XOVER -DVEN_RTC_EXTMEM_KB=64512 -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdosq_xover_fp \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(TB_DIR)/xover.cpp $(DOS_PERIPH)
	@echo "built (crossover + in-RTL x87 transcendentals): $(CURDIR)/obj_dir_l1axi_kvdosq_xover_fp/$(EXE)"

# ---- l1axi_kv_dos_q_xover_fpx: the transcendental crossover build with BIT-EXACT
# FDIV/FSQRT. F5 root-cause was FP-divergence: the area-optimized iterative SRT
# divider (+VEN_SRT_ITER) + integer iterative divide (+VEN_IDIV_ITER) are NOT
# bit-exact vs QEMU (the fpu87 gate's fp_div_core fails every vector), so Quake's
# per-frame fdivp diverges -> wrong branch -> null-pointer #PF at cs=00a7:0x30874.
# This target SUBTRACTS those two tokens from KV_FULL_DEFS so the DEFAULT bit-exact
# divider (the one `make verify` proves correct) is used, while keeping
# VEN_TRANSCENDENTAL (still needed for FSIN; its fyl2x is a secondary divergence we
# watch for). Separate obj dir; every other build + `make verify` stays identical.
KV_FULL_DEFS_BITEXACT := $(filter-out +define+VEN_SRT_ITER +define+VEN_IDIV_ITER,$(KV_FULL_DEFS))
.PHONY: l1axi_kv_dos_q_xover_fpx
l1axi_kv_dos_q_xover_fpx:
	$(VERILATOR) $(VL_FLAGS) --savable --public-flat-rw $(KV_FULL_DEFS_BITEXACT) \
	  +define+VEN_DBG_CORE +define+VEN_TRANSCENDENTAL +define+VEN_FPREM $(VL_EXTRA_DEFINES) \
	  -CFLAGS "-DVEN_L1_AXI -DVEN_KV260_SOC -DVEN_DOS_MODELS -DVEN_DBG_CORE -DVEN_SAVABLE -DVEN_XOVER -DVEN_RTC_EXTMEM_KB=64512 -I$(VENTIUM_ROOT)/sw/ps_periph" \
	  -Mdir obj_dir_l1axi_kvdosq_xover_fpx \
	  -F $(RTL_FILELIST) $(L1AXI_RTL) $(CPP_SRCS) $(TB_DIR)/xover.cpp $(DOS_PERIPH)
	@echo "built (crossover + transcendentals + BIT-EXACT FDIV): $(CURDIR)/obj_dir_l1axi_kvdosq_xover_fpx/$(EXE)"

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
	  -CFLAGS "-DVEN_L1_AXI" -Mdir $(L1AXI_CDC_OBJDIR) \
	  -F $(RTL_FILELIST) $(L1AXICDC_RTL) $(CPP_SRCS)
	@echo "built (L1+AXI dual-clock CDC): $(CURDIR)/$(L1AXI_CDC_OBJDIR)/$(EXE)"

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

# ---- cov: Verilator code-coverage build (verif/cov/ coverage suite) ---------
# Builds the SAME core sources + tb_main into a SEPARATE obj dir with Verilator
# line + toggle (+ user/SVA) coverage instrumentation. The instrumented model is
# functionally identical but slower and emits per-run coverage counters; tb_main
# dumps them to $VEN_COV_DAT at exit (VM_COVERAGE-guarded, inert in every other
# build). NEVER clobbers obj_dir/tb_ventium, so `make verify` / every gate keeps
# using the byte-identical default. COV_DEFS lets the runner widen the feature
# set (e.g. +define+VEN_IDIV_ITER) so optionally-instantiated modules light up.
#   make cov && VEN_COV_DAT=run.dat ./obj_dir_cov/tb_ventium --out t.vtrace <image>
COV_DEFS ?=
COV_OBJ ?= obj_dir_cov
COV_CFLAGS ?=
.PHONY: cov
cov:
	@if [ ! -f "$(RTL_FILELIST)" ]; then \
	  echo "ERROR: RTL filelist not found: $(RTL_FILELIST)."; exit 1; \
	fi
	$(VERILATOR) $(VL_FLAGS) --coverage --coverage-line --coverage-toggle \
	  -Wno-DECLFILENAME $(COV_DEFS) $(if $(strip $(COV_CFLAGS)),-CFLAGS "$(COV_CFLAGS)",) -Mdir $(COV_OBJ) \
	  -F $(RTL_FILELIST) $(CPP_SRCS)
	@echo "built (coverage): $(CURDIR)/$(COV_OBJ)/$(EXE)"

# ---- feature-flag coverage variant (in-RTL x87 transcendentals + FPREM) -----
# Same coverage core as `cov`, but with +VEN_TRANSCENDENTAL +VEN_FPREM so the
# opgen TRANSC findings (F2XM1/FSIN/FCOS/... deferred->HALT in the plain build)
# can be confirmed to WORK here -> proving they are feature-gated, not broken.
# Used by verif/cov/opgen/run-transc.sh.
.PHONY: cov-feat
cov-feat:
	$(MAKE) cov COV_OBJ=obj_dir_cov_feat \
	  COV_DEFS="$(COV_DEFS) +define+VEN_TRANSCENDENTAL +define+VEN_FPREM \
	           +define+VEN_BCD_ITER +define+VEN_SRT_ITER"

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
	rm -rf obj_dir obj_dir_selftest obj_dir_sva obj_dir_soc obj_dir_cov
	rm -f selftest.vtrace
