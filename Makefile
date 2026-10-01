# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium top-level build. Targets are wired during M0 integration.
# Paths to the prebuilt QEMU golden harness (in the submodule).
REFS        := ventium-refs/07-p5-emulation-harness
QEMU_I386   := $(REFS)/build/qemu/build/qemu-i386
QEMU_SRC    := $(REFS)/build/qemu
CAPSTONE    := $(REFS)/build/capstone
BUILD       := build

VERILATOR   ?= verilator
PYTHON      ?= python3
# The shared ccache directory is not guaranteed writable (for example, this
# checkout's external build volume may be mounted read-only).  A failed cache
# write must never prevent a functional gate from compiling.  Callers with a
# provisioned writable cache can explicitly opt back in with CCACHE_DISABLE=0.
CCACHE_DISABLE ?= 1
export CCACHE_DISABLE

.PHONY: all m0-smoke m1 m2 m3 m4 m5 m6 a20 fenv fpstore x87stk x87b l1 bus bus-sva issue-uv verify verify-clean rtl plugin tests clean help verify-sys verify-sys-fpreloc verify-sys-fpload verify-sys-faststore verify-srt verify-srt-iter verify-idiv verify-bcd verify-fbld verify-fppipe verify-fppipe2 verify-all coverage coverage-sys coverage-mem coverage-unit coverage-all opgen opgen-modes
.DEFAULT_GOAL := help

# A top-level `make -j` used to overlap independent heavyweight recipes.  The
# individual builders have their own cgroup/lock guard, but serialising this
# layer prevents non-Verilator helpers from forming a second process storm.
.NOTPARALLEL:

help:
	@echo "Ventium — targets:"
	@echo "  make m0-smoke   build RTL+plugin, gen golden traces, run TB, diff (M0 gate)"
	@echo "  make m1         M1 differential gate: real integer core func-equiv vs QEMU"
	@echo "  make m2         M2 differential gate: user-mode integer ISA completeness vs QEMU"
	@echo "  make m3         M3 differential gate: x87 FPU func-equiv vs QEMU (+ integer suites)"
	@echo "  make m4         M4 cycle gate: dual-issue U/V pipeline cycle-accuracy vs p5model"
	@echo "  make m5         M5 cycle gate: L1 cache-miss + x87/FP cycle accuracy vs p5model"
	@echo "  make m6         M6 errata gate: reproduce 4 documented P5 silicon errata behind a flag"
	@echo "  make issue-uv   decoder + U/V pairer regression for ESP RAW dependencies"
	@echo "  make verify     FAST unified m1-m5 gate (parallel + cached goldens; refactor-time gate)"
	@echo "  make verify-clean  drop the golden cache (forces a cold regen on the next make verify)"
	@echo "  make verify-sys M2S.0 system-mode ORACLE check: build qemu-system, gen + validate the"
	@echo "                  bare-metal protected-mode/paging golden trace (no RTL yet; M2S.1 starts that)"
	@echo "  make verify-sys-faststore  QEMU-diff precise system MOV-store #PF/restart + S_PIPE gate"
	@echo "  make verify-srt radix-4 SRT divider gate: fx_srt_div bit-exact vs the golden model"
	@echo "  make verify-srt-iter  iterative (1-step/clk) SRT divider engine: bit-exact vs the golden"
	@echo "                  (correct PLA == QEMU; buggy PLA == documented Pentium FDIV flaw)"
	@echo "  make x87b       x87 deferred-op boundary gate (REVIEW2 M-09)"
	@echo "  make a20        A20 gate: 1 MiB alias wrap via port 0x92 (REVIEW2 M-03)"
	@echo "  make fenv       x87 env gate: FNSTENV masks all exceptions (REVIEW2 M-01)"
	@echo "  make fpstore    x87 write-protect precision gate: FISTP must not pop before #PF"
	@echo "  make x87stk     x87 stack-fault matrix gate, 4 TB variants + the A4-H01 TR"
	@echo "                  variant (REVIEW1_Aug3 R2-H06 + REVIEW_Aug4 A4-H01)"
	@echo "  make l1         all L1/TLB/BTB/AXI memory-subsystem unit gates (auto-discovered)"
	@echo "  make verify-all UMBRELLA: every routinely-runnable gate (verify + verify-sys +"
	@echo "                  verify-srt + m6 + x87b + a20 + fenv + l1 + bus + bus-sva); one pass/fail summary"
	@echo "  make coverage   Verilator code-coverage + ISA-execution gate: run the full"
	@echo "                  user-mode ISA suite through a --coverage core build, report"
	@echo "                  line/toggle % per file + the executed-opcode histogram +"
	@echo "                  the first UNIMPLEMENTED/diverging instruction per test"
	@echo "  make coverage-sys  system-mode coverage: bare-metal images (--system) light"
	@echo "                  up the privileged paths (int/IRET/seg/TSS/SMM/paging/TLB)"
	@echo "  make coverage-mem  dedicated MEMORY-subsystem coverage (ven_l1d/axi/l2 TBs)"
	@echo "  make coverage-unit optional engine coverage (idiv/srt/sqrt/bcd + biu_p5)"
	@echo "  make coverage-all  every lane + the combined CORE (ISA+SYS) headline"
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
# LOCK CMPXCHG8B reg-dst hang (Err 81), and the erroneous V86 POPF/IRET #DB
# (Err 79). MOV moffs A2/A3 non-pairing (Err 59) is NOT reproduced: its model was
# withdrawn when REVIEW_Jul29 H-02 disabled the corrupt moffs fast-path arm, and
# errata_en[ERR_MOFFS] is now inert -- check 4 only guards that withdrawal (see
# task #72). Each reproduced test asserts the documented BUGGY value with the flag ON and
# the CLEAN value with the flag OFF. The HARD complement — `make verify` (errata
# OFF) staying GREEN — is enforced separately by the verify gate. (run-m6.sh
# builds the TB + each ELF itself.)
m6:
	bash verif/errata/run-m6.sh

