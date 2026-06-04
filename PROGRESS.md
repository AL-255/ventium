# Ventium — progress log

Living status for the P5/P54C Verilog replica. Plan: [`PLAN.md`](PLAN.md).
Newest entries at the top. Dates are ISO (YYYY-MM-DD).

## Status at a glance

| Milestone | Description | Gate | Status |
|---|---|---|---|
| **M0** | Bootstrap: repo skeleton, QEMU golden-trace plugin, trace format, Verilator TB shell, comparator | comparator runs end-to-end on trivial trace | ✅ done (infrastructure proven; RTL still a NOP stub) |
| M1 | Decoder + single-issue integer functional | integer subset diff-clean vs QEMU (decoder-exhaustive vs XED/Capstone is ongoing toward M2) | ✅ done (integer SUBSET func-equiv vs QEMU on smoke + M1 corpus; not yet decoder-exhaustive) |
| M2 | User-mode integer ISA completeness (re-scoped; system mode → M2S) | broad integer-ISA corpus diff-clean vs QEMU (user-mode) | ✅ done (28-program corpus func-equiv vs QEMU user-mode; system ops / far CALL-RET / ENTER / mem-operand bit-string + SHLD deferred & HALT; decoder-exhaustive-vs-XED still ongoing) |
| M2S | System mode: segmentation/paging/TLB/interrupts/SMM (needs system-mode oracle) | system-arch corpus diff-clean | ☐ not started (deferred from M2) |
| M3 | x87 FPU | x87 corpus diff-clean vs QEMU (`make m3` exit 0) | ✅ done (x87 functional core: stack/status/control/tag + 80-bit datapath, data movement + normal-operand arithmetic bit-exact vs QEMU; 14-program x87 corpus + 28 integer = 42/42 PASS. Transcendentals, BCD, FSAVE/FRSTOR/FLDENV, unmasked #MF, and non-default **precision** control (PC≠64-bit) are DEFERRED and HALT loudly) |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench CPI/pairing/mispredict match p5model | ✅ done (real 5-stage U/V fast path + serialized slow path; M1/M2/M3 func gates stay green; all 5 integer cycle bands met EMERGENT from the RTL pipeline — depadd CPI 1.080/pair 0.6%, indepadd CPI 0.590/pair 49.5%, agi 49.9%, brloop mispred 0.2% (7/3004), brrandom mispred 61.0% (244/400). Cycle oracle is an ESTIMATE (PLAN §8); FP/cache cycle accuracy = M5) |
| M5 | Cache-cycle + x87/FP-cycle accuracy (re-scoped; pin-level bus → M5B) | faddchain gated CPI≈3 + I$/D$-miss kernels track p5model; tightened abs-cyc; func+M4 bands green | ✅ done (FP latency+throughput+occupancy + L1 I$/D$ (2-way/128/LRU) miss timing — all EMERGENT, matching the p5model oracle. m1/m2/m3 stay green (53/53 func-diff-clean); all 5 M4 integer bands met; all 4 new M5 bands met (faddchain CPI 3.01, fpindep 1.16 < chain, dmiss/imiss miss-elevated). Tightened abs-cyc at **M5_TOL_PCT=10%**, achieved: FP/cache kernels ≤0.14% (faddchain +0.5%, fpindep +2%, dmiss +0.10%, imiss +0.14%), integer worst-case +6.16% (indepadd). Cycle oracle is an ESTIMATE (PLAN §8); miss penalty is a p5model assumption. Pin-level bus = M5B (no oracle)) |
| M5B | Pin-level 64-bit bus protocol (needs real-chip bus traces) | structural + local SVA (no differential oracle) | ☐ not started (deferred from M5) |
| M6 | Errata & stepping fidelity (stretch) | targeted errata repro | ☐ not started (next; M2S + M5B remain no-oracle deferred milestones) |

Legend: ☐ not started · ▶ in progress · ✅ done · ⚠ blocked

## What exists today (inherited)

- **`ventium-refs/` submodule** — full reference library (Intel manuals, Alpert &
  Avnon, AP-500/AP-526, Agner Fog, datasheet, spec updates, die-photo articles)
  with a cheap page-referenced index in `ventium-refs/00-index/INDEX.md`.
- **`ventium-refs/07-p5-emulation-harness/`** — a working QEMU-based functional +
  cycle **golden reference** for P54C/non-MMX:
  - plugin-enabled `qemu-i386 -cpu pentium` build scripts (#UDs on non-P5 opcodes),
  - `plugin/p5model.c` — in-order U/V cycle-estimation model (validated 6/6 on
    its microbenchmarks: dependent/independent ALU CPI, fadd chain, AGI, branch
    predictable/random),
  - `tools/isa_verify.py` — static P5-ISA checker (capstone),
  - mined timing constants + provenance in `docs/p5_timing_*.json`,
  - benchmark corpus (Dhrystone/Whetstone/LINPACK/CoreMark/STREAM + kernels).

  This is the cycle oracle for layers 3–4 and the functional oracle for layers
  1–2. **No RTL exists yet.**

## Log

### 2026-06-03 — M5 complete (L1 cache-miss timing + x87/FP cycle accuracy; tightened abs-cyc)

Extended the M4 dual-issue cycle model with the two pieces M4 deferred **and that
the `p5model` oracle can differentially verify** (`docs/m5-cycle-spec.md`):
**(1) L1 cache-miss cycle timing** and **(2) x87/FP latency + throughput +
occupancy** — both **EMERGENT** from real RTL state machines using the SAME
geometry/penalty as the oracle (`build/p5trace.so`: imiss=8, dmiss=8, 8 KB /
2-way / 32 B / 128 sets, misalign +3), never a formula copied from p5model. The
pin-level 64-bit bus protocol has **no oracle** and stays deferred to **M5B**.
Gate: `make m5` (= `bash verif/run-m5.sh`), exit 0. **Hard safety held: m1/m2/m3
stay func-diff-clean vs QEMU (53/53), and all five M4 integer bands stay met.**

**FP latency / throughput / occupancy (emergent).** The M4 FP serialize-stall is
replaced by a real scoreboard with **two distinct mechanisms**, mirroring the
oracle's `p5_insn_exec` (`verif/qemu-plugins/p5trace.c`):
- **Result LATENCY** (`fp_ready_cyc`): a dependent FP consumer stalls until the
  producer's result is ready (issue+lat). A dependent `fadd %st(1),%st` chain runs
  at **CPI 3.01** (fadd lat 3) — the headline gated band.
- **Pipe OCCUPANCY** (`fp_occ`, new): an FP op HOLDS the in-order pipe for `occ`
  clocks, so even a *following independent integer op* is delayed until occupancy
  expires (oracle `pipe_free_at = issue + occ`): `fdiv` occ 39, `fmul` occ 2,
  fadd/fsub occ 1. The op retires at issue+occ and `fp_ready` is anchored to the
  issue cycle. Independent FP pipelines at throughput 1 (`mb_fpindep` CPI **1.16**,
  far below the chain — latency-vs-throughput contrast).

**L1 cache miss timing (emergent).** Both caches are **2-way / 128-set / 32 B /
LRU** — the I-cache was rebuilt from M4's direct-mapped 256-line form to match the
oracle's associativity (set=addr[11:5], tag=addr[31:12], `victim = lru^1`), so the
miss SEQUENCE — not just the aggregate — agrees. An I-miss fills 8 words = imiss=8
clocks; a D-read-miss defers +dmiss to the next insn (read-allocate); misalign +3;
the 8-bank D-conflict +1 is kept from M4. Strided/oversized kernels show the
miss-driven CPI elevation (`mb_dmiss` CPI **2.50**, `mb_imiss` **6.01**) and their
absolute `cyc` tracks the golden to **≤0.14%**.

**Tightened abs-cyc (`M5_TOL_PCT=10%`, achieved figures — honest).** With the same
caches+FP timing modeled, the totals converge far inside the band: FP/cache
kernels `mb_faddchain` **+0.5%**, `mb_fpindep` **+2.1%**, `mb_dmiss` **+0.10%**,
`mb_imiss` **+0.14%**; integer kernels `mb_depadd` **+2.85%**, `mb_agi` **+2.84%**,
`mb_brloop` **+0.23%**, `mb_brrandom` **−0.86%**, worst-case `mb_indepadd`
**+6.16%** (unchanged structural path). No kernel needed a looser tolerance.

**Adversarial review — found + fixed** (each reproduced vs the p5model golden
first; functional correctness was paramount; each fix locked with a regression
kernel where applicable):
- **[high] FP unit OCCUPANCY/THROUGHPUT not modeled.** M4 charged only the result-
  latency consumer stall; an FP op retired in 1 clock and a *following independent*
  instruction issued immediately, so a single `fdiv` + independent integer work ran
  **~2× too fast** vs the oracle (fdiv occ 39, fmul occ 2 dropped). **Fixed:** added
  `fp_occ` and a real pipe-occupancy hold (the op retires at issue+occ; `fp_ready`
  anchored to issue). Reproduced: oracle single-fdiv+6 movs ≈ 54 cyc, RTL was ≈ 27
  → now matches per-op. Regression: `mb_fpocc` (fdiv/fmul + 8 independent movs;
  abs-cyc **−1.5%** vs golden).
- **[med] Unconditional short JMP (EB) never filled the V slot.** The oracle makes
  JMP `pclass=PV`/`pairs_second` (V-only-pairable, like Jcc). M4 set
  `pairs_second=0`, so `<UV op>; jmp` groups (e.g. the assembler's `.p2align`
  `mov; jmp` filler) never paired, costing a clock per group. **Fixed:** EB
  `pairs_second=1`; and an unconditional-jmp mispredict now costs 3 (oracle
  `P5_MISPREDICT_UNCOND`), not the V-cond 4 (the old V-branch always charged 4).
  Regression: `mb_jmppair` (abs-cyc **+1.6%**).
- **[med] FLD-const lat/occ should be 2.** FLDZ/FLD1/FLD<const> are occ=2/lat=2 in
  the oracle (vs lat=1 for FLD ST(i)/FLD mem). M4 conflated them. **Fixed.**
- **[med] I-cache direct-mapped vs oracle 2-way.** Different associativity → a
  different hit/miss sequence for conflict-prone/partially-resident working sets.
  **Fixed:** I-cache rebuilt as 2-way/128/LRU (`ic_present`/`ic_hit_way`/`ic_byte`/
  `ic_touch` + 2-way fill victim). `mb_imiss` miss count now matches the oracle
  exactly (2010/2010) where before the geometries diverged.
- **[med] Stores + slow-path disp/SIB loads bypassed the D-cache model.** The
  oracle's `p5_mem` runs `l1_access` for STORES too (read-allocate: allocate/LRU,
  no miss penalty) and for all loads. M4 mutated the D-cache only from fast-path
  register-indirect loads, so a line a store warmed was wrongly counted a miss.
  **Fixed:** slow-path S_LOAD/S_STORE run `dc_access` (+dmiss/misalign deferral on
  loads; allocate-only on stores, cycle-mode-gated). Regression: `mb_dstore`
  (199/200 reg-indirect loads HIT because the preceding stores warmed the lines —
  the divergent-miss-sequence bug is gone; abs-cyc there is dominated by the
  slow-path disp-store cost, an M4 cycle-approximation, so the regression checks
  STATE consistency, not abs-cyc).
- **[med] I-miss off-by-one + over-eager straddle.** M4 burned a non-fetching
  S_PIPE→S_PF transition clock (effective ~9 not 8), and `pipe_bytes_ok` always
  required BOTH `ic_present(eip)` and `ic_present(eip+11)`, charging a second-line
  I-miss for short instructions near a line end that don't straddle. **Fixed:** the
  detection clock now issues the fill's word-0 read (so a miss = exactly 8 clocks);
  the straddle line is required only when `(eip&31)+len > 32` (matching the
  oracle's real straddle test). Effect: `mb_imiss` +16.8%→**+0.14%**, and every
  kernel's startup cold-miss offset shrank.
- **[low] FK_ARITH fast path had no precision-control guard.** The slow path HALTs
  (Tier-3 deferral) on an arithmetic op under PC≠extended; the cycle-mode fast path
  silently used full extended precision → potential functional divergence vs QEMU's
  programmed-precision rounding. **Fixed:** the fast-path FK_ARITH now HALTs under
  `fctrl[9:8]!=11`, matching the slow path (default cw 0x037f is PC=11, so gate
  kernels are unaffected).
- **[low] Terminating `int 0x80` dropped its retire record (cycle mode).** The
  oracle emits a record for the syscall; the RTL halted without one, so the cycle
  trace was one record short (a `compare.py` LENGTH MISMATCH). **Fixed (cycle-mode
  only):** a genuine HALT syscall (`int 0x80`) emits one retire then stops;
  `d_unknown` (out-of-scope opcode) stays a LOUD no-retire HALT. Func mode keeps the
  QEMU-gdbstub convention (no exit-syscall row), so the functional gates are
  unaffected; `mb_imiss` now emits 4019 records = the golden 4019.

**Functional correctness preserved by construction + verified.** Cache/FP timing
changes ONLY cycle accounting (stalls), never architectural results; the FP fast
path reuses the exact M3 `floatx80` helpers and is gated on `cycle_mode` (func runs
keep FP on the proven slow FSM). The 2-way I-cache delivers the same bytes (only
the LRU/timing changed). Verified: `make m1`/`m2`/`m3` all exit 0 (53/53
func-diff-clean vs QEMU), and the five M4 integer bands stay met from the now
cache-aware RTL. RTL stays **lint-clean** (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**How to run:** `make m5`. It (a) runs `make m1 && m2 && m3` (HARD functional
regression), then (b) builds the TB and for each kernel generates the p5trace.so
golden + RTL `--cycle` traces, runs `compare.py --mode cycle` at the tightened
`M5_TOL_PCT=10%`, and asserts the M4 integer bands + the new M5 FP/cache bands
(computed by `m5_metrics.py`, which delegates to `m4_metrics` for the integer
kernels). Exit 0 iff func-green AND every gated band met.

**Honest caveats (PLAN §8 / `docs/m5-cycle-spec.md`).** The cycle oracle
(`p5model`) is itself an **estimate** of documented P5 timing rules, not silicon;
the miss penalty (imiss/dmiss=8) is a p5model **assumption**, not a documented P5
constant — matching it is estimate-vs-estimate, and we claim structural fidelity
(same caches/FP timing/components), not bit-true silicon timing. The **pin-level
64-bit bus protocol is deferred to M5B** (no differential oracle; structural +
local-SVA only). The serialized slow path (mul/div/string, disp/SIB loads, stores,
rel32/indirect/call/ret branches) stays functionally exact but **cycle-approximate
by design** — `mb_dstore`'s abs-cyc reflects that, hence its STATE-only check.

**Next:** M6 — errata & stepping fidelity (targeted errata repro). **M2S** (system
mode) and **M5B** (pin-level bus) remain no-oracle deferred milestones.

### 2026-06-03 — M4 complete (dual-issue U/V pipeline + branch prediction; first CYCLE milestone)

Turned the single-issue multi-cycle functional core into a **real in-order
5-stage dual-issue (U/V) integer pipeline** whose **emergent** cycle behavior
matches the `p5model` cycle oracle on the canonical integer microbenchmarks,
**while the M1/M2/M3 functional gates stay green** (the hard safety rule).
Gate: `make m4` (= `bash verif/run-m4.sh`), exit 0.

**The pipeline (emergent-not-faked, `docs/m4-pipeline-spec.md`).** The control is
reorganized into PF/D1/D2/EX/WB stages with **two pipes (U & V)**; the cycle
counts *fall out* of the structure, they are not computed from the p5model
formula. The proven M1–M3 execute/flag/FPU datapath is **reused unchanged**, so
functional behavior is preserved bit-for-bit.
- **Fast path (`S_PIPE`, `rtl/core/intcore.sv`):** simple/pairable insns
  (ALU reg/imm, MOV, LEA, INC/DEC, TEST, NOP, shift-by-imm, reg-base load, Jcc/JMP
  rel8) flow through the pipe at up to **2 insns/clock**. A combinational
  **pairing checker** (`fp_can_pair`, mirrors the p5model *rules*, never its
  formula) admits a V member only when: both simple, U is a U-member & V a
  V-candidate, no disp+imm, no GP RAW/WAW (ESP/flags excepted). Pairing classes
  follow AP-500 / `docs/ap500-pairing-table.md`: **UV** (ALU/MOV/LEA/INC/DEC/TEST),
  **PU = U-only-pairable** (ADC/SBB, shift-by-imm — lead a pair, never fill V),
  **V-only** (simple near branch). **Bypass:** the dependent `add`-chain runs at
  1/clk while independent adds pair (depadd vs indepadd). **AGI:** a 1-cycle
  interlock fires when an address base/index reg was written in the immediately
  preceding clock. **Branch prediction:** a 64-set×4-way **BTB with 2-bit
  saturating counters**, looked up in D1; miss ⇒ predict not-taken; first-taken
  **allocates strongly-taken (ctr=3)**; mispredict penalty 3 (U) / 4 (V) bubbles.
- **Serialized (slow) path:** complex/microcoded insns (mul/div/string/shift-CL/
  rotates/x87/etc.) issue **alone** on the existing multi-cycle FSM and hold the
  pipe until done — functionally exact, cycle-approximate (fine for M4, whose
  bands use only simple-ALU/branch streams; FP/cache cycle = M5).

**RTL cycle-trace producer (Producer C, cycle mode).** The core conveys
**pipe** (U/V) and **paired** to the TB via the retire path; `tb_ventium --cycle`
emits a `mode:"cycle"` vtrace `{n, pc, cyc=clock-at-retire, pipe, paired}`
(`docs/trace-format.md` §2.3) — a paired issue gives both members the same `cyc`
and `paired:true`. Default mode still emits the func trace (func gates unchanged).
`verif/m4_metrics.py` derives CPI / pairing% / AGI-stall% / mispredict% **from the
RTL trace** (only per-insn *identity* — is-this-a-branch — is borrowed from the
golden's `bytes`; every cycle *cost* is the RTL's), and checks the
`55-validate-model.sh` bands.

**Measured per-kernel metrics vs the p5model bands** (`make m4`, all GATED bands
met — EMERGENT from the RTL pipeline):

| kernel | band | RTL measured | verdict |
|---|---|---|---|
| `mb_depadd`   | CPI 0.97–1.10 & pairing <2% | CPI **1.080**, pairing **0.6%** | PASS |
| `mb_indepadd` | CPI 0.48–0.62 & pairing >40% | CPI **0.590**, pairing **49.5%** | PASS |
| `mb_agi`      | AGI stalls >20% of insns | AGI **49.9%** (1208/2419) | PASS |
| `mb_brloop`   | mispredict <2% | **0.2%** (7/3004 branches) | PASS |
| `mb_brrandom` | mispredict >20% | **61.0%** (244/400 branches) | PASS |

INFO-only (not gated): `mb_agiloop` (looped-AGI regression, see below) RTL CPI
**1.010** vs golden **1.013**, AGI fires **99.8%** of loop iterations;
`mb_faddchain` is FP, deferred to M5.

**Emergent-real vs approximate (honest).** *Real* and matched to the oracle: U/V
pairing decisions & pairing%, the 2-insn/clk vs 1/clk vs serialized cadence,
EX/WB bypass, the AGI interlock, and BTB 2-bit prediction (per-PC mispredict
counts match the oracle exactly on `mb_brloop`: inner 5/3000, outer 2/4).
*Approximate*: absolute cumulative `cyc` carries a fixed offset because p5model
charges an **icache cold-miss (imiss=8) per first-touched line** that the M4 RTL
(cache cycle = M5) does not model — so `compare.py --mode cycle` runs at a
generous structural tolerance (T=50%, pc-alignment / retire-order / no per-insn
blow-ups) and the **tight 55-validate bands are the real verdict**. The
serialized slow path (mul/div/string/x87, and rel32/indirect/call/ret branches)
is functionally exact but cycle-approximate by design.

**Adversarial review — found + fixed** (each reproduced vs the cycle golden /
QEMU first; functional-correctness fixes locked with a regression program):
- **[high] ADC/SBB pairable into V → pairing mislabel + ARCH CORRUPTION.** The
  fast-path decoder set `pairs_second=1` for all ALU ops incl. ADC(op2)/SBB(op3),
  so they could issue into V. p5model makes them **PU = U-only-pairable**
  (`pclass=PU`); pairing into V both inflated pairing% and shifted per-insn cyc.
  Worse, the V ALU path has **no carry-in forwarding**, so a paired `add(U)/adc(V)`
  computed the adc with the **stale architectural CF** instead of the carry U just
  produced — live arch corruption (invisible to func gates since func mode never
  pairs, and to the cycle compare which checks only pc). **Fixed:** ADC/SBB are
  now `pairs_second=0` (U-only-pairable) at all three decode sites (`00??_?001`,
  `00??_?011`, `0x83 /2,/3`), exactly the P5 rule — which also removes the
  corruption (an adc/sbb can never sit in V; the only V-pairable ALU ops do not
  consume CF). Verified: the cycle pairing structure now matches the golden
  with **0 pipe/paired mismatches** on a add/adc test, and the arch state is
  **func-equivalent vs QEMU**. Regression: `verif/tests/t_adcpair` (64-bit
  add/adc + sub/sbb carry-chains, reg & imm forms; func-diff-clean vs QEMU).
- **[med] BTB first-taken allocated weakly-taken (2) not strongly-taken (3).**
  Diverged from the oracle (`p5model.c:371 ctr=3`): after a loop-exit not-taken
  the RTL counter went 2→1 (predict not-taken) and re-mispredicted the next loop
  entry. **Fixed** to allocate ctr=3; per-PC mispredict counts on `mb_brloop` now
  match the oracle exactly (inner 5/3000, outer 2/4).
- **[med] Phantom AGI after a slow-path divert.** `agi_wr*` (regs written last
  fast clock) were not cleared when a non-simple insn diverted to the slow FSM, so
  on return the first insn could take a phantom 1-cycle AGI stall. **Fixed:** clear
  `agi_wr0/agi_wr1` on the divert. Verified vs the golden (`mov(base)` after a
  `mul` now costs 1, not 2).
- **[med] Looped-AGI undercount.** A per-PC suppressor (`agi_stalled_eip`, set once
  and never reset) charged a static AGI site inside a loop only on the FIRST
  iteration. **Fixed:** removed the suppressor — the stall now fires every time the
  hazard exists (the immediate double-charge is prevented *structurally* because
  the stall clock clears `agi_wr*`), matching p5model's per-issue
  `reg_wcycle==issue-1` check. Regression: `verif/tests/mb_agiloop` (INFO kernel;
  AGI fires 99.8% of iterations, RTL CPI 1.010 ≈ golden 1.013).
- **[low] rel32 / indirect / CALL / RET branches: no BTB modeling.** The fast path
  decodes only rel8 Jcc/JMP; wider/indirect/call/ret run the slow FSM with no
  prediction. **Dispositioned (documented tradeoff, not a corruption):** the
  serialized path is cycle-approximate by design and the integer gate uses only
  rel8 Jcc; functionally these branches are exact. Flagged for M5+ when real-code
  cycle fidelity (rel32-dominated) matters.
- **[low] `retire2_state` hardwired to the primary U `snap`.** Harmless today
  (the cycle compare checks only pc for the V member) but a latent trap if
  dual-issue were ever state-checked. **Fixed (guard):** added a sim-only
  assertion (`synopsys translate_off`) that trips if a paired V retire is ever
  emitted in func mode (`cycle_mode=0`), locking the cycle-only invariant; pairing
  is already structurally gated on `cycle_mode`.

**RTL stays lint-clean** (`verilator --lint-only -Wall -Wno-DECLFILENAME
-Wno-UNUSED`, exit 0, no warnings).

**How to run:** `make m4`. It (a) runs `make m1 && make m2 && make m3` (HARD
functional regression — a pipeline that breaks func-equivalence FAILS M4
regardless of cycle bands) then (b) for each integer microbench builds the ELF,
ISA-verifies it, generates the `p5trace.so` golden cycle vtrace and the RTL
`--cycle` vtrace, runs `compare.py --mode cycle` (structural) and asserts the
55-validate bands computed from the RTL trace. Exit 0 iff func-green AND every
gated integer band met.

**Honest caveat (PLAN §8).** The cycle oracle (`p5model`) is itself an **estimate**
of documented P5 timing rules, not silicon. M4 "cycle accuracy" = the RTL pipeline
matches those rules as captured by p5model, within tolerance — not bit-true to a
real chip. **x87/FP cycle accuracy and cache/bus timing are M5**, not M4: the FPU
stays functionally correct (M3 green) but serializes the pipe; its cycle count is
not yet matched. No assertion that the serialized slow-path cycle counts match the
oracle (they are approximate by design).

**Next:** M5 — cache/bus timing + x87/FP cycle accuracy (the `faddchain` CPI~3
kernel and the icache cold-miss offset folded into the cycle model).

### 2026-06-03 — M3 complete (x87 FPU functional core, bit-exact vs QEMU)

Added the **x87 floating-point unit** to the single-issue core and verified the
x87 architectural state **diff-clean vs QEMU** (`compare.py --mode func` exit 0).
**M3 = the x87 functional core: data movement + normal-operand arithmetic,
bit-exact vs QEMU's softfloat `floatx80`. Transcendentals and exotic corners are
deferred (and HALT loudly).** Gate: `make m3` (exit 0). `make m2` / `make m1` /
`make m0-smoke` all still pass; RTL stays lint-clean (`verilator --lint-only
-Wall -Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**The x87 FPU** (`rtl/core/intcore.sv` FSM + `rtl/fpu/fpu_x87_pkg.sv` datapath):
- **Register stack model**: 8×80-bit physical regfile with a 3-bit `TOP`; `st(i)`
  = `fpr[(TOP+i)&7]`; push = `TOP--`, pop = `TOP++`; an 8-bit per-register valid
  tag (`fptag`, 1=empty) drives FXAM's empty class and FFREE.
- **Status word** (`fstat`): condition codes C0/C2/C3 (compares/classify), the C1
  bit, and the masked exception flags IE/ZE/PE accumulated sticky; the retire
  snapshot overlays `TOP` into bits[13:11] exactly as QEMU's gdbstub reports it.
- **Control word** (`fctrl`): FLDCW/FNSTCW; reset/FNINIT = `0x037f` (RC=00
  nearest, PC=11 64-bit, all six masks set). RC (rounding control) is fully
  honored by the datapath (see below).
- **Tag word**: QEMU's user-mode gdbstub abridges `ftag` to `0x0000`, so the RTL
  reports `0x0000` (confirmed across empty/full-stack/FFREE/after-pop probes) —
  we reproduce **what QEMU reports**, not the architectural 2-bit-per-reg tag.
- **80-bit datapath** (`fpu_x87_pkg.sv`): a self-contained `floatx80` engine —
  add/sub (aligned 128-bit significand, RNE/directed round-pack), multiply
  (64×64→128), divide (long division with an exact-remainder sticky), sqrt
  (256-bit restoring integer sqrt + sticky), and float32/64↔floatx80,
  int16/32/64↔floatx80 conversions. The canonical layout (sign|exp in [79:64],
  mantissa in [63:0]) is the SAME encoding `gen_trace --x87` emits, so the st-reg
  hex strings compare directly.

**Trace infrastructure** (the second DPI hook, per `rtl-interface.md` §2 /
`trace-format.md` §2.2): the core calls `vtm_retire_x87` on the same retirement
as `vtm_retire`, carrying the post-commit x87 state (st0..st7 as packed 80-bit,
`fctrl`/`fstat`/`ftag`); the TB buffers both and emits ONE func record with the
x87 fields, and the RTL trace header declares `x87:true`. `fop`/`fiseg`/`fioff`/
`foseg`/`fooff` are reported 0 (matches QEMU user-mode, which does no FP ptr
tracking). The golden side uses the already-committed `gen_trace.py --x87`
i387/tail-anchor fix (commit c39905b). `compare.py` compares the full x87 set iff
BOTH headers say `x87:true`; the 28 integer programs keep `x87:false` and are
unaffected.

**Tier-1 / Tier-2 coverage — bit-exact vs QEMU** (the 14-program x87 corpus):
- **Tier 1** (data movement, stack, status/control, compares, classify): FLD/FST/
  FSTP (m32/m64/m80 + `st(i)`), FILD/FIST/FISTP (m16/m32/m64), FXCH, FFREE,
  FINCSTP/FDECSTP, FNOP; the seven constants FLDZ/FLD1/FLDPI/FLDL2E/FLDL2T/FLDLG2/
  FLDLN2; FABS/FCHS; FCOM/FCOMP/FCOMPP, FUCOM/FUCOMP/FUCOMPP, FTST, FXAM, FICOM/
  FICOMP; FNSTSW ax/m16, FNSTCW/FLDCW, FNINIT, FNCLEX, FWAIT.
- **Tier 2** (normal operands, default control word): FADD/FSUB/FSUBR/FMUL/FDIV/
  FDIVR (+ `p`/`ip` and memory/int FIADD… forms), FSQRT — round-to-nearest-even,
  64-bit precision, bit-exact.
- **Tier 3 pulled INTO the gate this phase**: non-default **rounding** control
  (RC = toward-zero / toward +inf / toward -inf) at 64-bit precision; masked
  special-operand arithmetic (x/0, 0/0, sqrt of a negative / of -0).

**Adversarial review — found + fixed** (each reproduced against QEMU with a tiny
program first, fixed, then locked with a new gated regression program; the FSQRT
clear-codes/C2 behavior was discovered while reproducing finding 1):
- **[high] FXAM on an Infinity** — `fxam_codes` returned the WRONG class encoding
  for Inf (C3+C0 = 0x4100; the in-code comment was self-contradictory). QEMU's
  `helper_fxam_ST0` sets **0x500 (C2+C0)** for Inf. Fixed the Inf branch.
  (Reproduced: `fxam` on +Inf → QEMU fstat=0x3d00; pre-fix RTL=0x7900.) Locked by
  `tx_fxam` (every FXAM class incl. ±Inf/QNaN/±0/normal/empty).
- **[med] FST/FIST store flags** — the store path never set PE (precision/inexact)
  on a rounding FST m32/m64 or non-integer FIST, and never set IE + integer-
  indefinite on an out-of-range FIST. QEMU's helper_fst*/fist* latch these via
  `merge_exception_flags`. Added `_ex` conversion variants returning inexact (and
  invalid+indefinite for FIST overflow), latched into `fstat` at store dispatch.
  (Reproduced: `fstps` of 1.2345678901234567 → QEMU fstat PE=0x0020; FIST of 2.5
  → PE; FIST m16 of 100000 → IE + 0x8000.) Locked by `tx_storeflags`.
- **[med] arithmetic under non-default RC/PC** — the datapath was hard-wired to
  RNE/64-bit and silently ignored `fctrl`. **Fixed RC fully** (round-pack now
  takes the RC field; toward-zero/+inf/-inf verified bit-exact for all of add/sub/
  mul/div/sqrt incl. the signed-zero cancellation cases). **PC (precision)** other
  than 64-bit is now a DEFERRED Tier-3 corner that **HALTs loudly** at the
  arithmetic op (rather than silently mis-rounding). (Reproduced: 10/3 under RC=11
  matches QEMU; PC=53-bit arithmetic correctly produces a length-mismatch FAIL,
  not a false pass.) Locked by `tx_round`.
- **[low] FDIV by zero / 0÷0 / FSQRT of a negative** — `fx_div` divided by mb=0
  (X in sim) and `fx_sqrt` of a negative returned sqrt(|x|) with a forced-positive
  sign. With masked exceptions QEMU produces: x/0 → signed Inf + ZE; 0/0 →
  real-indefinite QNaN (0xffff_c000000000000000) + IE; sqrt(−x) → real-indefinite
  QNaN + IE + C2; sqrt(−0) → −0 + C2. Implemented all four bit-exact (guarded the
  datapath against /0 and negative-sqrt as defense-in-depth). Locked by
  `tx_special`. (`helper_fsqrt` also clears 0x4700 and sets C2 whenever ST0's sign
  bit is set — reproduced and matched.)
- **[low] FCOM vs FUCOM #IA on NaN** — one shared `fcom_codes` produced correct
  C-codes but never raised IE. QEMU's signaling compares (FCOM/FCOMP/FCOMPP/FTST/
  FICOM, `floatx80_compare`) raise IE on ANY NaN; the quiet compares (FUCOM/
  FUCOMP/FUCOMPP, `floatx80_compare_quiet`) raise IE only on a SIGNALING NaN.
  Added SNaN/QNaN classifiers and a per-op signaling flag; IE latched accordingly.
  (Reproduced: FCOM vs QNaN → IE; FUCOM vs QNaN → no IE; FCOM/FUCOM vs SNaN(m80)
  → IE both.) Locked by `tx_fcomnan`.

**DEFERRED — loud HALT, never a false pass** (confirmed each retires the
preceding ops then STOPS, yielding a length-mismatch FAIL — verified for FSIN,
FRNDINT, FXTRACT, FPREM):
- **Transcendentals** FSIN/FCOS/FSINCOS/FPTAN/FPATAN/F2XM1/FYL2X/FYL2XP1 — QEMU
  computes these with its own approximation; matching it bit-exact ≠ matching a
  real Pentium, so deferred to a later ulp-tolerance oracle. HALT.
- **BCD** FBLD/FBSTP; **environment/state** FSAVE/FRSTOR/FLDENV/FNSTENV (28/108-
  byte memory images). HALT.
- **FCMOVcc / FCOMI / FUCOMI** register forms (P6+ extensions, not core P5
  user x87 in the corpus). HALT.
- **Tier-3 numeric ops** FPREM/FPREM1/FRNDINT/FSCALE/FXTRACT. HALT.
- **Non-default PRECISION control (PC ≠ 11 / 64-bit)** at an arithmetic op — the
  datapath implements full extended precision only; rather than silently
  mis-rounding to 53/24-bit, the core HALTs. (RC directed rounding IS supported.)
- **Unmasked numeric exceptions / #MF delivery** — not implemented; the corpus
  keeps exceptions masked (default cw) and avoids faulting operands. FWAIT is a
  no-op (no SE is ever set in the masked corpus).

**Harness:** `run-m3.sh` is the differential gate (per-program `x87:true` via an
optional `"x87"` manifest field; everything else identical to `run-m2.sh`).
`run-m1.sh` was also taught to build any discovered program's ELF/flat
generically from the manifest `src` (mirroring run-m2/run-m3) when the tests
Makefile didn't pre-build it — this enrolls the x87 corpus in the M1 integer gate
too (the x87 programs run as integer streams there and pass), so `make m1` is
green again (it was failing on the auto-discovered x87 dirs before, an
infrastructure gap independent of the RTL).

**How to run:** `make m3` (= `bash verif/run-m3.sh`). For each program discovered
from `verif/tests/**/manifest.json` it builds the ELF, ISA-verifies it, flattens
it, generates the QEMU golden (with `--x87` for x87 programs), runs the RTL TB
(`--x87`, init-ESP from the golden n=0), runs `compare.py --mode func`, and
asserts exit 0 for all.

**Observed result** (`make m3` from a clean TB build, exit 0):

```
    PROGRAM          MODE  RESULT DETAIL
    -------          ----  ------ ------
    smoke            int   PASS   func-equivalent (22 insns max)
    t_bit            int   PASS   func-equivalent (55 insns max)
    t_branch         int   PASS   func-equivalent (43 insns max)
    t_callret        int   PASS   func-equivalent (35 insns max)
    t_carry          int   PASS   func-equivalent (40 insns max)
    t_div            int   PASS   func-equivalent (60 insns max)
    t_ext            int   PASS   func-equivalent (50 insns max)
    t_leave16        int   PASS   func-equivalent (25 insns max)
    t_loop16         int   PASS   func-equivalent (60 insns max)
    t_loop2          int   PASS   func-equivalent (65 insns max)
    t_loop           int   PASS   func-equivalent (78 insns max)
    t_mem            int   PASS   func-equivalent (25 insns max)
    t_mixed          int   PASS   func-equivalent (200 insns max)
    t_moffs          int   PASS   func-equivalent (30 insns max)
    t_mul            int   PASS   func-equivalent (60 insns max)
    t_op16b          int   PASS   func-equivalent (60 insns max)
    t_op16           int   PASS   func-equivalent (60 insns max)
    t_op8            int   PASS   func-equivalent (64 insns max)
    t_partial        int   PASS   func-equivalent (44 insns max)
    t_prefix         int   PASS   func-equivalent (44 insns max)
    t_rep            int   PASS   func-equivalent (85 insns max)
    t_rotate         int   PASS   func-equivalent (68 insns max)
    t_setcc          int   PASS   func-equivalent (65 insns max)
    t_shift          int   PASS   func-equivalent (67 insns max)
    t_shld           int   PASS   func-equivalent (44 insns max)
    t_stack          int   PASS   func-equivalent (45 insns max)
    t_string         int   PASS   func-equivalent (50 insns max)
    t_unary          int   PASS   func-equivalent (80 insns max)
    tx_addsub        x87   PASS   func-equivalent (80 insns max)
    tx_chain         x87   PASS   func-equivalent (70 insns max)
    tx_cmp           x87   PASS   func-equivalent (45 insns max)
    tx_const         x87   PASS   func-equivalent (35 insns max)
    tx_ctl           x87   PASS   func-equivalent (30 insns max)
    tx_fcomnan       x87   PASS   func-equivalent (50 insns max)
    tx_fxam          x87   PASS   func-equivalent (40 insns max)
    tx_ldst          x87   PASS   func-equivalent (25 insns max)
    tx_muldiv        x87   PASS   func-equivalent (90 insns max)
    tx_round         x87   PASS   func-equivalent (45 insns max)
    tx_special       x87   PASS   func-equivalent (45 insns max)
    tx_sqrt          x87   PASS   func-equivalent (70 insns max)
    tx_stack         x87   PASS   func-equivalent (33 insns max)
    tx_storeflags    x87   PASS   func-equivalent (40 insns max)

    totals: 42 PASS / 0 FAIL / 42 total
M3 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

**Honest coverage statement:** M3 is the x87 **functional core** — the register
stack, status/control/tag words, and a `floatx80` datapath that is **bit-exact vs
QEMU** for data movement and **normal-operand** arithmetic under the default
control word, plus directed rounding (RC) and the masked special-operand cases
above. **Transcendentals, BCD, FSAVE/FRSTOR/FLDENV/FNSTENV, unmasked exceptions
(#MF), the P6 FCMOV/FCOMI forms, the Tier-3 numeric ops (FPREM/FRNDINT/FSCALE/
FXTRACT), and non-default precision control all HALT loudly** — never silently
mis-executed. No pipeline / U-V pairing / branch prediction / cycle accuracy yet
(M4/M5); M3 is functional-only.

**Next:** M4 — dual-issue U/V pipeline + instruction pairing + branch prediction
(the first CYCLE milestone: µbench CPI/pairing/mispredict matched against
`p5model`).

### 2026-06-02 — M2 complete (user-mode integer ISA completeness, func-equiv vs QEMU)

Extended the M1 single-issue core to the **complete user-visible integer ISA**
(`docs/m2-isa-spec.md`). **Every program in the corpus (M0/M1 baseline + the M2
corpus = 28 programs) is func-diff-clean vs QEMU user-mode** (`compare.py --mode
func` exit 0, no length mismatch). Gate: `make m2` (exit 0). `make m1` and
`make m0-smoke` still pass; RTL stays lint-clean (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**Instruction groups now implemented** (on top of the M1 ALU/MOV/LEA/PUSH/POP/
INC/DEC/TEST/Jcc/JMP subset): shifts & rotates `D0/D1/D2/D3`, `C0/C1` (ROL/ROR/
RCL/RCR/SHL/SHR/SAL/SAR, count `& 0x1f`, count==0 ⇒ no flag change) and
`SHLD/SHRD` (`0F A4/A5/AC/AD`, register destination); MUL/IMUL/DIV/IDIV
(`F6/F7 /4../7`, EDX:EAX), two-/three-operand IMUL (`0F AF`, `69`, `6B`);
MOVZX/MOVSX (`0F B6/B7/BE/BF`), NEG/NOT (`F6/F7 /2,/3`), INC/DEC r/m
(`FE/FF /0,/1`), CDQ/CWDE/CBW (`99/98`, `66 98`), XCHG (`86/87`, `90+r` incl.
`90`=NOP), SETcc (`0F 90+cc`), BSWAP (`0F C8+r`); bit tests BT/BTS/BTR/BTC
(`0F A3/AB/B3/BB` reg, `0F BA /4../7` imm) and BSF/BSR (`0F BC/BD`); stack/flags
PUSH/POP imm & r/m, PUSHA/POPA (`60/61`), PUSHF/POPF (`9C/9D`, user-mode POPF
mask), LAHF/SAHF (`9F/9E`), LEAVE (`C9`); string ops MOVS/STOS/LODS/SCAS/CMPS
(`A4..A7`, `AA..AF`) with REP/REPE/REPNE (`F3/F2`) and direction from DF
(`STD/CLD` = `FD/FC`); control/loop LOOP/LOOPE/LOOPNE (`E2/E1/E0`), JCXZ/JECXZ
(`E3`), near CALL `rel32` (`E8`) + RET (`C3`, `C2 iw`), near CALL/JMP r/m
(`FF /2,/4`); and the carry-flag trio STC/CLC/CMC (`F9/F8/F5`, added this phase).

**Prefix machine + partial-register handling.** A combinational prefix scanner
consumes a run of up to four legacy prefixes (`66` operand-size, `67`
address-size, `2E/36/3E/26/64/65` segment, `F0` LOCK, `F2/F3` REP) and feeds the
correct opcode + length downstream; segment/LOCK are functional no-ops in the
flat user model. **Partial-register semantics** route through a single
`reg_read`/`reg_merge` pair: an 8-bit write updates `[7:0]` (or `[15:8]` for
AH..BH) preserving the rest; a `66`-prefixed 16-bit write updates `[15:0]` and
**preserves `[31:16]`**; flags are computed at the operand width (SF=bit7/15/31,
PF on the low byte, CF/OF at the width boundary). The decoder maps AH..BH
(encoded index 4..7) to the physical GPR so every datapath site uses
`gpr[d_*_reg]` directly.

**EFLAGS undefined-bit masking.** `verif/diff/tracefmt.py::EFLAGS_UNDEFINED`
already carried the M2 cases (MUL/IMUL SF/ZF/AF/PF; DIV/IDIV all six;
SHL/SHR/SAR/SHLD/SHRD OF+AF; ROL/ROR/RCL/RCR OF; BT* OF/SF/AF/PF; BSF/BSR
CF/OF/SF/AF/PF; AAA/AAS/AAM/AAD/DAA/DAS). **No new entries were required this
phase:** the instructions fixed/added below either touch no flags (MOVZX/MOVSX,
MOV-moffs8, LEAVE, LOOP/JCXZ) or set only deterministic, *defined* flags
(STC/CLC/CMC set CF exactly; their masking-table absence is correct so CF is
compared in full), or their undefined bits are already covered by the existing
`bt`/`bsf`/`bsr` keys (the new 16-bit BT*/BSF/BSR forms reuse them). The table is
deliberately minimal so the gate cannot hide a real RTL bug.

**New test corpus** (added this phase; discovered by the gate via
`manifest.json`). The bulk of the M2 groups above were already covered by the
inherited corpus (`t_bit`, `t_callret`, `t_div`, `t_ext`, `t_loop2`, `t_mixed`,
`t_mul`, `t_op16`, `t_op8`, `t_partial`, `t_prefix`, `t_rep`, `t_rotate`,
`t_setcc`, `t_shift`, `t_shld`, `t_stack`, `t_string`, `t_unary`). The five new
programs regression-lock the adversarial-review findings the corpus did **not**
hit:
- `t_op16b` — `66`-prefixed MOVZX/MOVSX/BSF/BSR/BT*/BTS/BTR/BTC: proves the
  destination's `[31:16]` is preserved and the bit index is mod 16 (not mod 32).
- `t_carry` — STC/CLC/CMC, with the resulting CF consumed by ADC/RCL.
- `t_moffs` — MOV AL,moffs8 (`A0`) and MOV moffs8,AL (`A2`), hand-encoded.
- `t_leave16` — `66 C9` 16-bit LEAVE (preserve EBP[31:16], ESP += 2).
- `t_loop16` — `67`-prefixed LOOP/LOOPE/JCXZ using CX (preserve ECX[31:16]).

**Adversarial review — what was found and fixed** (every finding reproduced
against QEMU with a tiny program before fixing, and each fix re-verified
diff-clean; for the high findings a negative test — reverting the fix —
confirmed the new regression program FAILS, proving the lock):
- **MOVZX/MOVSX 16-bit (`66 0F B6/B7/BE/BF`)** [high, real]: `K_EXT` committed
  the full 32-bit result, ignoring `q_w`; the `66` form must preserve `[31:16]`.
  Fixed to `reg_merge(...,q_w,...)`. (Reproduced: `66 0F B6 C3` gave RTL
  `eax=0x000000a5` vs QEMU `0xdead00a5`.)
- **BSF/BSR 16-bit (`66 0F BC/BD`)** [high, real]: scanned all 32 bits, computed
  ZF from 32 bits, wrote a full-32 index. Fixed to scan/ZF/merge at `q_w`.
- **BT/BTS/BTR/BTC 16-bit reg/imm (`66 0F A3/AB/B3/BB`, `66 0F BA /4..7`)**
  [high, real]: bit index was always masked mod 32 and modify forms wrote full
  32. Fixed: index mod 16 for `q_w==2`, modify via `reg_merge`.
- **STC/CLC/CMC (`F9/F8/F5`)** [high, real]: not decoded → `d_unknown` → HALT.
  Added decode + a CF-only update arm (no other flags change).
- **MOV AL,moffs8 / MOV moffs8,AL (`A0/A2`)** [med, real]: only the 16/32-bit
  `A1/A3` were decoded; the 8-bit absolute forms HALTed. Added both (8-bit,
  preserve `[31:8]` on load).
- **16-bit near CALL/RET/LEAVE (`66 E8/C3/C2/C9`)** [low, real]: hardcoded 32-bit
  width. Now width-aware: 16-bit CALL pushes a 2-byte next-IP, RET pops 2 bytes,
  LEAVE pops 16-bit BP — all adjust ESP by 2 and (CALL/RET) truncate EIP to 16
  bits, exactly matching QEMU. LEAVE-16 is regression-tested (`t_leave16`);
  CALL-16/RET-16 are implemented but not testable in a continuing flat program
  (the 16-bit-truncated target lands at an unmapped low address and faults in
  **both** models — confirmed against QEMU), so they are documented, not gated.
- **`67`-prefixed JECXZ/LOOP/LOOPE/LOOPNE** [low, real]: always used the full
  32-bit ECX. Now the count register is CX (low 16, preserve `[31:16]`) under
  `0x67`. Regression-tested (`t_loop16`).

**Still HALTs (deliberately deferred; loud HALT, never mis-execute)** — confirmed
the core stops cleanly (retires nothing past the unsupported opcode) rather than
corrupting state:
- **Memory-operand BT/BTS/BTR/BTC and SHLD/SHRD** (the bit-string memory addressing
  and the memory-RMW shift-double): marked `d_unknown` → HALT. Genuine ISA forms
  but uncommon (compilers rarely emit them); deferred to a later milestone.
- **ENTER (`C8`)** — spec explicitly defers it ("LEAVE at least"); HALTs.
- **System / privileged ops, far CALL/RET, segment-load, paging/TLB** — out of
  M2 scope by design (need a system-mode oracle); these are **M2S**.

**How to run:** `make m2` (= `bash verif/run-m2.sh`). It builds the RTL TB, then
for each program discovered from `verif/tests/**/manifest.json` it builds the ELF
(`gcc -m32 -nostdlib -static`), ISA-verifies it (`tools/isa_verify.py`, pure P5),
flattens it, generates the QEMU golden (gdbstub), runs the RTL TB with init-ESP
from the golden n=0, runs `compare.py --mode func`, and asserts exit 0 for all;
prints a per-program table and exits 0 only if all pass.

**Observed result** (`make m2` from a clean TB build, exit 0):

```
    PROGRAM          RESULT DETAIL
    -------          ------ ------
    smoke            PASS   func-equivalent (22 insns max)
    t_bit            PASS   func-equivalent (55 insns max)
    t_branch         PASS   func-equivalent (43 insns max)
    t_callret        PASS   func-equivalent (35 insns max)
    t_carry          PASS   func-equivalent (40 insns max)
    t_div            PASS   func-equivalent (60 insns max)
    t_ext            PASS   func-equivalent (50 insns max)
    t_leave16        PASS   func-equivalent (25 insns max)
    t_loop16         PASS   func-equivalent (60 insns max)
    t_loop2          PASS   func-equivalent (65 insns max)
    t_loop           PASS   func-equivalent (78 insns max)
    t_mem            PASS   func-equivalent (25 insns max)
    t_mixed          PASS   func-equivalent (200 insns max)
    t_moffs          PASS   func-equivalent (30 insns max)
    t_mul            PASS   func-equivalent (60 insns max)
    t_op16b          PASS   func-equivalent (60 insns max)
    t_op16           PASS   func-equivalent (60 insns max)
    t_op8            PASS   func-equivalent (64 insns max)
    t_partial        PASS   func-equivalent (44 insns max)
    t_prefix         PASS   func-equivalent (44 insns max)
    t_rep            PASS   func-equivalent (85 insns max)
    t_rotate         PASS   func-equivalent (68 insns max)
    t_setcc          PASS   func-equivalent (65 insns max)
    t_shift          PASS   func-equivalent (67 insns max)
    t_shld           PASS   func-equivalent (44 insns max)
    t_stack          PASS   func-equivalent (45 insns max)
    t_string         PASS   func-equivalent (50 insns max)
    t_unary          PASS   func-equivalent (80 insns max)

    totals: 28 PASS / 0 FAIL / 28 total
M2 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

**Honest coverage statement:** M2 covers the user-mode integer ISA a flat QEMU
user-mode program can execute and reproduce bit-exactly. It is **NOT** yet
"decoder-exhaustive vs XED/Capstone" — that audit remains ongoing. Memory-operand
BT*/SHLD/SHRD and ENTER are genuine integer forms that currently HALT (deferred,
not mis-executed). System mode (segmentation/paging/TLB/interrupts/SMM), far
CALL/RET, and privileged ops are out of scope by design and move to **M2S**. No
pipeline / U-V pairing / branch prediction / caches yet (M4/M5); M2 is
functional-only (no cycle accuracy).

**Next:** M3 — x87 FPU (x87 corpus vs SoftFloat/MPFR + QEMU).

### 2026-06-02 — M1 complete (real single-issue integer core, func-equiv vs QEMU)

Replaced the M0 NOP-stub core with a **real single-issue, in-order, multi-cycle
functional integer core** (`rtl/core/intcore.sv`) that fetches IA-32 bytes over
the `mem_*` bus, decodes the M1 integer subset, executes one instruction at a
time, and reports post-commit architectural state through the single
`vtm_retire` DPI point. **Every program in the corpus (smoke + the three M1
tests) is now func-diff-clean vs QEMU** (`compare.py --mode func` exit 0, no
length mismatch).

**Core structure** (a coherent functional FSM, one instruction at a time):
`S_RESET → S_FETCH` (4 word reads → a 16-byte instruction window) `→ S_DECODE`
(combinational length + operand + ModR/M/SIB/disp decode) `→ S_LOAD` (memory
source/pop) `→ S_EXEC` (ALU + EFLAGS) `→ S_STORE` (push / mov-to-mem / RMW)
`→ S_RETIRE` (commit GPR/EFLAGS/EIP, pulse `retire_valid`) `→ S_HALT` (on
`int $0x80`, and now also on any opcode outside the M1 subset).

**Init-state handling:** the TB (playing the loader) drives `init_eip`/`init_esp`
at reset; the core latches them plus constant segment selectors (CS=0x23,
SS/DS/ES/GS=0x2b, FS=0) and EFLAGS reset 0x202 (bit1 + IF). Segments never change
in the M1 corpus — the core just reports the constants.

**Instruction subset implemented:** MOV (`B8+rd`, `89/8B /r`, `C7 /0`, and the
`A1`/`A3` EAX-moffs32 absolute forms — added this phase), LEA (`8D`), PUSH/POP
(`50+rd`/`58+rd`), the full ALU group ADD/OR/ADC/SBB/AND/SUB/XOR/CMP in all
standard forms (`/r` both directions incl. memory operands, `eAX,imm32`,
`81 /digit id`, `83 /digit ib` sign-extended), INC/DEC (`40+rd`/`48+rd`),
TEST (`85 /r`, `A9 id`), NOP (`90`), JMP `rel8`/`rel32`, the full `Jcc` `tttn`
condition set (`70+cc` and `0F 80+cc`), and `INT 0x80` (halt). EFLAGS (CF/PF/AF/
ZF/SF/OF) match QEMU exactly — the comparator compares them in full (no
undefined-flag ops in the corpus). General 32-bit ModR/M + SIB + disp8/disp32
addressing is decoded.

**New test corpus** (`verif/tests/**`, discovered by the gate via `manifest.json`):
- `t_branch` — Jcc condition-code coverage (je/jne/jl/jge/jg/jb/ja) with
  signed/unsigned operand pairs that diverge, plus never-taken sentinels.
- `t_loop` — counted loops / back-edges: dec/inc + cmp/test + jne/jl, each branch
  taken (per iteration) and finally not-taken (exit).
- `t_mem` — AGU coverage: store/reload via absolute disp32, `[reg]`, base+disp8,
  and SIB, then ALU on the reloaded values.

**Adversarial review — what was found and fixed (all reproduced before fixing):**
- **AF computed at the wrong bit position** (high; failed `t_loop` n=5, `t_branch`
  n=33). The six `flags_next` arms computed `af = a[3]^b[3]^res[3]` (carry *into*
  bit 3) instead of the architectural carry *out of* bit 3 = `a[4]^b[4]^res[4]`.
  Verified ~50% mismatch vs the true AF on random ADD/SUB operands; fixed and
  re-verified to 0 mismatches over 200k random cases each. Affects ADD/ADC/SUB/
  SBB/CMP/INC/DEC.
- **MOV moffs32 (`A1`/`A3`) decode gap** (failed `t_mem` n=4 + length mismatch).
  GAS emits `A3` for `movl %eax,<abs32>` (5 bytes); the decoder had no case and
  mis-lengthed it to 1 byte via `default`, desyncing the fetch stream. Added
  `A1` (MOV EAX,moffs32 load) and `A3` (MOV moffs32,EAX store).
- **ALU with a MEMORY SOURCE operand** (high; latent — not in corpus). The EXEC
  operand mux collapsed both ALU inputs onto `mem_load_data`, so `add (%edx),%eax`
  computed `mem OP mem` and dropped the register. Added a `d_mem_dst` decode flag
  distinguishing "memory is the source" from "memory is the RMW destination"; the
  mux now feeds `src_a=gpr[dst]`, `src_b=mem` for memory-source forms.
- **ALU with a MEMORY DESTINATION (read-modify-write)** (high; latent). Same root
  cause from the other direction: `add %eax,(%edx)` stored `mem OP mem` instead of
  `mem OP reg`. The `d_mem_dst` flag fixes `src_b` to `gpr[src]`.
- **`pop %esp`** (med; latent). Two NBAs to `gpr[ESP]` (`<= mem_load_data` then
  `<= ESP+4`) raced; the +4 won, discarding the popped value. Now the ESP bump is
  suppressed when the pop destination IS ESP, so the loaded value wins (Intel SDM).
- **Silent mis-decode of out-of-subset opcodes** (low). The `default`/`0F`-non-Jcc
  arms advanced 1–2 bytes silently. Added a `d_unknown` flag that routes to
  `S_HALT` (a LOUD stop, no retire) so an unsupported opcode can't corrupt the
  fetch stream. The implemented subset is unaffected.

All four latent datapath fixes (mem-source ALU, RMW, `pop %esp`, and the AF
exposing cases `add %eax,%eax`/`inc %eax`) were verified func-equivalent vs QEMU
with dedicated micro-tests before being declared fixed.

**False positives / out-of-scope (dispositioned, not "fixed"):**
- **Prefix consumption** (low): the decoder handles only a single `0F` for the
  two-byte Jcc; other prefixes (0x66/0x67/seg/F2/F3) are not consumed. The M1
  corpus contains no prefixes (all 32-bit default forms), so this is documented
  M1 scope, not a corpus bug. (M2 extends the decoder toward exhaustiveness.)
- **8-bit accumulator / other unimplemented opcodes** (low): out of the M1 subset
  per spec; now guarded by `d_unknown → S_HALT` rather than silently mis-decoded.

**HARNESS/SPEC fix (init ESP):** the spec-documented `--init-esp 0x40c348d0` was
**stale** — QEMU's linux-user loader places the initial stack pointer for these
static binaries at `0x40c34910` for smoke (and a slightly different value per
program, because argv[0] = the ELF path length varies). The literal `0x40c348d0`
made *every* program (incl. smoke) diverge at n=0 on ESP; the core is correct (it
latches whatever ESP it is given). The M1 gate now derives each program's init
ESP from its golden's n=0 record (environment-independent, and exactly the spec's
intent that "the testbench, playing the loader, establishes the init state");
`docs/m1-core-spec.md` and the TB default were corrected to `0x40c34910`.

**How to run:** `make m1` (= `bash verif/run-m1.sh`). It builds the corpus + RTL
TB, discovers every program from `verif/tests/**/manifest.json`, generates each
QEMU golden, runs the RTL TB (init ESP from the golden n=0), runs
`compare.py --mode func`, asserts exit 0 for all, and prints a per-program table.
Exits 0 only if all pass. RTL stays lint-clean (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**Observed result** (`make m1` from a clean TB build, exit 0):

```
    PROGRAM      RESULT DETAIL
    -------      ------ ------
    smoke        PASS   func-equivalent (22 insns max)
    t_branch     PASS   func-equivalent (43 insns max)
    t_loop       PASS   func-equivalent (78 insns max)
    t_mem        PASS   func-equivalent (25 insns max)
M1 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

`make m0-smoke` still exits 0 (the M0 infrastructure gate is met; with a real
core the smoke func compare now reports EQUIVALENT, which the M0 script treats as
a benign WARN and still passes).

**Honest coverage statement:** M1 implements an integer **SUBSET** sufficient for
the corpus and built to extend cleanly. It is **NOT** yet "decoder-exhaustive vs
XED/Capstone" (that remains ongoing, toward M2). There is **no** pipeline, U/V
pairing, branch prediction, or caches/TLB yet — those are M4/M5; cycle accuracy
is out of M1 scope (func-mode only). Correct architectural state on the integer
subset is the only M1 claim, and it is met.

**Next:** M2 — full integer ISA + memory + paging/segmentation (ISA arch corpus
diff-clean), extending the decoder toward exhaustive XED/Capstone coverage.

### 2026-06-02 — M0 bootstrap complete (infrastructure proven end-to-end)

Built the full M0 differential-testing skeleton — six components plus an
end-to-end integration runner — and ran the smoke pipeline cleanly from a
clean tree. **M0 proves the *infrastructure*, not functional correctness:** the
RTL is still a NOP stub, so the functional comparator is *expected* to diverge.

**Components landed** (all build/run in isolation, then wired together):
- **Producer A — golden FUNC trace** (`verif/qemu-trace/gen_trace.py`): drives
  `qemu-i386 -g <port>` over the GDB RSP, single-steps, and emits post-commit
  architectural state as a `mode:"func"` `.vtrace` (pure python3 stdlib; imports
  the shared `verif/diff/tracefmt.py`).
- **Producer B — golden CYCLE trace** (`verif/qemu-plugins/p5trace.c`): a TCG
  plugin (same U/V cycle model as the harness `p5model.c`) emitting retire-order
  PC + cumulative `cyc` + pipe/pairing. Builds to `build/p5trace.so`.
- **RTL skeleton** (`rtl/`): `ventium_top` + all PLAN §6 block stubs; the M0
  NOP-stub core boots reset and retires a fixed canned sequence via the
  `vtm_retire` DPI callback (`rtl-interface.md` §2).
- **Producer C — Verilator C++ TB** (`verif/tb/`): implements `vtm_retire`,
  preloads the flat image, services the M0 bus, and emits the RTL `mode:"func"`
  `.vtrace`.
- **Consumer — comparator** (`verif/diff/compare.py`): diffs A-vs-C (func) and
  B-vs-C (cycle); exit `0`=equivalent, `1`=divergence, `2`=malformed.
- **Test corpus** (`verif/tests/`): the `smoke` program (24 static / 22 retired
  i586-base instructions, no undefined-EFLAGS ops) + `elf2flat.py` loader and a
  manifest (`load_addr`/`entry`=`0x08048000`, `max_insn`=22).
- **Integration runner** (`verif/run-m0-smoke.sh`, invoked by `make m0-smoke`):
  builds corpus + plugin + TB, generates both golden traces, runs the TB,
  validates every `.vtrace` with `tracefmt.read_trace`, and runs the comparator
  in both modes — capturing (not aborting on) the comparator's exit code.

**How to run:** `make m0-smoke` (from the repo root). Artifacts land in
`build/m0/{qemu_func,qemu_cycle,rtl_func}.vtrace`.

**Observed end-to-end result** (`make m0-smoke` from a clean tree, exit 0):
- `qemu_func`: well-formed FUNC trace, 21 records (n=0..20, first pc=0x08048000).
  *(22 retired; the final `int $0x80` exit isn't emitted as a post-state row.)*
- `qemu_cycle`: well-formed CYCLE trace, 22 records (cyc 0..46, pairs=8, CPI≈2.09).
- `rtl_func`: well-formed FUNC trace, 16 records (NOP stub, n=0..15).
- FUNC compare (A vs C) — the EXPECTED coherent divergence:
  `RESULT: DIVERGENT` → `n=0 pc=0x08048000 field=eax: expected(A)=0x11111111
  got(C)=0x00000000` (golden `movl $0x11111111,%eax` vs stub's zeroed eax);
  `func exit=1`. The smoke program is longer than the stub's canned sequence, so
  the comparator also notes the length mismatch (A=21 vs C=16).
- CYCLE path is exercised by self-diffing the golden cycle trace (no RTL cycle
  DUT exists until M4): `RESULT: EQUIVALENT`, `cycle exit=0`.

This confirms the clock/reset/DPI/trace path, the three producers' formats, the
manifest→loader→TB seam, and the comparator all line up. **No integration bugs
required fixing** — the pinned `trace-format.md`/`rtl-interface.md` contracts and
the single-source-of-truth `tracefmt.py` held: DPI signature
(`ventium_pkg.sv` ↔ `dpi_retire.cpp`), field names/hex formatting, and the
register layout all matched on the first wired run.

**Next:** M1 — replace the NOP stub with a real decoder + single-issue integer
core, and turn the func comparator green on the smoke corpus (decoder matches
Capstone; integer ISA diff-clean vs QEMU). For a full match M1 must also align
the TB's reset ESP with QEMU's linux-user initial ESP (`esp=0x40c34900` in the
current golden trace) — see the corpus notes on push/pop.

### 2026-06-02 — Planning complete
- Read the reference library (`REF.md`, `MANIFEST.md`, `00-index/`) and the
  existing QEMU golden-model harness (`07-p5-emulation-harness/`).
- Locked target: **P54C, non-MMX, single core, L1-only, no FRC** (per REF.md
  practical recommendation; matches the existing harness).
- Wrote [`PLAN.md`](PLAN.md): scope & honest-fidelity statement, target µarch
  parameters (5-stage U/V integer pipe, 256-entry/4-way BTB, 8-stage FPU, 8 KB
  2-way split L1, 64-bit bus), reference map, Verilator+QEMU differential
  verification strategy, repo layout, 10-block RTL decomposition, and milestones
  M0–M6 gated on REF.md's five success layers.
- **Next:** start M0 — create `rtl/`, `verif/`, `tools/`, `docs/` skeleton; define
  the golden-trace record format; write the QEMU golden-trace plugin (sibling to
  `p5model.c`); stand up the Verilator testbench shell + trace comparator.
