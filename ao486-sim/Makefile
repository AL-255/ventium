# ao486-sim — build the Verilator harness around rtl/system.v.
# Run from this dir; verilator is invoked at the repo root so the repo-root-
# relative paths in rtl.f resolve.

REPO   := $(abspath ..)
TOP     := system
OBJDIR  := ao486-sim/obj_dir
EXE     := ao486sim

# Full-PC C++ compilation is multi-GiB.  Share the project-wide lock with the
# verification and shared-FP builds; choose a different frontend through
# VENTIUM_VERILATOR_BIN rather than bypassing the guard.
VERILATOR_BIN ?= verilator
VENTIUM_VERILATOR_BIN ?= $(VERILATOR_BIN)
# Recursive make command-line variables must not bypass the common guard.
override VERILATOR := $(REPO)/tools/verilator_serial.sh
export VENTIUM_VERILATOR_BIN
# This harness is frequently built from external/scratch volumes.  Do not let
# an unavailable shared ccache fail the generated-C++ build; callers can opt
# back in with CCACHE_DISABLE=0 when their cache is writable.
CCACHE_DISABLE ?= 1
export CCACHE_DISABLE
# Full-PC generated C++ is memory-heavy.  Do not use Verilator's `-j 0` (all
# host cores): it can start enough cc1plus processes to OOM the workstation.
# The portable/default build stays single-threaded. The explicitly named,
# cgroup-bounded IPC profiles can use their reviewed compiler limits. Fine
# splitting is mandatory in the 32-job profile; the wrapper independently
# enforces it for callers that bypass this Makefile.
ifeq ($(VENTIUM_BUILD_SCOPE_PROFILE),ipc_parallel32)
  VERILATOR_BUILD_JOBS ?= 32
  ifneq ($(filter-out $(shell seq 1 32),$(VERILATOR_BUILD_JOBS)),)
    $(error VERILATOR_BUILD_JOBS must be 1..32 in ipc_parallel32)
  endif
  VERILATOR_SPLIT ?= --output-groups 0 --output-split 3000 --output-split-cfuncs 3000
else ifeq ($(VENTIUM_BUILD_SCOPE_PROFILE),ipc_parallel)
  VERILATOR_BUILD_JOBS ?= 4
  ifneq ($(filter-out 1 2 3 4,$(VERILATOR_BUILD_JOBS)),)
    $(error VERILATOR_BUILD_JOBS must be 1..4 in ipc_parallel)
  endif
  VERILATOR_SPLIT ?= --output-groups 0 --output-split 20000 --output-split-cfuncs 20000
else
  override VERILATOR_BUILD_JOBS := 1
  VERILATOR_SPLIT ?= --output-groups 0 --output-split 20000 --output-split-cfuncs 20000
endif
# `--output-split` alone only makes included fragments; an aggregate
# `V*_vm_classes_0.cpp` can still consume several GiB at host-compiler time.
# Ungroup the generated classes as well, preserving the -O3 simulation model
# while keeping the one permitted compiler job bounded.
# A caller may request `make -j all ven`; those are two independent full-system
# Verilator builds and must never overlap.  Serialise this makefile even under a
# command-line jobserver.  This does not coordinate with or preempt FPGA tools.
.NOTPARALLEL:
DBGFLAGS := $(if $(DBG),--trace +define+AO486_TRACE_EIP,$(if $(FAST),+define+AO486_TRACE_EIP --threads 1,--threads 1))
# Real MiSTer PS software (drives the verilated mgmt bus via ps_shim.cpp).
PS_INC  := -I$(REPO)/ao486-sim/ps
PS_SRCS := ao486-sim/ps/ps_shim.cpp ao486-sim/ps/support/x86/x86.cpp ao486-sim/ps/ide.cpp ao486-sim/ps/x87_cosim.cpp
VFLAGS := -cc --exe --build -j $(VERILATOR_BUILD_JOBS) $(VERILATOR_SPLIT) --savable \
          --top-module $(TOP) \
          -O3 -CFLAGS "-O2 -std=c++17 $(PS_INC)" \
          -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
          -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-CMPCONST -Wno-MULTIDRIVEN \
          -Wno-LATCH -Wno-BLKANDNBLK -Wno-SELRANGE -Wno-IMPLICIT -Wno-PINMISSING $(DBGFLAGS)

