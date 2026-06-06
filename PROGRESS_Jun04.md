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
- 2026-06-05 — **core.sv DECOMPOSITION** (navigability pass): `core.sv` SPINE 7509 → 4267
  (−3242, −43 %) via 2 new pure-fn packages (`ventium_sys_pkg` 15 fns / `ventium_x87_pkg`
  16 fns, 31 verbatim moves) + a 16-file `core_*.svh` include-split of the `unique case`
  arms (still ONE module / ONE always_ff / ONE case — Verilator concatenates includes pre-
  elaboration). `reg_read`/`fp_bop`/`fri`/`fst`/`sreg_idx` correctly LEFT in the spine
  (impure). All 5 gates GREEN + byte-identical (0 goldens regenerated); both filelists lint
  0; SoC gate EQUIVALENT; ZERO reverts. Reviewed + independently re-run; details below.

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

### core.sv DECOMPOSITION — pure-fn packages + FSM include-split (2026-06-05, bit-exact)

**What this is.** The R2 navigability pass that finally shrinks the `core.sv` SPINE:
**7509 → 4267 lines (−3242, −43 %)**, with **zero** behavior change. Two mechanisms,
both netlist no-ops by construction (verbatim text relocation), each gate-proven:
1. **Pure-function extraction to two NEW packages.** 31 truly-pure helpers moved
   VERBATIM out of the module into packages (no module state captured in any body):
   - `rtl/core/ventium_sys_pkg.sv` (170 lines, `import ventium_decode_pkg::*` for
     `mfl`) — the 15 segmentation/descriptor/fault/TSS-offset helpers: `mfl_e`,
     `desc_base`/`desc_limit`/`desc_attr`/`desc_present`/`desc_dpl`/`desc_s`/
     `desc_type`, `seg_is_code`/`seg_writable`/`seg_readable`, `tsw_save_off`/
     `tsw_read_off`, `seg_load_fault`, `seg_fault_vec`.
   - `rtl/core/ventium_x87_pkg.sv` (229 lines, `import fpu_x87_pkg::*`) — the 16 x87
     instruction-level helpers: `fcom_codes`/`fst_eq`/`fst_lt`, `fx_is_nan`/
     `fx_is_snan`/`fcom_ie`, `apply_cmp`, `fconst`, `fxam_codes`, `f_mem_as_float`/
     `f_mem_as_int`, `f_arith`/`f_div_by_zero`/`f_zero_over_zero`/`f_eval`/
     `f_arith_fstat`. Each body uses only its args + literals + imported `fx_*` ops.
