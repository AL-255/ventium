# Ventium — progress snapshot (2026-06-04)

Dated progress record opened 2026-06-04. The full historical log stays in
[`PROGRESS.md`](PROGRESS.md); this file records the state at the close of the
planned roadmap and the continuing **R2 leaf-module-extraction** refactor.

## Roadmap status — COMPLETE (all planned milestones done)

| Milestone | What | Gate | Status |
|---|---|---|---|
| M0 | Bootstrap: QEMU golden-trace oracle, trace format, Verilator TB, comparator | comparator end-to-end | ✅ |
| M1 | Decoder + single-issue integer functional | integer subset diff-clean vs QEMU | ✅ |
| M2 | User-mode integer ISA completeness | broad integer corpus diff-clean | ✅ |
| M2S.0 | System-mode oracle + harness (qemu-system-i386, gen_trace --system) | sys golden round-trips | ✅ |
| M2S.1 | Real→protected mode + segmentation (dual boot_mode) | `pseg` RTL sys-diff (70) | ✅ done-partial |
| M2S.2 | 2-level paging MMU + split I/D TLBs + A/D + #PF decision | `pmode`(1084)/`ppage`(128) | ✅ done-partial |
| M2S.3 | IDT-delivered interrupts/exceptions + IRET | `pintr`(171)/`pfault`(348) | ✅ done-partial |
| M2S.4 | TSS + cross-priv delivery + inter-priv IRET | `pcpl`(304); HW task switch → M2S.4b | ✅ done-partial |
| M2S.4b | HARDWARE TASK SWITCH (far `JMP` to a 32-bit TSS) — the deferred M2S.4 piece | `ptask` RTL `--system` sys-diff (292) | ✅ done-partial |
| M2S.5 | SMM / RSM (partial oracle) | `psmm` structural self-check | ✅ done-partial |
| M2S.6 | Debug registers DR0–DR7 + `#DB` (last system stage) | `pdebug` RTL sys-diff (239) | ✅ done-partial |
| M3 | x87 FPU | x87 corpus diff-clean | ✅ |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench bands match p5model | ✅ |
| M5 | Cache-cycle + FP-cycle accuracy | FP/cache bands track p5model | ✅ |
| M5B | Pin-level 64-bit bus protocol (standalone) | structural + SVA (no oracle) | ✅ standalone |
| M5B-int | Wire the standalone bus into `rtl/` behind a default-OFF `bus_mode` | bus_mode=0 bit-identical; bus_mode=1 func-EQUIVALENT + SVA hold; standalone still green | ✅ done (2026-06-05) |
| M6 | Errata & stepping fidelity (stretch) | targeted errata behind a flag | ✅ partial |
| R1 | RTL modularization + fast gate (`make verify` ~2 s) | all m1–m5 + sys stay green | ✅ |

**Verification at this snapshot (independently re-run 2026-06-04):** `make verify`
(user) GREEN — 56/56 func diff-clean + all M4/M5 cycle bands; all 6 differential
system gates EQUIVALENT (pseg 70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 /
pcpl 304); `ptask` self-diff (292) + `psmm` structural OK; verilator lint clean.
Latest commit `2a00d06` (M2S.6) pushed to `origin/main`.

**Verification re-run after M2S.4b (independently re-run 2026-06-05):** `make verify`
(user) GREEN + bit-identical (exit 0; 57/57 func diff-clean, 0 goldens regenerated;
all M4 integer + M5 FP/cache bands met). **`ptask` is now a REAL RTL `--system` diff
EQUIVALENT to the golden, 292 records** (no longer self-diff-only) — RTL-SYS-DIFF-OK.
All 9 differential sys gates EQUIVALENT — pseg 70 / pmode 1084 / ppage 128 / pintr
171 / pfault 348 / pcpl 304 / **ptask 292** / pdebug 239 / pv86 949 — and psmm stays
SMM-PARTIAL-OK (structural; differential oracle infeasible). Verilator lint clean
(`--lint-only -sv -Wall -Wno-UNUSED -f ventium.f` → exit 0, 0 warn/err). Gate ports
used: ptask 57310, pcpl 57320, pfault 57330, pv86 57340, pseg/pmode/ppage/pintr/
pdebug/psmm 57350–57400 (all in 57000–57999). **Not committed** (the orchestrator
verifies + commits).

**Verification re-run after M5B-int close-out (independently re-run 2026-06-05):**
gates re-run by me, ACTUAL results:
- **bus_mode=0 (DEFAULT) — BIT-IDENTICAL (HARD gate):** `make verify` GREEN, exit 0 —
  **57/57 func PASS** (every program diff-clean vs QEMU incl. x87), all 5 M4 integer
  bands + all M5 FP/cache bands met, 0 goldens regenerated. Abs-cyc numbers UNCHANGED
  vs the recorded baseline: mb_depadd C=3497 (+2.85%), mb_indepadd C=1913 (+6.16%),
  mb_dmiss C=20544 (+0.10%), mb_imiss C=24149 (+0.14%). The bus subsystem is wholly
  inert in mode 0 (`ventium_top.sv:345` gates `c_req`→0): VCD probe shows **0 real
  ADS# pulses + 0 BRDY# beats** in mode 0, and the back-side bus access counts are
  identical to mode 1 (t_stack 592 reads / 48 writes / 308 clocks / 36 insns in BOTH).
- **bus_mode=1 — FUNCTIONAL + SVA:** the 12-program corpus through `tb_ventium
  --bus-mode` (`verif/bus/run_busmode_corpus.sh`, reusing the shared func goldens) is
  **12/12 func-EQUIVALENT vs QEMU** (`compare.py --mode func` exit 0; smoke,t_mem,
  t_stack,t_string,t_mul,t_loop,t_callret,t_rep,t_rotate,t_div + x87 tx_addsub,tx_ldst).
  Pins genuinely toggle (VCD: t_stack **73 ADS# pulses + 72 BRDY# data beats** in mode 1).
  The **19 biu_p5 SVA HOLD in-system**: the `make -C verif/tb rtl-sva` build (`--assert`
  + `bind biu_p5 biu_p5_sva`) ran the full corpus 12/12 with **ZERO assertion fires**.
- **STANDALONE bus gate GREEN:** `verif/bus/run.sh` — lint OK + **76 directed checks
  PASS, 0 FAIL** + the 19 SVA active → RESULT: ALL GREEN.
- **A couple sys gates EQUIVALENT (bus_mode=0):** pseg RTL-SYS-DIFF-OK (70 records) +
  pmode RTL-SYS-DIFF-OK (1084 records), both EQUIVALENT to the golden.
- **Lint clean:** `cd rtl && verilator --lint-only -sv -Wall -Wno-UNUSED -f ventium.f`
  → 0 warn/err (biu_p5 in the build; only the localized `lint_off UNUSED` for inert
  biu_p5 pin outputs + a `PINMISSING` around the unconnected dbg_* ports — no new waivers).
- **Review fix applied (med, honest-doc option a):** the false "bit-identical data
  carried by the bus / faithful carrier" invariant text in `rtl/bus/biu.sv` (header +
  the FRONT / bus_rdata_q / responder / unused-net comments) corrected to state
  `biu_p5` runs as a PROTOCOL EXERCISER only — the address on its pins and the data the
  loopback returns on d_in are NOT guaranteed to correspond (the responder generally
  replays the core's subsequent back-side word, since the core's ack is combinational).
  Comment-only change; the func-equivalent path (`c_rdata = m2_rdata`, combinational +
  independent of biu_p5), the SVA (protocol-timing, not data), and bus_mode=0 (bypass)
  are all unaffected — so no gated result changed. **Not committed** (orchestrator commits).

## Deferred, no-oracle tracks (carried, not auto-started)

