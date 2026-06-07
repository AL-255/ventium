# Rework targets — FSQRT/FDIV and caches

Actionable decomposition of the two headline P0 items in
[`TIMING_PROBLEMS.md`](TIMING_PROBLEMS.md) (P0‑1 FDIV/FSQRT, P0‑3/P1‑1 caches).
`[ ]` = todo, `[~]` = in progress, `[x]` = done. Each target keeps the x87 /
functional gates **bit‑exact** (`make m3`, `make verify`) and is re‑measured
against the synth probe (`fpga/scripts/synth_probe_core.tcl`).

Reference: Ken Shirriff, *“Pi in the Pentium / the FP ROM”* —
<https://www.righto.com/2025/01/pentium-floating-point-ROM.html> + his FDIV‑bug /
SRT‑division articles. Existing golden model + PLA emitter:
`tools/srt/srt_model.py` (run `python3 tools/srt/srt_model.py` to self‑test,
`… pla` to emit the SV PLA case block). Unit gate: `make verify-srt`
(`verif/srt/`, 609 vectors × 2 PLAs vs the golden). Differential gate: `make m3`.

> **Finding (research, 2026‑06‑06).** The Pentium **FP constant ROM** holds
> **transcendental** constants (π, log₂e, log₂10, ln2; arctan(n/32) + sin/cos(n/64)
> range‑reduction tables; exp/log/atanh poly coeffs; IEEE specials 1.0/2.0/−1.0/
> +inf/NaN; bitmasks) — it does **NOT** contain FDIV/FSQRT seeds. **FDIV/FSQRT are
> radix‑4 SRT** (digit‑recurrence + a *separate* quotient‑selection PLA, the
> FDIV‑bug structure), which Ventium already implements (`fx_srt_div`/`fx_srt_pla`).
> So → **Track A (FDIV/FSQRT, below) needs no ROM constants**, only iterative‑izing
> the SRT datapath. The article's constants belong to the **transcendental
> microcode** (task #11) — the real fix for the FSIN/FCOS/**FPATAN** HALT.

---

## A. FDIV / FSQRT → microcoded iterative SRT engine

The Pentium does FDIV/FSQRT with a **radix‑4 SRT datapath driven by microcode**,
using **FP‑ROM constants** (initial approximations / constants). Today Ventium has
a faithful but **combinational** SRT divider (`fx_srt_div`, 36 steps unrolled) and
a **combinational** 128‑iteration sqrt (`fx_isqrt`). Targets:

- [x] **D1 — SRT divider default‑on.** `fx_div` dispatcher now defaults to the
  genuine radix‑4 SRT (`fx_srt_div`, correct PLA); `+define+VEN_DIV_EXACT` opts
  back to the behavioral divider; `+define+VEN_SRT_FDIV_BUG` still selects the
  buggy PLA. *(done + verified — `fpu_x87_pkg.sv` `fx_div`; `make m3` 74/74 PASS.)*
- [x] **D2 — Digest the FP‑ROM article.** Done. **Finding (above):** the FP ROM is
  *transcendental* constants, NOT FDIV/FSQRT seeds; FDIV/FSQRT are radix‑4 SRT
  (PLA‑driven, already in RTL). Square root = SRT‑sqrt on the shared divide
  datapath (D = 2·Sⱼ partial root; adder‑free addend gen; ~70 clk).
- [x] **D3 — Engine design.** Done: a multi‑cycle FSM running **one radix‑4 step
  per clock** that lifts `fx_srt_div`'s exact per‑step body + rounding tail into
  registers (`S,C,qacc,k`), with `start/busy/done/result` handshake. Same datapath
  will serve sqrt (D6). **No ROM needed** for this track (PLA only).
- [~] **D4 — Constant/microcode ROM RTL.** *Re‑scoped: not on the FDIV/FSQRT path.*
  The FP constant ROM + transcendental microcode moved to **task #11** (its real
  home). FDIV/FSQRT use the SRT PLA, which already exists (`fx_srt_pla`).
- [x] **D5a — Iterative FDIV engine (standalone).** `rtl/fpu/fpu_srt_div.sv`: the
  one‑step‑per‑clock engine. **Unit‑verified bit‑exact** vs the 609 golden vectors
  for BOTH PLAs incl. the FDIV‑bug pair (`make verify-srt-iter` → SRT‑ITER‑GATE‑OK).
  ⇒ engine == `fx_srt_div` == `srt_model.py` == QEMU.
- [x] **D5b — FDIV core integration.** DONE + verified. Behind `+VEN_SRT_ITER`:
  engines instantiated near `u_fpu_state`; new `S_FP_BUSY` wait state; normal‑
  operand divides routed to `fpu_srt_div` (Inf/NaN/0÷0/x÷0 stay combinational);
  FDIV dropped from the fast‑path whitelist (`decode.sv`) so it takes the slow FSM;
  combinational commit suppressed for eligible ops; result committed on `done`.
  **`make m3` with `+VEN_SRT_ITER` = 74/74 bit‑exact** (incl. `tx_muldiv`).
