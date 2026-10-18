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
| `performance-r2` | `PerformanceOptimized`, rebuilt hierarchy | Planned `ExtraNetDelay_high` / `AggressiveExplore` / `NoTimingRelaxation`; post-route `Explore` | Native synthesis succeeded; reporting-context guard stopped the run before APR. No timing result. |
| `performance-r3` | Planned `PerformanceOptimized`, rebuilt hierarchy | Planned same performance APR | Stopped in 10.06 s before project creation: early interception of Vivado's lazily registered `wait_on_run` failed |
| `performance-r4` | `PerformanceOptimized`, rebuilt hierarchy | `ExtraNetDelay_high` / `AggressiveExplore` / planned `NoTimingRelaxation`; planned post-route `Explore` | Stopped at the 3 h 50 min APR limit during physical optimization, before routing. No routed timing result. |
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
Closed output: `performance-r4`, owner
`ventium-fresh-performance-oct17-r4.service`, invocation
`11102264390f4fcfb2d22f54aaa43248`, scope invocation
`06f5c70e48af46988f0931a729f5ff9d`. Launched from the repaired tooling at
`fdeecc90`. At **2026-10-18 02:54 EDT**, the owner enforced the unchanged
3 h 50 min implementation deadline during phase 10 of physical optimization.
The owner is terminal (`ExecMainStatus=1`), its Vivado scope is inactive, and
no Vivado process remains. The 200-file source closure and 159 defines were
unchanged; all **213 input/tool pins** were independently rechecked before any
subsequent tooling edits. No old checkpoint was an input. This trial did not
route or produce an accepted bitstream; 40 MHz closure remains unproven.

`closed.json` records `native_exit=124`, reason
`implementation 3h50m deadline`, `inputs_unchanged=true`, and total elapsed
**22,256.076 s**. The completion auditor correctly rejects it as a
native/resource failure. The monitored memory events contain no OOM or
OOM-kill event. Peak RAM was **15,156,060,160 bytes**, peak swap
**6,442,450,944 bytes**, and maximum simultaneous RAM+swap
**20,671,967,232 bytes (19.25 GiB)**. Do not add the separate RAM/swap peaks as
though simultaneous, or assume a smaller full-build cap is safe. At initial
post-exit inspection host available RAM was about 17.23 GiB, below the existing
18 GiB admission threshold; remeasure before launching another full trial.

Retained terminal evidence SHA256:

- `closed.json`: `d34aa44d6e9bab5aefe43e503ddb5312ef589ac1ce12b4793efe39ccc326c0c5`
- `started.json`: `305d660fcfeaa9f9c6d836103093fece3c0875af7b61dd803a2ec92e877bdaec`
- `prepared.json`: `57ae9fb2d1132574cc8cb7a7d65ee6dd4371840c439709b98c56bb3b90460831`
- `native.log`: `c36d061a43cf7b76ae0f730d88f73e582a8f3c8ff05bf949c4a57bc7d3bbada4`

Closed r2 owner: `ventium-fresh-performance-oct17-r2.service`, invocation
`e9e71270d712443e9bf65d44bf491472`; scope invocation
`f7dc258cdd6b486a903e37781f1ca6d4`. Native synthesis started at 18:13:25 local
time and completed RTL elaboration. Actual generated child script confirms:

```text
set_param general.maxThreads 1
set_property ip_cache_permissions disable [current_project]
synth_design -top rk_ao486_bd_wrapper -part xczu15eg-ffvb1156-2-i -directive PerformanceOptimized
```

Run properties confirm `AUTO_INCREMENTAL_CHECKPOINT=0`, empty incremental
checkpoint and extra options, and `FLATTEN_HIERARCHY=rebuilt`. There is no native
checkpoint-read command in synthesis. Final timing and dynamic acceptance remain
pending.

### r2 closure and reporting-context repair