# --- x87 deferred-op boundary gate (verif/tests/run_x87_boundary.sh) --------
# REVIEW2 M-09. tx_deferred_halt is the 99th corpus program and is DELIBERATELY kept
# out of the differential gate (QEMU executes FSIN, the RTL must HALT, so the
# length mismatch would read as a divergence). Its manifest delegates coverage to
# this script -- which NOTHING invoked, so the program was covered by nothing at all.
# Same shape as the 12 L1 gates that were absent from verify-all: an advertised gate
# that exists, passes, and is never run.
x87b:
	bash verif/tests/run_x87_boundary.sh

# --- A20 gate (verif/sys/run-a20-gate.sh) -----------------------------------
# REVIEW2 M-03. Exercises the 1 MiB alias wrap through a real-mode seg:off above
# 1 MiB (ES=0xFFFF:0x0510) with A20 enabled and then disabled via port 0x92. Carries
# its own control (A20 enabled must keep the addresses DISTINCT) so a pass cannot be
# produced by a build that masks unconditionally.
a20:
	bash verif/sys/run-a20-gate.sh

# --- segment-limit gate (verif/sys/run-seg-gate.sh) -------------------------
# REVIEW2_Aug1 C-06. Per-access segment LIMIT enforcement. This CANNOT be a
# differential test: QEMU does not enforce segment limits at all (measured --
# pseglim exits 133 there, i.e. its #GP counter stayed 0), so a diff would fail
# exactly when Ventium is correct. Two assertions: the violating access raises
# exactly ONE #GP(0) and the program completes (ecx==1), and the check rejects
# NOTHING across all 19 system tests. The second is the one that matters: this
# finding's delivery was reverted twice for shipping false positives.
# Builds its own objdir with +define+VEN_SEG_ENFORCE; the default build is
# unchanged (see core_fetch_decode.svh for why enforcement is not yet default).
.PHONY: seg
seg:
	@$(MAKE) -s -C verif/sys/tests/pcslim
	bash verif/sys/run-seg-gate.sh

# --- x87 environment gate (verif/sys/run-fenv-gate.sh) ----------------------
# REVIEW2 M-01. Asserts that FNSTENV MASKS ALL x87 exceptions after storing the
# environment (SDM Vol.2). This CANNOT be a differential test: the default CW 0x037F
# already has bits[5:0] set, so the behaviour is unreachable on the existing corpus,
# and QEMU does not implement the masking at all -- a diff would fail exactly when
# Ventium is correct. The test clears the mask bits first and checks against the SDM.
fenv:
	bash verif/sys/run-fenv-gate.sh

# --- x87 destination-store precision gate (verif/sys/run-pfpstore-gate.sh) --
# A shared FPU irrevocably owns x87 state when it accepts a command.  A memory
# destination must therefore be proven writable, not merely readable, before
# accepting FISTP/FSTP/FNSAVE/FNSTENV.  This page-protected FISTP regression
# checks the P|W #PF error and restart result, so an early stack pop cannot hide.
.PHONY: fpstore
fpstore:
	bash verif/sys/run-pfpstore-gate.sh

# --- x87 stack-fault gate (verif/sys/run-x87stk-gate.sh) ---------------------
# REVIEW1_Aug3 R2-H06. The full stack-fault matrix (7 faulting shapes x
# {masked,unmasked} + FXAM-on-empty control) in one BIOS image. Self-checked
# against the SDM -- QEMU 8.2.2 implements NO x87 stack faults, so no golden is
# possible. Graded by final-record witnesses + faultlog on the functional run
# and by PC-stream identity on the cycle/FP_PIPE/FP_PIPE2 variants.
x87stk:
	bash verif/sys/run-x87stk-gate.sh

# --- IDT gate offset vs CS limit (verif/sys/run-intlim-gate.sh) --------------
# REVIEW2_aug2 C-03. A gate whose offset lies beyond the destination CS limit must be
# rejected during DELIVERY, before CS/CPL are installed. Deliberately NOT differential:
# both a fixed and a broken core end up taking a #GP, so the presence of a fault proves
# nothing -- the first draft of this test passed with the fix reverted for exactly that
# reason. The assertion is the SAVED CS on the #GP frame, which names where the fault
# was taken. Verified to FAIL against a build with the limit compare removed.
.PHONY: intlim
intlim:
	@$(MAKE) -s -C verif/sys/tests/pintlim
	bash verif/sys/run-intlim-gate.sh

# --- truncated TSS / cross-priv delivery (verif/sys/run-tsslim-gate.sh) ------
# REVIEW2_aug2 C-03, fifth bullet + the CPL half of the first. A cross-privilege
# delivery must bound the TSS.ssN:espN read against tr_limit and raise #TS -- and that
# #TS must be classified at the ORIGINAL privilege. tr_valid/tr_limit previously sat in
# a lint sink, consumed by nothing. Both a fixed and a broken core complete, so the
# witness names WHICH handler ran rather than whether a fault occurred. Verified to
# FAIL against the pre-fix build.
.PHONY: tsslim
tsslim:
	@$(MAKE) -s -C verif/sys/tests/ptsslim
	bash verif/sys/run-tsslim-gate.sh

# --- far RETF selector bounds (verif/sys/run-retfsel-gate.sh) ----------------
# REVIEW2_aug2 H-07. Far CALL/RETF reach S_LJMP after stack activity and had no
# null/TI/table-limit test, so the popped CS -- the least trustworthy selector in the
# core -- indexed the GDT unchecked. NOT differential. The pre-fix core raises no
# fault at all and stalls at the LRET, so an ABSENT witness fails.
.PHONY: retfsel
retfsel:
	@$(MAKE) -s -C verif/sys/tests/pretfsel
	bash verif/sys/run-retfsel-gate.sh