- [x] **D6a — Iterative FSQRT engine (standalone).** `rtl/fpu/fpu_sqrt_iter.sv`:
  the existing restoring sqrt clocked at **2 steps/clock** (~66 clk ≤ occ 70).
  **Unit‑verified bit‑exact** vs `fx_sqrt` over 8000 random ops × 4 rc + directed
  (`make verify-srt-iter` → SQRT‑ITER‑GATE‑OK). ⇒ engine == `fx_sqrt` == QEMU.
  *(Authentic radix‑4 SRT‑sqrt on the shared divide datapath — D→2·Sⱼ — is a
  documented fidelity upgrade; needs its own golden. This iterative‑restoring
  form fixes the synth area/timing while staying bit‑exact today.)*
- [x] **D6b — FSQRT core integration.** DONE + verified. Slow‑path `FX_FSQRT`
  +normal routed to `fpu_sqrt_iter` via `S_FP_BUSY` (NaN/neg/±0/+Inf stay
  combinational). **`make m3 +VEN_SRT_ITER` = 74/74** (incl. `tx_sqrt`,
  `tx_fp_special`). Needed `QUIESCE=512` (the iterative sqrt idles ~66 clk > the
  default 64 idle‑window; `run-m3.sh` now takes `QUIESCE`).
- [ ] **D7 — Scoreboard from real `done`.** Drive `fp_ready_cyc`/`fp_occ_pending`
  (`core.sv:722,4075`) from the engine `done`; **floor to occ=39 (FDIV)/70 (FSQRT)**
  so `make m5` cycle bands stay green (decouple internal steps from commit latency).
- [ ] **D8 — Bit‑exact verify.** `make m3` (x87) + `make verify-srt` /
  `verify-srt-iter` stay bit‑identical; preserve the FDIV‑bug path. *(D5a done.)*
- [x] **D8b — Remove the combinational cones from synthesis.** DONE + verified.
  Broadened eligibility to all finite‑nonzero operands; stubbed `fx_srt_div`'s
  36‑step loop + `fx_sqrt`'s `fx_isqrt`+`r*r` under `+VEN_SRT_ITER` (zero/Inf/NaN
  guards kept). `make m3 +VEN_SRT_ITER` stays 74/74. *(Synth re‑probe D9 running.)*
  *(Original note:)* the functional integration ADDS the engines but the
  combinational `fx_srt_div`/`fx_isqrt` cones are STILL synthesized — the fast‑path
  `fp_arf = f_eval(...)` (computed every clock, `core.sv`) instantiates the full
  divide/sqrt arms regardless of the engines. To realize the LUT/CARRY8 collapse,
  under `+VEN_SRT_ITER`: broaden engine eligibility to all non‑{0,Inf,NaN}
  operands (incl. denormals — the engine == `fx_srt_div` for all operands), and
  **stub the combinational `fx_srt_div` 36‑step loop + `fx_isqrt` 128‑step loop**
  (their results are then never committed: fast‑path div is unused, slow‑path
  non‑eligible divides hit only the cheap zero/Inf/NaN guards). Re‑verify `make m3
  +VEN_SRT_ITER` stays 74/74.
- [x] **D9 — Re‑probe.** DONE. `synth_probe_core_iter.tcl` (`+VEN_SRT_ITER`):
  **CARRY8 170%→52% (now fits, −69%), LUTs 518%→363% (−30%), Fmax ~3.6→~11.4 MHz
  (3.2×)**; the 1823‑deep FPU carry chain is gone. Deltas in `TIMING_PROBLEMS.md`.
  New worst path = combinational integer DIV/IDIV (P0‑2) — the next item.

## B. Caches → infer real Block RAM

Today the icache exports its whole 8 KB array combinationally → it synthesized to
~65 K flip‑flops, **0 BRAM** used (`TIMING_PROBLEMS.md` P0‑3). The D‑cache is
timing‑only (no data array).

- [ ] **C1 — icache → registered BRAM read port.** Rework `rtl/mem/icache.sv`:
  drop the flattened combinational `ic_data_o/...` whole‑array outputs
  (`icache.sv:60,101-117`); make the data/tag/val/lru arrays **synchronous‑read
  BRAM** (one set/way per access).
- [ ] **C2 — Spine read‑latency adapt.** Update the fetch/fast‑path consumers
  (`core_fastpath.svh`, `core_bus_driver.svh`) for the **registered (1‑cycle)**
  cache read instead of same‑cycle combinational probe.
- [ ] **C3 — Confirm BRAM inference.** Re‑probe: icache maps to RAMB36/URAM, FF
  count drops ~65 K; `make verify`/`make m7` (Quake lock‑step) stay bit‑exact.
- [ ] **C4 — Real D‑cache data array.** Fold into the L1+AXI memory subsystem
  (`PLAN.md §5.2`, `TIMING_PROBLEMS.md` P1‑1): a BRAM/URAM data array giving
  same‑cycle hit + AXI burst on miss (the current `dcache_timing` has no data —
  its regs are even optimized away). Tracked there; listed here for completeness.

---

_**A (FDIV/FSQRT) COMPLETE + measured:** D1/D2/D3/D5a/D5b/D6a/D6b/D8b/D9 all done +
verified (`make m3 +VEN_SRT_ITER` 74/74; default `verify`/`m3` green; re‑probe:
CARRY8 now fits, Fmax 3.2×). Remaining FPU polish: D7 (drive the scoreboard from
real `done`, floored to occ 39/70 — cycle‑fidelity nicety; the worst path is now
elsewhere). Next big timing items (separate from FDIV/FSQRT): **P0‑2 integer
DIV/IDIV** (now the #1 path) and **P0‑3 icache→BRAM**. Transcendental constant‑ROM
microcode = task #11._
