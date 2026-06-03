# Ventium top-level build. Targets are wired during M0 integration.
# Paths to the prebuilt QEMU golden harness (in the submodule).
REFS        := ventium-refs/07-p5-emulation-harness
QEMU_I386   := $(REFS)/build/qemu/build/qemu-i386
QEMU_SRC    := $(REFS)/build/qemu
CAPSTONE    := $(REFS)/build/capstone
BUILD       := build

VERILATOR   ?= verilator
PYTHON      ?= python3

.PHONY: all m0-smoke m1 m2 m3 rtl plugin tests clean help
.DEFAULT_GOAL := help

help:
	@echo "Ventium — targets:"
	@echo "  make m0-smoke   build RTL+plugin, gen golden traces, run TB, diff (M0 gate)"
	@echo "  make m1         M1 differential gate: real integer core func-equiv vs QEMU"
	@echo "  make m2         M2 differential gate: user-mode integer ISA completeness vs QEMU"
	@echo "  make m3         M3 differential gate: x87 FPU func-equiv vs QEMU (+ integer suites)"
	@echo "  make rtl        verilate + build the RTL testbench"
	@echo "  make plugin     build the QEMU cycle-trace plugin"
	@echo "  make tests      build the test corpus binaries"
	@echo "  make clean      remove build artifacts"

# --- RTL + Verilator testbench (verif/tb owns the build fragment) -----------
rtl:
	$(MAKE) -C verif/tb

# --- QEMU cycle-trace plugin (verif/qemu-plugins owns its build) ------------
plugin:
	$(MAKE) -C verif/qemu-plugins QEMU_SRC=$(abspath $(QEMU_SRC)) CAPSTONE=$(abspath $(CAPSTONE))

# --- test corpus ------------------------------------------------------------
tests:
	$(MAKE) -C verif/tests

# --- M0 end-to-end smoke (filled in by verif/run-m0-smoke.sh) ---------------
m0-smoke: rtl plugin tests
	bash verif/run-m0-smoke.sh

# --- M1 differential gate (verif/run-m1.sh) ---------------------------------
# Builds the corpus + RTL TB, then for every program (smoke + M1 tests,
# discovered from verif/tests/**/manifest.json) generates the QEMU golden, runs
# the RTL TB, and asserts compare.py --mode func exits 0. (run-m1.sh builds the
# corpus + TB itself, so no prereqs are needed beyond a working toolchain.)
m1:
	bash verif/run-m1.sh

# --- M2 differential gate (verif/run-m2.sh) ---------------------------------
# Extends M1 to user-mode integer ISA completeness. Builds the RTL TB, then for
# every program (smoke + t_* + the new M2 programs, discovered from
# verif/tests/**/manifest.json) builds the ELF generically, ISA-verifies it,
# flattens it, generates the QEMU golden, runs the RTL TB, and asserts
# compare.py --mode func exits 0. (run-m2.sh builds the TB + each ELF itself.)
m2:
	bash verif/run-m2.sh

# --- M3 differential gate (verif/run-m3.sh) ---------------------------------
# Adds the x87 FPU. Builds the RTL TB, then for every program (integer + x87,
# discovered from verif/tests/**/manifest.json) builds the ELF, ISA-verifies,
# flattens, generates the QEMU golden, runs the RTL TB, and asserts compare.py
# --mode func exits 0. x87 programs (manifest "x87":true) run BOTH producers
# with --x87 so the x87 architectural state (st0..st7, fctrl, fstat, ftag) is
# compared; integer programs stay x87:false and are unaffected. (run-m3.sh
# builds the TB + each ELF itself.)
m3:
	bash verif/run-m3.sh

clean:
	-$(MAKE) -C verif/tb clean
	-$(MAKE) -C verif/qemu-plugins clean
	-$(MAKE) -C verif/tests clean
	rm -rf $(BUILD)/*.vtrace $(BUILD)/m0 $(BUILD)/m1 $(BUILD)/m2 $(BUILD)/m3