# --- far CALL selector before the push (verif/sys/run-callsel-gate.sh) -------
# REVIEW2_aug2 C-06, selector half. Witness is the ESP DELTA across the fault:
# 0x0CA10000 = stack untouched, 0x0CA10008 = CS:next_eip already pushed.
.PHONY: callsel
callsel:
	@$(MAKE) -s -C verif/sys/tests/pcallsel
	@$(MAKE) -s -C verif/sys/tests/pcalldesc
	bash verif/sys/run-callsel-gate.sh

# --- R2-C03 page-crossing fragment-engine correctness (verif/sys/run-xc04-gate.sh)
# Was the REVIEW2_aug2 C-04 reachability pin (PASSED only while the six non-split
# producers $fatal'd). The generic fragment engine landed, so the gate is now a
# CORRECTNESS gate: each producer's crossing must complete differentially clean
# vs QEMU (witnesses + RTL sys-diff), and the PAGING/C-04 fatal must never fire.
# Currently RED on pxc04 (S_LGDT read): the engine's read fragment-2 walk runs
# with the read-merge armed, corrupting walk_pde (see the gate header). Kept
# XFAIL-PINNED in verify-all until the RTL fix lands.
.PHONY: xc04
xc04:
	@$(MAKE) -s -C verif/sys/tests/pxc04
	@$(MAKE) -s -C verif/sys/tests/pxc04i
	@$(MAKE) -s -C verif/sys/tests/pxc04f
	@$(MAKE) -s -C verif/sys/tests/pxc04e
	@$(MAKE) -s -C verif/sys/tests/pxc04t
	@$(MAKE) -s -C verif/sys/tests/pxc04m
	bash verif/sys/run-xc04-gate.sh

# --- far RETF to an OUTER privilege level (verif/sys/run-retfout-gate.sh) ----
# REVIEW2_aug2 C-06, stack half. The witness is the ring-3 SS (0x23 fixed / 0x10 broken),
# NOT the privilege level: CPL takes the popped CS.RPL in the broken build too, so a
# test asking "did we reach ring 3" passes against the bug. esi carries ESP for the
# case where SS is switched but the pointer is not.
.PHONY: retfout
retfout:
	@$(MAKE) -s -C verif/sys/tests/pretfout
	bash verif/sys/run-retfout-gate.sh

# --- documentation/source consistency (verif/sys/run-docs-status-gate.sh) -----
# REVIEW_Aug3 M-02: the status documents must not drift from the RTL and the gates.
# Checks the documented loud-halt tags against the halt sites, the off-by-default
# correctness defines against the deployed KV_FULL_DEFS set, the expected-failure
# pin classifications, and that each status row's named evidence gate exists.
.PHONY: docs-status
docs-status:
	bash verif/sys/run-docs-status-gate.sh

# --- lint matrix (verif/lint/run-lint-gate.sh) ---------------------------------
# The structural warning classes (IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/
# LATCH/UNOPTFLAT) are hard errors across five build configurations: default,
# L1/AXI, the deployed KV260 set, iterative-BCD, and the FP_PS_ALL area-relief
# profile. Style/width noise stays visible but non-fatal.
.PHONY: lint
lint:
	bash verif/lint/run-lint-gate.sh

# --- cross-privilege call gate (verif/sys/run-callxpl-gate.sh) ---------------
# REVIEW2_aug2 C-06, call-gate half. Covers BOTH the desc[45:44] DPL misread (which
# made every DPL-3 gate #GP from ring 3, and hid the missing feature behind it) and
# the stack switch itself. Witness is the ring-0 SS + the caller ESP read back out of
# the pushed frame + the callee ESP, so "SS loaded" and "frame actually pushed on it"
# are distinguished.
.PHONY: callxpl
callxpl:
	@$(MAKE) -s -C verif/sys/tests/pcallxpl
	bash verif/sys/run-callxpl-gate.sh

# --- H-13: fetch cacheability follows the physical memory type ---------------
# REVIEW2_aug2 H-13. ven_cachemap is on this branch now, so the I-side query exists in
# the default build (outside the EN_L2 generate). Compares the l1axi build against a
# +VEN_IC_NO_MTYPE control: uncacheable code must refetch AND compute the same answer.
.PHONY: mtype
mtype:
	@$(MAKE) -s -C verif/sys/tests/pmtype
	bash verif/sys/run-mtype-gate.sh

# --- unimplemented-sequence reachability (verif/sys/run-unimpl-gate.sh) ------
# REVIEW2_aug2 H-08 + C-06. BOTH sequences this gate was built for are now IMPLEMENTED
# (NT task-return -> the directed pntret probe below; outer-level RETF -> `make retfout`),
# so both instrument counters are pinned to 0 and the gate's remaining job is the
# directed pntret assertion. Kept rather than deleted: it is the record that the two
# gaps were closed, and it still fails loudly if the NT return regresses.
.PHONY: unimpl
unimpl:
	@$(MAKE) -s -C verif/sys/tests/pntret
	bash verif/sys/run-unimpl-gate.sh

# --- instruction-fetch cacheability (verif/sys/run-icbypass-gate.sh) ---------
# REVIEW2_aug2 H-13. CR0.CD now drives ic_fill_nocache in the DEFAULT build, so the
# comparison sides swapped: the CACHING build is the one needing an opt-out define.
# This gate existed but NOTHING RAN IT -- the same orphan-gate problem that hid the
# missing L1 gates. Asserts both halves: the CD-honouring build really refetches, and
# it is architecturally transparent.
.PHONY: icbypass
icbypass:
	bash verif/sys/run-icbypass-gate.sh

