# Ventium top-level build. Targets are wired during M0 integration.
# Paths to the prebuilt QEMU golden harness (in the submodule).
REFS        := ventium-refs/07-p5-emulation-harness
QEMU_I386   := $(REFS)/build/qemu/build/qemu-i386
QEMU_SRC    := $(REFS)/build/qemu
CAPSTONE    := $(REFS)/build/capstone
BUILD       := build

VERILATOR   ?= verilator
PYTHON      ?= python3

.PHONY: all m0-smoke m1 m2 m3 m4 m5 m6 bus bus-sva verify verify-clean rtl plugin tests clean help verify-sys verify-soc verify-srt verify-all
.DEFAULT_GOAL := help

help:
	@echo "Ventium — targets:"
	@echo "  make m0-smoke   build RTL+plugin, gen golden traces, run TB, diff (M0 gate)"
	@echo "  make m1         M1 differential gate: real integer core func-equiv vs QEMU"
	@echo "  make m2         M2 differential gate: user-mode integer ISA completeness vs QEMU"
	@echo "  make m3         M3 differential gate: x87 FPU func-equiv vs QEMU (+ integer suites)"
	@echo "  make m4         M4 cycle gate: dual-issue U/V pipeline cycle-accuracy vs p5model"
	@echo "  make m5         M5 cycle gate: L1 cache-miss + x87/FP cycle accuracy vs p5model"
	@echo "  make m6         M6 errata gate: reproduce 4 documented P5 silicon errata behind a flag"
	@echo "  make verify     FAST unified m1-m5 gate (parallel + cached goldens; refactor-time gate)"
	@echo "  make verify-clean  drop the golden cache (forces a cold regen on the next make verify)"
	@echo "  make verify-sys M2S.0 system-mode ORACLE check: build qemu-system, gen + validate the"
	@echo "                  bare-metal protected-mode/paging golden trace (no RTL yet; M2S.1 starts that)"
	@echo "  make verify-srt radix-4 SRT divider gate: fx_srt_div bit-exact vs the golden model"
	@echo "                  (correct PLA == QEMU; buggy PLA == documented Pentium FDIV flaw)"
	@echo "  make verify-soc M8 SoC regression aggregate: run EVERY ventium_soc differential gate"
	@echo "                  (pirqsoc + psocdev + pvga + pide + pboot + pbootdma + test386)"
	@echo "  make verify-all UMBRELLA: every routinely-runnable gate (verify + verify-sys +"
	@echo "                  verify-soc + verify-srt + m6 + bus + bus-sva); one pass/fail summary"
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

# --- M6 errata self-check gate (verif/errata/run-m6.sh) ---------------------
# Reproduces four DOCUMENTED Pentium (P5/P54C) silicon errata behind the core's
# errata-enable flag (DEFAULT OFF) and self-checks each against its documented
# behavior (NOT a differential oracle — QEMU computes the CORRECT result, so the
# errata are verified vs the Intel Specification-Update values): the FDIV/SRT
# divide flaw (Err 23), FIST/FISTP overflow undetected (Err 20/21), the F00F
# LOCK CMPXCHG8B reg-dst hang (Err 81), and the MOV moffs A2/A3 non-pairing
# (Err 59). Each test asserts the documented BUGGY value with the flag ON and
# the CLEAN value with the flag OFF. The HARD complement — `make verify` (errata
# OFF) staying GREEN — is enforced separately by the verify gate. (run-m6.sh
# builds the TB + each ELF itself.)
m6:
	bash verif/errata/run-m6.sh

# --- bus gates --------------------------------------------------------------
# `bus`     = the STANDALONE biu_p5 protocol gate (19 SVA + 76 directed checks).
# `bus-sva` = builds the SVA-assertion-enabled INTEGRATED model and runs the
#   bus_mode=1 corpus through it with the protocol SVA LIVE (closes the review's
#   "build-only rtl-sva can be misread as running the corpus" gap). A program
#   passes only if no biu_p5 assertion fired AND it is func-equivalent vs QEMU.
bus:
	$(MAKE) -C verif/bus run
bus-sva:
	bash verif/bus/run_busmode_sva.sh

# --- FAST unified differential gate (verif/verify.sh) -----------------------
# Reaches the SAME verdict as the slow `make m5` (which supersets m1..m4) — but
# PARALLEL (xargs -P across cores, unique gdbstub ports), CACHED (each program's
# golden generated ONCE into build/golden-cache/, keyed by sha1(.s); a refactor
# changes the RTL but never the .s, so warm runs reuse every golden and only
# rebuild the RTL once + re-trace + re-compare), and with NO redundant 3x func
# re-run (m3 is the func superset; m1/m2 are subsets). The RTL trace is ALWAYS
# freshly regenerated and compared, so the verdict is fully authoritative. This
# is the refactor-time gate R1b uses after every extraction. (verif/verify.sh
# builds the corpus ELFs + TB itself.)
verify:
	bash verif/verify.sh

