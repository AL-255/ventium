# ao486-sim — build the Verilator harness around rtl/system.v.
# Run from this dir; verilator is invoked at the repo root so the repo-root-
# relative paths in rtl.f resolve.

REPO   := $(abspath ..)
TOP     := system
OBJDIR  := ao486-sim/obj_dir
EXE     := ao486sim

VERILATOR ?= verilator
DBGFLAGS := $(if $(DBG),--trace +define+AO486_TRACE_EIP,--threads 1)
# Real MiSTer PS software (drives the verilated mgmt bus via ps_shim.cpp).
PS_INC  := -I$(REPO)/ao486-sim/ps
PS_SRCS := ao486-sim/ps/ps_shim.cpp ao486-sim/ps/support/x86/x86.cpp ao486-sim/ps/ide.cpp
VFLAGS := -cc --exe --build -j 0 --savable \
          --top-module $(TOP) -o $(EXE) -Mdir $(OBJDIR) \
          -O3 -CFLAGS "-O2 -std=c++17 $(PS_INC)" \
          -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
          -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-CMPCONST -Wno-MULTIDRIVEN \
          -Wno-LATCH -Wno-BLKANDNBLK -Wno-SELRANGE -Wno-IMPLICIT -Wno-PINMISSING $(DBGFLAGS)

all:
	cd $(REPO) && $(VERILATOR) $(VFLAGS) -f ao486-sim/rtl.f ao486-sim/sim_main.cpp $(PS_SRCS)

run: all
	$(REPO)/$(OBJDIR)/$(EXE) --cycles 400000

clean:
	rm -rf $(OBJDIR)

.PHONY: all run clean