all:
	cd $(REPO) && $(VERILATOR) $(VFLAGS) -o $(EXE) -Mdir $(OBJDIR) -f ao486-sim/rtl.f ao486-sim/sim_main.cpp $(PS_SRCS)

# ---- ven: the Ventium-swapped full-PC cosim ----------------------------------
# system.v instantiates ven_ao486_shim (the Ventium core with the exact ao486
# port list) under +define+VEN_CORE; the legacy build above is untouched.
# Sources/defines per the recovered recipe in DISK_BOOT_STATUS.md: the root
# filelists (repo-root relative) + the ven main/DPI + the shared PS, keeping
# DPI (retire trace) and adding VEN_KV260_SOC for the shim's observability
# and interrupt pins.
# The full-PC default follows fpga/create_project_3mhz_wrapper.tcl's routed
# production profile: the P5's full 8 KiB/2-way/32-byte-line I$ and D$,
# BRAM-backed I-cache reads, and the uop cache.  Keep the system fast-path
# defines here as well: validating a different execution profile than the bitstream
# would make performance and boot evidence non-actionable.  VEN_CACHE_HALF and
# VEN_IC_NARROWB are retired congestion experiments and must never appear here.
VEN_DEFS := +define+VEN_CORE +define+VEN_L1_AXI +define+VEN_L1_HONOR_CD \
  +define+VEN_KV260_SOC +define+VEN_TRANSCENDENTAL +define+VEN_SRT_ITER \
  +define+VEN_IDIV_ITER +define+VEN_BCD_ITER +define+VEN_FP_PIPE \
  +define+VEN_FP_PIPE2 +define+VEN_FP_PC_RELAX +define+VEN_FP_SHARED +define+VEN_FP_SHARED_DIRECT \
  +define+VEN_FPREM +define+VEN_BTB_PIPE +define+VEN_IC_BRAM +define+VEN_UOPCACHE +define+VEN_UOP_SFETCH +define+VEN_SFETCH_RESIDENT +define+VEN_UOP_TAIL_LOCAL \
  +define+VEN_DBG_CORE +define+VEN_SYS_FASTPATH +define+VEN_SYS_FASTPATH_RELOC \
  +define+VEN_SYS_FASTLOAD_FLAT +define+VEN_SYS_FASTLOAD_BOUNDED \
  +define+VEN_SYS_FASTSTORE_FLAT +define+VEN_FAST_MEM_ADD +define+VEN_FAST_MOFFS_STORE \
  +define+VEN_FAST_RETRACE +define+VEN_PIPE_MEM_CHAIN \
  +define+VEN_PIPE_REG_LOAD_PRIME +define+VEN_KBD_AUTOACK \
  +define+VEN_KBC_FAST
VEN_SRCS := ao486-sim/ven/sim_ven.cpp ao486-sim/ven/vtm_dpi.cpp \
  ao486-sim/ven/ven_ao486_shim.sv ao486-sim/ven/ven_axi2avalon.sv \
  ao486-sim/ps/ps_shim.cpp ao486-sim/ps/support/x86/x86.cpp ao486-sim/ps/ide.cpp