# --- M2S system-mode gate (verif/sys/run-sys-golden.sh) ---------------------
# For EACH system test this: builds qemu-system-i386 (idempotent), builds the
# bare-metal image, confirms it runs to the isa-debug-exit, generates the
# SYSTEM-state golden .vtrace with gen_trace.py --system, validates it is
# well-formed AND captures the real->protected (CR0.PE 0->1, CS far-jump) [+
# paging (CR3 load, CR0.PG 0->1)] transitions, exercises the compare.py sys-field
# path by self-diffing the golden EQUIVALENT, AND builds the Verilator TB, runs it
# in --system mode on the SAME image, and DIFFS the RTL system trace vs the golden
# (cr0..cr4 + the 6 selectors + GPRs + eflags + eip) — a REAL RTL differential,
# not a golden self-diff. Independent of, and does not touch, the user-mode
# `make verify` gate. ALL FIVE tests below run the REAL RTL --system diff (step 7
# prints RTL-SYS-DIFF-OK); none is golden-self-diff-only / skipped:
#   pseg   (M2S.1) real->PM + flat & based GDT segment loads.
#   pmode  (M2S.2) identity 4 MiB PSE paging, full real->PM->PG->paged-exec.
#   ppage  (M2S.2) NON-identity 4 KiB paging (linear != physical).
#   pintr  (M2S.3) software INT n / INT3 / INTO -> int/trap gate handler -> IRET.
#   pfault (M2S.3) #PF / #GP / #UD hardware faults DELIVERING through the IDT ->
#                  handler -> IRET/restart.
#   pcpl   (M2S.4) TR/TSS + cross-privilege delivery + inter-priv IRET.
#   ptask  (M2S.4) hardware task switch (self-diff + step-5d validation).
#   psmm   (M2S.5) SMM / RSM — a PARTIAL-ORACLE stage. The qemu-system gdbstub
#                  single-step path MASKS SMI and has no SMM awareness, so a
#                  differential golden is INFEASIBLE and is NOT fabricated. Instead
#                  psmm self-checks the SMM round-trip STRUCTURALLY two ways:
#                  (3c) qemu FREE-RUN + QMP physical-memory readback, and (3d) the
#                  RTL SMM mechanism (SMI# -> P5 save-state map @ SMBASE+0xFE00 ->
#                  SMM handler -> RSM -> resume), proven RTL-only via the RTL trace
#                  + the save-map dump at the documented P5 offsets. Differential
#                  part documented + deferred (see tests/psmm/README.md).
# For pintr/pfault step 5b additionally validates the IDT-delivery sequence
# (handler entry + IRET return captured) before the RTL diff.
#   pv86   (M7.2) VIRTUAL-8086 mode: V86 entry (EFLAGS.VM 0->1 + CPL 0->3 + sel<<4
#                 bases) by IRET, V86 segmentation, the IOPL guard (CLI/STI/PUSHF/
#                 POPF/INT n #GP to the CPL0 monitor at IOPL<3 = method-1/VME-OFF),
#                 the 9-word V86 #GP frame on TSS.SS0:ESP0 (VM cleared, DS/ES/FS/GS
#                 zeroed), and the IRET back into V86 — a REAL RTL --system diff vs
#                 the golden (step 5e additionally validates the V86 transitions).
verify-sys:
	bash verif/sys/run-sys-golden.sh pseg
	bash verif/sys/run-sys-golden.sh pmode
	bash verif/sys/run-sys-golden.sh ppage
	bash verif/sys/run-sys-golden.sh pintr
	bash verif/sys/run-sys-golden.sh pfault
	bash verif/sys/run-sys-golden.sh pde
	bash verif/sys/run-sys-golden.sh pcpl
	bash verif/sys/run-sys-golden.sh ptask
	bash verif/sys/run-sys-golden.sh psmm
	bash verif/sys/run-sys-golden.sh pdebug
	PORT=53220 bash verif/sys/run-sys-golden.sh pv86

# M8 SoC regression aggregate — run every ventium_soc differential gate
# (pirqsoc + psocdev + pvga + test386) and report a pass/fail summary. The SoC
# analogue of `make verify`: re-checks the whole self-contained-SoC track after
# any change to rtl/soc/ventium_soc.sv or a wired device model.
verify-soc:
	bash verif/soc/run-all-soc-gates.sh

# --- verify-all umbrella (verif/run-verify-all.sh) --------------------------
# One command that runs EVERY routinely-runnable gate (verify + verify-sys +
# verify-soc + verify-srt + m6 + bus + bus-sva) and reports a single pass/fail
# summary, so a regression in the bus-protocol SVA, the errata flag, or the SRT
# divider cannot slip through by only running the differential aggregates. The
# m7 macro co-sims (Quake/Win95) are EXCLUDED-and-logged: they need gitignored
# producer artifacts that cannot be regenerated from a clean checkout.
verify-all:
	bash verif/run-verify-all.sh

# --- SRT divider gate (verif/srt/run-srt-gate.sh) ---------------------------
# Standalone Verilator unit gate for the genuine radix-4 SRT divider
# (fpu_x87_pkg::fx_srt_div, the optional +define+VEN_SRT_DIV feature). Drives
# golden vectors from the single-source model tools/srt/srt_model.py and asserts
# the RTL is bit-exact for BOTH the correct PLA (== correctly-rounded floatx80 ==
# QEMU) and the buggy PLA (the documented Pentium FDIV flaw, reproduced from
# first principles). Does NOT touch the core/SoC build, so the default `make
# verify`/`verify-soc` tracks are unaffected.
verify-srt:
	bash verif/srt/run-srt-gate.sh

# Drop the golden cache (forces a cold regeneration on the next `make verify`).
verify-clean:
	rm -rf $(BUILD)/golden-cache $(BUILD)/verify
	@echo "verify-clean: dropped $(BUILD)/golden-cache (next 'make verify' is cold)"

clean:
	-$(MAKE) -C verif/tb clean
	-$(MAKE) -C verif/qemu-plugins clean
	-$(MAKE) -C verif/tests clean
	rm -rf $(BUILD)/*.vtrace $(BUILD)/m0 $(BUILD)/m1 $(BUILD)/m2 $(BUILD)/m3 $(BUILD)/m4 $(BUILD)/m5 $(BUILD)/verify
	@echo "clean: (golden cache kept; use 'make verify-clean' to drop $(BUILD)/golden-cache)"
