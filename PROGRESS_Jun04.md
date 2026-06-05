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
| M2S.4 | TSS + cross-priv delivery + inter-priv IRET | `pcpl`(304); `ptask` self-diff | ✅ done-partial |
| M2S.5 | SMM / RSM (partial oracle) | `psmm` structural self-check | ✅ done-partial |
| M2S.6 | Debug registers DR0–DR7 + `#DB` (last system stage) | `pdebug` RTL sys-diff (239) | ✅ done-partial |
| M3 | x87 FPU | x87 corpus diff-clean | ✅ |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench bands match p5model | ✅ |
| M5 | Cache-cycle + FP-cycle accuracy | FP/cache bands track p5model | ✅ |
| M5B | Pin-level 64-bit bus protocol (standalone) | structural + SVA (no oracle) | ✅ standalone |
| M6 | Errata & stepping fidelity (stretch) | targeted errata behind a flag | ✅ partial |
| R1 | RTL modularization + fast gate (`make verify` ~2 s) | all m1–m5 + sys stay green | ✅ |

**Verification at this snapshot (independently re-run 2026-06-04):** `make verify`
(user) GREEN — 56/56 func diff-clean + all M4/M5 cycle bands; all 6 differential
system gates EQUIVALENT (pseg 70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 /
pcpl 304); `ptask` self-diff (292) + `psmm` structural OK; verilator lint clean.
Latest commit `2a00d06` (M2S.6) pushed to `origin/main`.

## Deferred, no-oracle tracks (carried, not auto-started)

- **R2 — leaf-module extraction** (this file's active work; the R1 deferral). Carve
  the leaf blocks (icache / dcache / tlb / regfile / fpu-state / btb) out of the
  `core.sv` spine into their own modules, **behavior-preserving** (gate-proven
  bit-exact after every step). R1 left these in because they are entangled with the
  shared pipeline FSM; R2 extracts what is mechanically separable and documents what
  must stay in the spine, and why.
- **M5B-int** — wire the standalone pin-level bus into `rtl/` (would change M5 cycle
  timing; no bus oracle to re-verify).
- **Full hardware task switch** (`ptask` differential) — the gnarliest M2S.4 piece.
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

**Status:** ✅ done — 4 of 6 leaves extracted (the 4 with a single write port);
regfile + fpu-state proven spine-bound and left inline (honest).

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
- **fpu-state** (`fpr/ftop/fstat/fptag` + the M5 scoreboard) — written from two
  runtime-exclusive FSM arms; `FNSTSW AX` writes `gpr[EAX]` from inside the x87 case
  (cross-leaf into the regfile); the scoreboard is braided into the integer cycle model.
  Needs an FSM rewrite. The pure x87 datapath already lives in `fpu_x87_pkg.sv`.

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

### M7 log

- 2026-06-04 — M7 opened; spec written; M7.0 oracle de-risk launched (Quake syscall
  capture / Win95 device+interrupt capture / throughput / V86 scope).