r2 closed at **20:31:57 local** after **8,361.87 s** (2 h 19 min 22 s),
native exit **1**, before implementation. This was **not an OOM or resource
stop**. Native `synth_design` itself completed successfully in **2 h 16 min
55 s**, with zero errors/critical warnings. Its pre-placement utilization was
**186,064 LUTs / 54,917 FFs / 277.5 BRAM tiles / 47 DSPs**. No routed frequency
or strategy improvement can be claimed from this incomplete trial.

The post hook saw **zero clocks** because it queried timing inside the generated
synthesis child, which marks its XDC files `USED_IN_IMPLEMENTATION=false`.
Do not infer that synthesis never saw a clock: the native log explicitly parsed
the scoped PS XDC and executed `create_clock` before timing optimization. The
same XDC creates `clk_pl_0` at 10 ns, feeding the unchanged 10/25 MMCM. The failed
post hook was not sufficient evidence to qualify the full clock closure.

A small, source-only Vivado 2025.2 reproduction confirmed the empty post-synth
clock view; merely changing the property back did not restore timing in that
view. A second fresh project using the actual repaired reporting procedure
passed: **clk_pl_0=10 ns, mmcm_fb=10 ns, mmcm_clk=25 ns**, followed by
`FRESH-SYNTH-CLOCKS-OK`. Evidence is under
`/home/yukidama/external/tmp/ventium-clock-visibility.WMNjkNHY/` (negative
reproduction) and `ventium-clock-project-view.zGKe9nLv/` (positive reproduction).
These are tooling tests, not CPU/APR/hardware acceptance.