# --- TSS I/O permission bitmap (verif/sys/run-ioperm-gate.sh) ----------------
# REVIEW2_aug2 C-07 + M-02. CPL3 with IOPL=0, so every I/O access consults the bitmap:
# odd ports 0x101..0x107 denied, even permitted, plus two WORD accesses whose SECOND
# port is denied. Witness is the #GP count in ecx: 6 correct, 4 if only the first port
# of a multi-port access is checked. Needs --soc-en (see task #73).
.PHONY: ioperm
ioperm:
	@$(MAKE) -s -C verif/sys/tests/pioperm
	bash verif/sys/run-ioperm-gate.sh

# --- L1 / memory-subsystem unit gates ---------------------------------------
# `l1` runs EVERY verif/l1/run-*.sh gate -- the list is GLOBBED, not enumerated, so a
# new gate script is picked up automatically (the M-08 RLAST-recovery gate arrived that
# way). Covers the L1D coherence + store/load gates,
# the I-cache snoop gate, the TLB and BTB gates, and the L1/AXI family (base,
# CDC, watchdog, cross-line, cross-word, CALL/RET-in-deployed-config, and the
# two longer *-verify sweeps).
#
# These existed for a long time but were reachable ONLY by invoking each script
# by hand — no make target, and no entry in verify-all, which nevertheless called
# itself "every routinely-runnable gate". They cover exactly the memory-path RTL
# that REVIEW2's C-0x/H-0x cache findings touch, so they were the least safe
# thing to leave out. Wiring them in found run-l1axi-callret-gate.sh permanently
# broken (it aborted on the tb's isa-debug-exit status before running a single
# check, so it could not pass in ANY tree state).
#
# The loop is deliberately NOT `set -e`-style early-exit: every gate runs even
# after one fails, so a single break cannot hide the state of the other eleven.
l1:
	@fail=0; pass=0; \
	for s in verif/l1/run-*.sh; do \
	  n=$$(basename $$s .sh); \
	  printf '\n---------- L1 GATE: %s ----------\n' "$$n"; \
	  if bash $$s; then \
	    printf '  L1 GATE PASS: %s\n' "$$n"; pass=$$((pass+1)); \
	  else \
	    printf '  L1 GATE FAIL: %s (rc=%s)\n' "$$n" "$$?"; fail=$$((fail+1)); \
	  fi; \
	done; \
	printf '\nL1 GATES: %d PASS / %d FAIL\n' "$$pass" "$$fail"; \
	if [ "$$fail" -ne 0 ]; then echo "L1 GATE SET: FAIL"; exit 1; fi; \
	echo "L1 GATE SET: PASS (all $$pass memory-subsystem gates green)"

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
issue-uv:
	bash verif/issue_uv/run-issue-uv-gate.sh