VEN_OBJDIR ?= ao486-sim/obj_dir_ven
VEN_EXE ?= ao486sim_ven
# Keep the checked performance profiles explicit at invocation time.  The default
# remains the conservative full-system build; a run that enables an experiment
# must name its extra defines and use a separate object directory/executable.
VEN_EXTRA_DEFS ?=
ven:
	cd $(REPO) && $(VERILATOR) $(VFLAGS) \
	  -LDFLAGS "-lz" \
	  -Mdir $(VEN_OBJDIR) -o $(VEN_EXE) $(VEN_DEFS) $(VEN_EXTRA_DEFS) \
	  -f rtl_ven_core.f -f rtl_ven_soc.f $(VEN_SRCS)
	@echo "built (ventium-swapped cosim): $(REPO)/$(VEN_OBJDIR)/$(VEN_EXE)"
	@echo "run from the ao486-sim/ CWD (the BIOS ROMs load via ../3rd-party paths)."

# Exact effective-define inventory of the measured 229c4cd5 gameplay binary
# (obj_dir_p54_structural_sep27/model/Vsystem__verFiles.dat).  This is separate
# from the conservative `ven` target: in particular, the ao486 DDR backend was
# already qualified with a single fill and downstream critical-word streaming.
# Accidentally falling back to `ven` doubles cache-line reads and would make a
# new gameplay IPC comparison meaningless. Keep the measured set frozen here;
# new experiments belong in VEN_IPC_DEFS below.
VEN_GAMEPLAY_229C_DEFS := +define+VEN_AO486_SINGLE_FILL +define+VEN_BCD_ITER \
  +define+VEN_BTB_PIPE +define+VEN_CORE +define+VEN_DBG_CORE \
  +define+VEN_DTLB_ASSOC_2WAY +define+VEN_FAST_MEM_ADC \
  +define+VEN_FAST_MEM_ADD +define+VEN_FAST_MEM_ADD7 \
  +define+VEN_FAST_MEM_ALU +define+VEN_FAST_MEM_MOV7 \
  +define+VEN_FAST_MOFFS_STORE +define+VEN_FAST_RETRACE \
  +define+VEN_FPREM +define+VEN_FP_ARITH_FWD +define+VEN_FP_ARITH_STREAM \
  +define+VEN_FP_ASYNC +define+VEN_FP_ASYNC_BRANCH \
  +define+VEN_FP_ASYNC_EARLY +define+VEN_FP_ASYNC_MEM \
  +define+VEN_FP_ASYNC_STREAM +define+VEN_FP_FXCH_QUEUE \
  +define+VEN_FP_LOAD64 +define+VEN_FP_LOAD_EARLY_CMD \
  +define+VEN_FP_MEM_ADMIT +define+VEN_FP_MEM_LOADS \
  +define+VEN_FP_MEM_QUEUE +define+VEN_FP_MISC_EARLY_DONE \
  +define+VEN_FP_OPERAND_OVERLAP +define+VEN_FP_PC_RELAX \
  +define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_FP_REG_ADMIT \
  +define+VEN_FP_SHARED +define+VEN_FP_SHARED_DIRECT \
  +define+VEN_FP_SHARED_EARLY_CMD +define+VEN_IC_BRAM \
  +define+VEN_IDIV_ITER +define+VEN_KBC_FAST +define+VEN_KBD_AUTOACK \
  +define+VEN_KV260_SOC +define+VEN_L1D_FILL_FORWARD \
  +define+VEN_L1D_HIT_UNDER_FILL +define+VEN_L1D_PERF \
  +define+VEN_L1D_TAG_INVALIDATE +define+VEN_L1D_WINDOW_KEEP_STORE \
  +define+VEN_L1D_WINDOW_REUSE +define+VEN_L1_AXI \
  +define+VEN_L1_HONOR_CD +define+VEN_L2_PERF +define+VEN_L2_STREAM_ANY \
  +define+VEN_L2_STREAM_CWF +define+VEN_LOAD_USE_FORWARD \
  +define+VEN_PERF_PROFILE +define+VEN_PIPE_MEM_CHAIN \
  +define+VEN_PIPE_SDECODE +define+VEN_REP_MOVS_CONT \
  +define+VEN_REP_MOVS_LOAD_FUSE +define+VEN_REP_MOVS_STREAM \
  +define+VEN_SEG_ENFORCE +define+VEN_SFETCH_RESIDENT \
  +define+VEN_SLOWOP_PERF +define+VEN_SRT_ITER \
  +define+VEN_STORE_DISPATCH +define+VEN_SYS_FASTLOAD_BOUNDED \
  +define+VEN_SYS_FASTLOAD_FLAT +define+VEN_SYS_FASTPATH \
  +define+VEN_SYS_FASTPATH_RELOC +define+VEN_SYS_FASTSTORE_FLAT \
  +define+VEN_TRANSCENDENTAL +define+VEN_UOPCACHE \
  +define+VEN_UOPCACHE_CHECK +define+VEN_UOP_16_SLOTS \
  +define+VEN_UOP_CROSS2 +define+VEN_UOP_CROSSLINE \
  +define+VEN_UOP_CROSSPAIR +define+VEN_UOP_CROSS_INDEX \
  +define+VEN_UOP_EXEC_REPAIR +define+VEN_UOP_FWAIT_FETCH \
  +define+VEN_UOP_FWAIT_HINT +define+VEN_UOP_REPAIR_FAIR \
  +define+VEN_UOP_SFETCH +define+VEN_UOP_TAIL_LOCAL \
  +define+VEN_VGA_FULL_STORE_SETUP +define+VEN_VGA_WIDE_STORE

