# ao486-sim — build the Verilator harness around rtl/system.v.
# Run from this dir; verilator is invoked at the repo root so the repo-root-
# relative paths in rtl.f resolve.

REPO   := $(abspath ..)
TOP     := system
OBJDIR  := ao486-sim/obj_dir
EXE     := ao486sim

VERILATOR ?= verilator
DBGFLAGS := $(if $(DBG),--trace +define+AO486_TRACE_EIP,$(if $(FAST),+define+AO486_TRACE_EIP --threads 1,--threads 1))
# Real MiSTer PS software (drives the verilated mgmt bus via ps_shim.cpp).
PS_INC  := -I$(REPO)/ao486-sim/ps
PS_SRCS := ao486-sim/ps/ps_shim.cpp ao486-sim/ps/support/x86/x86.cpp ao486-sim/ps/ide.cpp ao486-sim/ps/x87_cosim.cpp
VFLAGS := -cc --exe --build -j 0 --savable \
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
VEN_DEFS := +define+VEN_CORE +define+VEN_L1_AXI +define+VEN_L1_HONOR_CD \
  +define+VEN_KV260_SOC +define+VEN_TRANSCENDENTAL +define+VEN_SRT_ITER \
  +define+VEN_IDIV_ITER +define+VEN_BCD_ITER +define+VEN_FP_PIPE \
  +define+VEN_FPREM +define+VEN_BTB_PIPE +define+VEN_IC_NARROWB \
  +define+VEN_DBG_CORE +define+VEN_FAST_RETRACE +define+VEN_KBD_AUTOACK \
  +define+VEN_KBC_FAST
VEN_SRCS := ao486-sim/ven/sim_ven.cpp ao486-sim/ven/vtm_dpi.cpp \
  ao486-sim/ven/ven_ao486_shim.sv ao486-sim/ven/ven_axi2avalon.sv \
  ao486-sim/ps/ps_shim.cpp ao486-sim/ps/support/x86/x86.cpp ao486-sim/ps/ide.cpp
ven:
	cd $(REPO) && $(VERILATOR) $(VFLAGS) \
	  -Mdir ao486-sim/obj_dir_ven -o ao486sim_ven $(VEN_DEFS) \
	  -f rtl_ven_core.f -f rtl_ven_soc.f $(VEN_SRCS)
	@echo "built (ventium-swapped cosim): $(REPO)/ao486-sim/obj_dir_ven/ao486sim_ven"
	@echo "run from the ao486-sim/ CWD (the BIOS ROMs load via ../3rd-party paths)."

run: all
	$(REPO)/$(OBJDIR)/$(EXE) --cycles 400000

clean:
	rm -rf $(OBJDIR)

.PHONY: all ven run clean