[fresh_synth_evidence.tcl](../fpga/fresh_synth_evidence.tcl) now checks native
synthesis completion, opens **this fresh run's** synthesis through its owning
project, runs the clock/timing reports with normal scoped project constraints,
and closes the design. APR cannot launch until that succeeds. It never resumes
r2 or reads another run's checkpoint. No RTL, clock period, timing exception,
synthesis directive or APR directive was changed by this reporting repair.
[AMD's constraint-file reference](https://docs.amd.com/r/2025.2-English/ug903-vivado-using-constraints/Synthesis-and-Implementation-Constraint-Files)
documents the distinct synthesis/implementation applicability of XDC files.

The launcher also now uses the tested native-command **and property** parser,
so omission of Vivado's default `-flatten_hierarchy rebuilt` is not an error.
Both new helper modules are pinned before the next launch. **27 tooling tests
pass**, including clock selection, evidence ordering/failure cleanup, source-only
admission, and timing-result audits. A repeatable native regression is provided
by [test_native_synth_evidence.tcl](../fpga/test_native_synth_evidence.tcl), using
the tiny clock-only fixture; launch it through the exclusive guard in a new
external scratch directory with a new output-directory argument.
That repository-native regression also completed with exit **0** at **20:41:32
local**, again reporting exactly 10/10/25 ns clocks; its retained logs and
reports are under `ventium-clock-evidence-regression.GgJf4BCy/` in external tmp.

r3 found a separate startup issue in **10.06 s**, before project creation or
synthesis: Vivado lazily registers `wait_on_run`, so renaming it during script
initialization failed. The flow no longer intercepts that command. Instead,
the existing implementation-launch interceptor calls the tested evidence
procedure after the platform's normal synthesis wait. The procedure rejects an
incomplete synthesis; implementation cannot proceed on missing/invalid clocks.
The wrapper unit test now deliberately has no `wait_on_run` during initialization
to cover this native startup condition. r3's failure receipts are retained; r4
uses a new output/source copy and begins again from scratch.

### r4 synthesis result and APR launch

Native `synth_design` completed successfully in **2 h 16 min 26 s**, with zero
errors/critical warnings. The native run finished at **23:01:52 EDT Oct17**.
Pre-placement utilization is **186,064 LUTs / 54,917 FFs / 277.5 BRAM tiles /
47 DSPs**. These are synthesis counts, not routed resource or timing results.

The owning-project report now succeeds on the full design:
`build/synth-clocks.tsv` contains **clk_pl_0=10 ns, mmcm_fb=10 ns,
mmcm_clk=25 ns**, followed by `FRESH-SYNTH-CLOCKS-OK core=40MHz AXI=100MHz`
in the native log. All **213 launch pins** were rechecked unchanged after
implementation launched. The earlier reporting-context failure is resolved
for this run; no running source or reporting hook was amended.

The **unplaced** timing report still fails setup: core WNS **−1.011 ns**,
equivalent to a conditional **38.445273 MHz pre-placement estimate**. Global
WHS is **−0.455 ns**. Neither is a routed sign-off result, and comparing this
estimate with the old image's routed 28.701817 MHz would not establish an
improvement. The target remains 40 MHz. The reported worst unplaced setup path
is `q_pc_reg[0]` to shared-FPU `status_reg[10]`, with **90 logic levels** and
25.800 ns estimated data delay (5.882 ns logic / 19.918 ns estimated routing).
Its different endpoint does not establish that the older routed EIP-to-paired-
return bottleneck has been fixed; inspect the new post-route paths.

The path is not confined to FPU arithmetic. The native unplaced path traverses
instruction-byte/decode logic (`d_len[3]`), fetch/fragment shaping, L1D
`shadow_payload_select` and read-data selection before entering the shared-FPU
command-memory input. Subtracting the 2.902 ns source-clock arrival from the
report's cumulative arrivals gives these **estimated**, not routed, landmarks:

| Named point on this path | Cumulative data-path delay |
|---|---:|
| Decode `d_len[3]` | 11.551 ns |
| L1D `shadow_payload_select` | 17.560 ns |
| Shared-FPU `fp_shared_cmd_mem[9]` | 19.289 ns |
| FPU `status_reg[10]/D` | 25.800 ns |

Thus about **74.8% of this estimated path delay has accumulated before the
shared-FPU command input**. An FPU endpoint alone does not justify an FPU-only
placement remedy. Rebuilt-hierarchy cell names are mapping labels, not proof
that every intermediate name containing `reg` is a register boundary. Keep
the whole-core strategy scope and revisit this decomposition on routed paths;
do not use it to waive timing or infer a measured performance gain.

Pre-placement `check_timing` also reports **eight `no_clock` pins**, zero
unconstrained internal endpoints and four outputs without output delays. This
summary does not enumerate the eight pins. Final verbose coverage must resolve
them: the result audit rejects any nonzero `no_clock` count and permits only
the four named status LEDs without output delays. Do not waive the eight pins
or claim complete timing coverage from the three-clock inventory alone.

`build/stages.tsv` records native APR launch at **23:04:25 EDT Oct17**.
Its generated script consumes only **this run's newly synthesized DCP**, with
IP caching disabled and no incremental checkpoint. Actual run properties and
the generated commands agree on the performance APR directives listed above.
Implementation's 3 h 50 min limit expires at **02:54:25 EDT Oct18**; this includes
placement, optimization and routing. Final routed timing, timing coverage,
CDC/exception review and candidate hardware acceptance remain pending.

### Strategy selection after the live result

The current long-net placement experiment and prepared spread-placement trial
address different observed risks. AMD describes its high net-delay strategy as
penalizing long/high-fanout connections, while spread strategies distribute
logic to reduce local congestion. These descriptions motivate experiments;
they do not predict this design's timing gain.
[AMD 2025.2 implementation strategy descriptions](https://docs.amd.com/r/2025.2-English/ug904-vivado-implementation/Implementation-Strategy-Descriptions).

Do not describe r4 as an explicit **synthesis retiming** experiment: its native
`GLOBAL_RETIMING` property is `auto`. AMD's version-matched synthesis guide
states that `auto` does not perform retiming on non-Versal devices. If the long
combinational paths remain after routing, explicit retiming is a possible later
fresh trial, with native evidence of actual transformations and unchanged
architectural/debug behavior required. It is **not enabled or queued here**.
The same guide describes `AlternateRoutability` as reducing MUXF/carry use and
warns that `LogicCompaction` can hurt timing; fewer occupied slices alone would
not justify selecting it for the 40 MHz objective.
[AMD 2025.2 synthesis settings](https://docs.amd.com/r/2025.2-English/ug901-vivado-synthesis/Using-Synthesis-Settings).

Keep synthesis retiming separate from physical retiming. The 2025.2 command
reference identifies `AddRetime` / `AlternateFlowWithRetiming` as explicit
physical-retiming choices; the present `AggressiveExplore` configuration is
not one of them. A directive cannot be combined with an explicit `-retime`
switch. Do not substitute `-interconnect_retime` or
`PHYSOPT_RETIMING_FORWARD`: the cited documentation restricts those features
to **Versal**, whereas this target is Zynq UltraScale+. Any later retiming
experiment needs a device-supported configuration and native transformation
evidence, not just a strategy label. No retiming trial has been queued.
[AMD phys_opt_design reference](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/phys_opt_design),
[AMD PHYSOPT_RETIMING_FORWARD property](https://docs.amd.com/r/2025.2-English/ug912-vivado-properties/PHYSOPT_RETIMING_FORWARD).

Runtime control is a separate experiment axis. The actual r4 implementation
script sets `general.maxThreads=1`; live CPU time has tracked elapsed time
closely during the long post-placement timing-optimization phase. AMD documents
internal threading for placement, routing, physical optimization, STA and DRC,
with `general.maxThreads` in the range 1–8. This is distinct from launching
multiple Vivado jobs. If runtime prevents this strategy finishing within the
existing bound, a **fresh**, two-thread trial is a candidate, retaining one
build family, `-jobs 1`, the memory/disk reserves and the 3 h 50 min APR limit.
No speedup or memory safety for two threads has been demonstrated here. Update
the runner, Tcl policy, native-command audit and tests together only after the
live trial closes; do not edit its pinned inputs or automatically jump to eight
threads. r4 remains single-thread-capped.
[AMD 2025.2 multithreading limits](https://docs.amd.com/r/2025.2-English/ug904-vivado-implementation/Multithreading-with-the-Vivado-Tools).

An **isolated, unapplied** two-thread tooling proposal is now retained at
`/home/yukidama/external/tmp/ventium-fresh-threads.G7EfL3nz/` (300 KiB).
Its 28 host-only tests pass, including native-script thread-cap validation
for both synthesis and implementation and rejection of ambiguous/out-of-range
caps. It preserves `-jobs 1`, all existing resource limits and source-only
admission. No native two-thread probe or full build has run; the README requires
r4 closure/audit, review against preserved originals, repository regression,
and a small source-only native serialization probe before any later launch.
All 213 live r4 pins were rechecked unchanged after this preparation.

The `opt_design` crash workaround has a specific scope. The retained native
2025.2 help log `/var/tmp/ventium-icfrontspan-pwropt-help.HMmw46/help2.log`
still matches SHA256
`8c34e22d6e6955553a9d2c379a255df68b2e8b5880006df9afed691cbffd0e2c`:
`RuntimeOptimized` omits `bram_power_opt` from Default. The Oct3 crash log
still shows the fan-in/fan-out exception and `libxv_pwropt.so` destruction
stack; this is not a reason to disable timing-driven synthesis. In r4,
retargeting, constant propagation, sweep, BUFG and shift-register optimization
actually ran, including insertion of a `soc_reset` BUFG.

That help also documents explicit timing-driven `-resynth_remap` for reducing
critical-path logic depth. If the routed path remains deep, a later fresh trial
could retain the normal no-BRAM-power pass and test a separate explicit remap
pass before placement. Explicit optimization switches replace defaults and
cannot be combined with `-directive`; do not accidentally restore the crashing
power pass or omit the other required logic optimizations. This is a candidate
experiment, **not configured or queued**, and no timing/runtime gain is known.

### Constraint and preservation preflight

The actual generated synthesis script reads only the board `bitstream.xdc` /
`led.xdc` plus generated IP constraints and `dont_touch.xdc`. The frozen wrapper
explicitly excludes the legacy `fpatan_mcp.xdc`: its four-cycle waiver does not
apply to the replacement shared FPU. Final native clock/exception/coverage
reports must still establish the effective constraints; a source search alone
does not establish timing sign-off.

Do not describe the design as having no preservation attributes. The generated
`dont_touch.xdc` uses soft hierarchy preservation, but frozen
`source/flow/src/rk_ao486_system_pl.v:8` independently puts `DONT_TOUCH=yes` on the
outer SoC module. Its comment records a historical AXI-only logic-trimming
workaround. [AMD's 2025.2 property reference](https://docs.amd.com/r/2025.2-English/ug912-vivado-properties/DONT_TOUCH)
distinguishes preserving a hierarchical boundary from freezing every contained
cell: internal logic may still be optimized. The prior worst EIP-to-paired-return
path is inside that SoC boundary, so this attribute alone does **not** establish
the cause of its poor timing. Leaf/net properties and skipped physical
optimizations require native-result inspection before changing preservation.
No preservation attribute or running-build input was changed by this review.

### Observed physical optimization during r4 placement

The first completed in-placer physical-synthesis pass reported
**2,036 optimized cells/nets**, **1,147 added cells**, and **876 removed
cells**. This includes 1,865 LUT-combining changes and 160 equivalent-driver
rewirings. These are native transformation counts, not measured timing gains
or final utilization. The pass reports **zero retiming transformations**.

After detailed placement, the initialization of phase **4.1.1.1 BUFG
Insertion** reported estimated WNS **−7.432 ns** and TNS **−265,969.749 ns**
(`Physopt 32-619`, native `impl_1/runme.log`). This precedes the subsequent
post-placement timing-optimization phase; it is neither a completed placement
result nor routed timing. The summary supplies no path/clock-pair identity,
so do not convert it to a claimed core fmax. The target remains **40 MHz core /
100 MHz AXI**. The worker's own `.vdi` and `runme.log` agree with the top-level
log during that wait; the quiet interval was not just missing forwarding.

Very-high-fanout optimization replicated core `state_reg[0]` ten times and
L1/AXI `bypass_rst_m1_reg_rep__0_0` thirteen times. Another fanout pass replicated
`state_reg[5]_rep__3_0` three times and `state_reg[1]_rep_0` nine times.

There is now direct evidence of one preservation restriction: messages
`Physopt 32-1483`, `32-782`, and `32-780` report that
`rk_ao486_bd_i/rst0/U0/peripheral_aresetn[0]` could not be replicated because
`rk_ao486_bd_i/u_soc/inst` has `DONT_TOUCH`. Listed affected loads include DDR,
debug, management and mouse-mailbox reset/control pins. This establishes an
actual blocked optimization, **not** that this reset net causes the worst setup
path or that removing the attribute is safe. Reconcile it with final paths and
congestion before a narrowly scoped future experiment; preserve the historical
AXI-trimming workaround until such an experiment is independently qualified.
No attribute was changed in the live run.

The same boundary also blocked **reset-net BUFG insertion**, not just driver
replication: `Place 46-32` / `46-56` report one candidate, zero inserted buffers,
and one netlist-edit failure for `peripheral_aresetn[0]`. This is another
observed restriction, not evidence that bypassing it would close the critical
setup path. A later implementation-only property experiment would need to
retain the synthesis workaround and prove its exact affected scope; broad
preservation removal is not justified by this log.

### r4 completed placement

`place_design` completed successfully in **1 h 43 min 24 s**, with zero errors
and zero critical warnings. Its one warning is vendor IP waiver `LUTAR-1`
referencing a likely unusable hierarchy object in the AXI clock converter
(`Vivado_Tcl 4-2057`); final unwaived DRC/CDC inspection remains required.

The long post-placement timing-optimization phase completed after **61 min
15 s** (native cumulative elapsed 40:48 to 1:42:03), approximately **59.2% of
the complete placer runtime**. Its estimated WNS improved from **−7.432 ns**
to **−3.089 ns** (`Place 30-746`). This is an intermediate placement result,
not a routed fmax or a 40 MHz pass; the native summary does not identify the
worst path's clock pair. Physical optimization and routing must still finish.

The placed utilization report contains **185,184 LUTs (54.26%)**, **54,994
FFs**, **34,029 occupied CLBs (79.77%)**, **277.5 BRAM tiles**, and **47 DSPs**.
Lower LUT use alone therefore does not establish low physical occupancy.
Post-placement congestion estimates report global regions of **16×16** and
long-routing regions of **32×32** in all four directions; short-routing
regions are 16×16 except south at 8×8. These are placer estimates, not the
final router's congestion map or a route-completion guarantee. Retain the
spread-placement alternative if the final timing/runtime result warrants it.

### r4 post-placement physical optimization — partial results

The native `AggressiveExplore` pass was stopped at the deadline. Its seven completed
optimization phases give a measured runtime-versus-estimated-timing comparison:

| Completed phase | Phase elapsed | Native transformation summary | Estimated WNS before → after |
|---|---:|---|---:|
| Fanout optimization | 10 min 37 s | 4 nets optimized; 10 cells added | −3.089 → −3.079 ns |
| Single-cell placement | 20 min 59 s | 121 nets optimized; 121 cells moved; none added/deleted | −3.079 → −3.007 ns |
| Multi-cell placement | 13 min 42 s | 29 nets optimized; 62 cells moved; none added/deleted | −3.007 → −2.985 ns |
| Rewiring | 11 min 48 s | 52 nets optimized; 22 cells added; none moved/deleted | −2.985 → −2.935 ns |
| Critical-cell optimization | 45 min 45 s | 19 nets optimized; 29 cells added; none moved/deleted | −2.935 → −2.924 ns |
| Second fanout optimization | 2 min 45 s | 5 nets optimized; 22 cells added; none moved/deleted | −2.924 → −2.924 ns |
| Second single-cell placement | 9 min 57 s | 103 nets optimized; 103 cells moved; none added/deleted | −2.924 → −2.879 ns |

These phase durations are differences between native cumulative elapsed stamps
`00:00:48`, `00:11:25`, `00:32:24`, `00:46:06`, `00:57:54`, `01:43:39`,
`01:46:24`, and `01:56:21`; the initial
1 min 45 s timing update is outside that physical-synthesis task counter.
Use the native phase summaries
for transformation totals, not counts of per-net messages, which are incomplete.
Critical-cell optimization considered 30 candidate nets; its native aggregate
reports 19 optimized nets, including replication and driver replacement. A
second fanout phase considered eight candidates. The next multi-cell phase
started with 100 candidates but did not complete before the deadline.
No route or final physical-optimization result is available.

The seven completed optimization phases consumed **1 h 55 min 33 s** for **0.210 ns**
of estimated WNS improvement. Critical-cell optimization alone spent
**45 min 45 s** for **0.011 ns**; its reported TNS changed from −66802.393 to
−63484.869 ns. This is evidence to consider when choosing the
next fresh trial's effort/runtime policy, not a routed frequency gain. The
40 MHz constraint, single-thread setting and 3 h 50 min implementation bound
were unchanged throughout this trial.

For the next trial, do not assume that changing only the physical-optimization
directive removes this runtime cost. AMD describes `Explore` as multiple
optimization passes and `AggressiveExplore` as different algorithms with more
aggressive goals. Even physical `RuntimeOptimized` retains critical-cell and
placement optimization. Thus the prepared `Explore` alternative is an
experiment, not a guaranteed deadline remedy; retain the native phase/runtime
comparison and existing resource/deadline guards.
[AMD 2025.2 physical-optimization directives](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/phys_opt_design).

### Read-only board readiness during r4

At **2026-10-18 01:46 UTC** (Oct17 local), SSH and administrator authentication
worked on `riguke@rk-xczu15eg-f.local`. FPGA manager state was `operating`, with
no guest daemon, recorder or watcher found. Boot ID remained
`2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb`.

The reserved-memory node has two address cells and two size cells. Its big-endian
`reg` decodes to base **0x60000000**, size **0x10000000**; `no-map` is present,
with no reusable/pool property. Privileged `/proc/iomem` reports
`60000000-6fffffff : reserved`, with no overlapping System RAM interval. This
confirms the DDR reservation for this boot, not the identity or acceptance of a
future bitstream. No PL MMIO, programming, clock change or guest launch was done.

Storage needs attention before new board runs: root had **181 MiB free** and
`/dev/shm` only **43 MiB free (98% used)**. The privileged inventory confirms
many old debug runs consume the scratch space; an unprivileged `du` undercounts
root-owned directories. **Nothing was deleted by this initial preflight.**
Preserve the Oct17 Quake/Doom
sealed evidence, pristine Win95 media and needed binaries; admit any cleanup by
exact closed targets and verified host copies, not a broad directory removal.
This preparation does not interrupt the live synthesis or establish candidate
hardware acceptance.

The subsequent exact-target cleanup removed **13 old `run.vhd` duplicates**,
reclaiming **347,209,728 allocated bytes (331.125 MiB)** and raising board scratch
free space to **374 MiB**. Each file matched the preserved cold seed SHA256
`2df14ac9ae5f927cab2410e784d14c655f0e96644ca80ced3c0b012df7a36e4c` on both
host (`tmp/qk_td.vhd`) and board (`/tmp/ao486/quake-cold-oct02.vhd`). Privileged
checks found no open/mapped target or process using its run directory; all
targets were old single-link regular files, with inode/stat rechecks before
unlink. Unique disks, captures, logs, pristine Win95 media and bitstreams were
untouched. Every removed file is recoverable by copying the retained seed.

Exact targets, hashes, the executed script and recovery instructions are retained
under `/home/yukidama/external/tmp/ventium-board-prune-oct17.CV3L9Gjd/`.
`removed.json` has SHA256
`0891db31e652ef701cffbad62e2da457288d5a197ef366f972ca871685dfbc0f`, matching the
board receipt; all 13 entries report deletion complete. The root SSH session
was closed, the original seed hash remained unchanged, and FPGA manager remained
`operating`. No guest was launched and no PL state was modified.

### Preserved CoreMark acceptance assets

The unchanged **4,000-iteration** performance and validation media are retained
under `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/coremark-pll-media-r1/`.
A read-only recheck during r4 matched **all 32 source/tool pins and 72 artifact
hashes** in its `closed.json`; that receipt's SHA256 is
`f11b03f0eb5629c5523961d73958c3db9f48d6cdadfd6334925b5fb6c1424385`.
Both pinned Pentium QEMU reference runs exited 33, with no recorded errors.
These are reusable CRC oracles, **not candidate hardware passes**.

| Seed | `seedcrc / crclist / crcmatrix / crcstate / crcfinal` |
|---|---|
| Performance | `e9f5 / e714 / 1fd7 / 8e3a / 65c5` |
| Validation | `18f2 / e3c1 / 0747 / 8d84 / 5249` |

[ven_coremark_clock_trial.py](../fpga/board-tools/ven_coremark_clock_trial.py)
supports cold trials of the newly programmed image with `--pll-divider 25`
and `--expected-mhz 40`; it does not program the FPGA or use snapshots/STEP.
Use fresh private media copies and retain a new candidate deployment receipt.
[audit_coremark_clock_trial.py](../fpga/audit_coremark_clock_trial.py) checks
the completed console against these reference CRCs, measured duration, runtime
clock, current-trial paired-retirement evidence, hashes and clean closure.
Its image/source/deployment prerequisites remain separate. Neither these
preserved assets nor an older board trial qualifies r4; new CoreMark runs,
Win95 cold desktop/UI acceptance and a complete Quake timedemo remain pending.

### Historical r2 parser caveat

The r2 controller's original post-run parser incorrectly required the default
`-flatten_hierarchy rebuilt` argument to be printed explicitly. Vivado omits it.
Do **not** interrupt/restart a valid synthesis for this post-run parser bug or
silently relabel its inputs. [audit_fresh_strategy.py](../fpga/audit_fresh_strategy.py)
independently checks both the command and native property report; it passes on
this actual script, with three additional regression tests. A terminal
controller `flatten policy drift` audit failure must be distinguished from a
native tool failure, and the full native result still needs independent audit.
This configuration-only checker cannot establish completion or timing closure.
The launcher fix above applies to subsequent fresh runs; r2 instead ended on the
independent native reporting-context failure before this parser could matter.

### Explicit reporting-hook amendment during r2

The historical native clock report revealed an independent guard bug before
either reporting hook ran: **MMCM feedback (`mmcm_fb`) is also 100 MHz**. Counting
all 10 ns clocks as functional AXI clocks incorrectly yields two and would stop
the valid synthesis at its post hook. The fresh generated PS XDC explicitly
defines `clk_pl_0` at 10 ns.

At **2026-10-17 22:46:20 UTC**, while native synthesis was in timing optimization,
only `fresh_synth_post.tcl` and `fresh_reports.tcl` were amended to identify AXI by
`clk_pl_0` **and** its 10 ns period. Core selection still requires exactly one
25 ns clock; no constraint, source RTL, synthesis/APR option or checkpoint input
changed, and the run was not restarted. Both actual Tcl hook selectors passed
ten scenarios covering normal feedback, missing/wrong AXI, missing core and
duplicate core clocks.

The immutable original `started.json` remains intact. Exact before/after hashes,
owner/scope identities and timing of this change are recorded in
`performance-r2/report-hook-amendment.json`, SHA256
`c5f9473d9c0b07a783c14f83149be85d265c0692954f71b90f73e405effd5794`.
An independent comparison at the time confirmed **all 200 frozen source files
and every other launch pin unchanged**. The original controller was expected to
report `inputs_unchanged=false` and an assertion audit failure even if Vivado succeeded;
do not overwrite that receipt or call all launch inputs unchanged. The separate
result audit accepts only these exact two reviewed reporting deltas for this
specific invocation, and rejects any additional source/tool/constraint change.
r2 ultimately had native exit 1 from the separate post-synthesis clock-view
failure, so this exception cannot qualify it. Its original receipts remain
intact; later launcher/report repairs are for a new run, not retroactive edits
to that failed result.

### Closed-run acceptance audit

[audit_fresh_result.py](../fpga/audit_fresh_result.py) checks the closed native
result separately from the launcher's formatting-sensitive parser. It requires
native exit zero, unchanged pinned inputs, matching product hashes, exactly one
fresh synthesis/implementation/route sequence, and the implementation deadline.
It distinguishes the specifically identified `flatten policy drift` parser
exception and the exact reporting-hook amendment above. Other errors, resource
stops and source changes fail the audit. The full native completion, product,
stage, clock and timing checks still apply to an amended run.

The numeric review includes all four clock-pair paths, global setup/hold/pulse
width and failing-endpoint totals (including nonstandard path groups), complete
routing, no DRC errors/critical warnings, all ten AXI Gray-pointer bus-skew
constraints, and full timing coverage. Only the four asynchronous status LEDs
may lack output-delay constraints; unconstrained internal endpoints are never
accepted. Different synthesis strategies may change net counts, so an old
net-count threshold is not imposed. CDC status is recorded separately.

This audit explicitly leaves manual exception/source/CDC review and physical
standard-suite acceptance pending. Native completion, numeric timing closure
and processor acceptance are separate results. Run only **after** `closed.json`
exists (never on a partial synthesis/route):

```bash
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 fpga/audit_fresh_result.py \
  /home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/performance-r2
```

Seven result-audit tests pass in addition to three native-configuration,
four launch/freeze, eleven timing-parser and one ten-scenario clock-selection
test (**26 tooling tests**). Reading
the old baseline's text reports confirms the parser rejects its −9.841 ns setup
result; that parser check neither opens an old checkpoint nor qualifies a new
implementation. The only live-run pin changes are the explicitly recorded
reporting-hook amendment above.

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

During r2, growing synthesis scratch reduced free space to 5.2 GiB. A second
checked prune removed ten more obsolete closed synthesis-only DCPs
(**1,792,749,488 bytes**), restoring 6.8 GiB free space. None was a running
process's input/open file, an active-run pin, deployed image, source, report or
routed checkpoint. Exact paths/hashes are in `pruned-checkpoints2.json`. These
also have no trash copy; their retained sources can regenerate them.

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