- **R2 — leaf-module extraction** (this file's active work; the R1 deferral). Carve
  the leaf blocks (icache / dcache / tlb / regfile / fpu-state / btb) out of the
  `core.sv` spine into their own modules, **behavior-preserving** (gate-proven
  bit-exact after every step). R1 left these in because they are entangled with the
  shared pipeline FSM; R2 extracts what is mechanically separable and documents what
  must stay in the spine, and why.
- **M5B-int** — **CLOSED 2026-06-05.** The standalone pin-level bus is now wired into
  `rtl/` behind a default-OFF `bus_mode`, ADDITIVELY: bus_mode=0 (default) keeps every
  existing gate BIT-IDENTICAL (the subsystem is wholly inert — `c_req` gated to 0,
  0 ADS# pulses, M4/M5 cycle bands unchanged), and bus_mode=1 routes the core memory
  through the real `biu_p5` pin protocol and is func-EQUIVALENT vs QEMU on a 12-program
  corpus with the 19 SVA holding in-system. Deferral respected: the core still sees the
  M0 same-cycle ack (its cycle-accurate icache fill is preserved), so the absence of a
  pin-level cycle oracle costs nothing — NO cycle/pin-timing claim is made through the
  bus. Per the close-out review, `biu_p5` in-system is documented HONESTLY as a PROTOCOL
  EXERCISER (it returns a real back-side word on d_in but, because the core's ack is
  combinational, generally the core's NEXT access, not the word at the address on its
  pins — benign: the core's data is the independent combinational `c_rdata`, the SVA
  check protocol not data, bus_mode=0 bypasses it). See the M5B-int verification run
  below + the PROGRESS.md M5B row.
- **Hardware task switch** — the far-`JMP`-to-TSS variant is **CLOSED in M2S.4b**
  (`ptask` is now a real RTL `--system` diff, 292 records EQUIVALENT). What stays
  deferred (no corpus / no oracle): the `CALL`-far / `INT`-through-task-gate switch
  (sets EFLAGS.NT + the TSS back-link@0x00 — a JMP does NOT), `IRET` with NT=1
  (task-return), the round-trip switch-back (reloading the CPU-written outgoing TSS
  image), LDTR descriptor reload (no LDT machinery), and the `tr_valid`/`tr_limit`
  #TS-bound + TSS-descriptor type/present #GP/#NP negative paths.
- **M6 system-errata family** (BTB-flush / SMM / APIC / DP) — reachable now, but most
  lack a differential oracle.

---

## R2 — leaf-module extraction (IN PROGRESS, opened 2026-06-04)

**Goal.** Reduce the `rtl/core/core.sv` monolith by extracting the leaf blocks into
their own modules with clean port interfaces, **without changing behavior** — the
differential gate (`make verify` user GREEN + all sys gates EQUIVALENT + lint clean)
must hold after EVERY extraction. Replace the stub files `rtl/mem/icache.sv`,
`rtl/mem/dcache.sv`, `rtl/mem/tlb.sv` (and add `rtl/core/regfile.sv` / btb / fpu-state
as feasible) with the real extracted logic. The invariant is bit-exactness: any
extraction that cannot be made bit-exact is reverted and documented as spine-bound.

**Plan.**
1. Analysis (read-only): map each leaf's state + every core.sv touch-point + an
   extractability ranking + a proposed module interface.
2. Extract leaves one at a time, easiest/most-separable first, gate-verifying after
   each (revert-rather-than-regress).
3. Adversarial review (behavior-equivalence focus) + independent full-gate re-run.
4. Commit + push.

**Status:** ✅ done — **5 of 6** leaves extracted bit-exact; regfile alone proven
spine-bound and left inline (honest). (fpu-state, initially logged spine-bound, was
re-attacked and extracted bit-exact in the follow-on below — see "fpu_top" R2 log.)

### R2 outcome

A read-only analysis fan-out ranked each leaf by *write-port* structure (the
extraction discriminant): a leaf with **one** state-mutating transaction per clock
extracts bit-exact behind a single funnelled port; a leaf needing **two**
simultaneous writes needs an FSM restructure, not a lift. Then each extractable
leaf was lifted one at a time, **full gate after every step**, commit-on-green.

**Extracted (behavior-preserving, gate-verified bit-exact):**
- `rtl/mem/dcache_timing.sv` (74 L) — the D-cache timing model (`dc_tag/dc_val/dc_lru`):
  comb `lu_addr→lu_hit` off the registered arrays (pre-access, NBA-correct) + a single
  posedge access port. Commit `ed573c3`.
- `rtl/core/bpred_btb.sv` (115 L) — the BTB + 2-bit predictor (4 arrays): two comb
  predict ports (U/V) + one synchronous update transaction. Commit `f782700`.
- `rtl/mem/tlb.sv` (134 L) — ONE parameterized `tlb #(IS_D)` instantiated **twice**
  (`u_itlb`/`u_dtlb`): comb lookup + pulsed fill-commit (driven from the spine S_WALK)
  + CR3-flush (val-bits only). The page-walk FSM stays in the spine. Commit `544a365`.
- `rtl/mem/icache.sv` (150 L) — the functional I-cache (`ic_data/ic_tag/ic_val/ic_lru`):
  per-word fill + fill-complete MRU + 3 mutually-exclusive LRU-touch ports (U/straddle/V,
  last-write-wins order preserved), arrays exposed read-only so the spine keeps its
  `ic_present/ic_byte` probes verbatim; victim picked in-spine from pre-edge LRU. Commit
  `6bb98ea`.

**Left in the spine (proven spine-bound — honest):**
- **regfile `gpr[8]`** — 88 write statements; CONFIRMED 2-writes/clock (dual-issue U+V,
  XCHG, MUL/DIV EAX+EDX, CDQ/CWD, POP/LEAVE dst+ESP). Bit-exact extraction needs a
  2-write-port mux + re-routing all 88 arms = an FSM restructure, not a lift.

**fpu-state — re-attacked and EXTRACTED bit-exact (was initially logged spine-bound).**
The first R2 pass deferred fpu-state as "needs an FSM rewrite." A second analysis fan-out
found that was over-conservative: the only 2-write-port patterns are FXCH (a 2-slot SWAP)
and FCOMPP/FUCOMPP (2 adjacent tag bits) — both ISOLATED and expressible as dedicated
`we_fxch`/`we_pop2` ports rather than a generic dual-write mux, and the two writer arms
are RUNTIME-EXCLUSIVE (fast M5 cycle-mode vs slow S_FEXEC/S_FSTORE) so per-category
strobes safely OR. The cross-leaf `FNSTSW AX`→`gpr[EAX]` and the scoreboard simply STAY
in the spine (the module exposes `fstat_o`/`ftop_o` read ports). See the fpu_top entry in
the R2 log for the full extracted-vs-stayed split + the byte-identical proof.

**Honest note on size:** the leaf *logic* moved into 473 lines of self-contained,
separately-readable modules, but `core.sv` did **not** shrink (5741 → 5990) — the
port-wiring + combinational drivers + comments for the small/timing leaves exceed the
inline logic removed. The win is **separation + testability + clear interfaces**
(each leaf now has a documented port boundary), not raw line reduction. Behavior is
bit-exact: this is verified, not asserted.

**Verification (independently re-run on the final HEAD `6bb98ea`):** `make verify`
(user) PASS (56/56 func + all M4/M5 cycle bands — cache/BTB-sensitive bands clean:
dmiss +0.10%, imiss +0.14%, brloop 7/3004 mispred, brrandom 251/400); all **9** sys
gates green (pseg 70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 / pcpl 304 /
pdebug 239 RTL `--system` EQUIVALENT; ptask self-diff; psmm structural); verilator
lint clean (0 warn/err). Adversarial review verdict: GENUINE + behavior-preserving
(one cosmetic INFO: an unread `itlb_lk_perm[2:1]` slice, waived by `-Wno-UNUSED`).

### R2 log

- 2026-06-04 — R2 opened; roadmap snapshot recorded; leaf analysis launched.
- 2026-06-04 — R2 done: dcache_timing/bpred_btb/tlb(×2)/icache extracted bit-exact
  (`ed573c3`/`f782700`/`544a365`/`6bb98ea`); regfile + fpu-state documented spine-bound.
- 2026-06-05 — **fpu_top (the x87 STATE FILE) extracted bit-exact** — the 5th leaf;
  reverses the earlier "fpu-state spine-bound" call (it was extractable after a richer
  write-port design). Reviewed + gate-verified independently below.
- 2026-06-05 — **dead-stub cleanup.** Removed the 4 remaining empty M0-skeleton stub
  modules whose logic is spine-resident: `core/fetch.sv` (the fetch FSM IS the pipeline;
  its I-cache is already `icache.sv`), `core/exec_int.sv` (the execute FSM IS the
  pipeline; its ALU is already `ventium_alu_pkg`), `sys/sys_state.sv` (CRx/seg-hidden/
  GDTR/IDTR/TR/DR — many-write-port FSM-coupled state), and `core/regfile.sv` (the GPR
  file — spine-bound: true dual-issue 2-write-port; COULD be lifted to a state-bank
  module later via the fpu_top pattern for a clean R2 6-of-6, but removed here as a dead
  placeholder, not extracted). Deleted the files + their `ventium_top` no-op
  instantiations + their `ventium.f`/`ventium_soc.f` entries (consistent with the earlier
  `ucode_rom` removal). Also FIXES the `ventium_soc.f` MULTITOP lint warning (the stubs
  were uninstantiated extra tops). `make verify` bit-identical (0 goldens regenerated —
  the stubs were no-ops); ventium.f + ventium_soc.f both lint 0; SoC gate still EQUIVALENT.

### fpu_top — x87 architectural STATE FILE extraction (2026-06-05, bit-exact)

**What this is.** `rtl/fpu/fpu_top.sv` (the M0 empty placeholder, previously a no-op
`fpu_top u_fpu(.clk,.rst_n)` stub in `ventium_top.sv`) is now the REAL x87 architectural
STATE FILE, instantiated as `u_fpu_state` INSIDE `core.sv` (FP state interacts with the
core FSM, so it is a core submodule — same pattern as the dcache/tlb in-core instances).
The `ventium_top` stub is removed (like the earlier ucode/dcache/tlb stub removals).

**EXTRACTED into `fpu_top` (the module owns):** the 8×80-bit physical stack `fpr[8]`, the
3-bit TOP pointer `ftop`, the control/status/tag words `fctrl`/`fstat`/`fptag`; the
synchronous FNINIT power-on reset (`ftop=0`/`fctrl=0x037f`/`fstat=0`/`fptag=0xFF`,
`fpr[]=0`); the TOP-relative `st(i)` read addressing exposed as combinational read ports
(`st0..st7` = `fpr[ftop+i]`, `rd_phys_top` = `fpr[ftop]`, raw `ftop_o/fstat_o/fctrl_o/
fptag_o`); and a write-port set covering EVERY observed mutation pattern — `we_push`
(ftop--/`fpr[ftop-1]`/tag-clear), `we_top`+`we_fstat`, `we_sti` (with `wsti_clr_tag`
distinguishing FST_STI which clears the dest tag from AR_STI_ST0 which does not), the
2-slot `we_fxch` SWAP, `we_pop`, `we_pop2` (FCOMPP/FUCOMPP), `we_ffree`, `we_incstp`/
`we_decstp`, `we_fctrl` (FLDCW), `we_fninit`. The module owns the OLD-ftop NBA index
arithmetic internally (push uses the registered `ftop-1`, pop uses `ftop`, sti uses
`ftop+idx`, ftop bumped in the same `always_ff`), so the inline NBA ordering is
reproduced VERBATIM.

**STAYED in the spine (`core.sv`):** (a) the entire DATAPATH — every floatx80/fstat value
is still computed by `fpu_x87_pkg` calls (`f_eval`/`fconst`/`apply_cmp`/`fcom_codes`/
`fcom_ie`/`fxam_codes`/`fx_sqrt`/`f_mem_as_*`/`f_arith_fstat` + the `fstore_val` narrow),
now in a new `fp_we_*` combinational driver that re-derives BOTH writer guards and drives
the module's write ports (the module NEVER computes a floatx80 and NEVER masks fstat);
(b) the M5 FP scoreboard (`fp_ready_cyc`/`fp_occ_pending`/`fp_issue_cyc`) + its reset +
the issue-stall/occ-burn gates; (c) the S_FEXEC/S_FSTORE FSM sequencing + the
`f_pc_bad`→S_HALT gate + the `f_do_store`/`f_do_retire` transition; (d) `FNSTSW AX` →
`gpr[EAX]` (cross-leaf: reads `fstat_o`/`ftop_o`, writes the integer file); (e) the trace
overlay `retire_fstat=(fstat&~0x3800)|(ftop<<11)` / `retire_ftag=0` / `x87_touched_r`.
`fstat` is presented to the module FULLY COMPUTED (the spine does all masking/merge/
sticky-OR) and exposed RAW (TOP not overlaid) so the overlay + FNSTSW stay byte-identical.

**Bit-exact proof (independently re-run + reviewed 2026-06-05).** Established the
pre-refactor BASELINE by reverting the 3 RTL files to HEAD, rebuilding, and capturing the
RTL traces; then diffed against the refactored traces:
- **`make m3` GREEN — 57 PASS / 0 FAIL**, and the 57 RTL `.vtrace` outputs are
  **0/57 differing** (BYTE-IDENTICAL) vs the baseline snapshot — `retire_st0..st7`/
  `fctrl`/`fstat`/`ftag` all identical across the 14 x87 programs + the integer suite.
- **`make verify` GREEN + BYTE-IDENTICAL** — func 57/57; the 68 verify RTL traces are
  **0/68 differing** vs baseline (incl. the M5 cycle-mode FP traces). Every cycle band
  matches the baseline TO THE DIGIT: mb_faddchain CPI **3.010** (lat-3 chain), mb_fpindep
  CPI **1.158** (< chain), mb_dmiss **2.504**, mb_imiss **6.009**; abs-cyc deltas
  depadd +2.85% / indepadd +6.16% / agi +2.84% / brloop +0.23% / brrandom +0.27% /
  dmiss +0.10% / imiss +0.14% — all unchanged. **Goldens regenerated: 0** (57/57 func
  cache hits, 67 cached, 0 new — the `.s` sources are untouched).
- **2-write-port FXCH + push/pop ftop/tag semantics PRESERVED** — exercised by tx_chain
  (FXCH reorder) + tx_stack (`fxch %st(7)` deep-swap + bare-FXCH) + the load/store/pop
  corpus; all byte-identical. The FST_STI-with-pop tag-bit corner (sti==0: `we_sti` tag-
  clear then `we_pop` tag-set on the same bit) preserves the inline last-write-wins order
  (the module's `we_pop` block is textually after `we_sti`, so pop wins — matches HEAD).
- **Lint clean** — `verilator --lint-only -Wall` line-normalized diff vs HEAD: **0 NEW
  warnings**, and one warning REMOVED (a dead `logic resv` local the refactor dropped).
  ZERO non-UNUSED warnings (no MULTIDRIVEN/LATCH/UNOPTFLAT/WIDTH) — the spine `logic`
  aliases `ftop/fctrl/fstat/fptag` are single-driver (the module `*_o` outputs), the
  `fp_we_*` `always_comb` is fully defaulted (no latch), no comb loop through the read→
  drive→write path. No NBA-order change.
- **Scope clean** — only `rtl/core/core.sv`, `rtl/fpu/fpu_top.sv`, `rtl/ventium_top.sv`
  touched; `rtl/soc`/`verif/soc`/`ventium-refs` and the M8 SoC files UNTOUCHED. Not
  committed — the orchestrator verifies + commits.

## M2S.4b — HARDWARE TASK SWITCH (far `JMP` to a 32-bit TSS) — CLOSES the M2S.4 deferral

The gnarliest M2S.4 deferral — the **hardware task switch** — now lands as a real RTL
`--system` differential, and `ptask` is **promoted from golden self-diff to a REAL RTL
`--system` diff EQUIVALENT to the golden, 292 records**. M2S.4 had left a far
`JMP`/`CALL` to a SYSTEM (TSS) descriptor HALTing cleanly in `S_LJMP` (no mis-delivery);
`ptask` tracked the golden bit-for-bit to ~n=275 then halted at the ljmp-to-TSS, staying
self-diff + the step-5d validation only and OUT of `RTL_SYS_TESTS`. M2S.4b implements
the switch and promotes the gate.

### What landed (RTL, gated `sys_mode`; IA-32 SDM Vol.3 §7.3)

A far `JMP` whose target GDT descriptor is an available (type `0x9`) or busy (`0xB`)
32-bit TSS dispatches out of the `S_LJMP` system-descriptor arm into a four-state
task-switch micro-sequence (new states `S_TSW_SAVE/_READ/_SEG/_BUSY` in
[`rtl/core/core.sv`](rtl/core/core.sv)):

- **S_TSW_SAVE** — write the OUTGOING task state into the CURRENT TSS (`tr_base`), one
  dword per beat at the documented 32-bit-TSS offsets: EIP@0x20 (= the insn after the
  jmp = `next_eip`), EFLAGS@0x24, the 8 GPRs@0x28..0x44, the 6 segment selectors
  ES@0x48/CS@0x4C/SS@0x50/DS@0x54/FS@0x58/GS@0x5C, LDTR@0x60.
- **S_TSW_READ** — read the INCOMING state from the NEW TSS (named by the jump selector,
  base from its GDT descriptor) into `tsw_*` holding regs: CR3@0x1C, EIP@0x20,
  EFLAGS@0x24, the GPRs, the 6 selectors, LDTR.
- **S_TSW_SEG** — reload each of the 6 incoming segment descriptors' hidden
  base/limit/attr from the GDT (two reads per descriptor); CPL ← the new CS.RPL,
  `cs_d` ← its D/B bit.
- **S_TSW_BUSY** — toggle the descriptor busy bits (a JMP CLEARS the outgoing TSS busy
  `B→9` and SETS the incoming one `9→B`, via single-byte GDT writes to the access byte),
  then COMMIT atomically: new TR (`tr_base/limit/sel` + `tr_attr`), `CR0.TS=1`, the
  incoming EIP/EFLAGS/GPRs/CR3, and retire ONCE (`q_pc` = the jmp PC).

A JMP does **not** set EFLAGS.NT or the TSS back-link (only a CALL / interrupt-task-gate
does). A new `tr_attr` reg captured at `S_LTR` holds the outgoing TSS descriptor access
so its busy bit can be cleared on a switch without a re-read. The TSS/GDT accesses are
excluded from the paging post-translate (identity-map convention, paging off in the
corpus). One bring-up bug found+fixed: the `tsw_save_off`/`tsw_read_off` field-offset
helpers first returned 6-bit values, so offsets ≥0x40 (the segment selectors at
0x48..0x60) overflowed and aliased to low addresses (0x48→0x08), zeroing all 6 selectors
(cs=0x0000 → wrong `cs_d` → 16-bit mis-decode). Widened the helpers to 8-bit; cs/ss/ds/
es/fs/gs then reload correctly and the diff is EQUIVALENT.

`ptask` is now in `RTL_SYS_TESTS` in [`verif/sys/run-sys-golden.sh`](verif/sys/run-sys-golden.sh)
→ step-7 RTL-SYS-DIFF-OK; the `verify-sys` Makefile target already listed it.

### ptask gate record (independently re-run 2026-06-05, PORT 57310)

Golden 292 records; step-5d HARDWARE TASK SWITCH validation VALID (state save + reload
+ busy toggle); step-6 self-diff EQUIVALENT; **step-7 RTL `--system` diff EQUIVALENT
292/292** (`compare.py` sys path engaged, cr0..cr4 + selectors + GPRs + eflags + eip).
Proofs all matched in the golden AND reproduced by the RTL (the diff is byte-equivalent):
- **n=275** — incoming reload: EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x00070000, plus
  `CR0.TS` set (cr0 0x60000011→0x60000019) and EFLAGS←TSS2.
- **n=285/286** — outgoing SAVE proof: EDX=0x000F01D8 (TSS1 saved resume EIP), then
  ESI=0x1A1A1A1A (the live EAX saved into TSS1, read back).
- **n=289** — busy-toggle proof: EDI=0x0000898B (TSS1 access 0x89 *available*, TSS2
  access 0x8B *busy*).

### ADDITIVE proof (independently re-run 2026-06-05)

- **`make verify` (user) GREEN + bit-identical** — exit 0; 57/57 func diff-clean
  (0 goldens regenerated); all M4 integer + M5 FP/cache bands met. The whole task
  switch is gated behind `sys_mode`, INERT in user mode — `S_LJMP` is only reached from
  the protected-mode (`!seg_real`) far-jump slow-FSM path, itself `sys_mode`-only.
- **All prior sys gates stay EQUIVALENT** (RTL `--system` diff, RTL-SYS-DIFF-OK): pseg
  70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 / **pcpl 304** / pdebug 239 /
  **pv86 949** — and **psmm SMM-PARTIAL-OK** (structural; differential oracle infeasible).
  The cross-priv/TSS-adjacent ones (pcpl PORT 57320, pfault 57330, pv86 57340)
  re-confirmed EQUIVALENT.
- **Lint clean** — `cd rtl && verilator --lint-only -sv -Wall -Wno-UNUSED -f ventium.f`
  → exit 0, 0 warn/err.
- **Review findings:** none supplied for this close-out (empty set) — nothing to apply.
- Ports 57310/57320/57330/57340 + 57350–57400 (all 57000–57999). **Not committed** —
  the orchestrator verifies + commits. `ventium-refs/` untouched (read-only).

### Deferred (honest done-partial; not in the `ptask` corpus — no oracle to differentially validate)

The `CALL`-far / `INT`-through-task-gate task switch (sets EFLAGS.NT + the TSS
back-link@0x00 — a JMP does NOT); `IRET` with NT=1 (the task-return); the round-trip
switch-back (reloading the CPU-written outgoing TSS image — the gnarliest reload); LDTR
descriptor reload (no LDT machinery — the LDTR slot is saved/skipped, 0 in the corpus);
`tr_valid`/`tr_limit` #TS bound + TSS-descriptor type/present #GP/#NP negative paths.

## M7 — macro-workload lock-step (Quake + Win95) — OPENED 2026-06-04

Per user direction (Quake via QEMU-proxied syscalls; Win95 via a real system
co-sim built now — V86 + co-sim bus; **run each as far as feasible**). Architecture
in [`docs/m7-lockstep-spec.md`](docs/m7-lockstep-spec.md): **input-replay lock-step**
— QEMU is the golden + environment, the RTL is the checked CPU, the trace carries
arch state + the environment inputs each instruction consumed (syscall effects for
Quake; device-read values + delivered interrupts for Win95), the TB replays those
inputs, and the comparator grades only the CPU. Stages: M7.0 oracle/contract +
de-risk (running) → M7.1 Quake (ELF loader + int-0x80 proxy) → M7.2 V86 mode →
M7.3 Win95 device-input replay + boot-prefix run.

### M7.3 log (Win95 system co-sim)

- 2026-06-05 — **M7.3a DONE (producer half): a deterministic Win95 boot-prefix golden
  exists.** Per the M7.0 partial-go, built the record/replay environment + the
  `--system-replay` producer:
  - **Record artifact** (`verif/m7/win95/record.sh` + `replay-verify.sh`): `rr=record`
    over a **COW overlay** of the read-only `win95.qcow2` (base untouched — verified
    sha unchanged), `-rtc base=utc`, `-net none`, bounded; → `replay.bin` (4.7 MB
    deterministic event log). `rr=replay` is **bit-reproducible** — two replays
    byte-identical (23 IRQ0 / 126,573 device reads / 40,186 writes, per-class identical).
    Landmines fixed: `-boot order=c` is non-replayable (omit); QEMU needs a flush-grace
    after stop or the rrfile truncates; `shift=auto` freezes replay at the first timer →
    use `shift=4`.
  - **De-risk CORRECTION:** the gdbstub does NOT answer under `-icount rr=replay` (the
    replay engine blocks the stub). The working capture path is
    `-accel tcg,one-insn-per-tb=on -d cpu` (full register dump per instruction) with
    `int`+`memory_region_ops` in the SAME `-D` log so textual order = replay-icount
    order. `gen_trace.py --system-replay` (two-pass: initial phys-mem at reset + the
    aligned `-d cpu` stream) + `replaylog.py` (the alignment engine) implement it.
  - **300,000-instruction system golden** (`win95-boot.vtrace`, 228 MB): full per-record
    arch state (pc + GPRs + eflags + 6 sels + cr0..cr4 + segment-hidden base/limit/attr),
    **byte-identical across two independent passes** (sha `c1486a6f…`), self-compares
    EQUIVALENT through compare.py. Reaches reset F000:FFF0 → real-mode SeaBIOS POST →
    **real→protected transition (CR0.PE 0→1 at record 23)** → PM BIOS + PCI enumeration.
  - **Trace contract** (`tracefmt.py` dev_in/dma_wr/hwint/intr fields; all optional,
    none in `func_compare_keys` ⇒ replayed, never graded): `dev_in:[{addr,val,size,region}]`,
    `dma_wr:[…]`, `intr:{vec,err,…}`.
  - **Consumer (M7.3b) plan + first RTL gaps (in prefix order):** GAP 2 (the FIRST wall)
    — the core does NOT decode `IN`/`OUT` (E4–E7, EC–EF) at all → it would HALT at the
    record-13 RTC `in`; must add IN/OUT decode + the co-sim `dev_in` bus. GAP 1 — no
    async-interrupt injection port (the 300k prefix has **0 interrupts** — first IRQ0 is
    at insn ~6.2M — so this is deferrable for the bounded bring-up). **Verdict: PARTIAL —
    GO on the bounded 300k prefix; the interrupt region + full GUI boot stay
    throughput-deferred (honest, never faked).**

- 2026-06-05 — **M7.3b DONE (consumer): Win95 boots bit-exact on the RTL to 213,859
  instructions.** The co-sim consumer half — the RTL is the checked CPU, qemu's
  recorded environment is replayed, the comparator grades only CPU arch state.
  - **IN/OUT decode** (E4–E7 / EC–EF: IN/OUT imm8 + DX, byte/word/dword) as a new
    S_IO bus-handshake state: an `IN` takes its value from the new co-sim `io_*` bus
    (the recorded `dev_in`), an `OUT` drives `io_wdata` (the existing `out 0xf4`
    isa-debug-exit is preserved). Plus **CPUID** (0F A2, a deterministic `-cpu pentium`
    leaf table) and **INS/`rep insb`** (6C/6D), and two real-mode operand-size decode
    fixes (Jcc 0F 8x / JMP E9 / near branches → rel16 + 16-bit target mask in 16-bit
    mode). ALL gated on a new `cosim_en` (or 32-bit/non-cosim-inert), so every prior
    gate is byte-identical. (A transient dropped-`A7`-CMPSD decode arm was caught +
    fixed during the build.)
  - **Co-sim bus** (`verif/tb/win95_cosim.{h,cpp}` + tb `--win95-image`/`--lockstep`):
    loads the phys-mem/BIOS image, cold-resets at F000:FFF0 (the core's own system
    reset = golden record 0), and on each RTL `IN` returns the next recorded `dev_in`
    value (masked to size, order-checked). The ONLY injected state is the device-read
    VALUE into eAX (audited HONEST — no CPU register/flag/eip is fabricated; the RTL
    computes everything else, incl. the `OUT`s that drive fw_cfg). No DMA-into-RAM is
    applied because every `dma_wr` in the prefix is a CPU-driven `OUT` to a port, which
    the RTL executes itself.
  - **Result (independently re-verified):** the RTL runs the full **300,000**-record
    prefix without an ISA halt and is **bit-exact through record 213,859** — crossing
    the real→PM transition (CR0.PE 0→1 @ record 23), the IN/OUT wall, CPUID, the BIOS
    shadow-copy, and the fw_cfg `rep insb` — a **~6,700× reach increase**. The first
    divergence (record 213860, `mov eax,[esp]`, golden `eax=0` vs RTL `0x0a001900`) is
    **NOT a CPU bug**: it reads a fw_cfg **DMA-to-RAM** word the device cleared in
    guest RAM — the producer's `memory_region_ops` capture traces device-REGION
    accesses, not fw_cfg DMA into plain RAM, so the harness can't replay it; the RTL
    correctly reads the value it itself wrote. A harness environment-capture gap,
    characterized honestly (pushing past needs a guest-RAM-diff capture — a deferred
    harness feature). `--dedup-golden` (compare_stream) collapses the 4–8 verbatim
    full-arch re-dumps qemu's `one-insn-per-tb -d cpu` emits for `rep` re-entries
    (audited: byte-identical on every graded field incl. pc ⇒ provably tracer
    re-dumps, not retirements) — an alignment fix on a known producer artifact, NOT a
    comparator weakening (default OFF; the per-field grading stays byte-strict).
  - ADDITIVE: `make verify` 57/57 GREEN, all sys gates EQUIVALENT (pseg/pmode/ppage/
    pintr/pfault/pcpl/pdebug/pv86 + ptask/psmm), Quake lock-step still bit-exact, lint
    clean. Reproducer: `verif/m7/win95/run-win95-cosim.sh`.
  - **M7 COMPLETE (honest):** both requested macro-workloads run in lock-step on the
    RTL — Quake bit-exact to ~1.106M instructions (frontier = vDSO clock), Win95 boot
    bit-exact to 213,859 instructions (frontier = fw_cfg DMA-to-RAM). 6 real ISA gaps
    found + fixed across the two (TEST mem-form, call gs:[], LOCK CMPXCHG, IN/OUT,
    CPUID, INS) + V86 mode. Both frontiers are documented HARNESS/throughput limits,
    never CPU defects; a full Quake frame / Win95 GUI boot stays throughput-deferred.

### M7 log

- 2026-06-04 — M7 opened; spec written; M7.0 oracle de-risk launched (Quake syscall
  capture / Win95 device+interrupt capture / throughput / V86 scope).
- 2026-06-04 — **M7.0 de-risk DONE.** Verdicts:
  - **Quake: GO.** `int 0x80` is dispatched inside QEMU's host `cpu_loop` (not as
    stepped guest code), so ONE RSP `s` over a syscall site runs the whole kernel
    emulation — the post-step `g`-packet already has `eax=ret` AND every kernel
    memory write applied. Capture: read 2 bytes at EIP (`==cd80`, catches the
    musl/vDSO `__kernel_vsyscall` stub a static-site set would miss), snapshot
    nr+args, step, read `ret`=eax + the kernel-written region via RSP `m`+diff per a
    per-nr dispatch table. Proven: 38 syscalls in exact `-strace` order; all 3
    write classes (zero-fill anon `mmap2` 32 MB zone, struct-fill `clock_gettime64`,
    read-buffer `readv` → `pak0.pak` 'PACK' magic). Deterministic via `-seed` +
    static no-PIE EXEC. No qemu hook/plugin needed.
  - **Win95: PARTIAL-GO.** All 3 input classes (PIO/MMIO read VALUE via the dest GPR;
    interrupt VECTOR+BOUNDARY) capturable over the same gdbstub — but ONLY under
    **record/replay** (`rr=record`→`rr=replay` + blkreplay COW overlay + drop
    `-rtc base=localtime`), because plain `-icount` diverges at the first RTC read.
    rr=replay is bit-identical across runs (33,511 ints / 2,232,434 reads identical
    twice). Full boot is throughput-deferred.
  - **V86: GO (lands 100%).** Method-1 (VME-off) subset — `v86=sys_mode&eflags[17]`,
    IOPL guards (`CLI/STI/PUSHF/POPF/INT n/IRET/IN/OUT`→`#GP` when `iopl<3`), sel<<4
    seg bases + forced CPL3 + the 9-word V86 exception frame. A closed ~400-insn
    bare-metal gate, fully oracled by the existing sys contract.
  - **Throughput (the binding limit):** RTL ~95k insns/s; gdbstub oracle was ~12
    insns/s (latency-bound RSP), **fixed ~300–600× by adding `TCP_NODELAY`** to the
    RSP socket (this commit) → ~10k insns/s. Feasible prefixes: Quake overnight
    ~hundreds-of-k–few-M insns (covers full process init + the 38-syscall surface;
    a full frame in a multi-hour window; a full timedemo is OFF the table); Win95 a
    bounded boot prefix. **The harness is architecturally complete; the RUN is
    throughput-capped — bounded honestly, never faked.**
  - Enabler landed: `gen_trace.py` `TCP_NODELAY` (speed-only; every existing golden
    bit-identical — pseg re-verified EQUIVALENT). Next: M7.1 (Quake harness:
    producer int-0x80 proxy + TB ELF/process-image loader + int-0x80 proxy).
- 2026-06-04 — **M7.1 DONE: Quake lock-step is BIT-EXACT over a 30k-insn prefix.**
  The full input-replay harness works end-to-end and grades only the CPU:
  - **Producer** (`gen_trace.py --syscall-proxy` + `tracefmt.py` `sys_call` field):
    single-steps `tyr-quake-p5` under `qemu-i386 -seed 1234`, captures each int-0x80
    effect (eax=ret + kernel memory writes via the per-nr dispatch table; `%gs` TLS
    base from `set_thread_area`) and the initial process image (PT_LOAD + stack +
    vDSO stub). 9 syscalls captured in the prefix.
  - **Consumer** (TB `quake_image.cpp` loader + the int-0x80 proxy + a `proxy_en`-gated
    user-mode `%gs` base in `core.sv`/`ventium_top.sv`): loads QEMU's process image,
    replays each `sys_call` effect at the int-0x80 boundary (writes→bus, eax+gs→core),
    runs the RTL as the checked CPU. The proxy injects ONLY the kernel environment
    effect — never CPU-computed state (review-audited HONEST).
  - **Result: 30,000 / 30,000 records EQUIVALENT** (`compare.py` exit 0), independently
    re-run from a clean TB rebuild + a fresh trace. Negative controls (corrupt eax/
    ebx/gs, truncate) all correctly DIVERGENT — the grade is real. All 9 int-0x80
    boundaries + the `%gs` 0x2b→0x33 TLS transition (correct for 28,551 records) match.
  - **2 genuine ISA gaps found + fixed** (the payoff of a macro-workload): `TEST r/m,imm`
    memory form (`F6/F7 /0,/1` mod≠11) and the operand-segment base for an indirect
    `call gs:[0x10]` under a segment override — both forms the M1–M6 corpus never hit,
    fixed additively + differentially re-validated by the lock-step.
  - ADDITIVE: `make verify` GREEN (56/56 goldens byte-identical), all 9 sys gates
    EQUIVALENT, lint clean — the proxy/`%gs` path is inert without `--quake-image`.
  - Reproducer: `verif/m7/run-quake-lockstep.sh [N] [PORT]`. The run length is
    oracle-bound (gdbstub ~10k insn/s); a longer background prefix follows.
- 2026-06-05 — **M7.1 LONGEST-RUN: Quake bit-exact to 1,106,162 instructions, then
  a named ISA wall.** Ran a ~9.6M-record background golden (timeout-bounded) and the
  RTL lock-step against it via a new O(1)-memory streaming comparator
  (`verif/diff/compare_stream.py`, reuses compare.py's exact func+eflags grading;
  24 MB RSS for 9.6M records vs compare.py loading all into RAM). Result: **1,106,162
  instructions EQUIVALENT** (independently streamed; the 1M cross-check matches
  compare.py; corrupt control DIVERGENT) — then the RTL HALTed (went quiescent) on
  the instruction at n=1106162, pc=0x080a7810, bytes `f0 0f b1 97 f4 33 00 00` =
  **`LOCK CMPXCHG dword ptr [edi+0x33f4], edx`** — `CMPXCHG` (0F B1) with a memory
  operand, undecoded by the core (musl's atomic/lock path). A genuine, precisely-
  named coverage gap — the **3rd** ISA gap the Quake macro-workload has surfaced
  (after `TEST r/m,imm` mem-form + the `call gs:[]` operand segment in M7.1). The
  run went as far as the RTL's ISA coverage allows; the wall is real, not a harness
  artifact (everything before it is bit-exact). Next: implement `CMPXCHG` (0F B0/B1)
  to push the frontier (it also benefits Win95).
- 2026-06-05 — **CMPXCHG (0F B0/B1) implemented + the Quake frontier is now a HARNESS
  time-boundary, not a CPU gap.** Added `CMPXCHG r/m8,r8` + `r/m16/32,r16/32` (reg +
  mem forms, all widths, LOCK=no-op on the in-order core) as a new `K_CMPXCHG` slow-FSM
  RMW: flags = `CMP acc,temp`; equal⇒dest←src, ZF=1; not-equal⇒acc←temp, ZF=0 (mem
  written back unchanged for atomicity, matching QEMU). The equality decision is latched
  (`cmpxchg_wrsrc_r`) across S_EXEC→S_STORE so the not-equal acc update can't corrupt the
  store-data resolver. **Validated:** targeted differential test `verif/tests/t_cmpxchg`
  EQUIVALENT vs QEMU (both opcodes, reg+mem, equal+not-equal, 8/16/32-bit, LOCK form);
  `make verify` PASS **57/57**; the Quake lock-step now **passes the old wall at
  n=1106162** (the `lock cmpxchg [edi+0x33f4],edx` executes bit-exact) and runs the full
  1.2M instructions. The next divergence (n≈1,106,793, `mov ecx,[esp+0x18]`) is **NOT a
  CPU bug**: it reads `tv_nsec` from a **vDSO `__vdso_clock_gettime`** result — the vDSO
  reads the kernel vvar time page directly in userspace (no syscall, so the proxy can't
  replay it), and host wall-clock advances between golden-gen and the RTL run (tv_sec
  matched, tv_nsec didn't). So the Quake user-mode frontier is now bounded by **vDSO
  clock nondeterminism** (the documented harness time class), with the CPU proven
  **bit-exact over ~1.106M instructions** of real Quake code. Pushing further would
  require replaying the vvar-page reads as inputs (a harness feature, diminishing
  CPU-verification returns) — deferred. Lint clean; sys gates green.
- 2026-06-05 — **M7.2 DONE: VIRTUAL-8086 mode (method-1 / VME-OFF) RTL-diffs
  EQUIVALENT 949/949.** The `pv86` bare-metal gate boots real→protected→paging→TSS,
  ENTERS V86 by an IRET of a 9-word V86 frame (EFLAGS.VM 0→1, CPL 0→3, sel<<4 seg
  bases, paging still live), exercises V86 sel<<4 segmentation, and routes 6 IOPL-
  sensitive ops (CLI/STI/PUSHF/POPF/INT 0x21/INT 0x20 at IOPL=0) as `#GP(0)` to the
  CPL0 monitor, each pushing the 9-word V86 frame on TSS.SS0:ESP0 with VM cleared +
  DS/ES/FS/GS zeroed, then IRETing back into V86.
  - **What landed (RTL delta in `rtl/core/core.sv`, all gated behind
    `v86=sys_mode&&eflags[17]` so it is INERT when EFLAGS.VM=0):** (a) `v86`/`iopl`/
    `seg_real`/`eff_cpl` signals (`eff_cpl` feeds the #PF US-bit + perm_fault);
    (b) MOV-sreg + far-jump `sel<<4` bases under `seg_real` (no GDT read); (c) the
    IOPL guard at `S_DECODE` → `#GP(0)` to the monitor for CLI/STI/PUSHF/POPF/INT n/
    IRET when `iopl<3`; (d) the 9-word V86 frame in `S_INT_PUSH` (`from_v86`: push
    GS..EIP+errcode, clear VM, zero DS/ES/FS/GS) reusing the `xpl_active` TSS switch +
    the cross-priv decision via `eff_cpl`, and `S_IRET` return-into-V86 (popped
    EFLAGS.VM=1 from CPL0 → 9-word pop, force CPL3, sel<<4 bases). `int_step` widened
    3→4 bits for the 10-beat push. Two corpus-surfaced fidelity fixes (additive):
    MOV-moffs A0–A3 width now follows `eff_addr` (16-bit moffs under V86/real); the
    `pv86.ld` `.reset` LMA pinned with `AT()` so the reset `ljmp` is not truncated
    (golden regenerated 956→949).
  - **M7.2 review finding applied (robustness, no functional change):** in `S_INT_CS`
    the `from_v86` latch is now gated on the SAME cross-priv predicate that loads
    `int_new_esp`/SS from the TSS — `from_v86 <= v86 && (tgt_dpl < eff_cpl)` (was
    `from_v86 <= v86`). A correct V86 monitor's IDT gate always targets a CPL0
    handler (`tgt_dpl<eff_cpl=3`), so this is a no-op for every valid delivery (the
    corpus stays 949/949). It closes the latent path where a malformed V86 gate to a
    DPL3 target would take the same-priv push arm yet still set `from_v86=1`, emitting
    the 9-word frame off a never-loaded `int_new_esp`/SS base. Pure hardening.
  - **pv86 gate record (re-run from a fresh TB build + fresh deterministic golden,
    PORT 53310):** golden 949 records; step-5e V86 validation VALID (V86 entry VM 0→1
    + CPL 0→3 + PG live at n=692; 6 IOPL-sensitive `#GP` deliveries to the CPL0
    monitor with the TSS stack switch + VM cleared at n=698/736/777/820/865/903; IRET
    back into V86 VM 0→1 at n=735/776/819/864/902); step-6 self-diff EQUIVALENT;
    **step-7 RTL --system diff EQUIVALENT 949/949** (`compare.py` exit 0, cr0..cr4 +
    selectors + GPRs + eflags + eip). Success proof matched: ecx=0x6 (6 deliveries),
    eax=0x1 (CLI count), ebx=0x02010101, edx=0x20→0xf4, esi=0xcafebabe (V86 sel<<4
    sentinel read back from linear 0x20000). The negative control (corrupt esi
    sentinel) is correctly DIVERGENT, so the grade is real; the golden is
    deterministic/byte-identical across regen.
  - **ADDITIVE proof (independently re-run 2026-06-05):** `make verify` GREEN +
    bit-identical (56/56 func goldens, 0 regenerated; all M4 integer bands + M5 FP/
    cache bands met). All 7 differential sys gates stay EQUIVALENT — pseg 70 / pmode
    1084 / ppage 128 / pintr 171 / pfault 348 / pcpl 304 / pdebug 239 — and the
    structural gates stay green (ptask SELF-DIFF-OK + task-switch VALID, psmm
    SMM-PARTIAL-OK). Lint clean (`verilator --lint-only -Wall -Wno-UNUSED` → 0
    warn/err; the `int_step` 3→4 widening is width-clean). The V86 path is fully
    inert without EFLAGS.VM=1, so the user gate is unaffected. Harness: `pv86` is in
    `RTL_SYS_TESTS` in `run-sys-golden.sh` + a `PORT=53220 pv86` line in the
    `verify-sys` Makefile target.
  - **Deferred (out of scope per the brief, documented follow-on):** VME/VIF/VIP +
    the interrupt-redirection bitmap (method-2). INT3 (0xCC) and INTO (0xCE) are not
    IOPL-trapped under V86 (distinct #BP/#OF V86 semantics, never exercised by the
    corpus — un-oracled, documented in-code). IN/OUT IOPL trapping is not wired
    because this core does not decode the IN/OUT opcodes at all (no oracle in the
    corpus; the V86 task uses CLI/STI/PUSHF/POPF/INT n) — documented in the IOPL-guard
    comment + manifest. The non-V86 #DF nesting / SS-RPL revalidation deferrals from
    M2S.4 are unchanged (pre-existing, not touched).
  - Reproducer: `PORT=53xxx bash verif/sys/run-sys-golden.sh pv86`. The `pv86` test
    dir is the Corpus-phase deliverable (currently git-untracked); `ventium-refs/`
    untouched (read-only).

## M6B — 5th selectable erratum: Erroneous #DB on V86 POPF/IRET with a #GP (Err 79) — OPENED + DONE 2026-06-05

- 2026-06-05 — **M6B DONE: Erratum 79 (242480-041 printed p.50 / PDF p.58, NoFix)
  reproduced behind `errata_en[4]` (`0x10`), DEFAULT OFF, and self-checked vs the
  DOCUMENTED Spec-Update text — `make m6` is 15/15 PASS (was 11/11).** This is the
  one M6B candidate whose required infra all already existed (V86 = M7.2, DR0–3 data
  breakpoints + #DB delivery = M2S.6, IDT #GP delivery FSM = M2S.3) AND whose
  documented behavior is a deterministic, witnessable Actual/Expected state delta —
  so no value is fabricated.
  - **Honest framing (NON-differential, no oracle — same as every M6 erratum).**
    QEMU computes the CLEAN result (it never reproduces this P5 silicon bug), so this
    is NOT a differential `--system` golden. It is self-checked against the documented
    242480-041 Erratum 79 PROBLEM/IMPLICATION text, behind the errata flag: ON asserts
    the documented Actual, OFF asserts the clean Expected. Empirically confirmed the
    clean `err_dbgp` image boots to isa-debug-exit under real `qemu-system-i386`
    delivering ONLY the `#GP` (no spurious `#DB`) — the no-oracle point, in-code.
  - **Documented behavior reproduced (verbatim, verified against the PDF):** in
    virtual-8086 mode at IOPL<3, `POPF`/`IRET` are IOPL-sensitive and `#GP(0)`-trap to
    the monitor WITHOUT accessing the stack; a data breakpoint armed on the SS:ESP
    linear address must NOT fire (the stack was never touched). PROBLEM: "...incorrectly
    triggered as soon as the GP fault handler is entered." IMPLICATION: "...the saved
    state (CS:EIP in the stack...) points to the first instruction of the GP Fault
    handler." Every value used is from this text — `#DB` vector = 1, DR6.Bn set (the
    armed breakpoint's status bit), saved CS:EIP == the `#GP` handler's first
    instruction, the `#DB` delivered IN ADDITION to the `#GP`. **No fabricated value**
    (the numeric `0x000f0260` gpEIP / `0xffff0ff1` DR6 / `0xcafe0079` sentinel are
    properties of the TEST IMAGE — the handler link address, the DR6 reserved-1 base +
    B0, a chosen sentinel — not invented erratum-behavior values; the erratum claim
    asserted is the RELATIONSHIP, not a magic number).
  - **RTL delta (`rtl/core/core.sv`, all gated `errata_en[ERR_DBGP=4]` AND `v86`):**
    widened `errata_en` 4→5 bits; at the V86 IOPL `#GP` guard, for `POPF`/`IRET` ONLY
    (not CLI/STI/PUSHF/INT n), compute `dr_match(seg_base[SG_SS]+ESP, want_x=0)` and
    latch `err79_pending` + the matched DR6.Bn bits; at the `S_INT_PUSH` `from_v86`
    last beat — after the `#GP` retires into the handler entry — chain `arm_db()` with
    saved CS:EIP = `int_gate_off` (the `#GP` handler's first instruction) + DR6.Bn
    sticky-set. The chain is additionally guarded on `(from_v86 && int_vec==13)` so a
    stray latch can never mis-chain onto an unrelated delivery (defensive; the
    well-formed corpus never hits it). Plumbed the wider port through `ventium_top.sv`
    (`[4:0]`) and the TB mask (`tb_main.cpp`: `& 0xF` → `& 0x1F`). With the flag OFF
    the whole compare is dead, so the clean path is unchanged.
  - **Self-check (`verif/errata/err_dbgp/` + `run-m6.sh` §5, system-mode `--bios`
    image):** real→PM→paging→TSS→V86 (modeled on `pv86`+`pdebug`), arms a 4-byte
    data-write bp on the V86 SS:ESP linear (`0x2F000`), enters V86 at IOPL=0, executes
    `POPF` (the documented trigger). A `#GP` monitor + a vector-1 `#DB` handler witness
    counts / DR6 / saved-EIP into the visible GPRs (the M2S.1 hidden-state trick — the
    trace carries no raw vec/DR6 field; the handlers read them into GPRs which ARE in
    the trace). Read the witness-complete record (`edx==0xcafe0079 && eax!=0x42`).
    - **OFF (default):** `#DB`=0, DR6 clear, saved EIP=0 — only the `#GP` (count 2: the
      POPF `#GP` + the terminate INT 0x20 `#GP`). The clean documented Expected.
    - **ON (`--errata 0x10`):** the erroneous `#DB` ALSO fires — `#DB`=**1** (exactly
      one), DR6.B0 set (`0xffff0ff1`), and the `#DB`'s saved CS:EIP (`0x000f0260`) ==
      `gp_handler`'s first instruction. The documented Actual + Implication.
    - **Negative control (real):** the breakpoint is on SS:ESP but `POPF` never writes
      it (it traps first) — a faithful clean core must not fire (OFF). And the erratum
      is documented ONLY for POPF/IRET, so the chain is gated to POPF/IRET — the
      terminate `INT 0x20` (also an IOPL `#GP`) does NOT spuriously fire the `#DB` even
      with the flag ON: the `#DB` count is exactly 1, not 2 (the over-fire guard).
  - **Gate record (independently re-run 2026-06-05):** `make m6` = **15/15 PASS / 0
    FAIL** (+4 new Err79 self-checks: V86 task ran in both runs; OFF only `#GP`, no
    `#DB`, DR6 clear; ON erroneous `#DB` also delivered count=1 + DR6.B0; ON `#DB`
    saved EIP == `#GP` handler first instruction). **`make verify` (errata OFF) GREEN +
    bit-identical** (57/57 func goldens, 0 regenerated; all M4 integer + M5 FP/cache
    bands met). **All sys gates stay EQUIVALENT (errata OFF):** pv86 949/949, pdebug
    239/239, pintr 171/171 — the new path is gated on `errata_en[ERR_DBGP]` AND
    `from_v86` (both 0 across the entire non-V86 corpus), so it is doubly inert by
    default and the whole non-V86 corpus is byte-identical. **Lint clean**
    (`verilator --lint-only -Wall -Wno-UNUSED` → 0 warn/err; the `[4:0]` widening +
    the in-block `logic [3:0] ssp_hit` are width-clean).
  - **Still deferred (honest, unchanged reasons — the other M6B candidates have NO
    reachable self-checkable oracle):**
    - **Err 26** (CMPXCHG8B opcode-bytes crossing a page boundary → `#UD` instead of
      `#PF`): the clean core does NOT implement CMPXCHG8B's MEMORY form at all
      (`core.sv` 0F C7 sets `d_unknown` → loud HALT; only the F00F reg-dst hang of
      Err 81 is modeled), AND there is no instruction-FETCH page-split detector. Needs
      the CMPXCHG8B memory datapath + a fetch page-split path — neither built.
    - **Err 32** (EIP altered after specific FP ops + MOV Sreg,Reg): NO published
      corrupted-EIP value — the Spec-Update says only "an erroneous value... will most
      frequently result in an invalid opcode exception," by definition unpredictable.
      Any injected value would be fabricated (the exact M6 trap that got the invented
      FDIV values removed). Also needs FXCH-forced-into-V-pipe pairing + a
      descriptor-cache-MISS model. No oracle → deferred.
    - **Err 42** (incorrect decode of certain 0F instructions): needs an ASYNC
      cache-line-invalidation/snoop event within a narrow 3-clock window (bus/DP infra
      not built) AND the documented result is vague ("execute invalid or erroneous
      instructions" — no deterministic Actual). No self-checkable oracle even if the
      async path existed → deferred.
    - **Err 80** (CR2/CR4 not restored on RSM): SMM/RSM is already STRUCTURAL-only
      (M2S.5 — the gdbstub single-step oracle masks SMI# and has no SMM awareness, so a
      differential golden is infeasible and deliberately not fabricated), and the P5
      SMRAM save-map does not save/restore CR2/CR4. An M2S.5 SMM follow-on, not an M6B
      candidate. Deferred.
    - **Err 82** (event-monitor counting discrepancy) — a performance-counter/timing
      erratum; no cycle-exact P5 perf-event-counter model and QEMU does not model P5
      perf counters → no oracle. Deferred.
    - **Err 83** (FBSTP A/D bits on 16-bit address wrap): needs the FBSTP 80-bit BCD
      store + a 16-bit-wrap-in-USE32 addressing corner + an A/D-bit differential
      read-back (the read-back is itself an M2S.2 deferral) — none built. Deferred.
    - Also unchanged: DR7.GD `#DB` firing stays IMPLEMENTED-BUT-DISABLED
      (`DBG_GD_ENABLE=0`) per the M2S.6 deferral (qemu does not model GD → no oracle;
      enabling it would make the RTL take a #DB the pdebug golden lacks).
  - **Deliverables (build artifacts `.bin/.o`/`.elf` gitignored; sources tracked):**
    `verif/errata/err_dbgp/err_dbgp.S` + `.ld` + `Makefile`, `verif/errata/run-m6.sh`
    §5, `verif/errata/README.md` + `.gitignore`, `docs/m6-errata-spec.md`,
    `rtl/core/core.sv`, `rtl/ventium_top.sv`, `verif/tb/tb_main.cpp`. Reproducer:
    `make m6` (Err79 §5) + `make verify` (the OFF bit-identical complement).
    `ventium-refs/` untouched (read-only). Not committed — the orchestrator
    verifies + commits.

## M8 — self-contained SoC (PC peripherals in RTL) — OPENED 2026-06-05

Goal (user-directed): implement the PC platform devices in synthesizable Verilog so
Ventium boots + runs **without QEMU providing the platform**. The verification model
shifts: register-level **differential vs `qemu-system-i386`** where deterministic +
**structural** for device timing/IRQ cadence + **behavioral** boot-progress (no clean
bit-exact oracle for the devices — QEMU's device timing ≠ ours).

- **M8.0 — design/de-risk DONE.** Architecture: a NEW separate top `rtl/soc/ventium_soc.sv`
  (the verification `ventium_top` stays untouched, so all existing gates are
  bit-identical), the SAME core with new INTR/NMI/INTA pins, devices attached at the
  EXISTING abstract `io_*`/`mem_*` seams (NOT the pin-level bus — `biu.sv` is
  single-cycle loopback with no pin oracle + a multi-cycle device latency would corrupt
  the cycle-accurate icache fill). Firmware: a CUSTOM minimal boot ROM first
  (differentially checkable by running the same ROM under qemu-system); SeaBIOS deferred
  (needs fwcfg/PCI/PAM). Staging: M8.1 INTR-pin + PIC + PIT → M8.2 RTC/A20/i8042 → M8.3
  VGA + custom ROM → M8.4 IDE (deferred, largest) → M8.5 PCI (deferred). Device priority
  from the M7.3a Win95-boot histogram (IDE dominant, then VGA, ACPI-timer, RTC, PCI, PIC/PIT).
- **M8 device modules DONE (commit `af54d41`).** 7 standalone, synthesizable, lint-clean
  device models, each with a directed unit self-check **bit-matched to the QEMU 8.2.2
  device C source** (unit-level — NOT yet differential-vs-qemu-system; that arrives at
  integration): `ven_pic` (8259 master+slave+ELCR, 42/42), `ven_pit` (8254, 59/59 — the
  `count==0`⇒`0x10000` check made non-vacuous via the mode-0 OUT terminal-count timing),
  `ven_rtc` (MC146818, 33/33), `ven_i8042` (kbd/A20), `ven_acpipm` (PM timer, 12/12),
  `ven_port92` (A20/reset), `ven_vgaregs` (VGA register file, 49/49). Common register
  interface (`clk/rst/cs/we/addr/wdata/rdata` + device-specific) so the M8.1 PMIO decoder
  wires them uniformly; the `ven_pic` adds `irq_in[15:0]`/`int_out`/`inta`/`inta_vector`.
  `verif/soc/` unit harnesses (per-target obj dirs, no parallel-build race); build
  artifacts gitignored. Honest structural caveats (free-running cadence, PIC single-step
  composition) documented in each module.
- **Dependency landed:** `3rd-party/opl3_fpga` submodule (OPL3/YMF262 FM synth) added
  (`523cafe`) for a future SoundBlaster device stage.
- **NEXT: M8.1** — `ventium_soc` + the core INTR/NMI/INTA delta (drives the verified
  `S_INT_GATE` IDT path from an external pin — closes the M7.3a interrupt-injection gap),
  wiring PIC+PIT, gated `soc_en` (all existing gates bit-identical), with a bare-metal
  differential-vs-qemu-system gate.

- **M8.1 — `ventium_soc` + core external-interrupt delta — DONE 2026-06-05** (closes the
  M7.3a **GAP 1**: no path to inject a hardware interrupt — the core now takes a real
  on-die device IRQ through the verified IDT FSM). Reviewed + verified end-to-end this
  session; not yet committed (the orchestrator commits).

  - **Core delta (`rtl/core/core.sv`, +190/−2), minimal + additive, gated on a NEW
    `soc_en` input (defaults 0, tied 0 in `ventium_top`).** New ports: `soc_en`, `intr`
    (level, 8259 master INT), `nmi` (edge), `inta` (1-clk INTA strobe out), `inta_vector`
    [7:0], `inta_valid`. New latches (mirror the `smi_pending` block): `intr_pending`
    (level mirror), `nmi_pending`/`nmi_prev` (edge-latch), `irq_shadow` (STI
    one-instruction inhibit), `nmi_in_progress` (set on NMI delivery, cleared by IRET).
    Combinational accept predicates with the **IA-32 priority SMI > NMI > maskable INTR**:
    `nmi_take = soc_en && nmi_pending && !nmi_in_progress && !smi_take`;
    `intr_take = soc_en && intr_pending && eflags[9](IF) && !irq_shadow && !nmi_take &&
    !smi_take`; `assign inta = (state==S_DECODE) && intr_take`. The divert is two `else if`
    branches in the existing S_DECODE priority chain **right after** the SMI# block, each
    reusing the existing HW-fault task `start_fault` **verbatim** (`int_sw<=0`,
    `state<=S_INT_GATE`): NMI → vector 2 + `nmi_in_progress<=1`; INTR → `inta_vector`. So
    delivery flows through the SAME verified `S_INT_GATE → S_INT_CS → S_INT_PUSH` IDT FSM
    (gate read, IF/TF clear on an interrupt gate, frame push, V86/IOPL via the existing
    `from_v86` path) — **no new delivery logic**. A second additive edit routes IN/OUT
    through the existing `S_IO` bus when `soc_en=1` (so the PMIO decoder can service
    PIC/PIT over the `io_*` seam), **except `out 0xf4`** which still HALTs (the
    isa-debug-exit terminator). When `soc_en=0` the whole divert + the IN/OUT branch are
    dead and the existing `else state<=S_HALT` path is byte-identical.

  - **`ventium_soc` (`rtl/soc/ventium_soc.sv`, `rtl/ventium_soc.f` filelist).** Instantiates
    `core` (`soc_en=1`, `boot_mode` from a port; cosim/proxy/cycle/errata all inert) +
    `ven_pic` (8259) + `ven_pit` (8254, `TICK_DIV=1024`) on a combinational PMIO decoder
    over the `io_*` seam: `cs_pic` for 0x20/0x21/0xA0/0xA1/0x4D0/0x4D1, `cs_pit` for
    0x40–0x43; single-beat combinational ack; undecoded ports ack `rdata=0`. Interrupt
    wiring: `ven_pit.out0 → ven_pic.irq_in[0]`; `ven_pic.int_out → core.intr`;
    `core.inta → ven_pic.inta`; `ven_pic.inta_vector → core.inta_vector`; nmi tied 0. The
    DPI retire block is mirrored verbatim from `ventium_top` so the SAME trace writer emits
    the system-mode `.vtrace`. `ventium_top` is NOT modified (only the tie-off). New `--soc`
    TB driver (`verif/tb/tb_soc.cpp`, `verif/tb/Makefile` `soc` target into a separate
    `obj_dir_soc` so it never clobbers the sys-gate build).

  - **The INTR delivery is REAL (not faked), verified by reading the path end-to-end.**
    The 8254 PIT ch0 (mode-0 one-shot, re-armed in the handler) raises `out0` → `ven_pic`
    `irq_in[0]` → the PIC's `int_out` (= QEMU `pic_update_irq` on the master) → `core.intr`.
    The core pulses `inta` the clock it accepts the INTR; `ven_pic` returns `inta_vector`
    **combinationally** via the same logic as QEMU `pic_read_irq()` and applies the
    `do_intack` side-effects (set ISR / clear IRR / advance priority) on the clocked edge
    when `inta` strobes. The core latches that vector into `start_fault(inta_vector,…)`
    and lands at IDT[0x20]'s target = the handler at `0x000f0190` — i.e. a wrong/faked
    vector would land elsewhere, so the handler entry **proves** the vector return is
    genuine. Verified: **N=4** real deliveries observed on the RTL trace, each entering
    `0x000f0190` with **IF=0** (the interrupt gate cleared IF), interrupting the spin-loop
    mainline (savedEIP 0x000f013b/0x000f0136), and **IRET-resuming the SAME mainline PC**
    with IF=1.

  - **The gate (`verif/soc/run-soc-gate.sh`, test `verif/sys/tests/pirqsoc/`):
    CHECKPOINT-DIFFERENTIAL = EQUIVALENT.** Three checks, all PASS on a real `ventium_soc`
    run (26828 retired, 4 IRQ0 deliveries): **(A) SETUP DIFFERENTIAL** — 94 setup records
    vs the `gen_trace.py --system` golden, **90 byte-identical + 4 LAPIC eax-only**
    (documented off-surface: the SPIV/LVT0 MMIO writes to 0xFEE000xx are RTL-inert in the
    SoC; the test programs them only because qemu-system `-machine pc` routes the i8259
    INTR through the LAPIC), **0 HARD diffs**, both reach the spin loop at the identical
    setup length. **(B) CHECKPOINT DIFFERENTIAL** — the RTL end-state at EIP 0x000f017e
    equals `pirqsoc.checkpoint.golden` **EXACTLY**: esi=4 (IRQ0 counter), edi=0x00 (PIC
    master ISR readback after EOI), ebp=0xFF (IMR), edx=ecx=0x40FF (=N*0x1000+ISR+IMR),
    eax=0xFF, esp=0x90000, mem[0x2000]=4 / mem[0x2004]=0x00 / mem[0x2008]=0xFF. This
    end-state is **only reachable** if the handler genuinely ran N times, EOI'd each
    delivery (so ISR reads 0x00 through the PIC's real intack/EOI logic), and re-armed the
    PIT — it is the authoritative qemu full-speed end-state, boundary-independent. **(C)
    STRUCTURAL/SVA** — the N=4 per-delivery effect (handler IF=0, mainline interrupt, IRET
    resume IF=1). The compare is on **genuinely-deterministic CPU-observable state**, not
    weakened/vacuous.

  - **HONEST DIFFERENTIAL vs STRUCTURAL split.** **DIFFERENTIAL** = the setup prefix
    (90/94 byte-identical) + the post-spin end-state checkpoint (GPRs + var memory ==
    golden EXACTLY). **STRUCTURAL** = the **IRQ0 fire cadence** (which exact instruction
    boundary each IRQ0 hits) — this is set by the PIT/CPU clock ratio (`TICK_DIV=1024`
    prescaler) and is **provably NOT differential**: the qemu-system gdbstub single-step
    oracle (`gen_trace.py --system`) masks `CPU_INTERRUPT_HARD` via `SSTEP_NOIRQ`, so it
    CANNOT deliver a hardware INTR at all (it spins forever, 0 handler entries). The
    single-step golden (`pirqsoc.sys.vtrace.golden`) is **retained as the documented proof**
    that the oracle cannot deliver the HW INTR — so the per-delivery EFFECT is correctly
    structural, **infeasible-not-faked**. The `TICK_DIV=1024` choice is purely structural:
    it only has to be slow enough that the mainline runs the full handler + a spin-loop
    check between edges, so the counter reaches exactly N before the (N+1)th edge; the
    end-state checkpoint is independent of it.

  - **INERTNESS PROOF (soc_en=0 / pins tied off is GENUINELY byte-identical).** `make verify`
    is **GREEN**: 57/57 func PASS (incl. x87), all M4 integer cycle bands + all M5 FP/cache
    bands met. The crux: **func golden cache hits 57/57 with misses regenerated: 0, and 0
    goldens new this run** — the RTL traces matched the cached pre-change goldens
    byte-for-byte, so the new external-interrupt divert + the `soc_en` IN/OUT branch are
    dead with `soc_en=0`. **All 10 sys gates pass**: 9 EQUIVALENT via the real RTL
    `--system` diff vs golden (RTL-SYS-DIFF-OK) — pseg 70, pmode 1084, ppage 128, pintr
    171, pfault 348, pcpl 304, ptask 292, pdebug 239, pv86 949 records match; the
    pintr=171 / pfault=348 / pcpl=304 / pv86=949 counts match the design-spec reference
    numbers **exactly**, confirming the `S_INT_GATE → S_INT_CS → S_INT_PUSH` delivery FSM
    is byte-for-byte unchanged by the additive divert. psmm is SMM-PARTIAL-OK (structural,
    golden documented-infeasible).

  - **Lint clean** (`verilator --lint-only -Wall -Wno-UNUSED`, the canonical TB flags) for
    BOTH `ventium_soc` (`--top-module ventium_soc`) and `ventium_top` (`--top-module
    ventium_top`) — zero warnings from any new signal. `ventium-refs` untouched (submodule
    working tree clean; the pre-existing staged pointer bump is unrelated). `ventium_top`
    behaviorally unmodified (only the `soc_en=0` tie-off + a lint sink for the dangling
    `inta`). Files: `rtl/core/core.sv`, `rtl/ventium_top.sv`, `rtl/soc/ventium_soc.sv`,
    `rtl/ventium_soc.f`, `verif/tb/tb_soc.cpp`, `verif/tb/Makefile`, `verif/soc/run-soc-gate.sh`,
    `verif/sys/tests/pirqsoc/`.

  - **Design-fidelity notes carried forward (minimal-scope, all soc_en-gated/inert):**
    (1) `irq_shadow` is set on STI only (MOV-SS shadow not wired); (2) `nmi_in_progress`
    masks only further NMI, not INTR (correct IA-32 — an NMI handler with IF=1 can take
    INTR); (3) `inta_valid` is currently sunk (the master 8259 always supplies a vector) —
    the documented home for a future spurious-IRQ7/IRQ15 refinement; (4) the LAPIC
    SPIV/LVT0 writes are RTL-inert (no LAPIC in the SoC; `ven_pic.int_out → core.intr`
    directly).
