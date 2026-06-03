# M4 — dual-issue U/V pipeline + branch prediction (first cycle milestone)

M4 (PLAN §7) turns the functional integer core into a **real in-order 5-stage
dual-issue (U/V) pipeline** with pairing, bypass/interlock, AGI, a BTB + 2-bit
branch predictor — so that the core's **emergent cycle behavior** matches the
`p5model` cycle oracle on the canonical microbenchmarks. This is the first
milestone gated on **cycles**, not just architectural state.

## The core principle (why this can't be faked)

The cycle gate must be **emergent**, not computed. The RTL must *actually be* a
PF/D1/D2/EX/WB pipeline that issues up to two instructions per clock through two
pipes; the cycle counts then *fall out* of the structure. Re-implementing the
p5model formula in the RTL and comparing it to p5model would be tautological and
is forbidden. The validation is: an independent structural pipeline (RTL) agrees
with an independent analytic model (p5model) on instruction streams with
**analytically-known** P5 behavior — that mutual agreement is the evidence.

(Honest caveat, per PLAN §8: the cycle oracle is itself an *estimate*, not
silicon. M4 "cycle accuracy" = the RTL pipeline matches the documented P5 timing
rules as captured by p5model, within tolerance — not bit-true-to-a-real-chip.)

## Scope

**In scope (the M4 gate):** the **integer** pipeline cycle behavior +
branch prediction. Hard gate = the integer microbenchmarks match p5model within
the `55-validate-model.sh` tolerances:
| kernel | stream | expected |
|---|---|---|
| `depadd`   | dependent `add $1,%eax` chain | CPI 0.97–1.10, pairing <2% |
| `indepadd` | independent `add` to 2 regs   | CPI 0.48–0.62, pairing >40% |
| `agi`      | produce reg → use as base next insn | AGI 1-cycle stalls fire |
| `brloop`   | predictable backward branch   | mispredict <2% |
| `brrandom` | data-dependent branch (~50%)  | mispredict >20% |

**Deferred to M5 (NOT M4):** x87/FP **cycle** accuracy (the `faddchain` CPI~3
kernel) and cache/bus timing. The FPU stays *functionally* correct (M3 gate green)
but is treated as a multi-cycle unit that **serializes** the pipe — its cycle
count need not match p5model yet.

**Hard safety rule:** the M1/M2/M3 **functional** gates MUST stay green
(`make m1`/`make m2`/`make m3` exit 0). A pipeline that breaks functional
equivalence is a regression — do **not** commit it. Partial cycle coverage,
honestly documented, is acceptable; a functional regression or a faked cycle
match is not.

## Microarchitecture (REF.md §2, AP-500, Alpert & Avnon)

- **5 stages:** PF (prefetch) → D1 (decode/pair) → D2 (addr-gen/operand) →
  EX (execute) → WB (writeback). In-order issue, in-order completion.
- **Two pipes U & V.** D1 decodes up to two instructions and the **pairing
  checker** decides if the second issues to V this clock:
  - both must be "simple" (UV class) — or the U-only/V-only special cases
    (`adc/sbb`/shift-by-imm = U-only-pairable; simple near branch = V-only);
  - no RAW/WAW on GP regs between the pair (ESP & flags excepted — stack-engine /
    cmp+jcc cases); no displacement+immediate; prefixed ops are U-only;
  - microcoded/complex ops (mul/div/string/shifts-by-CL/x87/etc.) are **not
    pairable** and **serialize** (issue alone, may take multiple cycles).
  Use the pairing classes already documented in `m2-isa-spec.md` / mined in
  `ventium-refs` (AP-500 241799, Agner Fog).
- **Bypass/interlock:** full EX→EX and WB→EX forwarding so an independent
  dependent chain runs at 1/clk (depadd) but a load-use / AGI inserts the right
  stall. **AGI:** 1-cycle stall when an address base/index reg was written in the
  immediately preceding clock.
