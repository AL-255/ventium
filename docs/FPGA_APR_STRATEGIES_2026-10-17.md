# APR strategy comparison — 40 MHz target

## Scope and baseline

The target remains **40 MHz core / 100 MHz AXI** (25 ns / 10 ns), with timing
met after routing. **Every current trial starts from source and runs fresh
synthesis and APR. No old checkpoint, netlist, project or IP synthesis cache is
used.** This supersedes the earlier checkpoint experiments documented below.
No clock constraint is relaxed. The installed image and board state are
untouched; new physical implementations still require independent acceptance.

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

## Current fresh synthesis + APR trials

| Trial | Timing-driven synthesis | Placement / physical optimization / routing | Status |
|---|---|---|---|
| `performance-r2` | `PerformanceOptimized`, rebuilt hierarchy | `ExtraNetDelay_high` / `AggressiveExplore` / `NoTimingRelaxation`; post-route `Explore` | Launched from a new source copy/project; no timing result yet |
| `routability-spread` | `AlternateRoutability`, rebuilt hierarchy | `AltSpreadLogic_medium` / `Explore` / `AlternateCLBRouting`; post-route `Explore` | Prepared, not launched |

The first combination targets the measured long logic/routing path. The second
tests a routing-oriented mapping and spread placement, if the first result
warrants it. These are explicit custom combinations, not claims of measured
improvement or exact stock strategy presets. Synthesis timing optimization is
enabled (no `-no_timing_driven`). Both retain the previously working
`RuntimeOptimized` **opt_design** crash-avoidance directive; that is distinct
from incremental implementation's negative-WNS target, which is not used here.

The source closure is the deployed CPU/profile, not the dirty checkout:

- Parent source: `ventium-fprem-sequence.iSZ9BAj4/programmable-clock-r3/source`.
  All 200 source/metadata files match its pinned `prepared.json`, SHA256
  `5308f8044f35b387e833e1b62a52ec7605bb3a5e157096d9327b638d4b659a54`.
- Each trial makes a new source copy and overlays only the repaired full-width
  `ven_pll_ctrl.sv` / `ven_programmable_clock.v`. The controller is byte-identical
  to the deployed repair; the wrapper is checked against its exact narrowed
  port adapter. No checkpoint is inspected or passed into the build.
- CPU/cache RTL and all **159 defines** are preserved; the wrapper checks full
  P5 cache geometry, `cycle_mode=1'b1`, pipelined FP and relocated fast-memory
  defines. This source admission is not dynamic U/V execution evidence.
- CPU sources in this freeze must not be described as current dirty-checkout RTL.

[run_fresh_strategy.py](../fpga/run_fresh_strategy.py) and
[fresh_strategy.tcl](../fpga/fresh_strategy.tcl) create a new project, disable
IP caching before BD generation, clear incremental checkpoint properties, and
override the legacy flow's synthesis/APR options immediately before launch.
They retain native run properties, active source paths, exact invocation,
source hashes, synthesis-clock evidence, stage timestamps and final reports.
New checkpoints generated **within** a run are normal synthesis/APR outputs;
they are never starting inputs for another strategy.

Resource limits: one Vivado family/one native worker, **16 GiB RAM / 6 GiB swap**,
21 GiB combined early stop, 4 GiB disk reserve, 2 GiB host RAM/swap reserve.
Whole-run limit is eight hours; **implementation is bounded to 3 h 50 min**,
including placement, optimization and routing. A timeout/resource stop is not
a completed timing result. Four fresh-flow tests plus eleven timing/parser
tests pass; these are tooling tests, not CPU or FPGA standard-suite acceptance.

