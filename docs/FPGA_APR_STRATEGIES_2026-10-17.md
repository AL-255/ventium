# APR strategy comparison — 40 MHz target

## Scope and baseline

The target remains **40 MHz core / 100 MHz AXI** (25 ns / 10 ns). No clock
constraint is relaxed, no RTL is changed, and no new synthesis is performed.
Experiments begin independently from the deployed programmable-clock image's
existing routed netlist, not the dirty CPU checkout. The installed image and
board state are untouched; these are implementation experiments, not new
hardware acceptance results.

Keep these quantities separate:

| Baseline quantity | Value |
|---|---:|
| Core implementation target | 40 MHz |
| Measured board core clock | 39.999830 MHz |
| Post-route setup slack at 25 ns | −9.841 ns |
| Conditional post-route core timing estimate | 28.701817 MHz |
| Global worst hold slack | +0.004 ns |
| Routable / fully routed nets | 224,107 / 224,107 |

The timing estimate is `1000 / (25 − setup_slack)` for the ordinary full-cycle
same-domain worst path. It is **not** the clock programmed into the FPGA and
does not assert a measured failure threshold. Positive hold, other domains,
cross-clock requirements, pulse widths, CDC and timing coverage still need
inspection; the estimate alone is not full timing sign-off.

Current verified Quake gameplay IPC is **0.496499864 total U+V**, deployed image
`2886d24c`, cycles **625,021,130,428–629,480,208,865**. The APR candidates have
**no gameplay measurements or physical standard-suite acceptance**. The existing
image's pass cannot qualify a new physical implementation.

The [physical map analysis](FPGA_PHYSICAL_MAP_2026-10-17.md) motivates this trial:
the worst path has 89 logic levels and 74.7% routing delay; the local routing
window peak reaches 90.37% despite much lower whole-chip routing utilization.

## Selected experiments

Each strategy reopens the **same baseline**, rather than inheriting the previous
strategy's modifications. Physical optimization can restructure/replicate cells;
"unchanged RTL" does not mean an identical optimized netlist.

| Strategy | Operations | Whole native-run bound | Status |
|---|---|---:|---|
| `postroute-aggressive` | Explicit incremental `TimingClosure`, then `phys_opt_design -directive AggressiveExplore` | 1 hour | Corrected r2 running; no result yet |
| `postroute-replication` | Explicit incremental `TimingClosure`, then `phys_opt_design -directive AlternateReplication` | 1 hour | Prepared; not launched |
| `replace-netdelay` | Unroute/unplace unlocked cells; `ExtraNetDelay_high` placement; `AggressiveExplore` physical optimization; `NoTimingRelaxation` routing | 3 h 50 min | Conditional follow-up; not launched |

The first two preserve the existing physical solution as their starting point.
The third deliberately explores a new placement; it is **not** an incremental
reuse claim. No hand-edited logic, guest-specific change, retiming directive,
false path, multicycle waiver or reduced-frequency constraint is introduced.

### Initial no-op control: inherited incremental target

The initial `aggressive-r1` trial, using implementation scripts `83c63768`,
closed natively in **495.680 s** with unchanged inputs, no OOM/swap, all
224,107 nets fully routed and no DRC errors/critical warnings. Peak charged
RAM was 4,675,801,088 bytes. Core setup/hold remained **−9.841 / +0.004 ns**:
**28.701817 MHz timing estimate, 0% gain**. The optimization itself took only
642 ms: this was **a policy no-op**, not evidence that a genuine aggressive
physical optimization cannot improve the design.

The native log explained that the restored checkpoint retained the previous
incremental `RuntimeOptimized` target of **−10.018 ns**. Since actual WNS
−9.841 ns already exceeded that target, Vivado skipped all setup optimization
and did not modify the netlist. A 25 ns XDC constraint alone therefore did not
make that inherited incremental flow seek zero slack.

The corrected trials explicitly execute
`read_checkpoint -incremental -force_incr -directive TimingClosure` with the
same baseline reference, then require the native reuse report to state both
`Incremental Directive = TimingClosure` and **`Target WNS = 0.000`** before
optimization. This changes the optimizer's objective, **not the 40 MHz clock
constraint**. [AMD documents this distinction between the two incremental
directives](https://docs.amd.com/r/2022.1-English/ug949-vivado-design-methodology/Incremental-Directives-and-Target-WNS).

The selected directives were checked against the installed Vivado 2025.2 manual.
AMD documents post-route physical optimization and these directive alternatives:
[phys_opt_design](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/phys_opt_design),
[implementation strategy mapping](https://docs.amd.com/r/2025.2-English/ug904-vivado-implementation/Directives-Used-by-phys_opt_design-and-route_design-in-Implementation-Strategies).

## Execution and validation

- [apr_trial.tcl](../fpga/apr_trial.tcl) checks the part/top, pinned checkpoint,
  25 ns / 10 ns clocks and M10/D1/O25 MMCM parameters before and after each trial.
  It records before/after timing for both clock domains and both cross-domain
  directions, utilization, route status, DRC, CDC, bus skew and timing coverage.
  It retains a result checkpoint, but never generates or deploys a bitstream.
- [run_apr_trial.py](../fpga/run_apr_trial.py) invokes the mandatory exclusive
  Vivado launcher. Only one Vivado family can run. Limits: one tool worker,
  **12 GiB RAM / 4 GiB swap**, a 15 GiB combined-memory early-stop threshold,
  **4 GiB disk reserve** and **2 GiB host available-RAM/swap reserve**.
  Output is confined to a fresh leaf under `/home/yukidama/external/tmp`.
- Native exit 0, completion marker, immutable input hashes, complete routing,
  no routing errors and no DRC errors/critical warnings are required for a
  completed trial. A worse frequency or negative hold is recorded as such,
  not hidden behind a successful tool exit. Hardware and timing acceptance
  remain separate from native completion.
- **Ten offline guard tests pass**, including the native zero-slack target,
  domain completeness, clock
  relaxation, multicycle/exception rejection, nonfinite timing, cross-clock
  frequency misuse, route errors, critical DRC warnings and hold qualification.

Run artifacts:
`/home/yukidama/external/tmp/ventium-apr-oct17.ByfMRzYU/`.
The first owner is `ventium-apr-aggressive-oct17-r1.service`, invocation
`0b39daa8016e453fb7726036f8f58cdb`.
The corrected owner is `ventium-apr-aggressive-oct17-r2.service`, invocation
`d96a55959d5d4ebfac4fbe3eadc69937`.

Source checkpoint:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/programmable-clock-power-repair-r5/build/routed.dcp`.
SHA256: `b38e8bd49d8327eb6497146016e252703f9e90235957e903ec85f932fec41d17`.
The baseline build's `closed.json` binds it to deployed raw image SHA256
`2886d24c5f9c84219f54e23a4766cfb7106f2999d28e794a0fd00256fd60cc52`.

Each leaf retains `started.json`, native logs, resource samples and `closed.json`.
Do not treat a partially written checkpoint or an intermediate router timing
estimate as a completed APR result. Final frequency comparisons will use the
explicit post-operation timing reports.
