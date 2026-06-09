# M5 — cache-cycle + x87/FP-cycle accuracy spec

M5 (PLAN §7, re-scoped) extends the M4 cycle model with the two pieces M4
deliberately deferred and that the **p5model oracle can differentially verify**:
**(1) cache-miss cycle timing** and **(2) x87/FP cycle accuracy**. The pin-level
64-bit **bus protocol** (ADS#/BRDY#/NA#/KEN#/CACHE#/HITM#/burst/locked/pipelined/
snoop) has **no differential oracle** and is split into **M5B** (deferred,
structural-only — the M2S pattern).

## Why this scope (the partial-oracle problem)

Our cycle oracle is `build/p5trace.so` (the p5model U/V estimate). It models the
L1 caches as a hit/miss state machine with a **fixed miss penalty** (`imiss=8`,
`dmiss=8`, `cache=1`) and the x87 FP **latencies/throughputs** — so an RTL that
models the *same* caches and FP timing can be diffed against it
(`compare.py --mode cycle`). It does **not** model bus pins, and QEMU has no
pin-level bus trace, so the BIU FSM cannot be differentially verified here →
M5B, built structurally and validated only by local properties / self-consistency
(real validation needs logic-analyzer/FPGA traces we don't have; REF.md §4, layer 2).

**Honest caveat (PLAN §8):** p5model's miss penalty is an *assumption*, not a
documented P5 constant (harness README). Matching it is estimate-vs-estimate. The
RTL must use the **same** `imiss/dmiss/geometry` as p5model so the cycle
*components* agree; we do not claim silicon-exact memory timing.

## What M4 already has vs what M5 adds

- M4: dual-issue U/V pipeline, pairing, bypass, AGI, BTB/predictor; integer cycle
  *bands* match p5model; FP **serializes** (functionally correct, cycle-approx);
  no cache-miss modeling (so absolute `cyc` ran at a loose `tol-pct 50%`, though
  the real gap is only ~3%).
- M5 adds:
  1. **L1 cache timing.** Model I-cache (8 KB, 2-way, 32 B line, 128 sets) and
     D-cache (8 KB, 2-way, 32 B line, 8 banks) hit/miss with LRU; a miss adds the
     p5model penalty (`imiss=8`/`dmiss=8`, configurable to match the plugin args).
     The 8-bank D-cache bank-conflict (+1 V-pipe clock, addr bits 2–4) is already
     modeled in M4 — keep it. Misaligned access +3 (AP-500).
  2. **x87/FP cycle accuracy.** Replace the FP serialize-stall with proper
     latency/throughput so a dependent `fadd` chain runs at **CPI≈3** (lat 3) and
     independent FP ops pipeline (tput 1). Latencies from
     `docs/p5-timing-model.md` / `p5_timing_canonical.json`:
     `fadd/fsub` lat 3 / tput 1; `fmul` lat 3 / tput 2; `fdiv` 19/33/39
     (precision-dependent); `fsqrt` 70. (Transcendentals are now IMPLEMENTED under
     `+VEN_TRANSCENDENTAL` (M11/#11) but are NOT cycle-modeled — they HALT in the
     default/cycle build, and per #6 the scoreboard keeps fixed P5 latencies, not
     the engines' real `done`. See `docs/m11-transcendental-spec.md` §4.)
  3. **Tighten the cycle gate:** lower `M4_TOL_PCT` toward a tight, documented
     value once cache+FP timing close the offset, and **promote `faddchain` from
     INFO to a GATED band** (CPI in a band around 3.0).

## Gate (`make m5` / `verif/run-m5.sh`)

1. **Functional regression (hard):** `make m1`/`m2`/`m3` exit 0 — never regress.
2. **M4 integer cycle bands (hard):** depadd/indepadd/agi/brloop/brrandom still meet
   their `55-validate` bands from the (now cache-aware) RTL.
3. **New FP-cycle band (gated):** `mb_faddchain` — dependent `fadd %st(1),%st`
   chain → **CPI ≈ 3.0** (band e.g. 2.7–3.3), emergent from the FP latency model.
4. **New cache-cycle checks:** an I-cache-miss kernel (`mb_imiss`, code/loop larger
   than 8 KB or straddling lines) and a D-cache-miss kernel (`mb_dmiss`, strided
   accesses exceeding 8 KB / 2-way) show the expected miss-driven cycle increase,
   and their absolute `cyc` tracks the p5model golden within the tightened tolerance.
5. **Absolute-cyc match tightened:** with cache timing modeled, the integer kernels'
   total `cyc` should agree with the p5model golden within a documented tight
   tolerance (target ≤ ~10%; report the achieved figure honestly — two estimates
   need not be identical, structural fidelity is the point).

Build microbench ELFs as in M4 (`gcc -m32 -nostdlib -static -Wl,--build-id=none
-Wl,-Ttext=0x08048000`); goldens via `qemu -cpu pentium -plugin build/p5trace.so`;
RTL via `tb_ventium --cycle`; metrics via `m4_metrics.py`/`m5_metrics.py`.

**Anything not modeled HALTs / stays cycle-approximate and is documented. Never
fake a cycle match; the cycle oracle is an ESTIMATE.**

## Deferred to M5B (no oracle)

Pin-level 64-bit P5 bus interface unit (`rtl/bus/biu.sv`): `ADS#/BRDY#/NA#/KEN#/
CACHE#/HITM#/W-R#/M-IO#/D-C#/LOCK#/HOLD/HLDA/BOFF#/AHOLD/EADS#`, burst line
fills, write-back, locked and pipelined cycles, inquire/snoop, reset/INIT/BIST.
Built structurally + checked with local SVA/self-consistency; not differentially
verified until real-chip bus traces are available. Tracked like M2S.