.PHONY: ven-gameplay-base
ven-gameplay-base:
	cd $(REPO) && $(VERILATOR) $(VFLAGS) \
	  -LDFLAGS "-lz" \
	  -Mdir ao486-sim/obj_dir_ven_gameplay_base -o ao486sim_ven_gameplay_base \
	  $(VEN_GAMEPLAY_229C_DEFS) \
	  -f rtl_ven_core.f -f rtl_ven_soc.f $(VEN_SRCS)
	@echo "built matched-source gameplay base: $(REPO)/ao486-sim/obj_dir_ven_gameplay_base/ao486sim_ven_gameplay_base"

# IPC development candidate: the exact measured gameplay profile plus only
# these new structural cache/dual-load options. Native snapshots of the older
# binary are incompatible; qualification must cold-boot private disk copies.
# This does not change `ven` or claim the new options are FPGA-routed.
VEN_IPC_DEFS := +define+VEN_L1D_BANKED_DATA +define+VEN_L1D_BANK0_SHARED_XLINE \
  +define+VEN_L1D_CODE_BUFFER +define+VEN_L1D_CODE_STREAM \
  +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_P54_DUAL_HIT \
  +define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_P54_DUAL_LOAD_PAIR \
  +define+VEN_P54_DUAL_LOAD_PRIME +define+VEN_PIPE_BRANCH_LOAD_PRIME \
  +define+VEN_PIPE_REG_LOAD_PRIME
.PHONY: ven-ipc
ven-ipc:
	cd $(REPO) && $(VERILATOR) $(VFLAGS) \
	  -LDFLAGS "-lz" \
	  -Mdir ao486-sim/obj_dir_ven_ipc -o ao486sim_ven_ipc \
	  $(VEN_GAMEPLAY_229C_DEFS) $(VEN_IPC_DEFS) \
	  -f rtl_ven_core.f -f rtl_ven_soc.f $(VEN_SRCS)
	@echo "built IPC candidate: $(REPO)/ao486-sim/obj_dir_ven_ipc/ao486sim_ven_ipc"

run: all
	$(REPO)/$(OBJDIR)/$(EXE) --cycles 400000

clean:
	rm -rf $(OBJDIR)

ven-state-profiler:
	cd $(REPO) && tools/build_scope.sh -- python3 tools/build_state_delta.py $(VEN_OBJDIR)

.PHONY: all ven ven-state-profiler run clean