Current artifact root:
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/`.
Current owner: `ventium-fresh-performance-oct17-r2.service`.
Final timing and dynamic acceptance remain pending.

`performance-r1` stopped before BD generation/synthesis in 20.09 seconds because
the guard expected IP cache property `disabled`, whereas installed Vivado
2025.2 returns `disable`. This was a host guard bug, not a synthesis failure.
Inputs remained unchanged; peak charged RAM 751,202,304 bytes, no swap/OOM.
The corrected guard accepts only the two disabled spellings. A separate native
empty-project probe (`property-probe.log`) confirms `disable`, the incremental
property names/disable readback, and all selected synthesis/implementation
directives. r2 starts completely fresh, not from r1's empty project.

Disk preparation removed **12 obsolete closed synthesis-only DCPs (2,145,782,725
bytes)** from older Oct 11–14 experiments, retaining sources, logs, reports,
accepted images and useful routed results. Exact paths/hashes are in
`pruned-checkpoints.json` under the artifact root. There is no trash copy;
recovery requires rebuilding the preserved sources.

## Superseded checkpoint-only experiments — historical evidence

**Do not launch these for the current objective.** They did not start from
fresh synthesis and cannot satisfy the user's current requirement.

Each strategy reopens the **same baseline**, rather than inheriting the previous
strategy's modifications. Physical optimization can restructure/replicate cells;
"unchanged RTL" does not mean an identical optimized netlist.

| Strategy | Operations | Whole native-run bound | Status |
|---|---|---:|---|
| `postroute-aggressive` | Explicit incremental `TimingClosure`, then `phys_opt_design -directive AggressiveExplore` | 1 hour | r3 canceled at 115.19 s when fresh-only scope became active |
| `postroute-replication` | Explicit incremental `TimingClosure`, then `phys_opt_design -directive AlternateReplication` | 1 hour | Retired without launch |
| `replace-netdelay` | Unroute/unplace unlocked cells; `ExtraNetDelay_high` placement; `AggressiveExplore` physical optimization; `NoTimingRelaxation` routing | 3 h 50 min | Retired without launch |

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

`aggressive-r2` stopped **before physical optimization** at 710.984 s, native
exit 1, with unchanged inputs and no OOM/swap. Its reference reload did report
100.00% canonical cell/net reuse and `TimingClosure` with **Target WNS `0.0`**.
The guard incorrectly demanded the textual representation `0.000`. This was a
host/Tcl report-format bug, not a failed timing-closure strategy. The corrected
guard compares finite numeric zero, rejects duplicate/missing/negative/nonzero
targets, and is tested under both Python and real `tclsh`, including the actual
native report. r3 was canceled before producing any result checkpoint, with
unchanged inputs, peak charged RAM 3,545,952,256 bytes and no swap/OOM. It is a
scope-change cancellation, not a measured strategy failure.

The selected directives were checked against the installed Vivado 2025.2 manual.
AMD documents post-route physical optimization and these directive alternatives:
[phys_opt_design](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/phys_opt_design),
[implementation strategy mapping](https://docs.amd.com/r/2025.2-English/ug904-vivado-implementation/Directives-Used-by-phys_opt_design-and-route_design-in-Implementation-Strategies).

### Historical execution and validation

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
- **Eleven offline guard tests pass**, including the native zero-slack target,
  domain completeness, clock
  relaxation, multicycle/exception rejection, nonfinite timing, cross-clock
  frequency misuse, route errors, critical DRC warnings and hold qualification.

Run artifacts:
`/home/yukidama/external/tmp/ventium-apr-oct17.ByfMRzYU/`.
The first owner is `ventium-apr-aggressive-oct17-r1.service`, invocation
`0b39daa8016e453fb7726036f8f58cdb`.
The corrected owner is `ventium-apr-aggressive-oct17-r2.service`, invocation
`d96a55959d5d4ebfac4fbe3eadc69937`.
The numeric-guard retry is `ventium-apr-aggressive-oct17-r3.service`, invocation
`6dec43fb8aa34b24aa368c8d8d4b8556`.

Source checkpoint:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/programmable-clock-power-repair-r5/build/routed.dcp`.
SHA256: `b38e8bd49d8327eb6497146016e252703f9e90235957e903ec85f932fec41d17`.
The baseline build's `closed.json` binds it to deployed raw image SHA256
`2886d24c5f9c84219f54e23a4766cfb7106f2999d28e794a0fd00256fd60cc52`.

Each leaf retains `started.json`, native logs, resource samples and `closed.json`.
Do not treat a partially written checkpoint or an intermediate router timing
estimate as a completed APR result. Final frequency comparisons will use the
explicit post-operation timing reports.