2. **FSM include-split (the bulk of the reduction).** The one giant `always_ff`'s
   `unique case (state)` arms are relocated as RAW case-arm text into **14**
   `core_*.svh` files \`include`d at the original site INSIDE the case; the 2
   contiguous module-scope combinational drivers go to 2 more `.svh` — 16 files,
   3045 lines total (each carries a banner "RAW case-arm text … NOT a standalone
   unit"): `core_fastpath` (S_RESET/S_PF/S_PIPE), `core_fetch_decode`,
   `core_load`, `core_exec` (S_EXEC, the 619-line largest), `core_io`,
   `core_store_useq`, `core_seg_ljmp`, `core_int_deliver`, `core_iret`,
   `core_tss_priv`, `core_tsw`, `core_smm`, `core_fp_exec`, `core_walk`, +
   `core_bus_driver` / `core_io_driver` (module-scope `always_comb`).

**STAYED in the spine — and why it is STILL ONE FSM module.** `core.sv` remains ONE
module / ONE `always_ff` / ONE `unique case (state)`: Verilator concatenates the
include text BEFORE elaboration, so the split is purely textual (source byte-size
3.39 MB unchanged before/after the include split). The per-clock **FSM prologue**
(retire bookkeeping + soc intr/nmi sampling + the `xlate_miss`→S_WALK paging
diversion + the `unique case` header) MUST run before the case every clock, so it
stays inline (`core.sv:3045-3074`), as do `S_HALT`/`S_F00F_HANG`/`default`/`endcase`
and the scattered/interleaved tail `always_comb` blocks + function defs + the
itlb/dtlb instances (not contiguous, low value). Impure helpers correctly LEFT in
the module (verified present in `core.sv`, absent from both packages): **`reg_read`**
(reads module `gpr[]` — the brief's mis-listed "pure datapath helper", correctly
NOT moved), **`fp_bop`** (calls `reg_read` → transitively impure), **`fri`/`fst`**
(read module `ftop`/`fp_st[]`), **`sreg_idx`** (references the module-local
`SG_CS..SG_GS` localparams), plus `mem_xlate`/`dr_match`/`smm_off`/`smm_save_data`
(read CRx/DRx/creg/gpr/seg or module localparams). Step 3 of the plan (moving
`reg_merge`+`strb_of`) was deliberately **skipped** (not reverted): both are pure
but their sibling `reg_read` must stay, so a 2-function package was near-zero value.

**Compile/import order (lint-proven).** `+incdir+core` added to BOTH
`rtl/ventium.f` and `rtl/ventium_soc.f` so the `\`include "core_*.svh"` resolve; the
two packages inserted AFTER `fpu_x87_pkg.sv` (after `ventium_decode_pkg.sv`) and
before any module — `ventium_sys_pkg` follows `ventium_decode_pkg` (for `mfl`),
`ventium_x87_pkg` follows `fpu_x87_pkg` (for `fx_*`). The 4 new imports sit at
`core.sv:24-27`. Lint passing on both full filelists is the definitive
elaboration-order proof.

**Bit-exact proof (independently re-run + reviewed 2026-06-05).**
- **Source-level structural proof (netlist no-op).** Expanded every `\`include` in
  the new `core.sv` and diffed vs `HEAD:rtl/core/core.sv`: the ONLY added executable
  lines are the **2 package imports**; ALL 259 removed executable (non-comment) lines
  appear **verbatim** in the two packages; everything else in the diff is comment
  banners/pointers. All 16 `.svh` bodies (after banner) are verbatim contiguous
  substrings of HEAD `core.sv`; all 31 package function bodies are verbatim in HEAD.
- **`make verify` GREEN + BYTE-IDENTICAL** — func **57/57** PASS, **golden cache hits
  57/57 (misses regenerated: 0)** = byte-identical traces; all M4 integer + M5 FP/
  cache bands met to the digit (mb_depadd C=3497 +2.85%, mb_indepadd 1913, mb_dmiss
  2.504, mb_imiss 6.009, mb_faddchain CPI 3.010, mb_fpindep 1.158 — all unchanged).
- **`make m3` GREEN — 57 PASS / 0 FAIL** (every `tx_*` x87 program func-diff-clean).
- **`make verify-sys` exit 0 — 10/10**: pseg/pmode/ppage/pintr/pfault/pcpl/ptask/
  pdebug/pv86 all RTL-SYS-DIFF-OK EQUIVALENT (9 real RTL `--system` differentials) +
  psmm SMM-PARTIAL-OK (documented partial-oracle, structural).
- **SoC gate** (`bash verif/soc/run-soc-gate.sh`) exit 0 — **SOC-GATE-OK
  CHECKPOINT-DIFFERENTIAL EQUIVALENT** (setup 90/94 byte-identical + 4 documented
  LAPIC eax-only; checkpoint GPRs+memory MATCH; 4 IRQ0 deliveries structural-OK).
- **Lint** — `verilator --lint-only -sv -Wall -Wno-UNUSED` on `-f ventium.f` AND
  `-f ventium_soc.f` both exit 0, **0 warn / 0 err**, 18 modules each.
- **ZERO reverts** — every check passed first try; nothing regressed.
- **Scope clean** — only `rtl/core/core.sv` + `rtl/ventium.f` + `rtl/ventium_soc.f`
  modified, plus 18 new files under `rtl/core/` (2 packages + 16 `.svh`). NO M8 SoC
  device modules (`rtl/soc/ven_*.sv`) and NO `ventium_soc.sv` logic touched (only its
  `.f` filelist); `ventium-refs` untouched (its submodule-pointer drift
  `83a9d2c→8fb9ed0` pre-dates this work — present in the conversation-start snapshot —
  and affects no gate). Not committed — the orchestrator verifies + commits.

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

### M8.2 — RTC + 8042 + port-92 + the A20 mask into ventium_soc (2026-06-05, per-record differential)

**What this is.** The M8.2 self-contained-SoC increment: the three already-built,
unit-checked PC-peripheral device models — the **MC146818 RTC/CMOS** (`ven_rtc`,
0x70/0x71), the **8042 keyboard controller** (`ven_i8042`, 0x60/0x64), and the
**port-92 fast-A20** (`ven_port92`, 0x92) — are wired into `ventium_soc` alongside
the M8.1 PIC+PIT, plus a combined **A20 address mask**. Proven with a NEW gate that
is a **FULL per-record differential** vs `qemu-system-i386` 8.2.2 — *stronger* than
the M8.1 pirqsoc checkpoint-differential.

- **Wiring (`rtl/soc/ventium_soc.sv`, additive on the M8.1 top).** The PMIO decoder
  gains `cs_rtc` (0x70/0x71), `cs_i8042` (0x60/0x64), `cs_port92` (0x92), non-
  overlapping with the PIC/PIT selects; the read mux zero-extends the selected
  device byte into `io_rdata`. Device IRQ lines route into the cascaded PIC:
  `rtc_irq8 → irq_in[8]` (slave IR0), `kbd_irq1 → irq_in[1]`, `mouse_irq12 →
  irq_in[12]` (slave IR4) — connectivity toward a future key/RTC workload (no
  autonomous stimulus in this minimal SoC, so quiescent; the IR0 path stays the
  structurally-exercised one). The three files are added to `rtl/ventium_soc.f`
  (21 modules, lint clean).

- **The A20 mask (the one genuinely new behavior).** `eff_a20 = i8042.a20 |
  port92.a20`; when masked, physical address **bit 20 is forced low** on the core's
  outgoing bus (`mem_addr = eff_a20 ? core_mem_addr : core_mem_addr & ~32'h0010_0000`).
  At reset the 8042 (`outport=0xCF`, A20=1) holds A20 ENABLED, matching qemu's CPU
  `a20_mask=~0`. This is **value-exact** vs qemu because `dcache_timing` carries NO
  data array (load data always returns via `mem_rdata` for the masked address), so
  the 1 MiB wraparound reads the wrapped location exactly as qemu (which has no
  data cache) does.

- **The gate — `psocdev`, FULL PER-RECORD DIFFERENTIAL (122/122 EQUIVALENT).**
  `verif/sys/tests/psocdev/` (`.S` + `.ld` + `Makefile` + `manifest.json`) is a
  bare-metal, **interrupt-free** real→protected test. Because every device
  interaction is a synchronous IN/OUT or an A20-masked memory access (no async HW
  INTR), qemu's gdbstub single-step (`gen_trace.py --system`) IS a valid per-record
  oracle — the `SSTEP_NOIRQ` limitation that forced pirqsoc to a checkpoint shape
  does NOT apply. `verif/soc/run-soc-dev-gate.sh` builds the image + the `--soc` TB,
  confirms it reaches `isa-debug-exit` (code 133) under qemu-system, regenerates the
  golden (drift-checked vs the committed `psocdev.sys.vtrace.golden`), runs
  `ventium_soc`, and diffs with `compare.py --mode func` → **EQUIVALENT over all 122
  retired instructions**. Coverage: RTC `REG_D`(0x80)/`REG_B` control round-trip
  (write 0x82→read 0x82)/scratch CMOS index-0x50 round-trip (0x5A,0xA5)/index-port
  read(0xFF)/NMI-disable-bit non-aliasing; port-92 A20 register (reset 0x00, on 0x02,
  off 0x00, bit0 always 0 = never a reset request); 8042 A20 commands (0xDF/0xDD);
  and the **cross-device A20 wraparound** (witness `ebp=0x22222222` — reading
  `A20_HI=A20_LO+(1<<20)` with A20 masked returns the value written to `A20_LO`).

- **Honest oracle boundaries (documented, NOT faked — adversarially re-reviewed).**
  EXCLUDED from the differential because they are not reproducible by a standalone
  register model vs qemu-system: (1) the RTC **host-clock-derived** state — time
  bytes (qemu seeds from the host wall clock, the RTL from a fixed 2026-06-05 seed →
  genuinely different), `REG_A.UIP`, `REG_C` flags; (2) the 8042 **keyboard/mouse
  OBF/data path** — qemu `-machine pc` attaches a LIVE PS/2 keyboard whose async
  power-on/BAT bytes populate the controller OBF, which a controller-only model does
  not have. The 8042 is instead exercised differentially via its **queue-independent
  A20-command path** (0xDF/0xDD → `outport[1]` → `a20_gate`, observed through the A20
  mask), and the OBF path is covered by the standalone **`ven_i8042` unit self-check**
  (`verif/soc/run_i8042.sh` — ALL CHECKS PASSED). These are consistent with the
  project's existing boundaries (LAPIC-eax-only, SMM-infeasible).

- **No regression + adversarial verification.** `make verify` PASS (57/57 func, 0
  goldens regenerated), `make verify-sys` EQUIVALENT, the **M8.1 pirqsoc gate still
  EQUIVALENT** (the A20 mask is identity there — A20 enabled, all addresses <1 MiB),
  both filelists lint 0/0. A 5-dimension adversarial-review workflow (gate-
  genuineness, A20-correctness, oracle-boundary-honesty, wiring/regression,
  determinism) + per-finding verification returned **ZERO defects, ZERO overclaims,
  ZERO required fixes** (the oracle-boundary dimension was re-run cleanly after a
  workflow-agent error; verdict HONEST/SOUND). `ventium-refs` untouched; `ventium_top`
  / `ventium.f` unmodified (M8.2 touches only `ventium_soc.sv` + the new device/test
  files). Files: `rtl/soc/ventium_soc.sv`, `rtl/ventium_soc.f`,
  `verif/sys/tests/psocdev/{psocdev.S,psocdev.ld,Makefile,manifest.json,psocdev.sys.vtrace.golden}`,
  `verif/soc/run-soc-dev-gate.sh`.

### Expert fidelity review (REVIEW_Jun5.md) — response: BCD closure + honesty + boundary tests + plan (2026-06-05)

An external expert produced `REVIEW_Jun5.md` (a P54C fidelity review). Verdict:
credible ISA-exact + cycle-approximate replica over the tested subset; main risk =
**wording overclaim**, plus real microarchitecture-fidelity gaps. Addressed with 9
parallel analyst subagents (specs) → 4 parallel implementer subagents (disjoint
docs/tests/bus-script) + the orchestrator (the RTL closure), then integrated +
gated centrally. Two follow-on adversarial passes confirmed accuracy.

- **REAL RTL CLOSURE — the 6 BCD/ASCII-adjust instructions (closes the "full
  integer ISA" gap).** `AAA`(0x37)/`AAS`(0x3F)/`DAA`(0x27)/`DAS`(0x2F)/`AAM`(0xD4
  ib)/`AAD`(0xD5 ib) — previously `d_unknown`→HALT — now execute, **bit-exact vs
  QEMU `helper_aaa/aas/daa/das/aam/aad`** (`int_helper.c`). Decoded as `K_ALU`
  `ALU_AAA..ALU_AAD` (each writes AX via `q_w=2`); a dedicated `bcd_ax`/`bcd_flags`
  `always_comb` computes the AX result + DEFINED flags and overrides
  `alu_out`/`flags_out`. The subtle part, found by the gate: the architecturally-
  UNDEFINED flags **persist into the next instruction** (where they are not
  masked), so AAA/AAS must **carry SF/ZF/PF/OF through** exactly as QEMU does
  (only CF/AF change) — not clear them; DAA/DAS/AAM/AAD fully define their flags to
  match QEMU (incl. OF=0, AAM/AAD CF=AF=0). `tracefmt.eflags_undefined_mask`
  already carried the BCD masks (0x8C4 / 0x800 / 0x811). New differential test
  `verif/tests/t_bcd/` (35 ops across every code path: low-nibble/AF/CF, the
  `AL>0xF9` AAA-icarry, `old_AL>0x99` DAA/DAS high-adjust, non-standard AAM/AAD
  bases) → **`make verify` 59/59 EQUIVALENT, the 57 pre-existing goldens
  byte-identical (additive, zero regression)**. AAM base-0 `#DE` is deferred,
  consistent with the existing native-DIV-by-zero (also no `#DE`).

- **HONESTY — public claims re-scoped** (the review's #1 risk). README.md + PLAN.md:
  "high-fidelity"→"ISA-exact and cycle-approximate for the broad verified subset";
  "full integer ISA"→"broad IA-32 integer ISA with documented HALT gaps"; the
  D-cache labelled a **timing model** (no data/MESI/writeback), the TLB a
  **correctness model** (not P54C-structured), the integrated bus a **protocol
  exerciser** (pins ≠ data, single non-burst cycles). New
  **`docs/isa-coverage.md`** — a machine-derived family-by-family IMPLEMENTED/
  PARTIAL/HALT matrix (the HALT set grepped from every `d_unknown=1'b1`; correctly
  keeps LGDT/LIDT/LTR IMPLEMENTED, lists the genuine gaps: SLDT/LLDT, SMSW/LMSW,
  CMPXCHG8B, MMX, transcendentals, …). New **`docs/modeled-by-effect.md`** — the
  Action-1 inventory (native mul/div incl. no-#DE, string/stack/CALL-RET, x87
  slow-path, task/SMM/walk, timing-dcache, correctness-TLB, protocol-BIU) with a
  timing-visibility-first priority order.

- **x87 boundary (machine-checkable).** `verif/tests/tx_deferred_halt/` +
  `verif/tests/run_x87_boundary.sh`: a deferred transcendental (`FSIN`) must
  **loud-HALT** at its boundary (PASS — nothing past it retires), pinning the
  coverage edge so it cannot silently rot. `verif/tests/tx_fchs_fabs_special/`: a
  differential confirming `FCHS`/`FABS` flip/clear only the sign bit on ±inf/NaN
  (PASS, no RTL change needed). `docs/m3-fpu-spec.md` gains a deferred-x87 section.

- **Bus SVA single command** (Recommended Step 2). New
  `verif/bus/run_busmode_sva.sh` + `make bus` / `make bus-sva`: `bus-sva` builds
  the SVA-assertion-enabled integrated model and runs the `bus_mode=1` corpus with
  the 19 `biu_p5` protocol SVA LIVE (a program passes only if no assertion fired
  AND it is func-equivalent vs QEMU) — closes the "build-only `rtl-sva` can be
  misread" gap. `docs/m5b-bus-spec.md` §5.4 makes the integrated-bus caveat explicit.

- **Deferred microarchitecture fidelity — SPEC'd, not landed** (these perturb the
  calibrated M4/M5 cycle bands and need NEW microbenchmarks → incremental, gated
  per family): `docs/m5-div-spec.md` (iterative DIV/IDIV: occupancy 17/25/41 +
  IDIV, EDX:EAX, a real `#DE`), `docs/m5-mul-spec.md` (staged ~10-cycle U-pipe
  MUL/IMUL), `docs/fastpath-coverage-spec.md` (AP-500 pairable forms that serialize
  today), `docs/cache-tlb-structural-spec.md` (P54C-shaped split TLB + a D-cache
  data/MESI/writeback model). **`docs/review-response-plan.md`** maps every review
  finding → DONE / SPEC'd-deferred → the doc/test that addresses it.

- **Verification.** `make verify` PASS (59/59), `make m3` PASS, `make verify-sys`
  EQUIVALENT, `run_x87_boundary.sh` PASS, lint BOTH filelists 0/0, `make bus-sva`
  (corpus + SVA). RTL touched: `rtl/core/core.sv` (BCD decode + `bcd_*` block),
  `rtl/core/ventium_alu_pkg.sv` (the `ALU_AAA..ALU_AAD` encodings) — additive,
  every other gate byte-identical. `ventium-refs` untouched.

### Iterative-divider OCCUPANCY — DIV/IDIV cycle fidelity (2026-06-05, review Limit #5)

The first real **microarchitecture-fidelity** closure from the review (Actions
3/4/7/8, `docs/m5-div-spec.md`). DIV/IDIV were computed by native Verilog `/`/`%`
in one execute clock — charging **1 cycle** where the P5 (p5model) charges
**17/25/41** (DIV r/m8/16/32) and **22/30/46** (IDIV). No existing band caught it
(none used DIV). Closed empirically, gate-driven:

- **Measured the gap** with a `divl`-loop microbenchmark: the p5model golden
  charges the `divl` **+41** cyc; the RTL charged **+7** (the slow-FSM cost of one
  reg-form divide). So the modeled occupancy to add = `occ − 7`.
- **Implementation** (`rtl/core/core_exec.svh`, K_MULDIV DIV/IDIV arms): the native
  helper still produces the bit-exact quotient/remainder (Action 8 — architectural
  vs timing separated); the modeled occupancy is charged as a **deferred penalty**
  via the existing `pending_mem_pen` mechanism (the same one that folds a D-cache
  miss into the next insn's `pipe_free_at`): `pending_mem_pen <= occ − 7` (DIV
  34/18/10, IDIV 39/23/15). This holds the U pipe so a dependent EDX:EAX consumer
  cannot issue until the divide latency elapses (EDX:EAX latency coupling). No new
  FSM state; no functional change (arch state per retire is identical → `make
  verify` func stays byte-clean).
- **NEW gated bands** `mb_div8/mb_div16/mb_div32/mb_idiv32` (`verif/tests/` + the
  `div` band in `verif/m5_metrics.py`: CPI-elevation AND abs-cyc within 10% of the
  p5model golden, wired into `verify.sh` + `run-m5.sh`). All PASS:
  **div8 +0.20% (occ 17), div16 −3.31% (occ 25), div32 +0.09% (occ 41),
  idiv32 +0.08% (occ 46).**
- **Verification.** `make verify` PASS (func GREEN incl. `t_div`; the 4 DIV bands
  PASS; every prior band held), `make m3` 63/63, `make verify-sys` EQUIVALENT,
  `make m5` slow-gate green, lint both filelists 0/0. The `occ` numbers are
  p5model/Agner-derived (cycle-modeled, not silicon — Action 9 labeling).
- **MUL/IMUL staged occupancy** (`docs/m5-mul-spec.md`, occ 10) is the analogous
  fast-follow. RTL touched: `rtl/core/core_exec.svh`; `ventium-refs` untouched.

### Divide-error #DE — the divide family's architectural completion (2026-06-05)

The companion to the occupancy work (review Action 4): DIV/IDIV now **raise `#DE`
(vector 0)** — previously a zero divisor evaluated native `/` (X-prone) and an
overflowing quotient silently wrapped, both DIVERGING from QEMU (seen live while
building `mb_div8`: a byte divide whose quotient exceeds 0xFF makes QEMU `#DE`).

- **RTL** (`rtl/core/core_exec.svh`, K_MULDIV DIV/IDIV): detect **divide-by-zero**
  (`srcv==0`) AND **quotient overflow** (DIV: the wide quotient's high bits
  nonzero; IDIV: quotient outside the signed destination range, incl. the
  `INT_MIN / -1` corner). On a fault the result write is skipped + EFLAGS left
  unchanged; `sys_mode` DELIVERS through the verified `S_INT_GATE` IDT FSM
  (`start_fault(8'd0, 1'b0, 32'd0, q_pc)` — FAULT semantics push the faulting EIP),
  user mode loud-HALTs (no IDT). The non-faulting path is byte-unchanged.
- **Test** `verif/sys/tests/pde` (NEW, non-paging real→protected): a vector-0 `#DE`
  interrupt gate + two triggers (div-by-zero and quotient overflow), a handler
  that counts + resumes past each divide, then a non-faulting divide + exit. `#DE`
  is **synchronous**, so the qemu-system gdbstub single-step golden delivers it →
  a **per-record differential**: RTL `--system` trace **EQUIVALENT, 78/78 records**
  (the `#DE` frame-push → IDT[0] → handler → IRET-resume matches qemu byte-for-
  byte). Registered in `verify-sys` + `INTR_TESTS` + `RTL_SYS_TESTS`.
- **Verification.** `make verify` PASS (63/63, byte-identical — the `#DE` guards
  don't touch non-faulting divides; the 4 DIV occupancy bands still PASS), `make
  m3` 63/63, `make verify-sys` EQUIVALENT incl. the new `pde`, lint both filelists
  0/0. The divide family is now cycle-faithful (occupancy) AND architecturally
  complete (`#DE`); only a structural SRT datapath remains (no observable). RTL
  touched: `rtl/core/core_exec.svh`; `ventium-refs` untouched.

### Multiply occupancy — MUL/IMUL cycle fidelity (2026-06-05, review Action 5)

The multiply analogue of the divide occupancy (`docs/m5-mul-spec.md`). MUL/IMUL
were native `*` in one execute clock (~7 cyc via the slow FSM) where the P5
(p5model) charges **occ=10** (NP, U-pipe, all widths). Measured `mull` at p5model
**+10** vs RTL **+7**, so the modeled occupancy = `occ − 7 = 3`, charged as a
DEFERRED penalty (`pending_mem_pen <= 7'd3`) — the SAME mechanism + measured base
as the divider — for ALL three multiply forms: 1-operand MUL (K_MULDIV q_md 4),
1-operand IMUL (q_md 5), and the 2/3-operand IMUL (K_IMUL2). The native `*` still
produces the bit-exact result (architectural vs timing separated). NEW gated bands
`mb_mul` + `mb_imul2` (CPI-elevation AND abs-cyc within 10% of the p5model golden;
wired into `verify.sh` + `run-m5.sh` as the `MUL` class) both **PASS: +0.31% /
+0.15% (occ 10)**. `make verify` PASS (func byte-identical — timing-only; the 63
prior goldens unchanged), `make verify-sys` 10/10 EQUIVALENT, lint 0/0. The
integer MUL+DIV families are now cycle-faithful; only structural multiplier/SRT
datapaths remain (no observable). RTL touched: `rtl/core/core_exec.svh`;
`ventium-refs` untouched.

### AP-500 fast-path coverage — batch 1: accumulator-immediate ALU (2026-06-05, review Action 6)

The first (and riskiest-category) coverage closure: the dual-issue fast path only
recognised a whitelist of forms; AP-500-pairable forms it didn't recognise fell to
the slow FSM and **serialized** (couldn't dual-issue). Batch 1 adds the
accumulator-immediate ALU forms `05/0D/15/1D/25/2D/35/3D` (`ALU eAX, imm32`):
ADD/OR/ADC/SBB/AND/SUB/XOR/CMP, mirroring the existing `A9` (TEST eAX,imm32) + `83`
reg-imm arms (`rtl/core/decode.sv`, the `8'b00??_?101` arm; ADC/SBB=PU, CMP writes
no reg). The lowest-risk batch (pure register/immediate, no memory/stack).

- **Func byte-identical** — the hard requirement: the fast path now EXECUTES these
  forms (instead of deferring to the slow FSM), so they must match QEMU exactly.
  `make verify` reports **65/65 goldens unchanged (0 regenerated)** — bit-identical.
- **They now pair.** NEW gated band `mb_accimm` (the `PAIR` class in
  `verif/m5_metrics.py`: pairing% ≥ 40 AND abs-cyc within 10% of the p5model
  golden; wired into `verify.sh` + `run-m5.sh`): the kernel interleaves an
  accumulator-eAX op (U) with an independent `mov reg,reg` (V) → **RTL pairing 50%
  (matching p5model exactly), abs-cyc +0.35%** (vs ~0% pairing / ~2× cycles before
  the fix). PASS.
- **No band perturbation.** Every existing M4/M5 band held (`mb_depadd`..`mb_imiss`,
  the div/mul bands) — the converted forms aren't used by those kernels, and where
  they would be, the RTL converges TOWARD the p5model golden (which pairs them).
- **Verification.** `make verify` PASS, `make verify-sys` 10/10 EQUIVALENT (the
  fast path is `!sys_mode`-gated, so system mode is untouched), lint both filelists
  0/0. Batches 2-5 (byte forms, `81`/`C7` reg-imm, PUSH/POP, near branches, memory)
  are ordered by risk in `docs/fastpath-coverage-spec.md` §3 — each needs its own
  pairing microbenchmark + a re-run of all bands + the full func diff. RTL touched:
  `rtl/core/decode.sv`; `ventium-refs` untouched.

### External CPU testbench — test386.asm, differential vs qemu-system (2026-06-05)

Added an EXTERNAL, independently-authored x86 CPU tester for much broader
differential coverage than the hand-written corpus — at the user's request to
"find suitable testbenches online and download them."

- **Downloaded** [`test386.asm`](https://github.com/barotto/test386.asm) (GPL-3.0,
  a comprehensive 80386+ CPU tester for emulators) into
  `ventium-refs/09-external-cpu-tests/test386.asm/` (full source + `COPYING`).
  Built with NASM into a 64 KiB BIOS image — exactly the Ventium system-mode image
  model (reset 0xfffffff0 → f000:0045; `qemu-system-i386 -bios`).
- **Differential vs QEMU.** Golden = `qemu-system-i386` single-step
  (`gen_trace.py --system`); checked CPU = the Ventium RTL. The bare core
  (`ventium_top --system`) HALTs at the FIRST instruction's POST-code `OUT DX,AL`
  (n=4) — no PC platform — so **`ventium_soc`** (`tb_soc`, `soc_en=1`, whose PMIO
  decoder acks the undecoded POST port) is the correct vehicle. Result:
  **EQUIVALENT — `ventium_soc` matches qemu-system-i386 byte-for-byte over 60,000
  instructions** of test386's prefix (conditional jumps, addressing modes, early
  protected-mode/bit/string tests), per-record under the EFLAGS-undefined mask.
- **Gate + artifacts** (`verif/external/test386/`): `run-test386-gate.sh` (build
  the SoC TB → regen the golden + drift-check → run `ventium_soc` → `compare.py`
  EQUIVALENT; `MAXI` controls the prefix), the committed `test386.bin` (nasm-built,
  so the gate needs no nasm) + a 1,500-insn reference golden, and a README noting
  the GPL-3.0 source location. This is an honest gap-finder like the M7 lock-step
  (the first OUT was a platform-not-ISA finding; a deeper frontier — an
  unimplemented opcode or the SoC's free-running PIT — is the next thing it will
  surface).
- **NOTE — `ventium-refs` (the user's reference submodule):** test386's source +
  built image were downloaded INTO it per the request; the main-repo gate is
  self-contained via the committed `verif/external/test386/test386.bin`. Committing
  + pushing the `ventium-refs` submodule (their own reference repo) is left to the
  user. Main-repo files: `verif/external/test386/{run-test386-gate.sh,test386.bin,
  test386.golden.vtrace,README.md}`.

### AP-500 fast-path coverage — batch 2: reg-form r/m32,imm32 (2026-06-05, review Action 6)

The general-register sibling of batch 1: the reg-form immediate ops `81 /r`
(`ALU r/m32, imm32` — the imm32 version of the existing `83` imm8 arm) and `C7 /0`
(`MOV r/m32, imm32` — the ModRM sibling of `B8+r`), both **mod11 / register-only**
(no memory) in `rtl/core/decode.sv`. ADC/SBB=PU, CMP writes no reg, `C7` only `/0`;
the 16-bit (66-prefixed) forms keep `0x66` first so they stay on the slow FSM.

- **Func byte-identical** — `make verify` 66/66 goldens unchanged (the fast-path
  execution of these reg-imm forms matches QEMU exactly; mirrors the proven
  `83`/`B8` arms).
- **They now pair** — NEW gated band `mb_rmimm` (PAIR class, generalising the
  `accimm` branch): a general-register `81`/`C7` op (U) interleaved with an
  independent `mov reg,reg` (V) → **RTL pairing 50% (matching p5model), abs-cyc
  +0.35%** (vs ~0% pairing before). PASS.
- **No band perturbation** — every M4/M5 band held; `make verify-sys` 10/10
  EQUIVALENT (the fast path is `!sys_mode`-gated). lint 0/0.
- Batches 3-5 (byte forms `04`/`A8`, `D1` shift-by-1, PUSH/POP, near branches,
  memory) remain ordered by risk in `docs/fastpath-coverage-spec.md` §3; `D1`
  shift-by-1 (a trivial mirror of `C1`) is the next safe one. RTL touched:
  `rtl/core/decode.sv`; `ventium-refs` untouched.

### AP-500 fast-path coverage — batch 3: shift-by-1 (D1) (2026-06-05, review Action 6)

`SHL/SHR/SAL/SAR r/m32, 1` (`D1 /4..7`, the `x+x`/halve idiom) — the implicit-
count-1 sibling of the existing `C1` (shift-by-imm8) arm: same shift datapath with
`shimm` fixed at 1, no imm byte (len 2), reg form only (rotates `/0..3` stay on the
slow path), PU (`rtl/core/decode.sv`). **Func byte-identical** (`make verify` 67/67
goldens unchanged), every M4/M5 band held, NEW gated band `mb_sh1` (PAIR class)
PASSES at **pairing 50% / abs-cyc +0.35%** (a D1 shift now leads a pair with an
independent V partner; before it serialized on the slow FSM). `make verify-sys`
10/10 EQUIVALENT, lint 0/0. Batches 4-5 (byte forms `04`/`A8`, PUSH/POP, near
branches, memory) remain risk-ordered in `docs/fastpath-coverage-spec.md` §3 — the
byte forms add byte-width fast-path ALU; PUSH/POP + stores add real stack/memory
functional surface. RTL touched: `rtl/core/decode.sv`; `ventium-refs` untouched.

### AP-500 fast-path coverage — batch 4: near branches + TEST-reg (2026-06-05, review Action 6)

The DECODE-ONLY remaining forms, batched together (all reuse the existing
branch/ALU execution, so zero functional risk): `E9` (JMP rel32, mirrors `EB`),
`0F 8x` (Jcc rel32 — a new two-byte `0F` sub-decode in `fp_decode` that fast-paths
only the `8x` sub-range, mirroring the `7x` Jcc rel8 arm; every other `0F` op stays
on the slow FSM), and `85 /r` (TEST r/m32,r32 reg form, reusing the `ALU_TEST`
datapath like `A9`). All in `rtl/core/decode.sv`.

- **Func byte-identical** — `make verify` 68/68 goldens unchanged (these reuse the
  proven `EB`/`7x` branch + `A9` TEST execution; no new datapath).
- **They now pair** — NEW gated band `mb_nearbr`: the `cmp/test`→`jcc` idiom with a
  >128-byte loop body that forces a `0F 85` (Jcc rel32) back-edge; the `85` TEST (U)
  pairs with an independent `mov` (V) and the `0F 85` (PV) fills V after `dec` →
  **RTL pairing 50% (matching p5model), abs-cyc +1.16%**. PASS.
- **No regression** — all M4/M5 bands held; `make verify-sys` 10/10 EQUIVALENT
  (fast path is `!sys_mode`-gated); lint 0/0.

**This is where the decode-only fast-path batches stop.** The remaining AP-500
forms — the BYTE forms (`04`/`A8`/`84`, byte-width ALU: the fast-path GP writeback
is 32-bit-only, no `reg_merge`), PUSH/POP (`50+r`/`58+r`: the fast path does no
memory stores + needs the ESP micro-update), and the general MEMORY/STORE forms —
are NOT decode-only: each needs the fast-path EXECUTION datapath extended
(width-aware writeback / a store path / ESP) and carries real functional risk, so
they are a separate, carefully-gated effort, not a quick decode add
(`docs/fastpath-coverage-spec.md` §3). RTL touched: `rtl/core/decode.sv`;
`ventium-refs` untouched.

### M8.3 — VGA register file + ACPI PM timer into ventium_soc (2026-06-05, per-record differential)

**What this is.** The M8.3 self-contained-SoC increment: the **last two** built-but-
unwired device models (`ven_vgaregs`, `ven_acpipm`) are wired into `ventium_soc`,
completing the **7-device set**. The VGA register file gets a **FULL per-record
differential** (the substantial deliverable); the ACPI PM timer is wired for
connectivity with a documented oracle boundary. Mirrors the M8.2 pattern
(`psocdev`) exactly. **Empirically grounded:** every modeled VGA path was first
observed under `qemu-system-i386 8.2.2` (a scratch probe) before the test was
written, so the gate matched on the first run.

- **`ventium_soc.sv` wiring (the ONLY RTL changed — the core / `ventium_top` /
  `ventium.f` are byte-identical).** Two new chip-selects on the existing PMIO
  seam: `cs_vga` for the legacy `0x3B0..0x3DF` window (the same window qemu's
  std-vga decodes; the device internally returns `0xFF` for the mono/color-aliased
  invalid sub-range, matching `vga_ioport_invalid`), `cs_acpipm` for `0x608`. Read
  mux: VGA byte → `{24'd0,vga_rdata}`, ACPI PM → the native `rdata32`
  (`{8'h0,count[23:0]}`). `ven_vgaregs` + `ven_acpipm` instantiated; both added to
  `rtl/ventium_soc.f`. Lint **0 warnings** (`-Wno-UNUSED`); no new core build.

- **VGA register file is FULLY per-record differentiable.** It is CPU-observable
  register state ONLY (no framebuffer/scan-out), matched to qemu `hw/display/vga.c`
  (`vga_ioport_read/write`). The `pvga` gate exercises + grades byte-identical vs
  qemu-system over **292/292** retired instructions: MISC/ST00 reset reads;
  SEQUENCER + GRAPHICS per-index write masks (`sr_mask`/`gr_mask`); the DAC 3-byte
  palette write + read auto-increment; the ATTRIBUTE index/data flip-flop +
  per-index masks (`ar_write_val`); the **color/mono port aliasing** (write
  `0x3c2` bit0 flips which of `0x3b0..0x3bf` / `0x3d0..0x3df` read `0xFF`); CRTC
  index/data in BOTH the color (`0x3d4/0x3d5`) and mono (`0x3b4/0x3b5`) banks; the
  **CRTC CR0-7 write-lock** (CR11 bit7, incl. the CR7-bit4-always-writable case —
  confirmed against qemu's `VGA_CR11_LOCK_CR0_CR7` source); and the **IS1 dumb-
  retrace toggle** (`0x3da/0x3ba` reads alternate `0x09/0x00`, **verified
  DETERMINISTIC across qemu runs** = dumb-not-precise retrace, so it is ON the
  differential surface — unlike the host-clock RTC time bytes). `cs` pulses
  exactly **one clock** per `S_IO` access (`io_ack=io_req`), so the DAC/IS1 read
  side-effects commit exactly once.

- **ACPI PM timer (`0x608`) — wired, write-inert differential + documented read
  boundary.** Empirically: qemu's default `-machine pc` leaves the PIIX4 PM I/O
  region **DISABLED** (PMBASE unprogrammed → `0x608` reads `0xFFFFFFFF` as
  unassigned I/O), and even when enabled the PM value is **host-clock-derived**
  (qemu samples a host virtual clock; the RTL samples `clk`) — not reproducible by
  a `clk`-sampled register model, exactly like the **8042-OBF host-queue** and
  **LAPIC-eax-only** precedents. So `pvga` never **READS** `0x608`; it does an
  `OUT 0x608` (write-inert) — a no-op in BOTH qemu (`acpi_pm_tmr_write` does
  nothing / unassigned-write-ignored) and the RTL — so it **retires identically**,
  a genuine if narrow per-record differential of the write-inert + non-HALT
  property. The PM value-read stays covered by the standalone `ven_acpipm` unit
  self-check (`verif/soc/run_acpipm.sh`). Quiescent in the differential, so it
  cannot perturb the VGA compare.

- **The gate (`verif/soc/run-soc-vga-gate.sh`, test `verif/sys/tests/pvga/`):
  PER-RECORD DIFFERENTIAL = EQUIVALENT 292/292.** Real→protected, then synchronous
  VGA + ACPI-PM I/O, graded against the `gen_trace.py --system` single-step golden
  (valid per-record oracle — NO interrupts, so the `pirqsoc` `SSTEP_NOIRQ`
  limitation does not apply). Golden drift-checked vs the committed
  `pvga.sys.vtrace.golden`: identical.

- **No regression — all SoC + core gates GREEN.** `psocdev` (M8.2) **122/122
  EQUIVALENT**, `pirqsoc` (M8.1) EQUIVALENT, `test386` external corpus **1500/1500
  EQUIVALENT** (all run on the modified `ventium_soc`); `make verify` **69/69
  golden cache hits, 0 regenerated** (the core is untouched, so func byte-
  identical by construction). RTL touched: `rtl/soc/ventium_soc.sv` +
  `rtl/ventium_soc.f`; `ventium-refs` untouched.

**M8 device integration is now COMPLETE: all 7 device models are wired into
`ventium_soc`** (PIC, PIT, RTC, i8042, port-92, VGA, ACPI-PM). The remaining M8
follow-ons are unbuilt larger devices (8237 DMA, SoundBlaster/OPL3, IDE, PCI) and
self-contained boot firmware — separate, larger efforts.

### M8.3b — `make verify-soc` SoC regression aggregate (2026-06-05, infra)

With four `ventium_soc` differential gates now in the tree (pirqsoc/psocdev/pvga/
test386) and **no** single command to run them, a SoC regression could slip
through by running only one gate. Added `verif/soc/run-all-soc-gates.sh` + a
`make verify-soc` target (the SoC analogue of `make verify` / `verify-sys`): runs
EVERY SoC gate in sequence (sequential, not parallel — they share the `tb_soc`
obj_dir + `build/soc` + a gdbstub port), prints a pass/fail summary, exits 0 only
if all pass. Codifies the no-regression check that M8.3 had to run by hand, so
future SoC work (the IDE/PCI/DMA builds) re-checks the whole track with one
command. Verified: `make verify-soc` → **4/4 PASS** (pirqsoc EQUIVALENT, psocdev
122/122, pvga 292/292, test386 1500/1500). Touches only `Makefile` + the new
aggregate script — no RTL, no behavior change. `ventium-refs` untouched.

### M8.4a — IDE/ATA controller (primary master, PIO) into ventium_soc (2026-06-05, per-record differential)

**What this is.** The first NET-NEW SoC device build beyond the device-integration
track: a synthesizable IDE/ATA controller (`rtl/soc/ven_ide.sv`), PIO mode, primary
channel, MASTER drive — the most-impactful remaining device (Win95-boot histogram:
IDE dominant). Preceded by a multi-agent **understand-phase workflow** (ground the
ATA device in qemu 8.2.2, pin the differentiable surface + oracle boundaries + the
disk-backend strategy) and an **adversarial design critique**; implemented oracle-
first (extract qemu's IDENTIFY/disk values, build the RTL to match) so the gate was
EQUIVALENT on the FIRST RTL run.

- **The disk value-match (the crux).** `verif/sys/tests/pide/gen_disk.py` is the
  SINGLE SOURCE OF TRUTH: from one byte buffer it emits BOTH `pide.img` (fed to
  qemu via `-drive if=ide,format=raw,index=0`) and `pide.disk.hex` (fed to
  `ven_ide` via `$readmemh`), so the qemu backing image and the RTL backing store
  cannot drift (a Stage-0 drift assert reconstructs + compares). qemu's
  `ide_data_readw` is `cpu_to_le16` (identity on the LE host), so a 16-bit data-
  port read = `(buf[2j+1]<<8)|buf[2j]`; the RTL returns `{disk[2j+1],disk[2j]}`
  for the same j → **READ SECTORS data byte-identical by construction**. 128-sector
  (64 KiB) image → qemu `guess_chs_for_size` = cyls 2/heads 16/secs 63; `ven_ide`
  is parameterized identically so IDENTIFY geometry and image size cannot disagree.

- **`ven_ide.sv` (PIO, primary master).** ATA task-file registers (0x1F0-0x1F7) +
  control block (0x3F6); a command FSM for IDENTIFY DEVICE (0xEC), READ SECTORS
  (0x20, single + MULTI-sector), EXECUTE DEVICE DIAGNOSTIC (0x90), and
  command-abort; the 16-bit data-port word + a clocked drain (each `inw` advances
  one word — `insw`/`rep insw` is NOT used: the core gates INS decode on `cosim_en`
  so it would HALT under `soc_en`; plain `inw` (66 ED) goes through S_IO); the
  reset signature; the absent-slave masking (ONLY error/status/alt-status read 0x00
  for the selected absent slave — matching qemu `core.c` `ide_ioport_read`);
  DIAGNOSTIC's `select<=0xA0` (ATA_DEV_ALWAYS_ON) + `error<=0x01`; LBA28 addressing.
  The IDENTIFY 256-word block: geometry words COMPUTED from the geometry parameters;
  the model/serial/firmware strings + feature/capability words are config-pinned
  constants captured from qemu 8.2.2 (e.g. `w85` WCE = `0x4021`, the OBSERVED value,
  NOT the design's `0x6021` guess — extracted from the golden). Lint **0 warnings**.

- **FULLY per-record differentiable (the `pide` gate, EQUIVALENT 5335/5335).** The
  test sets nIEN (0x3F6 bit1) FIRST → NO IRQ14 ever delivered → every interaction
  is a synchronous IN/OUT or a polled-status read → qemu's single-step golden is a
  valid per-record oracle (SSTEP_NOIRQ is structurally irrelevant: no IRQ raised).
  Grades byte-identical vs qemu-system over all 5335 instructions: reset signature,
  absent-slave masking, IDENTIFY (256 words), READ SECTORS LBA 0 + 127 (proves
  LBA→offset addressing; sector-0 word 255 = 0xAA55 boot sig), a **multi-sector**
  read (nsector=2 @ LBA 0, drains 512 words across the sector boundary — GATE-PROVES
  the `data_idx==255 && nsec_left>1 → xfer_lba+1` PIO continuation matches qemu's
  per-sector DRQ re-arm), and DIAGNOSTIC. The IDENTIFY pinning keeps the
  differential REAL — the committed RTL constants are graded against a FRESHLY
  generated golden each run, so qemu drift is caught.

- **Adversarial review (multi-agent workflow, 5 agents): verdict SOUND, no must-fix.**
  Four lenses (read-path, register/abort, IDENTIFY+honesty, boundary/scope) built
  their own qemu probes for paths the directed test does NOT cover and confirmed:
  the differential is REAL (no faked/weakened/vacuous compare — the golden is fresh
  each run, `compare.py --mode func` grades every IDENTIFY/READ word via eax); the
  IDENTIFY pinning is correct (all 256 words re-derived from a fresh golden, 0
  mismatches — geometry computed, strings/features build-pinned-and-graded); the
  off-surface boundaries hold (IRQ14 quiescent under nIEN, no transient BSY). Every
  divergence it found is on a path the gate provably cannot reach (data-port read
  while DRQ=0, absent-slave lcyl/hcyl, out-of-range LBA, non-{EC/20/21/90} commands,
  CHS, SRST, secondary channel). Its recommendations were folded in: the
  multi-sector read above (was 3256 records, now 5335, the FSM converted from
  source-asserted to gate-proven) and prose tightenings documenting the
  single-shared-register-file absent-slave model, the data-port DRQ=0 behavior, the
  command-abort being value-verified-not-gate-exercised, and the secondary channel's
  real 0x50 divergence (in `ven_ide.sv` + the `pide` manifest).

- **Oracle boundaries (documented, off the differential surface).** (1) the IRQ14
  line-edge instruction boundary — nIEN-polled, no IRQ raised, the line wired to
  PIC IR14 quiescent (the IR1/IR8/IR12 precedent). (2) the inter-instruction async-
  BSY-vs-synchronous timing — qemu's block read settles in an async BH before the
  next single-step (the golden never shows a lingering BSY), the RTL settles within
  the S_IO window → the poll loop runs the same count (empirically: 3256 records,
  same count). Deferred to M8.4b: WRITE SECTORS, SET FEATURES/SET MULTIPLE, SRST
  (an async BH in qemu), the secondary channel (left undecoded), bus-master DMA.

- **Gate + no-regression.** `verif/soc/run-soc-ide-gate.sh` (disk-gen+drift → build
  → qemu-exit WITH -drive → golden WITH -drive + record-drift → run tb_soc →
  compare EQUIVALENT), added to `make verify-soc`. **`make verify-soc` → 5/5 PASS**
  (pirqsoc, psocdev 122/122, pvga 292/292, **pide 5335/5335**, test386 1500/1500 —
  the IDE wiring's new cs windows 0x1F0-0x1F7/0x3F6 + the quiescent IR14 do not
  perturb the others). `make verify` **69/69 cache hits, 0 regenerated** (the core
  is untouched). RTL touched: `rtl/soc/ven_ide.sv` (new) + `rtl/soc/ventium_soc.sv`
  + `rtl/ventium_soc.f` + `verif/tb/Makefile` (the `-DVEN_IDE_DISK_HEX` define).
  `ventium-refs` untouched.

### M8.4b — IDE WRITE SECTORS (PIO, single + multi-sector) (2026-06-05, per-record differential)

**What this is.** The symmetric WRITE data-path completing the M8.4a READ: `ven_ide`
now handles **WRITE SECTORS (0x30/0x31)**, single + multi-sector — the data-port
*host→device* fill (the M8.4a stub `3'd0: ;` no-op is now a real write path). Same
arc: a research/design workflow grounded the WRITE handshake + the snapshot
strategy, an adversarial review checked the write edge-cases; implemented
oracle-first → **EQUIVALENT on the first RTL run**.

- **`ven_ide.sv` WRITE path.** `wdata` widened to 16-bit (the data port carries a
  full word; task-file regs use `[7:0]`); `ventium_soc` wires `io_wdata[15:0]`. A
  new `in_write` flag + the `0x30/0x31` dispatch arm (DRQ set **immediately**, no
  BSY — qemu `cmd_write_pio` sets DRQ in `ide_transfer_start`). The data-port write
  arm (guarded `r_status[3] && in_write`, mirroring qemu's `ide_data_writew`
  DRQ/PIO-out guard) stores each `outw` word into `disk[]` at the **same**
  `disk_byte` the READ uses (little-endian: `disk[base]<=wdata[7:0]`,
  `disk[base+1]<=wdata[15:8]`), advances `data_idx`, and on the last word commits /
  re-arms the next sector — the exact inverse of the READ drain. `insw`/`rep
  outsw` are NOT used (INS/OUTS are cosim-gated in the decoder → HALT under
  `soc_en`); plain `outw` (`66 EF`, decoded unconditionally) through S_IO. Lint 0.

- **FULLY per-record differentiable (the `pide` gate grows to EQUIVALENT 10854/10854).**
  The test (nIEN-polled, synchronous) now also: WRITE SECTORS single @ **scratch
  LBA 64** (pattern `0xC000+j`, distinct from the native `0x4000+j`) then **reads
  it back** (returns `0xC0xx` per-record — proving the write took effect,
  **non-vacuous**: a no-op/broken write would read back `0x40xx` and FAIL); and a
  **multi-sector** WRITE @ LBA 70 nsec=2 (status `0x58` re-armed at the sector
  boundary — the load-bearing continuation record) then reads back LBA 70-71 (512
  words = `0xC000..0xC1FF`), GATE-PROVING the WRITE continuation FSM + both
  sectors' data. The write status handshake (0x58-immediate / 0x58-re-arm /
  0x50-commit) is a NEW differential surface the READ did not exercise.

- **Snapshot strategy (so differential writes don't corrupt the single source).**
  `-drive ...,snapshot=on` routes qemu's guest writes to an anonymous temp overlay
  (the committed `pide.img` is opened read-only); the write only needs to survive
  within one run, which both the qemu overlay and the RTL's in-memory `disk[]`
  provide. A gate **md5 PRE==POST assert** enforces `pide.img` stays byte-pristine.

- **Oracle boundaries (documented, off-surface, gate-unreachable).** The async
  write-back BH settles before the next single-step (golden never shows a transient
  BSY/0xD0 — verified; the RTL commits synchronously → same poll-count parity); the
  RTL commits word-by-word to `disk[]` vs qemu's buffer-then-end-of-sector commit
  (identical CPU-observable result — the LBA isn't re-read until a later READ); a
  stray data-port write while DRQ=0 is dropped (guard matches qemu). Deferred to a
  later ATA-misc milestone: out-of-range-LBA abort, CHS, the misc commands, SRST.

- **Gate + no-regression.** `run-soc-ide-gate.sh`: `snapshot=on` + `MAXI=14000` +
  the md5-pristine assert. **`make verify-soc` → 5/5 PASS** (pirqsoc, psocdev
  122/122, pvga 292/292, **pide 10854/10854**, test386 1500/1500); `make verify`
  **69/69 cache hits, 0 regenerated** (core untouched). RTL touched:
  `rtl/soc/ven_ide.sv` + `rtl/soc/ventium_soc.sv` (the 16-bit `wdata` wire) +
  `verif/tb/Makefile` unchanged. `ventium-refs` untouched.

### M8.4c — IDE PIO fidelity hardening (OOR-abort, CHS, reg-advance, guards, misc cmds) (2026-06-06)

**What this is.** Closes the IDE PIO fidelity gaps the M8.4a/b adversarial reviews
mapped — converting six documented-boundary divergences into modeled, **gate-proven**
behavior. Same arc: a research/design workflow grounded each in qemu (esp. the OOR
multi-sector partial-abort timing), an adversarial review checked the corners;
implemented + brought to EQUIVALENT.

- **`ven_ide.sv` edits (all in the existing FSM, lint 0).** (1) **OOR-LBA clean
  abort** — the one real correctness gap (was a silent mod-128 alias/corruption):
  a READ past the last sector aborts UPFRONT (0x41/0x04, no DRQ, regs unchanged);
  a WRITE / multi-sector transfer crossing the boundary commits the in-range
  sectors then aborts on the OOR sector's last word, with the OOR sector's words
  DROPPED (disk[] gated on `xfer_lba < DISK_SECTORS`) — matching qemu's
  `ide_sect_range_ok` deferred-check timing exactly. (2) **LBA-register advance**
  (`ide_set_sector`): after a completed transfer the task file shows start+count,
  nsector=0. (3) **CHS addressing** (devhead bit6=0): `chs_lba =
  (cyl*HEADS+head)*SECS + sector-1`. (4) **command-while-DRQ guard**: a non-RESET
  command issued mid-transfer is dropped (`if (!r_status[3])`). (5)
  **read-during-write guard**: a data-port read in a write window returns 0x0000
  and consumes no slot. (6) **misc commands** 0x70 SEEK / 0x10 RECAL / 0x91
  INIT-DEV-PARAMS complete 0x50/0x00. Plus: every accepted command now **clears
  the error register** (qemu core.c:2168, "needed by Windows") — the one bring-up
  fix (a prior abort's 0x04 was lingering into a later command's error read).

- **The `pide` gate grows to EQUIVALENT 20728/20728.** Ten new directed sequences,
  each non-vacuous: OOR READ @128 (+ follow-up LBA0 read proves the disk untouched
  + the reg-advance); OOR WRITE @129 (+ alias LBA1 read proves no corruption);
  multi-READ crossing @127 (in-range sector delivered, abort at the boundary,
  sector reg = OOR LBA); multi-WRITE crossing @127 (+ LBA127 read-back proves
  commit-before-abort); CHS C0/H1/S2 → LBA64 data; command-while-DRQ (a mid-DRQ
  IDENTIFY is dropped, the original READ's data intact); read-during-write (a stray
  inw=0x0000 consumes no slot, the 256-word fill stays aligned); and the three misc
  commands. Every value first observed under qemu, graded per-record.

- **Adversarial review (4-agent workflow): verdict SOUND** — fidelity FAITHFUL on
  the gate surface (the 20728/20728 is real + non-vacuous, all 6 items independently
  re-verified vs `core.c`), NO gate-reachable must-fix. Its findings were folded in:
  the **mid-DRQ task-file-register WRITE drop** (qemu `core.c:1287`) is now also
  modeled (0x1F1-0x1F6 writes gated on `!DRQ`); and the precise residuals it mapped
  are documented as boundaries — the LBA-mode **multi-sector register trajectory**
  (nsector forced to 0 at the first boundary vs qemu's per-sector decrement; the
  READ visible LBA regs lag qemu by one sector *during* a transfer, agreeing only
  on the POST-transfer value which IS gate-proven), the misc-command state
  side-effects (0x91 geometry also drives CHS translation), and the CHS-mode
  register-advance off-by-one. All gate-unreachable (the test reads task-file regs
  only post-transfer / at the crossing-abort, never mid-transfer).

- **No regression.** `make verify-soc` **5/5 PASS** (pirqsoc, psocdev 122/122, pvga
  292/292, **pide 20728/20728**, test386 1500/1500); `make verify` **69/69 cache
  hits, 0 regenerated**. snapshot=on + the md5 PRE==POST assert keep `pide.img`
  pristine across the new WRITEs. Deferred: SET FEATURES/SET MULTIPLE + other misc
  commands, the boundaries above, LBA48, bus-master DMA, SRST. RTL touched:
  `rtl/soc/ven_ide.sv`. `ventium-refs` untouched.

### M8.4d — ATA command-set additions: SET MULTIPLE / SET FEATURES / SRST (2026-06-06)

**What this is.** The bounded, first-try-passable subset of the deferred IDE
command set (the research/design workflow recommended a tiered scope; this is its
Tier 1 — localized, no data-path touch, fully synchronous). The `pide` gate grows
to **EQUIVALENT 21875/21875**.

- **`ven_ide.sv` (lint 0, no data-path/FSM change).** SET MULTIPLE (0xC6): accept a
  power-of-two ≤ 16 (or 0) → 0x50, else abort 0x41/0x04 — and, faithfully, does
  NOT patch the cached IDENTIFY w59 (qemu `cmd_set_multiple_mode` updates only the
  runtime `mult_sectors`; `ide_identify` is cached after the first call). SET
  FEATURES (0xEF): subcommand in the FEATURE register — 0x03 set-transfer-mode
  patches the **cached** IDENTIFY words 62/63/88 (`put_le16` into `identify_data`,
  so a re-IDENTIFY DOES reflect it), 0x02 write-cache-enable patches w85→0x4021,
  **0x82 write-cache-disable patches w85→0x4001** (qemu *completes* 0x82 — it is NOT
  an abort), a no-op group → 0x50, genuinely-unsupported → abort. The mutable words
  are register-backed
  (`r_w62/63/85/88`). SRST (0x3F6 bit2 assert-edge): synchronous signature restore
  (reuses the DIAGNOSTIC result), never raising BSY — the qemu soft-reset BH
  collapses before the next single-step (same async-BH boundary as READ/WRITE).

- **Gate (EQUIVALENT 21875/21875), all non-vacuous.** SET MULTIPLE 8 (accept) +
  3/32 (abort, not-pow2 / >16); the post-commands IDENTIFY shows **w59=0x0110
  unchanged** (proving SET MULTIPLE does NOT touch the cached block — a faithful
  differential) and **w88=0x043F** (proving SET FEATURES 0x03 udma2 DID patch the
  cached block, 0x203F→0x043F); SET FEATURES 0x02/0x99; and the SRST signature
  restore (dirty 0x41 → post 0x50/error 0x01/signature). The bring-up caught the
  IDENTIFY-cache nuance: my first attempt made w59 register-backed (0x0108), but
  qemu's `cmd_set_multiple_mode` never patches the cached w59 — corrected so w59
  stays 0x0110 (cached) while w62/63/85/88 are register-backed (SET FEATURES does
  patch those).

- **Adversarial review (3-agent workflow): verdict SOUND** — every tested path
  byte-exact (transfer-mode groups incl the `1<<(val+8)` shift, invalid-group
  aborts, all 12 no-ops, the pow2≤16 boundary, w59-not-patched, SET-FEATURES words
  surviving SRST, synchronous SRST with no transient BSY). It caught one real
  divergence I'd mislabeled: SET FEATURES **0x82** is NOT unsupported — qemu
  completes it (w85→0x4001). Rather than document it as a boundary, I **fixed the
  RTL** (0x82 now completes + patches w85) and added it to the gate (status 0x50 +
  the re-IDENTIFY w85=0x4001). The `reset_reverts` side-effect of 0xCC/0x66 is noted
  as unmodeled (unobservable without the deferred 0x91-geometry).

- **No regression.** `make verify-soc` **5/5 PASS** (pide 21875/21875); `make
  verify` **69/69 cache hits, 0 regenerated**.

- **Deferred to M8.4d2 (the design's Tier 2 + the FSM-restructure items, all still
  documented boundaries):** the 0x91 INIT-DEV-PARAMS geometry side-effect + the
  CHS-mode register-advance (legacy-niche, add combinational divides), the LBA-mode
  multi-sector register trajectory (advance-at-window-open + nsector countdown —
  restructures the graded data core), READ/WRITE MULTIPLE (0xC4/0xC5, the N-sector
  DRQ window), LBA48 (0x24/0x34), and SET FEATURES 0x82 (async flush). RTL touched:
  `rtl/soc/ven_ide.sv`. `ventium-refs` untouched.

### M8.4e — Secondary channel + absent slave + empty ATAPI CD-ROM (2026-06-06)

**What this is.** `ven_ide` parameterized so the SoC can instantiate the SECONDARY
channel's master as the empty ATAPI CD-ROM qemu's `-machine pc` auto-creates
(`ide1-cd0`), decoded at 0x170-0x177 + control 0x376. Two new params: `IS_ATAPI`
(0xEB14 signature, DIAGNOSTIC status 0x00, the ATAPI command surface) and `HAS_DISK`
(suppresses the `$readmemh` — the empty CD has no media). The `pide` gate grows to
**EQUIVALENT 21996/21996** (it then becomes 22897 with the M8.4e2 fold-back below).

- **`ven_ide.sv`.** `IS_ATAPI`/`HAS_DISK` params + `SIG_LCYL/SIG_HCYL` (0x14/0xEB vs
  0x00/0x00); the absent slave's independent lcyl/hcyl shadow (reset 0xFF, broadcast-
  tracked); an ATAPI command branch. **`ventium_soc.sv`.** The `u_ide2` instance
  (IS_ATAPI=1, HAS_DISK=0), `cs_ide2`/`cs_ide2_ctl` decode, `ide_irq15` → PIC IR15
  (quiescent, nIEN), the read mux. NO second `-drive` (qemu auto-creates ide1-cd0).
- **Gate.** SEC-1 signature 0xEB14, SEC-2 DIAGNOSTIC 0x00, SEC-3 IDENTIFY abort +
  signature, SEC-4 READ abort (no DRQ), SEC-5 secondary absent-slave masking +
  lcyl/hcyl=0xFF; plus the PRIMARY absent-slave lcyl/hcyl=0xFF read placed EARLY
  (fresh shadow, before any LBA write broadcasts over it).

### M8.4e2 — ATAPI command-surface fidelity (4-dimension review fold-back) (2026-06-06)

**What this is.** The M8.4e adversarial review (4-dimension Workflow, **30 findings
confirmed / 4 rejected** after independent adversarial verification) found the
IS_ATAPI dispatch was a coarse "abort everything but 0x90", whereas qemu treats
several CD-permitted commands as completions, and the boundary docs OVERCLAIMED that
qemu aborts them. Folded back **oracle-first** (extend the test to probe each, read
the golden, build the RTL to match): `pide` grows to **EQUIVALENT 22897/22897**.

- **ATAPI command surface made command-specific (`ven_ide.sv`), every value pinned to
  the golden:** **DEVICE RESET (0x08)** → `ide_reset`+signature, status 0x00 / error
  0x00 / nsector·sector=1 / 0xEB14 / devhead 0xA0 (head cleared), NO IRQ
  (`cmd_device_reset` returns false). **SET FEATURES (0xEF)** → COMPLETES 0x50 (the
  empty CD still has a BlockBackend). **FLUSH CACHE (0xE7)** → ABORTS 0x41/0x04 at
  RUNTIME (the no-medium `blk_aio_flush` error via `ide_flush_cb`) — the golden
  overturned the review's "completes 0x50" guess, a clean oracle-first catch.
  **IDENTIFY/READ (0xEC/0x20/0x21)** → full `ide_set_signature` THEN abort (now also
  resets nsector·sector + clears the head bits, not just lcyl/hcyl). **Unsupported
  opcodes (e.g. 0xB0 SMART, NOT CD_OK)** → BARE `ide_abort_command`, task file LEFT
  UNTOUCHED (a pre-written lcyl=0x55 SURVIVES). **ATAPI SRST** → status 0x00 (not
  0x50). **Absent slave** gains an INDEPENDENT nsector/sector shadow (reset 1,
  broadcast-tracked, never advanced by a master command). **Data-port reads** outside
  a read-DRQ window return 0x0000 (idle/write-window/empty-CD, no X-leak). `HAS_DISK`
  lint sink.
- **Honest docs (the mandatory part).** Corrected the header + manifest claim that
  qemu "aborts 0xA0/0xA1 (matches qemu)" — it does NOT: 0xA0 PACKET / 0xA1
  IDENTIFY-PACKET are CD_OK and qemu DRQ-enters them (status 0x58). The RTL's bare
  abort is now an ACKNOWLEDGED, documented divergence on the deferred full-ATAPI-PACKET
  surface; the directed test issues NEITHER, so the EQUIVALENT stays honest. The stale
  "secondary channel UNDECODED" boundary is removed (now decoded + gate-proven).
- **No regression.** `make verify-soc` **5/5 PASS** (pide 22897/22897); `make verify`
  **69/69 cache hits, 0 regenerated**. Both standalone lint configs (ATA / +DISK_HEX)
  0 warnings. RTL touched: `rtl/soc/ven_ide.sv`, `rtl/soc/ventium_soc.sv`. Test:
  `verif/sys/tests/pide/pide.S`. `ventium-refs` untouched.
- **Still deferred:** the full ATAPI PACKET protocol (0xA0 12-byte CDB + `ide_atapi_cmd`
  + sense; 0xA1 256-word ATAPI identify) — a dedicated future milestone.

### M8.4f-pre — Minimal PCI config shim (maps the bus-master IDE BAR4) (2026-06-06)

**What this is.** The first of the two M8.4f (bus-master DMA) increments, recommended by
a 4-investigation research Workflow that **empirically probed the gate's own
qemu-system-i386**: the PIIX3 IDE is at PCI 00:01.1, its bus-master BAR4 is UNMAPPED at
reset and a fixed-port BMIDE decode reads 0xFF until the guest programs BAR4 via
0xCF8/0xCFC AND sets `PCI_COMMAND.IO` — so a fixed-port hard-decode is NOT differentiable.
A minimal single-function PCI config shim is therefore a HARD PREREQUISITE. The `pide` gate
grows to **EQUIVALENT 22947/22947** (first RTL run, oracle-first).

- **`ventium_soc.sv` (the shim, folded in — not a full host bridge).** Decodes
  CONFIG_ADDRESS (0xCF8, dword latch, enable bit31) + the CONFIG_DATA window
  (0xCFC..0xCFF, 1/2/4-byte) for **bus0/dev1/fn1 only**. Models exactly what a driver
  touches, pinned to the live golden: vendor/device `0x70108086` (RO), class/prog-if
  `0x01018000` (RO), `PCI_COMMAND` (R/W IO/MEM/MASTER, reset 0), BAR4 (R/W, low 4 bits RO
  → write 0xC000 reads back `0xC001`, reset `0x00000001`). Absent functions / unmodeled
  offsets read all-ones (the qemu reply); the test reads only modeled offsets.
- **`pide.S`.** A PCI block (after all existing graded sections) reading vendor/device,
  class, the pre-enable command, the pre-program + post-program BAR4, and the post-enable
  command — all per-record graded. This is the **first exercise of the 32-bit `outl`/`inl`
  (`io_size=4`) I/O path under `soc_en`**: the no-shim run confirmed the mechanics retire
  byte-identical (only the config DATA diverged), de-risking the research's top concern.
- **No regression.** `make verify-soc` **5/5 PASS** (pide 22947/22947); `make verify`
  **69/69 cache hits, 0 regenerated**. SoC lints clean (beyond the pre-existing
  `fpu_x87_pkg` WIDTHEXPAND). RTL touched: `rtl/soc/ventium_soc.sv`; test: `pide.S`;
  `ventium-refs` untouched.
- **Next (M8.4f proper):** the DMA engine — a ven_ide mem-master port + a 2-master
  priority mux on the SoC `mem_*` seam + the BMIC/BMIS/BMIDTP register file at the BAR4
  base + a single-PRD single-sector READ DMA (0xC8), polled via BMIS bit0 + status 0x50
  (under nIEN, `ide_bus_set_irq` is gated so BMIS-INT is never set), proven non-vacuously
  by a CPU read-back of the DMA'd buffer.

### M8.4f — IDE bus-master DMA engine (single-PRD READ DMA) (2026-06-06)

**What this is.** The second M8.4f increment: a working IDE BUS-MASTER DMA path — the
Win95-boot mechanism — on top of the M8.4f-pre PCI/BAR4 seam. The `pide` gate grows to
**EQUIVALENT 24040/24040** (first RTL run, oracle-first; all DMA values pinned to the
live golden before the RTL was written).

- **`ven_ide.sv` (HAS_DMA=1 on the primary).** The BMIDE register file — BMIC (off0,
  `cmd & 0x09`), BMIS (off2, DMAING RO-to-sw / ERROR·INT write-1-clear / bits5-6 R/W),
  BMIDTP (off4, dword, low-2 forced 0); a READ DMA (0xC8) arm capturing the LBA; and a
  PRD-walk + single-sector copy FSM (`DMA_IDLE→PRD0→PRD1→XFER`) driving a NEW
  single-beat **memory-master port** (`dma_mem_req/we/addr/wdata/wstrb` + `rdata/ack`).
  On the BMIC START (bit0) 0→1 edge with a DMA armed, it reads one 8-byte EOT PRD from
  RAM at BMIDTP, copies 512 B (128 dwords, little-endian from `disk[]` — byte-identical
  to a PIO read) to RAM at the PRD base, then clears DMAING + sets status 0x50 +
  `advance_lba_regs`. Under nIEN the completion IRQ is gated, so **BMIS-INT is never
  set** (the test polls DMAING).
- **`ventium_soc.sv` (the architecturally-sensitive part).** A 2-master **priority mux**
  on the single `mem_*` port (`core_mem_*` vs `ide_dma_mem_*`, by `ide_dma_busy`), the
  A20 mask applied to the muxed address, and **`io_ack = io_req && !ide_dma_busy`** — the
  BMIC-START OUT is HELD for the whole burst so the core parks in S_IO (mem bus free),
  exactly mirroring qemu's synchronous `bmdma_cmd_writeb`→`dma_cb`. So every instruction
  after START sees DMA-done state; the golden's BMIS poll loops once and the RTL matches.
  `cs_bmide` decodes the BAR4 window only when `PCI_COMMAND.IO` is set.
- **Non-vacuous gate.** The DMA target buffer is pre-filled with a `0xFFFFFFFF` sentinel
  (distinct from disk content + the PIO buffers); the CPU read-back of all 128 dwords is
  graded byte-identical to disk LBA0 (word255=0xAA55) — a no-op DMA would fail. BMIDTP
  readback 0x5000, BMIC 0x09, final BMIS 0x00, status 0x50, LBA advance (nsector 0 /
  sector 1) — all per-record EQUIVALENT.
- **Adversarial review (3-agent workflow, 18 confirmed / 5 rejected).** The
  architecturally-sensitive parts were ADVERSARIALLY VERIFIED SOUND: NO combinational
  loop (`io_req` is driven off the registered S_IO `state`, not `io_ack`; verilator
  `-Wall` finds no UNOPTFLAT), the 2-master mem-mux is race-free (the core drives
  `core_mem_req` only in memory states, never S_IO, and the DMA launches only from a
  held BMIC-START OUT which is itself an S_IO access), write-vs-read ordering holds, and
  the gate is non-vacuous (the `0xFFFFFFFF` sentinel would fail a no-op DMA). **Folded
  back three real fidelity fixes:** (A, 3 reviewers) the task-file status reads **0x58**
  (DRQ) in the window between `0xC8` and BMIC-START (qemu's `ide_sector_start_dma`
  returns false so the dispatch never clears it) — now set + gate-proven; (C) the DMA
  address **bypasses the CPU A20 gate** (PCI bus-master DMA addresses the physical bus
  directly; A20 now masks only the core address); (D) a true START **0→1 edge guard**
  on the launch. Documented as KNOWN deferred divergences: OOR-LBA DMA (currently
  aliases mod-128 vs qemu's range-abort), BMIC STOP / no-armed-START DMAING, the
  sub-dword BMIC/BMIS access-width replies, and the PRD-count/multi-PRD/WRITE-DMA/LBA48
  surface.
- **No regression** (the mem-mux sits on the core's critical path). `make verify-soc`
  **5/5 PASS** (pide 24040/24040 — the mux passes `core_mem_*` through unchanged when
  the DMA is idle); `make verify` **69/69 cache hits, 0 regenerated**; SoC lints clean.
  RTL: `rtl/soc/ven_ide.sv`, `rtl/soc/ventium_soc.sv`; test: `pide.S`; `ventium-refs`
  untouched.
- **Deferred (documented, the test issues none):** WRITE DMA (0xCA), multi-PRD
  scatter-gather, multi-sector (nsector>1), LBA48 DMA (0x25/0x35), the IRQ-driven
  (nIEN=0) completion + BMIS-INT path, the PRD error branches + BM_STATUS_ERROR, OOR-LBA
  DMA abort, mid-flight BMIC STOP, secondary-channel DMA, and the full PCI host bridge
  (M8.5). The engine transfers exactly 128 dwords (the PRD count field is assumed 512).

### M8.4g — DMA hardening: ORACLE-BLOCKED (investigated, no RTL change) (2026-06-06)

**Finding (not a milestone — a documented limit).** Asked to harden the DMA (WRITE DMA,
multi-sector, multi-PRD), a research workflow + empirical probing established that **only a
single-PRD single-sector READ DMA is differentiable under the `gen_trace` single-step
oracle.** `gen_trace` single-steps with pure `vCont;s` and **never pumps qemu's main loop /
block-AIO**, so qemu's async DMA completion does not run during a trace; the M8.4f
single-sector READ works only because qemu's block layer completes that small cached read
*inline*. WRITE DMA (0xCA), multi-sector READ (nsector=2), and multi-PRD single-sector (2
PRDs) **all** leave status 0x58 / regs unadvanced / buffer untransferred even after 256 polls
(DMAING clears but the ATA command never completes) — an oracle limitation, not an RTL gap.
No RTL change can make qemu produce a completed state to match. The probe was reverted (repo
stays green at M8.4f); the user chose to **pivot to PIO fidelity (M8.4d2)** rather than invest
in a risky `gen_trace` AIO-pump that would touch all SoC goldens. Recorded so it is not
re-attempted.

### M8.4d2 — READ MULTIPLE / WRITE MULTIPLE (0xC4/0xC5) block-mode PIO (2026-06-06)

**What this is.** The highest-Win95-value deferred PIO item (a research workflow picked it over
the riskier 0x91-geometry / CHS-reg-advance / LBA-trajectory items). Block-mode PIO: SET
MULTIPLE (0xC6) sets the block size; 0xC4/0xC5 transfer `MIN(nsector, mult_sectors)` sectors per
DRQ window (one `n*512`-byte window, DRQ held across the sectors) vs one-sector-per-window for
0x20/0x30. The `pide` gate grows to **EQUIVALENT 38656/38656** (first RTL run, oracle-first).

- **`ven_ide.sv` (additive — the only qemu difference vs 0x20/0x30 is `req_nb_sectors`).** A
  `mult_sectors` reg (reset 16 = `MAX_MULT_SECTORS`); the existing 0xC6 accept branch now STORES
  `mult_sectors <= nsector` (w59 stays the cached constant 0x0110 — qemu freezes the IDENTIFY on
  the first 0xEC). A per-window `r_blk_size` (1 for 0x20/0x21/0x30/0x31/0xEC; `mult_sectors` for
  0xC4/0xC5) + `blk_left` counter. The 0xC4/0xC5 arms (mult==0 → abort *before* the range check).
  The READ-drain + WRITE-fill wraps became **two-level**: intra-block (`blk_left>1`) advances the
  sector but KEEPS the DRQ window open (no IRQ, no reg advance); block boundary re-arms; final
  clears DRQ. **Seeding `blk_left=1` for the existing commands makes the pre-M8.4d2 24040-record
  baseline byte-identical** (the new intra-block branch is provably never taken for them — gate-proven).
- **Gate (EQUIVALENT 38656/38656), all non-vacuous.** TEST A (READ MULTIPLE 4 @ LBA0): the
  status stays **0x58 after draining sector 0** (the block window does NOT re-arm at the
  sector-0/1 boundary — a per-sector-window RTL would diverge), 1024 words byte-identical to disk
  LBA0-3, post sector 0x04. TEST B (partial, nsec=6 mult=4): block1=4 sectors, then re-arm
  (0x58), block2=`MIN(2,4)`=2 sectors (word0=0x0400 LBA4), post sector 0x06. TEST C: 0xC4 with
  mult=0 → abort 0x41/0x04. TEST D (WRITE MULTIPLE @ LBA112 nsec=2): read-back 0xE000/0xE100
  proves the block write moved 2 sectors. TEST E: re-IDENTIFY w59 stays 0x0110 (cache freeze).
- **Adversarial review (3-agent workflow, 9 confirmed / 3 rejected).** Verified the two-level
  wrap preserves the 0x20/0x30/0xEC baseline byte-identically (no regression). Found one real
  **HIGH** divergence: block-mode (0xC4/0xC5) OOR was range-checked **per-sector**, but qemu
  checks the **whole block atomically** (`ide_sect_range_ok` with n=`MIN(nsector,mult)`) — a block
  *straddling* the last LBA aliases data (READ) / commits a partial prefix (WRITE) and completes
  0x50, where qemu rejects the whole block. **Folded back** the clean READ-side fix: a
  `first_blk_oor` whole-block check at the 0xC4 arm → upfront abort (status 0x41, error 0x04, regs
  unmoved), gate-proven by **TEST F** (0xC4 @ LBA126 nsec=4, the 4-sector block straddles → abort,
  sector reg unmoved 0x7E). The WRITE-side straddle (qemu fills-then-atomic-rejects vs the RTL's
  per-sector abort) and the multi-block later-straddle (entangled with the documented nsector
  trajectory) are honestly documented as KNOWN divergences (the test issues none) for a future
  IDE-OOR-fidelity pass. Also fixed a header overclaim (the "matches ide_sect_range_ok" note is
  scoped to the per-sector 0x20/0x30 path).
- **No regression** (the change edits the load-bearing READ/WRITE drain). `make verify-soc`
  **5/5 PASS** (pide 38656/38656); `make verify` **69/69 cache hits, 0 regenerated**; SoC lints
  clean. RTL: `rtl/soc/ven_ide.sv`; test: `pide.S` (MAXI 26000→42000). `ventium-refs` untouched.
- **Deferred to M8.4d3 (the test issues none):** the 0x91 INIT-DEV-PARAMS geometry side-effect
  + the CHS-mode register-advance (share `r_heads/r_sectors`; legacy/Win95-irrelevant), the
  LBA-mode mid-transfer register trajectory (agrees post-transfer; the mid-transfer flip is
  gdbstub-timing-fragile), and LBA48 (0x24/0x34/0x29/0x39).

### M8.5 — PCI host bridge: bus-0 enumeration + BAR sizing (SoC) (2026-06-06)

**What this is.** The full PCI host bridge / enumeration — the natural extension of the M8.4f-pre
single-function shim into a bus-0 config-space the way a real BIOS/OS enumerates. A research
workflow **empirically probed the live gate qemu** (`-machine pc`) to capture the exact config of
every bus-0 function. The `pide` gate grows to **EQUIVALENT 38788/38788** (first RTL run,
oracle-first). (Distinct from the FPU "M8.5 SRT divider" below — a numbering coincidence; this is
the SoC-track M8.5.)

- **`ventium_soc.sv` (additive — generalizes the shim, no new module).** `pci_sel` (bus 0 +
  enable bit31), `pci_devfn`, `pci_reg`; a per-devfn config-read table for the 5 chipset-core
  functions `-machine pc` creates — **00:00.0** i440FX host (0x12378086 / class 0x06000002),
  **00:01.0** PIIX3 ISA (0x70008086 / status 0x0200 / class 0x06010000 / header-type **0x80
  multifunction**), **00:01.1** IDE (0x70108086 / reg0x04 = status **0x0280** | command / class
  0x01018000 / BAR4), **00:01.3** PIIX4-PM (0x71138086), **00:02.0** std-VGA (0x11111234) — all
  values pinned to the live golden. Only the IDE function is config-writable (command + BAR4); the
  rest are RO. Absent devfn / bus≠0 / disabled-mechanism → 0xFFFFFFFF. **Fixed a latent bug:** the
  IDE reg0x04 high word was 0x0000, qemu returns the status 0x0280 — the prior M8.4f-pre test reads
  command via `inw` (low word), so the 38656 baseline is unaffected (the fix is gate-proven by the
  new DWORD read = 0x02800005).
- **Gate (non-vacuous, oracle-first).** A PCI-enumeration block reads the 5 functions' IDs + class
  + the ISA multifunction header + the IDE status DWORD (the fix) + the IDE BAR4 **sizing** (write
  0xFFFFFFFF → read the 16-byte mask **0xFFFFFFF1**, restore 0xC000 → 0xC001) + the genuinely-absent
  devfns {0x01, 0x0A} and a bit31-disabled probe (all → 0xFFFFFFFF).
- **Controlled subset, honestly documented.** The test reads ONLY the modeled functions + curated
  absent slots — NOT a blind dev 0..31 sweep. The gate qemu (`-machine pc`, no `-net none`) also has
  an **e1000 NIC (00:03.0)** + the VGA/e1000 **memory BARs** + chipset quirk regs (PAM/SMRAM/PIRQ/
  PMBASE) that are **unmodeled and never read** — a full blind scan WOULD diverge on them (a
  documented deferral / future work).
- **Adversarial review (3-agent workflow, 10 confirmed / 8 rejected) — clean.** Every confirmed
  finding was doc-severity (no RTL bugs): verified the 38656 IDE prefix is architecturally
  byte-identical (the bytes-only diffs are jump-displacement re-encodings from the longer binary),
  the write-gate generalization is logically identical, the config values + BAR sizing + absent
  semantics match the live qemu, the controlled-subset is honestly documented, lint clean.
  **Folded back:** the modeled **PM reg0x3C interrupt-pin** (0x00000100 pin A — the one
  modeled-function gap the review found) is now modeled + gate-proven via a new test read, and a
  stale `0x02800000` comment was corrected to the live `0x02800005` (status 0x0280 | command 0x0005,
  IO|BM set by the prior M8.4f-pre block). Final gate EQUIVALENT **38788/38788**.
- **No regression** (the generalized decode underlies the 38656 IDE prefix + the `cs_bmide` DMA
  window, which still keys off the IDE `pci_cmd[0]`/`pci_bar4`). `make verify-soc` **5/5 PASS**;
  `make verify` **69/69 cache hits, 0 regenerated**; SoC lints clean. RTL: `rtl/soc/ventium_soc.sv`;
  test: `pide.S`. `ventium-refs` untouched.

### M9 — FIRST REAL BOOT: firmware chain-loads a boot sector from disk (2026-06-06)

**What this is.** The smallest thing that is genuinely **booting** — and the milestone the whole
M8 SoC build was for. A research workflow empirically proved (and PoC'd) that, with **zero new
RTL**, `ventium_soc` can run a reset-vector firmware that **chain-loads a real boot sector off the
IDE disk and executes it**. Unlike `pide` (a hand-written firmware that drives devices *in place*),
`pboot` runs **real boot code loaded from the disk at run time** — the BIOS→MBR handoff. New
`pboot` gate: **EQUIVALENT 1084/1084** (first productized run).

- **The boot flow** (`verif/sys/tests/pboot/`, all synchronous so single-step-differentiable):
  `pboot_stub.bin` (the 64 KiB -bios) boots at F000:FFF0 → real→protected (flat GDT) → sets **nIEN
  FIRST** (no IRQ14 ever) → `READ SECTORS` disk **LBA0** via PIO into RAM at **0x8000** → **far-jmps
  into it**. The boot sector (`pboot_mbr.bin`, disk LBA0, ending in the `0x55 0xAA` signature) then
  **executes from RAM** (cs=0x08): writes a 64-bit signature (0xB007B007 / 0x600DCAFE) → isa-debug-exit.
- **Single-source disk** (`gen_disk.py`): the boot sector is at LBA0 of BOTH `pboot.img` (qemu
  `-drive`) and `pboot.disk.hex` (ven_ide `$readmemh`), drift-asserted; the rest zero.
- **Non-vacuous gate** (`run-soc-boot-gate.sh`, wired into the SoC aggregate as gate #5): per-record
  EQUIVALENT vs the qemu-system single-step golden, **plus** a hard assertion that BOTH the golden and
  the RTL trace **reach pc=0x00008000** (the boot sector executing from RAM — proving the handoff
  actually happened, not a silent early halt) and that the disk stays md5-pristine. The
  self-modifying fetch (firmware writes 0x8000 then jmps into it) is gate-confirmed hazard-free.
- **Zero new RTL** — runs on the existing core + `ven_ide` PIO read path + the flat TB memory + the
  M8.x device set. `make verify-soc` **6/6 PASS** (pboot 1084/1084); `make verify` **69/69 cache
  hits, 0 regenerated**. `ventium-refs` untouched.
- **The path to a fuller boot (documented, NOT done — a separate, much larger track).** A real
  SeaBIOS POST / OS boot is **not single-step-differentiable** today. Blocking gaps: (ISA) CPUID is
  gated off under `soc_en` (a 1-line ungate; the first SeaBIOS HALT), and far CALL/RETF, LES/LDS,
  LSS/LFS/LGS, RDTSC, WBINVD/INVD, SGDT/SIDT/SLDT/LLDT, CMPXCHG8B, ENTER, BOUND are unimplemented
  (loud HALT); (MEMORY/CHIPSET) no i440FX PAM shadow registers (0x58-0x5F) or a ROM-shadow-aware
  memory model for SeaBIOS's relocate-to-shadow-RAM, no port-0x61 refresh-toggle, no 0xB8000/0xA0000
  VGA framebuffer; (ORACLE) `gen_trace` single-steps with no main-loop pump, so IRQ-driven / async
  progress never advances and a 100K-1M-instruction POST has no checkpoint — needing a replay-log
  oracle (the repo's Win95 `-d cpu` mechanism) before any POST-scale or IRQ-driven boot can be gated.
  Near-term differentiable follow-ons: a 16-bit-real-mode boot sector at 0000:7C00 (M9-rm) and a
  bus-master DMA chain-load (M9b, reusing the M8.4f single-PRD READ DMA).

### M9b — DMA chain-load boot: the BIOS→MBR handoff via bus-master DMA (2026-06-06)

**What this is.** The M9 boot again, but the firmware chain-loads the boot sector with **bus-master
DMA** instead of PIO — combining two already-gate-proven pieces (the M8.4f single-PRD READ DMA + the
M9 boot/handoff) into one boot, with **zero new RTL**. New `pbootdma` gate: **EQUIVALENT 592/592**
(first RTL run). Beyond proving the boot handoff, it proves **DMA-write/instruction-fetch
coherency**: the bus-master engine writes the executed region (0x8000) and the CPU immediately
far-jmps in and fetches from it.

- **The boot flow** (`verif/sys/tests/pboot/pboot_dma_stub.S`, a second -bios alongside the PIO
  `pboot_stub.bin`, all synchronous → single-step-differentiable): boot F000:FFF0 → real→protected
  (flat GDT) → **nIEN FIRST** (no IRQ14 ever) → enable `PCI_COMMAND.IO|bus-master` + map BMIDE
  `BAR4=0xC000` (0xCF8/0xCFC, devfn 0x09) → build one **EOT PRD @0x5000** pointing at RAM **0x8000**
  (`dword1=0x80000200`) → `BMIDTP=0x5000` (0xC004) → task-file nsector=1/LBA0/devhead 0xE0 +
  **READ DMA 0xC8** → `BMIC=0x09` START|RWCON-READ (0xC000) → poll `BMIS` DMAING (0xC002) to 0 →
  **far-jmp 0x08:0x8000** into the DMA-loaded boot sector. The target 0x8000 is pre-filled with a
  `0xFFFFFFFF` sentinel first, so a no-op DMA would fetch garbage and diverge (non-vacuous).
- **Same disk, same boot sector** as M9 (`pboot_mbr.bin` at LBA0, single-source `gen_disk.py`); only
  the -bios firmware differs. The DMA recipe is byte-for-byte the proven M8.4f single-PRD READ DMA —
  the **only** DMA shape single-step-differentiable (a single-PRD single-sector cached READ completes
  INLINE in qemu's block layer; multi-sector/multi-PRD/WRITE never advance under `gen_trace`'s
  no-AIO-pump single-step — see `memory/m84f-dma-plan.md`).
- **Non-vacuous gate** (`run-soc-bootdma-gate.sh`, wired into the SoC aggregate as gate #6, PORT
  51261): fresh qemu single-step golden each run, per-record EQUIVALENT, **plus** the hard
  pc=0x00008000 handoff assertion on BOTH the golden and the RTL trace, the disk-pristine md5 check,
  and the exit-133 check. 592 records (vs 1084 for PIO — the DMA offloads the 256-word `inw` drain).
- **Zero new RTL** — runs on the existing core + `ven_ide` DMA engine + the PCI shim + the 2-master
  mem mux + the flat TB memory. SoC aggregate **7/7 PASS**; `make verify` **69/69 cache hits, 0
  regenerated**. `ventium-refs` untouched.

### Gate hygiene — `verify-all` umbrella + `ppci` orphan cleanup (2026-06-06)

- **`make verify-all`** (`verif/run-verify-all.sh`): one command that runs EVERY routinely-runnable
  gate — `verify` (m1-m5 func+cycle) + `verify-sys` + `verify-soc` + `verify-srt` + `m6` (errata) +
  `bus` + `bus-sva` — with a single pass/fail summary, so a regression in the bus-protocol SVA, the
  errata flag, or the SRT divider can no longer slip through by only running the differential
  aggregates. The m7 macro co-sims (Quake/Win95) are **excluded-and-logged** (not silently dropped):
  they need gitignored producer artifacts unbuildable from a clean checkout; the driver prints how to
  run them manually. **Validated green: VERIFY-ALL-OK, all 7 gates PASS.**
- Removed the untracked `verif/sys/tests/ppci/` scratch dir — an M8.5 PCI config-space **probe**
  (dumped over COM1 for empirical ground-truth capture), wired into no gate and superseded by the
  inline PCI enumeration in `pide.S`.

### M9-rm — CANONICAL real-mode boot: chain-load to 0000:7C00 (2026-06-06)

**What this is.** The boot the way a PC BIOS actually does it: a -bios firmware that **stays in
16-bit real mode** the whole time and chain-loads the boot sector to the canonical **0000:7C00**,
then far-jmps in. The third boot variant (after M9 PIO→0x8000 and M9b DMA→0x8000), and the only one
that never leaves real mode. New `pbootrm` gate: **EQUIVALENT 1065/1065** (first RTL run), with
**zero new RTL**.

- **The boot flow** (`verif/sys/tests/pboot/pboot_rm_stub.S`, all synchronous → single-step-diff):
  reset F000:FFF0 → 16-bit real mode (NO GDT, NO CR0.PE, NO PM far-jmp) → **nIEN FIRST** → `READ
  SECTORS 0x20` disk LBA0 via 16-bit PIO (`inw`/`stosw` into `es:di=0000:7C00`) → **far-jmp
  0x0000:0x7C00**. The 16-bit boot sector (`pboot_rm_mbr.S`, disk LBA0) executes from RAM at cs=0/
  ip=0x7C00, writes a distinct signature (0x7C00B007/0x600DF00D @0x9000) → isa-debug-exit.
- **`cr0` stays the reset `0x60000010` on every record** (never enters PM) — strictly simpler than
  M9, yet exercises a path the PM boots never did: **real-mode IDE PIO + the canonical 0000:7C00
  handoff**. Non-vacuous gate (`run-soc-bootrm-gate.sh`, SoC aggregate #7, PORT 51262): per-record
  EQUIVALENT **plus** the `pc=0x00007c00` handoff assertion on BOTH traces (the trace pc is the raw
  eip offset; cs.base=0 ⇒ offset==linear==0x7C00) + disk-pristine md5 + exit-133.
- **Encoding care** (a read-only design workflow grounded these in the core's 16-bit decode): the
  drain pointer uses `movl $0x7C00,%edi` to zero-extend EDI so it tracks qemu's truncated `es:di`;
  `inw`/`stosw`/`decw` stay bare 16-bit ops (no stray 0x66); only `[disp16]`-direct ModR/M is used
  (the only real-mode addressing form the core decodes). Uses a **distinct disk**
  (`pboot_rm.img`/`pboot_rm.disk.hex`) so the three boot gates never share an image.
- **No regression:** SoC aggregate **8/8 PASS**; `make verify` **69/69 cache hits, 0 regenerated**.
  `ventium-refs` untouched.

### M10 — x87 packed-BCD FBLD/FBSTP (a deferred family, now implemented) (2026-06-06)

**What this is.** The first deferred x87 family lifted out of the loud-HALT set. A research workflow
scoped the whole deferred-x87 backlog and recommended **FBLD/FBSTP** (packed-BCD load/store) as the
cleanest first increment: genuinely P5 (BCD dates to the 8087), deterministic + single-step
differentiable (pure integer/softfloat, no libm), and maximally self-contained — it reuses the
existing 10-byte (m80) load/store micro-sequences with **zero new FSM state and no FIP/FDP/FOP
tracking**. (It also unblocks Erratum 83.) Two new `x87:true` directed tests, both **EQUIVALENT vs
QEMU on the first RTL run**.

- **Oracle-first paid off.** The research *guessed* FBSTP sets no PE; the regenerated qemu golden
  showed FBSTP **does** set PE on inexact rounding (2.5→2 and 3.5→4 both set fstat bit5). Building to
  the read bytes — not the guess — got it right first try. Likewise the BCD-indefinite image
  (`00..00 C0 FF FF`) and the `|val| ≥ 1e18` overflow threshold (tighter than `fx_to_int_ex`'s 2^63
  bound — a value in `[1e18, 2^63)` is a valid int64 yet an invalid BCD) were oracle-pinned.
- **RTL** (core + FPU package only): two `fxop_e` members (`FX_FBLD`/`FX_FBSTP`); the `DF /4`/`DF /6`
  decode arms (were `d_unknown`→HALT); a `fstore_val` arm + the push dispatch; the existing PE/IE
  latch and last-beat-pop lists extended. New pure functions `fx_bcd_to_fx` (BCD→floatx80 via the
  same exact `fx_from_int` FILD uses) and `fx_fx_to_bcd` (floatx80→18-digit BCD via `fx_to_int_ex`,
  with the separate 1e18 check, the indefinite image, and PE from the inexact bit).
- **Tests** (`verif/tests/tx_bcd_ld`, `tx_bcd_st`, auto-discovered by `make verify`): FBLD of
  +1234567/−1234567/+123456789012/+0 (st0 live-graded as 80-bit + a FISTP→GPR cross-check); FBSTP of
  +42/−42 (sign byte), 2.5→2 / 3.5→4 (round-to-even + PE), and 5e18→indefinite+IE — the 10 BCD bytes
  read back into eax/edx/ecx (memory isn't graded) so the bytes are compared.
- **No regression / boundary intact:** `make verify` **71/71** (69 cache hits + the 2 new), the FSIN
  loud-HALT boundary (`run_x87_boundary.sh`) still PASSES (FBLD/FBSTP removed from the deferred set;
  FSIN stands in for the still-deferred transcendentals/FP-environment ops). Docs updated
  (`m3-fpu-spec.md`, the boundary-test comment). `ventium-refs` untouched.

### M8.5 — Genuine radix-4 SRT divider + the FDIV bug from first principles (2026-06-06)

**What this is.** The *real* Pentium division datapath — base-4 SRT with the
quotient-selection PLA reverse-engineered from the die photo (Ken Shirriff,
righto.com Dec 2024) and formalised by Coe-Tang / Edelman (SIAM Rev. 1997) —
added as an **optional compile-time feature** behind `fpu_x87_pkg::fx_srt_div`.
Where the prior M6 FDIV erratum could only return a *hard-coded* documented
vector (no oracle for the general flaw), the SRT engine reproduces the famous
FDIV bug **algorithmically, no operand special-cased**, and the canonical
flaw *emerges* from the five missing PLA entries.

- **`fpu_x87_pkg.sv` (new `fx_srt_pla` + `fx_srt_div`; `fx_div` is now a
  compile-time dispatcher).** The partial remainder is kept in **ones-complement
  carry-save** (sum + carry words) exactly as the chip does, with the delayed
  `+1` correction injected into the carry LSB after a complemented (positive-
  digit) subtract; the quotient digit is chosen from a **4-integer-bit truncated
  index** (`xxxx.yyy`) into the reverse-engineered selection PLA. That truncation
  plus the ones-complement modular wraparound is precisely what lets a divide land
  on a *missing* cell. Five PLA cells that should hold `+2` read `0`
  (`8·P_Bad ∈ {23,27,31,35,39}` in columns `D ∈ {17,20,23,26,29}/16`); a remainder-
  sign-aware final rounding packs to the 64-bit floatx80 significand.

- **Optional, default OFF (matches the user's "compile-time parameter" choice).**
  `+define+VEN_SRT_DIV` routes FDIV/FDIVR through the genuine SRT engine (correct
  PLA → still bit-exact vs QEMU); adding `+define+VEN_SRT_FDIV_BUG` selects the
  buggy PLA → the flaw is reproduced for **all** operands. With no defines the
  divider is the fast `fx_div_exact` and **nothing changes**.

- **The bug, from first principles (validated bit-exact).** `4195835/3145727`
  → flawed floatx80 `0x3FFF_AAB7F6392A768638` (rounds to the documented double
  `0x3FF556FEC7254ED1` = `1.3337390689…`, wrong at the 13th significant bit),
  bug hit at iteration 8 (Edelman §7 "≥9 steps to failure"). The model also flaws
  the second published pair `5505001/294911` (D=17), while the negative controls
  `7654321/3145727` (triggering divisor, non-published pair) and `4195835/3.0`
  divide **clean** — a triggering divisor is necessary but not sufficient.

- **New gate `make verify-srt`** (`verif/srt/`, Verilator, independent of the
  core/SoC build): drives golden vectors from the single-source model
  `tools/srt/srt_model.py` (validated correctly-rounded over a 10 000-divide
  corpus) and asserts `fx_srt_div` is bit-exact for **both** PLAs — **609 vectors
  × 2 PLAs, SRT-GATE-OK**. The model bug found during bring-up was in the *Python*
  side (out-of-range index returning ±3 instead of clamping to ±2 during the
  post-bug excursion); the RTL ladder PLA was correct throughout.

- **No regression.** `make verify` **69/69 cache hits, 0 regenerated**;
  `make verify-soc` **5/5 PASS**. The M6 runtime erratum (`fx_div_errata`) is
  unchanged and stays the documented default-build anchor; its comment now points
  at `fx_srt_div` as the oracle it previously lacked. RTL touched:
  `rtl/fpu/fpu_x87_pkg.sv`. New: `tools/srt/srt_model.py`, `verif/srt/*`.
  `ventium-refs` untouched.