- **Branch prediction:** 256-entry, 4-way BTB with 2-bit saturating counters,
  looked up in D1; BTB-miss ⇒ predict not-taken; first-taken allocates (and
  mispredicts). Mispredict penalty 3 (U-pipe) / 4 (V-pipe), uncond/call = 3;
  correctly-predicted = 0 bubble. Recover (flush wrong-path) at resolution.

## How to evolve the core (suggested, implementer's call)

The current `intcore.sv` is a multi-cycle FSM (one insn over many cycles) — its
cycle counts are NOT P5-like. Reorganize into pipeline stages. A practical,
correctness-preserving structure (mirrors how real CISC pipelines work):
- **Fast path:** simple/pairable instructions (the common ALU/mov/lea/push/pop/
  test/cmp/jcc set) flow through PF/D1/D2/EX/WB at up to 2/clk with bypass.
- **Serialized path:** complex/microcoded instructions (mul/div/string/shift-CL/
  x87/etc.) reuse the existing proven execute logic but issue **alone** and hold
  the pipe until done (functionally correct, cycle-approximate — fine for M4
  since the cycle gate uses only simple-ALU/branch streams).
This keeps the full M1/M2/M3 functional behavior while delivering real dual-issue
cycle behavior on the streams the gate measures. (A clean rewrite that pipelines
everything is welcome if it stays func-green — but is not required for M4.)

## RTL cycle-trace producer (infrastructure to build)

Today the RTL emits only a **func** trace via `vtm_retire`. Add a **cycle** trace
(Producer C, cycle mode) so `compare.py --mode cycle` can diff it against the
`p5trace.so` golden:
- The TB counts core clocks. On each retirement, emit a `cycle`-mode record
  `{n, pc, cyc = clock-count-at-retire, pipe, paired}` (trace-format §2.3). When
  two instructions retire in the same clock (a paired issue), both carry the same
  `cyc` and `paired:true`.
- The core conveys **pipe** (U/V/none) and **paired** to the TB — add a small DPI
  hook `vtm_retire_cycle(n, pipe, paired)` (or extend the retire path), called on
  the same retirement as `vtm_retire`. The TB in `--cycle` mode writes the cycle
  trace; in default mode it writes the func trace as before (so func gates are
  unchanged).
- Header: `{"vtrace":1,"producer":"rtl","mode":"cycle",...}`.

## Verification (the M4 gate)

`verif/run-m4.sh` (model on run-m1/m2), `make m4`:
1. **Functional regression:** `make m1 && make m2 && make m3` all exit 0 (hard).
2. **Cycle micro-gate:** for each integer microbench ELF (`mb_depadd`,
   `mb_indepadd`, `mb_agi`, `mb_brloop`, `mb_brrandom` — build freestanding from
   the `ventium-refs/.../tools/microbench.c` asm bodies):
   - golden: `qemu-i386 -plugin build/p5trace.so,out=…` → cycle vtrace;
   - RTL: `tb_ventium --cycle …` → cycle vtrace;
   - `compare.py --mode cycle --tol-pct <T>` AND the RTL-derived aggregate
     metrics meet the `55-validate-model.sh` bands (depadd CPI 0.97–1.10 &
     pairing<2%; indepadd CPI 0.48–0.62 & pairing>40%; agi stalls fire; brloop
     mispred<2%; brrandom mispred>20%).
   Pick a tolerance `T` that is honest (the RTL and p5model need not be
   bit-identical cycle-by-cycle, but totals/CPI must land in the bands). Document
   the chosen tolerance and any kernel that only *approximately* matches.

**Gate = functional regression green AND the integer cycle micro-gate met.** FP
cycle (faddchain) is reported for information only and deferred to M5. Anything
unimplemented still HALTs. Be explicit in PROGRESS about what is emergent-real vs
approximate, and that the oracle is an estimate.