verify: issue-uv
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
#   pssiret (REVIEW_aug2 C-07) inter-priv IRET outer-SS VALIDATION + the proof that
#                  a rejected frame commits NOTHING (no EIP/EFLAGS/ESP/CS/CPL move).
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
	bash verif/sys/run-sys-golden.sh psysfpreloc
	bash verif/sys/run-sys-golden.sh psysfpload
	bash verif/sys/run-sys-golden.sh ppage
	# REVIEW2 C-02: directed page-crossing test. XFAILs today (that divergence IS
	# the defect); the runner fails loudly if it ever starts passing.
	bash verif/sys/run-sys-golden.sh pxpage
	bash verif/sys/run-sys-golden.sh pintr
	bash verif/sys/run-sys-golden.sh pintr16
	bash verif/sys/run-sys-golden.sh pfault
	bash verif/sys/run-sys-golden.sh pfcpl3
	bash verif/sys/run-sys-golden.sh pde
	bash verif/sys/run-sys-golden.sh pcpl
	# REVIEW_aug2 C-07: inter-priv IRET must VALIDATE the outer SS and commit
	# nothing until it has. Grades the FAULT FRAME (saved CS/EFLAGS.IF + the
	# handler's own SS:ESP), not merely that a fault occurred.
	bash verif/sys/run-sys-golden.sh pssiret
	# REVIEW2_aug2 C-06 prerequisite: the ONLY golden-compared far CALL/RETF in the
	# tree. psocfarcall/psocpmretf are referenced by zero gates AND have no source
	# (.bin/.elf/.o only), so they can be neither rebuilt nor registered;
	# pcallsel covers the reject path only. Without this, a reorder of the
	# far-transfer path would ship unregressed.
	bash verif/sys/run-sys-golden.sh pfarok
	# psoccallfmem: memory-indirect far CALL (FF /3) mode split -- real/V86 far
	# pointers carry a segment value (base = sel<<4, no descriptor table); only
	# protected selectors are bounded and descriptor-probed. Both operand-size
	# forms in real mode, the stack-built lcall *0(%bp) shape, 64 KiB stack-top
	# wrap pushes, an IF=1 case, PM valid/bad-selector controls, and a V86 case.
	bash verif/sys/run-sys-golden.sh psoccallfmem
	# REVIEW_aug2 H-06: INVD/WBINVD are CPL0-only and RDTSC honours CR4.TSD.
	bash verif/sys/run-sys-golden.sh ppriv
	# REVIEW_aug2 H-01: 16-bit PROTECTED-mode stacks (address AND pointer, plus
	# SS.B captured at a cross-privilege delivery). Measured unreachable before.
	bash verif/sys/run-sys-golden.sh pstk16
	# REVIEW_aug2 H-04: a fault DURING delivery must escalate to #DF (and a fault
	# during #DF delivery must shut down, which ppriv's sparse IDT exercises).
	bash verif/sys/run-sys-golden.sh pdf
	bash verif/sys/run-sys-golden.sh ptask
	bash verif/sys/run-sys-golden.sh ptaskcpl
	# REVIEW_Aug3 C-02: the paged control-flow address mirrors. ptaskpg is ptask
	# with paging ON and EVERY switch object non-identity-mapped (straddling GDT
	# and TSS2, outgoing/incoming LDTs differing in base AND limit, TI=1 incoming
	# CS/SS/DS through the staged incoming LDT); pretfoutpg is pretfout with the
	# outer ESP/SS pops landing on a different physical page than the linear
	# page, in both 32-bit and 16-bit (H-02 zero-extension) operand sizes.
	bash verif/sys/run-sys-golden.sh ptaskpg
	bash verif/sys/run-sys-golden.sh pretfoutpg
	# REVIEW_Aug3 C-04: far-transfer intent. pcalltss proves the NESTING task
	# switch for a far CALL to an available TSS (back-link, NT, BOTH descriptors
	# busy, saved resume EIP, NT-IRET return); pjmpgate proves a far JMP through
	# a call gate to a more-privileged NONCONFORMING target raises #GP(selector)
	# while the far CALL succeeds and the conforming-target JMP keeps CPL.
	bash verif/sys/run-sys-golden.sh pcalltss
	bash verif/sys/run-sys-golden.sh pjmpgate
	# REVIEW_Aug3 H-11b: pltr proves LTR writes the descriptor busy byte before
	# TR commits (readback 0x8B), a second LTR on the busy descriptor #GP(sel),
	# and a null LLDT under paging with GDT[0] non-present commits the invalid
	# LDTR with NO #PF. (The null-LLDT suppression initially missed the paging
	# divert -- S_LTR stayed `translatable`; fixed by gating it and perm_fault
	# on the same predicate as the suppressed request. See manifest rtl_blocker.)
	bash verif/sys/run-sys-golden.sh pltr
	# REVIEW_Aug3 H-02: pretfres proves a same-privilege RETF whose popped CS
	# is rejected (not-present, 32- and 16-bit) faults with ESP UNCHANGED, and
	# a 16-bit outer RETF zero-extends the popped outer SP word. (The
	# offset-past-limit restartability case lives in piretgp0: QEMU has no
	# return-EIP-limit check, so it is witness-graded.)
	bash verif/sys/run-sys-golden.sh pretfres
	# REVIEW_Aug3 H-03 (+H-02 offset-past-limit): piretgp0 is a WITNESS gate
	# (QEMU lacks the return-EIP-vs-limit check; the H-03(b) DPL<RPL anomaly
	# is unreachable through legal loads): #GP(0) with error code ZERO at the
	# over-limit IRET and RETF, ESP preserved, at-limit IRET succeeds, and the
	# reachable outer-IRET segment-cleanup boundary (step 7w).
	bash verif/sys/run-sys-golden.sh piretgp0
	# REVIEW_Aug3 M-01: piopermwrap proves a word/dword IN/OUT whose extent
	# wraps past port 0xFFFF is denied #GP(0) outright (never decided by
	# adjacent bitmap memory), with the byte-at-0xFFFF and dword-at-0xFFFC
	# boundary cases PERMITTED. Differential: QEMU denies too, via the
	# architecturally-required 0xFF bitmap terminator byte.
	bash verif/sys/run-sys-golden.sh piopermwrap
	# REVIEW1_Aug3 R2-C01: pxfer proves S_LJMP validates far transfers PER
	# KIND: ten rejected transfers (direct CALL RPL>CPL; direct JMP conforming
	# DPL>CPL; RETF to a system descriptor; JMP to an LDT-resident TSS; JMP to
	# a not-present TSS (#NP); CALL through a not-present call gate (#NP);
	# call-gate target nonconforming DPL>CPL; and from CPL3: direct JMP
	# nonconforming DPL<CPL; CALL to a TSS DPL<CPL; RETF popped RPL<CPL) --
	# each witnessed to perform NO stack write and NO busy-bit write -- plus
	# three ACCEPTED controls (conforming JMP, same-level CALL/RETF, JMP to a
	# valid available TSS). Differential vs QEMU; the one oracle gap (QEMU
	# #TS vs SDM #GP for the LDT-resident TSS) uses the pssiret shared-
	# handler pattern with the vector graded from +ven_faultlog (step 7d).
	bash verif/sys/run-sys-golden.sh pxfer
	# REVIEW1_Aug3 R2-C02: pselnull proves ONE null-selector definition
	# (sel[15:2]==0) and TI-preserving selector error codes: a null DS load
	# with GDT[0] NONZERO and NON-PRESENT reads nothing (no #PF) and stages
	# visible null DS, with legal SS-relative sentinels; a far
	# JMP through LDT entry 0 (0x0004) succeeds; an out-of-bounds LDT
	# selector faults #GP(0x0004); an incoming task LDTR of 0x0004 is
	# #TS(0x0004); a paged task switch with a null incoming DS completes.
	# WITNESS gate (case D cannot be diffed: QEMU raises the same #TS only
	# AFTER committing the switch); graded in step 7w.
	bash verif/sys/run-sys-golden.sh pselnull
	# Intel-spec null-data accesses: four precise GP0/no-effect cases and six
	# legal alternate-segment controls. QEMU softmmu cannot be this oracle;
	# the standalone witness requires an actually enforced frozen TB profile.
	bash verif/sys/run-pnullseg-gate.sh
	# REVIEW1_Aug3 R2-C04 (pxprobe): a cross-privilege delivery whose frame
	# straddles onto a NOT-PRESENT second page must #PF BEFORE the SS/CPL
	# commit -- err=2 (supervisor class), CR2 = the first faulting push's
	# address, old SS:ESP/CPL3/EFLAGS intact, no escalation cascade (the
	# faultlog extra in step 7e). Fully differential vs the QEMU golden.
	bash verif/sys/run-sys-golden.sh pxprobe
	# pxwrap: the wrapped cross-privilege frame-probe matrix. A new TSS stack
	# that wraps its stack-pointer window (B=0: SP < frame size; B=1: ESP <
	# frame size) splits the frame into two offset chunks over up to four
	# pages; every touched page is denied in turn (#PF err=2, push-order CR2,
	# old context intact, zero bytes, no escalation) and then permitted (the
	# CPL0 handler verifies every frame byte). 16-bit interrupt/trap gates
	# with and without error code, B=1 4 GiB-wrap layouts, max-parameter call
	# gates (70/140-byte frames), V86 permitted controls. Differential vs
	# QEMU + the faultlog count extra. pxwrapm is the witness half: QEMU
	# pushes incrementally while the probe commits nothing, so the
	# zero-bytes property is graded in-guest (step 7w) with QEMU's partial
	# pushes pinned honestly (step 5f); the V86 denials are terminal in both
	# oracles (no #PF can leave V86 without re-probing the same stack).
	bash verif/sys/run-sys-golden.sh pxwrap
	bash verif/sys/run-sys-golden.sh pxwrapm
	# pxfrag: the fragment-engine abort contract on the read side. A crossing
	# GDTR read is faulted at fragment 2 (with the handler poisoning the
	# fragment-1 bytes between the abort and the restart -- a stale merge
	# installs the old limit and the case-A selector bracket flips) and at
	# fragment 1 (the pre-engagement miss), then restarted to completion;
	# differential vs QEMU. The write phases stay with pxc04e/pxc04f.
	bash verif/sys/run-sys-golden.sh pxfrag
	# pxdplan: the frame page-plan probe contract (witness gate). Deny cases
	# on 64 KiB-colliding destination pages prove the validation phase writes
	# nothing and sets no D bit; the success case proves the D-mark pass runs
	# pre-commit and the pushes never walk (the colliding pages evict each
	# other from the direct-mapped DTLB, so a DTLB-translated push would);
	# +ven_frmpglog counters prove one probe beat per distinct page (a 35-slot
	# call-gate frame probes 3 beats, not 35).
	bash verif/sys/run-sys-golden.sh pxdplan
	# fxabort: the fragment-abort phases the system images cannot reach. A
	# focused --binary TB around the whole core drives each engine phase from
	# a small driver image and (a) pulses reset mid-phase, proving the engine
	# returns to the one idle state with no shaping armed, and (b) faults the
	# probe / read-frag2 / read-frag1 phases with same-cycle and delayed acks,
	# counting engagements/aborts and watching for stale redirect. The core's
	# own abort assertions run in the build and must stay silent.
	bash verif/fxabort/run-fxabort-gate.sh
	# REVIEW1_Aug3 R2-H05: call-gate parameter copy + 16-bit gates. pcgparam:
	# 32-bit cross-priv gates with pcount 0/1/31 (order proof, RETF imm16
	# discard, caller-stack restore) + the same-priv no-copy control. pcg16:
	# 16-bit gates from a 32-bit caller (same-priv word frame; cross-priv word
	# params; SET_ESP upper-16 semantics) + a 32-bit gate from a 16-bit caller.
	# pcgpg: caller/callee page-boundary straddles (fx split push + S_CG_PRD
	# split read) and old-context #PFs for a denied destination/source page
	# (both fully differential vs QEMU). All three pin the B1 (RETF imm16 outer
	# pops) and B2 (gated CS.RPL) fixes -- RED on a pre-fix build by design
	# (0xDA halt / 32-bit-frame defect on HEAD; see the pcgparam manifest).
	bash verif/sys/run-sys-golden.sh pcgparam
	bash verif/sys/run-sys-golden.sh pcg16
	bash verif/sys/run-sys-golden.sh pcgpg
	# REVIEW1_Aug3 R2-C03: the generic page-crossing fragment engine. All six
	# ex-xc04 producers, converted from the reachability pin into CORRECTNESS
	# tests: each crossing runs on NON-CONTIGUOUS physical frames (a
	# wrong-physical-page access returns poison) and is diffed against the QEMU
	# golden; the write producers also prove probe-before-commit atomicity (a
	# not-present second page #PFs BEFORE page 1 is touched). pxc04i/pxc04t
	# have no NP variant (documented in their manifests: the frame push IS
	# delivery -> recursive fault; QEMU's TSS dummy pre-access faults at a
	# different address than the probe -> CR2 oracle gap). pxc04 (S_LGDT read)
	# is included: the read-frag2 S_WALK merge contamination it exposed is
	# fixed (fx_walk_hold in rtl/core/core.sv).
	bash verif/sys/run-sys-golden.sh pxc04
	bash verif/sys/run-sys-golden.sh pxc04i
	bash verif/sys/run-sys-golden.sh pxc04f
	bash verif/sys/run-sys-golden.sh pxc04e
	bash verif/sys/run-sys-golden.sh pxc04t
	bash verif/sys/run-sys-golden.sh pxc04m
	# REVIEW_Aug4: A4-C01 (crossing-store probe dirty intent; the clean-leaf
	# hang and the probe-D-write classes) and A4-C02 (direct far JMP / same-
	# privilege RETF target offset at limit+1 -- the pre-commit rejection).
	bash verif/sys/run-sys-golden.sh pxwalkd
	bash verif/sys/run-sys-golden.sh pjmpoff
	# A4-H05: combined-invalid descriptor fault precedence (type/privilege
	# BEFORE presence, QEMU tss_load_seg order; 7 discriminators + 7 controls).
	bash verif/sys/run-sys-golden.sh pdescprec
	# A4-H03: 16-bit protected-mode interrupt frames (word slots, errcode size,
	# SS.B wrap, cross-priv; the IRETW recovery incl. the outer-SS.B ESP mask).
	bash verif/sys/run-sys-golden.sh pint16f
	# A4-H06: same-privilege delivery partial frames are ARCHITECTURAL (QEMU
	# pushes incrementally too): straddling frame, page 2 NP and page 2 RO;
	# CR2/err/partial bytes/ESP, then the delivery restarts and completes.
	bash verif/sys/run-sys-golden.sh psamepf
	# A4-H09: task-switch phase fault injection (WITNESS gate): save-RO,
	# incoming NP, LDTR NP, system DS, both busy-write faults; the phase-model
	# partial states + busy-order invariant. Pins the S_TSW_SAVE/S_TSW_BUSY
	# missing write classification (found by this test).
	bash verif/sys/run-sys-golden.sh ptswflt
	# prsmflush: an executable invalidation (CR3 reload / A20 edge / RSM) must
	# beat CONSUMPTION -- no fast-serve path may retire a line the flush is
	# killing. Cases B+C differential vs the QEMU golden, case A (SMM/RSM)
	# witness-graded (the gdbstub masks SMI; no golden possible).
	bash verif/sys/run-prsmflush-gate.sh
	# psmmmeta: RSM must restore the interrupted context's hidden segment
	# metadata (seg_pm_loaded / seg_b / ss_b) with the PRE-SMI values, not the
	# SMM handler's -- a leaked stack width flips the first post-RSM push, and
	# a leaked data-segment D/B flips the legality of an expand-down DS access
	# above 64K (discriminated on the +VEN_SEG_ENFORCE variant build; the gate
	# runs both). Witness-graded (the gdbstub masks SMI; no golden possible).
	bash verif/sys/run-psmmmeta-gate.sh
	# pintslim: the cross-privilege interrupt-frame pre-probe must segment-
	# check each frame slot with the SLOT'S width -- a 16-bit gate's word
	# slot ending exactly at the new stack segment's bound is legal (both
	# B bits, expand-up + expand-down); one slot-width past must #SS(0)
	# pre-commit. Discriminated on the +VEN_SEG_ENFORCE variant build (the
	# canonical run is additionally a full differential vs the QEMU golden).
	bash verif/sys/run-pintslim-gate.sh
	bash verif/sys/run-sys-golden.sh psmm
	bash verif/sys/run-sys-golden.sh pdebug
	bash verif/sys/run-sys-golden.sh ppopf
	PORT=53220 bash verif/sys/run-sys-golden.sh pv86

