# Ventium top-level build. Targets are wired during M0 integration.
# Paths to the prebuilt QEMU golden harness (in the submodule).
REFS        := ventium-refs/07-p5-emulation-harness
QEMU_I386   := $(REFS)/build/qemu/build/qemu-i386
QEMU_SRC    := $(REFS)/build/qemu
CAPSTONE    := $(REFS)/build/capstone
BUILD       := build

VERILATOR   ?= verilator
PYTHON      ?= python3

.PHONY: all m0-smoke m1 m2 m3 m4 m5 rtl plugin tests clean help
.DEFAULT_GOAL := help

help:
	@echo "Ventium — targets:"
	@echo "  make m0-smoke   build RTL+plugin, gen golden traces, run TB, diff (M0 gate)"
	@echo "  make m1         M1 differential gate: real integer core func-equiv vs QEMU"
	@echo "  make m2         M2 differential gate: user-mode integer ISA completeness vs QEMU"
	@echo "  make m3         M3 differential gate: x87 FPU func-equiv vs QEMU (+ integer suites)"
	@echo "  make m4         M4 cycle gate: dual-issue U/V pipeline cycle-accuracy vs p5model"
	@echo "  make m5         M5 cycle gate: L1 cache-miss + x87/FP cycle accuracy vs p5model"
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

# --- M4 cycle-accuracy gate (verif/run-m4.sh) -------------------------------
# The FIRST cycle-gated milestone. (a) HARD functional regression: make m1,
# make m2, make m3 must all exit 0 (a dual-issue pipeline that breaks functional
# equivalence FAILS M4 — never trade correctness for a cycle match). (b) Cycle
# micro-gate: for each integer microbench (mb_depadd/indepadd/agi/brloop/
# brrandom, built by the corpus agent under verif/tests/) generate the
# p5trace.so golden cycle trace AND the RTL --cycle trace, compare.py --mode
# cycle, and assert the 55-validate-model.sh bands (CPI / pairing% / AGI /
# mispredict%) computed FROM THE RTL TRACE (emergent, not the p5model formula).
# faddchain (FP) is INFO-only (FP cycle = M5). Exit 0 iff functional regression
# green AND every integer kernel meets its band. (run-m4.sh builds the TB + each
# ELF itself and invokes make m1/m2/m3 internally.)
m4:
	bash verif/run-m4.sh

# --- M5 cycle-accuracy gate (verif/run-m5.sh) -------------------------------
# Extends M4 with the two cycle pieces M4 deferred and that the p5model oracle
# CAN differentially verify: (1) L1 cache-miss timing (I$/D$ hit/miss SM with
# the SAME imiss=8/dmiss=8 8KB/2-way/32B geometry p5trace.so uses) and (2) x87/
# FP cycle accuracy (real FP latency/throughput pipe, replacing the M4 serialize
# stall). The pin-level 64-bit bus protocol has NO oracle and is DEFERRED to M5B
# (not built here). The gate: (a) HARD functional regression — make m1/m2/m3
# must all exit 0 (cache/FP timing changes only stall accounting, never
# architectural results); (b) HARD M4 integer bands — the five M4 kernels still
# meet their 55-validate bands from the now-cache-aware RTL; (c) NEW M5 bands —
# mb_faddchain CPI ~3.0 (gated, promoted from M4 INFO), mb_fpindep CPI below the
# faddchain CPI (latency<->throughput), mb_dmiss/mb_imiss miss-driven CPI
# elevation + abs-cyc tracking the golden within the tightened M5_TOL_PCT (10%);
# (d) integer abs-cyc vs golden reported under the tightened tolerance. Exit 0
# iff func green AND M4 bands met AND new M5 bands met. (run-m5.sh builds the TB
# + each ELF itself and invokes make m1/m2/m3 internally.)
m5:
	bash verif/run-m5.sh

clean:
	-$(MAKE) -C verif/tb clean
	-$(MAKE) -C verif/qemu-plugins clean
	-$(MAKE) -C verif/tests clean
	rm -rf $(BUILD)/*.vtrace $(BUILD)/m0 $(BUILD)/m1 $(BUILD)/m2 $(BUILD)/m3 $(BUILD)/m4 $(BUILD)/m5