# Generic equal-nonzero-base system client.  This uses a separate simulator
# profile and profiler to prove the narrow relocated system fast path is taken;
# see verif/sys/run-sysfpreloc-gate.sh.  Kept separate from verify-sys because
# it necessarily rebuilds the define variant.
verify-sys-fpreloc:
	bash verif/sys/run-sysfpreloc-gate.sh

# Uses an isolated VEN_SYS_FASTLOAD_FLAT/VEN_SYS_FASTSTORE_FLAT profile and
# profiler to prove the restricted common-base MOV r32,[base] / MOV [base],r32
# paths are taken; see
# verif/sys/run-sysfpload-gate.sh.  Kept separate from verify-sys because it
# necessarily rebuilds the define variant.
verify-sys-fpload:
	bash verif/sys/run-sysfpload-gate.sh

# Precise #PF restart is the safety boundary for the system fast-store producer:
# a present/read-only PTE must reject MOV [disp32],r32 before any write, then
# restart it after the handler maps RW. The gate also proves the post-restart
# loop actually uses S_PIPE; see verif/sys/run-pfaststore-gate.sh.
verify-sys-faststore:
	bash verif/sys/run-pfaststore-gate.sh

# --- verify-all umbrella (verif/run-verify-all.sh) --------------------------
# One command that runs EVERY routinely-runnable gate (verify + verify-sys +
# verify-srt + m6 + a20 + l1 + bus + bus-sva) and reports a single pass/fail summary,
# so a regression in the bus-protocol SVA, the errata flag, the memory subsystem
# or the SRT divider cannot slip through by only running the differential
# aggregates.
#
# The AUTHORITATIVE list is the GATES array in verif/run-verify-all.sh, which
# prints itself at run time -- this comment is a convenience copy and must not be
# trusted over that output. It previously listed `verify-soc`, which has no make
# target and no gate script in this checkout, and omitted the 12 `l1`
# memory-subsystem gates entirely.
#
# EXCLUDED-and-logged (not silently dropped): verify-soc (absent — M-03/M-04) and
# the m7 macro co-sims (Quake/Win95), which need gitignored producer artifacts
# that cannot be regenerated from a clean checkout.
verify-all:
	bash verif/run-verify-all.sh

# --- coverage gates (verif/cov/, see verif/cov/README.md) --------------------
# Verilator only instruments INSTANTIATED modules, so coverage is gathered in
# four complementary lanes; the coverage build lives in its own obj_dir_cov, so
# `make verify`/every gate keeps using the byte-identical obj_dir/tb_ventium.
# `coverage`      = full user-mode ISA suite through the --coverage core build
#   (run-cov.sh): per-file line/toggle %, the executed-opcode histogram built
#   from RETIRED instructions, and the first unimplemented/diverging instruction
#   per test vs the QEMU golden (e.g. it pinpoints the known FPREM gap).
# `coverage-sys`  = the same core in --system mode on the bare-metal images
#   (run-sys-cov.sh) — lights up int/IRET/seg/TSS/SMM/paging/TLB.
# `coverage-mem`  = faithful standalone ven_l1d/ven_axi_master/ventium_l1_axi/
#   ven_l2 testbenches + an all-sets ven_l1d sweep (run-mem-cov.sh).
# `coverage-unit` = the optional iterative engines (idiv/srt/sqrt/bcd/fbld) +
#   biu_p5 via their proven standalone gates (run-unit-cov.sh).
# `coverage-all`  = every lane + the COMBINED CORE (ISA+SYS) headline.
coverage:
	bash verif/cov/run-cov.sh
coverage-sys:
	bash verif/cov/run-sys-cov.sh
coverage-mem:
	bash verif/cov/run-mem-cov.sh
coverage-unit:
	bash verif/cov/run-unit-cov.sh
coverage-all:
	bash verif/cov/run-all-cov.sh

# --- per-opcode ISA regression suite (verif/cov/opgen/) ---------------------
# Script-generated ONE test per P54C opcode (from x86reference.xml), all
# operand/ModRM/SIB cases, parallel differential vs qemu-i386 (PM32/user) +
# qemu-system (real-mode/CPL0 mode lane). `opgen` regenerates + runs everything
# and prints the 555-opcode coverage accounting; `opgen-modes` runs the CPL0
# mode lane. New divergences fail; cataloged findings (known_diverge.txt) don't.
opgen:
	python3 verif/cov/opgen/gen_opspec.py
	python3 verif/cov/opgen/gen_easweep.py
	python3 verif/cov/opgen/gen_tests.py
	bash   verif/cov/opgen/run-opgen.sh
	python3 verif/cov/opgen/coverage_report.py
opgen-modes:
	bash verif/cov/opgen/run-modes.sh

# --- SRT divider gate (verif/srt/run-srt-gate.sh) ---------------------------
# Standalone Verilator unit gate for the genuine radix-4 SRT divider
# (fpu_x87_pkg::fx_srt_div, the unconditional default divider). Drives
# golden vectors from the single-source model tools/srt/srt_model.py and asserts
# the RTL is bit-exact for BOTH the correct PLA (== correctly-rounded floatx80 ==
# QEMU) and the buggy PLA (the documented Pentium FDIV flaw, reproduced from
# first principles). Does NOT touch the core/SoC build, so the default `make
# verify`/`verify-soc` tracks are unaffected.
verify-srt:
	bash verif/srt/run-srt-gate.sh

# --- FPREM/FPREM1 differential gate (verif/srt/run-fprem-gate.sh) -----------
# Full-core differential of the tx_fprem corpus program vs the pinned QEMU
# golden on all three remainder-engine configurations: the canonical build
# (dedicated fpu_fprem), the unified-engine build (+VEN_SRT_ITER +VEN_FPREM),
# and the deployed-profile build (l1axi_kv_full, L1/AXI bus mode). One
# documented oracle gap is masked by record-exact ranges from the test's
# manifest (QEMU never fills FPREM1's C0/C3/C1 quotient codes).
verify-fprem:
	bash verif/srt/run-fprem-gate.sh

# --- iterative SRT divider gate (verif/srt/run-srt-iter-gate.sh) -------------
# Standalone clocked gate for the multi-cycle, one-step-per-clock iterative SRT
# divider (rtl/fpu/fpu_srt_div.sv) — the FPGA-synthesizable form of fx_srt_div.
# Reuses the same single-source golden vectors and asserts the engine is
# bit-exact for BOTH PLAs (== fx_srt_div == QEMU), i.e. equivalent to the proven
# combinational divider. Needs Verilator --timing.
verify-srt-iter:
	bash verif/srt/run-srt-iter-gate.sh
	bash verif/srt/run-sqrt-iter-gate.sh

# --- iterative integer divider gate (verif/idiv/run-idiv-gate.sh) ------------
# Standalone clocked gate for the multi-cycle integer DIV/IDIV engine
# (rtl/core/ven_idiv.sv) — the FPGA-synthesizable form of the native '/'/'%'.
# Bit-exact (quotient/remainder/#DE) vs the native per-width predicates over all
# six forms (DIV/IDIV x r8/r16/r32). Needs Verilator --timing.
verify-idiv:
	bash verif/idiv/run-idiv-gate.sh

# --- iterative FP->packed-BCD (FBSTP) engine gate ----------------------------
# Standalone clocked gate for the multi-cycle FP->BCD engine (rtl/fpu/ven_bcd.sv)
# — the FPGA-synthesizable form of fx_fx_to_bcd (whose 18 chained combinational
# /10 stages were the core's worst timing path). Bit-exact vs fx_fx_to_bcd.
verify-bcd:
	bash verif/bcd/run-bcd-gate.sh

# --- iterative packed-BCD->floatx80 (FBLD) engine gate ----------------------
# Standalone clocked gate for the multi-cycle BCD->FP engine
# (rtl/fpu/ven_bcd_to_fp.sv) — the FPGA-synthesizable form of fx_bcd_to_fx (whose
# 18 chained *10 stages were the worst LOGIC path under +VEN_FP_PIPE). Bit-exact.
verify-fbld:
	bash verif/fbld/run-fbld-gate.sh

# --- 2-stage FP arithmetic split gate (verif/fppipe/run-fppipe-gate.sh) -------
# Combinational gate proving f_eval_s2(f_eval_s1(...)) == f_eval(...) bit-exact
# for the add/sub/mul groups + all rounding modes + normal/zero/Inf/NaN operands
# — the datapath split that the +VEN_FP_PIPE 3-stage FP execute pipeline is built
# on. No clock (pure function composition).
verify-fppipe:
	bash verif/fppipe/run-fppipe-gate.sh

# --- 2-stage FP-commit cycle-equivalence gate (verif/fppipe/run-fp-pipe2-ab.sh) ---
# Proves +VEN_FP_PIPE2 (the K26 60 MHz FADD-commit split) is CYCLE-SAFE: builds two
# cycle TBs differing only by VEN_FP_PIPE2 and asserts the --cycle traces are
# equivalent (faddchain byte-identical; fpindep same final arch state, CPI in the M5
# band) + band-checks vs the p5trace golden. The split moves the deferred fpr commit
# N+1 -> N+2, still <= the scoreboard's issue+lat(3) publish, so behaviour is held.
verify-fppipe2:
	bash verif/fppipe/run-fp-pipe2-ab.sh

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
