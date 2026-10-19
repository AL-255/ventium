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
| `routability-r2` | `AlternateRoutability`, rebuilt hierarchy | Planned `AltSpreadLogic_medium` / `Explore` / `AlternateCLBRouting`; post-route `Explore` | Stopped through its controller after technology mapping stalled with task-cap rejections. No completed synthesis/APR or timing result. |
| `routability-r3` | `AlternateRoutability`, rebuilt hierarchy | Same planned APR as r2 | Stopped by the 21 GiB combined-memory guard during technology mapping; no OOM or task-cap rejection. No completed synthesis/APR or timing result. |
| `routability-r4` | `AlternateRoutability`, rebuilt hierarchy; one synthesis process | Same APR as r2; routing never reached | Synthesis and placement completed; stopped at 3 h 50 min APR limit in physical optimization. No routed timing result. |
| `performance-retime-r1` | `PerformanceOptimized`, rebuilt hierarchy, explicit synthesis retiming | Planned spread placement / explicit physical-operation sets / `NoTimingRelaxation` | Stopped by the 21 GiB combined-memory guard during technology mapping. No OOM, completed synthesis/APR or timing result. |
| `performance-retime-r2` | Same retiming strategy, fresh source/project, named `serial20` memory profile | Same bounded physical operations / spread placement / `NoTimingRelaxation` | Stopped during technology mapping by the 25 GiB combined-memory guard; no OOM/task rejection, completed synthesis or routed timing. |
| `performance-bounded-r1` | `PerformanceOptimized`, rebuilt hierarchy, explicit retiming off; fresh source/project, `serial20` | Spread placement / bounded physical-operation sets / planned `NoTimingRelaxation` | Failed Oct19 00:55 EDT: Vivado SIGSEGV exporting the post-physical-optimization checkpoint. Synthesis, placement and physical optimization completed; routing never started. No routed timing result. |
| `performance-route-first-r1` | `PerformanceOptimized`, rebuilt hierarchy, explicit retiming off; one synthesis thread | Spread placement / optional physical stages disabled / `NoTimingRelaxation`; four APR threads | Fresh full run launched Oct19 01:10:30 EDT. Source admission and actual resource limits verified; no completed synthesis or routed timing result yet. |

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

Resource limits: one Vivado family/one native worker. The default `standard16`
profile is **16 GiB RAM / 6 GiB swap**, with a 21 GiB combined early stop.
Retiming-r2 uses the separately tested serial-only **20/6 GiB** profile and
25 GiB combined early stop described below. Both retain the 4 GiB disk reserve
and 2 GiB host RAM/swap reserve.
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

The `routability-r3/build/synth_1-properties.rpt` also explicitly records
`STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING=auto`; this trial is **not** a synthesis
retiming experiment either. For a future isolated retiming trial, the 2025.2
syntax/option table specifies `-global_retiming on` (project property
`STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING`), although the command reference's
long description still mentions older `-retiming`/`-no_retiming` switches.
Validate the property and generated native command in a fresh tiny project
after the current Vivado family exits; do not assume the legacy switches work.
Then keep placement/physical-optimization/routing fixed to separate synthesis
retiming from physical retiming, and require actual transformation evidence
plus routed timing and physical acceptance. No such probe or full trial has
been launched, and neither RTL nor live pinned tooling has been changed.
[AMD 2025.2 synth_design syntax](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/synth_design).

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
No full-chip speedup or memory safety for two threads has been demonstrated.
The runner, Tcl policy, native-command audit and tests were updated together
only after r4's terminal outcome and input hashes were retained. r4 used one
internal thread throughout; no trial jumps to eight threads.
[AMD 2025.2 multithreading limits](https://docs.amd.com/r/2025.2-English/ug904-vivado-implementation/Multithreading-with-the-Vivado-Tools).

The originally isolated two-thread tooling proposal is retained at
`/home/yukidama/external/tmp/ventium-fresh-threads.G7EfL3nz/` (300 KiB).
It was applied as `dd86ae61` after exact comparisons against its preserved
originals. All **29 host-only tests pass in the repository**, including thread-cap validation
for both synthesis and implementation and rejection of ambiguous/out-of-range
caps. It preserves `-jobs 1`, all existing resource limits and source-only
admission. The first two-thread full-chip trial is described below. The old scratch README records
the preparation-time state; this section records its subsequent integration.

Small fresh-source native probes use a separate **4 GiB RAM / 1 GiB swap** cap
and ten-minute timeout, not a reduced cap for the full design. The first probe,
`ventium-native-threads-oct18.Q25JMa`, stopped before synthesis because Vivado's
boolean setter rejected `false`; the probe now uses numeric `0`, matching the
production flow. The second, `ventium-native-threads-oct18.2E1OXm`, completed
native synthesis and logic optimization with two threads serialized in both
worker scripts, but its owner rejected the implementation completion status.
It is retained as a failed probe, not a pass. The instrumented fresh rerun at
`ventium-native-threads-oct18.yW1jdK` identified the actual status as
`Not started place_design`: after stopping at `opt_design`, Vivado reports the
next unstarted implementation step. The corrected probe requires that exact
status plus fresh native completion markers, no error marker and a successful
command log. Synthesis writes a run-end marker only; implementation also writes
per-step markers. Regression cases reject missing completion evidence, native
errors and wrong status. Native implementation indents its thread-setting
line, so the probe trims outer whitespace without accepting extra commands.

The final fresh probe **passed** at `ventium-native-threads-oct18.A4aEQz`.
Owner `ventium-fresh-threads-probe-oct18-r4.service`, invocation
`51a6372b4e5e4e0ab8a4658509897739`, exited zero at **03:06:37 EDT** after
107 seconds. Both native worker checks and `FRESH-THREADS-NATIVE-OK` passed
with `threads=2`, `jobs=1`; its Vivado scope closed and no native worker
remained. This establishes serialization of the installed tool's thread cap,
not full-chip timing, runtime, memory safety, or FPGA acceptance. No old
project or checkpoint was imported into any probe.

Final probe SHA256:

- Probe Tcl: `83d109a2fd496185fac404a9bf1948b82a5d1709cf0e61171011f76cb636df0f`
- Native log: `9bdf6238e5d68485fc4fdf074117aa43366e721bc5f3bf734570f2bf6ee1c6e6`
- Native synthesis script: `c701d1f3f45cb0528a6bdc24ededf1fadbcef3f1f18d425d5635fc413aca6cb5`
- Native implementation script: `69378ecdd70283248805943f0d41bfc33719433c8059519c7b2adbc6be54c586`

The next full trial was requested through
`ventium-fresh-routability-oct18-r1.service` (invocation
`6b8ff5be019244aaaa42848b16c4c06f`) at **03:07:57 EDT**, using
`--strategy routability-spread --threads 2`. Its owner exited one at the
existing RAM/swap admission assertion, before copying sources or starting
Vivado. The requested `routability-r1` output does not exist. A post-exit sample
showed 18,845,564 KiB available, below the required 18,874,368 KiB (18 GiB);
swap was ample. This is an admission refusal, not a failed synthesis or an
OOM. Full-build limits remain **16 GiB RAM / 6 GiB swap**, with the same
reserves and deadlines. Do not repeatedly start owners against marginal
headroom; remeasure before another fresh attempt. The user has been asked to
free 1–2 GiB of unused application memory; no application was terminated.

Headroom subsequently recovered, and the second owner attempt was admitted
with **20,059,455,488 bytes available RAM**. Active fresh output:
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/routability-r2`.
Owner `ventium-fresh-routability-oct18-r2.service`, invocation
`79b1819f356547b2a611ed12fddd340d`; scope invocation
`b3f9a83c91ca43f1a844c1fc355b1a9b`. Native Vivado was observed running after
admission. The requested cap is **two internal threads / one native job**,
with unchanged **16 GiB RAM / 6 GiB swap**, reserves, eight-hour whole-run
limit and 3 h 50 min APR limit. The 200-file source closure, 159 defines,
40 MHz core / 100 MHz AXI target and UV-fast `cycle_mode=1` profile remain
unchanged. All launch pins were rechecked. No previous checkpoint is an input;
no synthesis/APR timing or hardware acceptance result is claimed yet.
The owner started at **03:13:50 EDT**, and native synthesis launched at
**03:14:39 EDT**. Its generated script/property audit confirms
`AlternateRoutability`, rebuilt hierarchy, timing-driven synthesis, two
internal threads, disabled IP cache and no previous checkpoint input. This
configuration audit does not establish synthesis completion.
The running native synthesis log also records parsing the generated PS8 XDC
and deriving generated clocks. That XDC creates `clk_pl_0` with a **10 ns**
period; the frozen `ven_programmable_clock.v` uses MMCM multiplier **10**,
input divider **1**, and output divider **25** (40 MHz nominal core clock).
Thus the root clock constraint is ingested during synthesis, not merely added
by the post-synthesis reporting step. The completed-design clock-period and
timing-coverage checks remain pending; these inputs alone do not prove closure.

At approximately 28 minutes, the scope's `pids.events` reported `max 2` and
`TasksCurrent=TasksMax=48`: two process/thread creation attempts encountered
the task cap. The owning project, native synthesis parent and its two internal
task workers were still present; parent CPU time continued advancing, with no
native synthesis error observed. These helpers belong to the single build
family, not independent/orphan builds. RAM/swap guards had no OOM events.
Task-limit events are now included in live polling. The tiny two-thread probe
did not establish full-chip task headroom; do not describe all resource limits
as unpressured. No live guard, source or tool input was changed. Review this
task-cap evidence before selecting the next fresh run's concurrency envelope.

Native timing optimization subsequently finished at cumulative **02:12:49
wall / 02:12:07 CPU**, and technology mapping started. Relative to the preceding
XDC-completion stamp (**00:17:32 wall / 00:17:11 CPU**), this phase consumed
**1 h 55 min 17 s wall / 1 h 54 min 56 s CPU**. The earlier performance-r4
timing-optimization phase took **1 h 16 min 22 s wall**; the new strategy is
therefore not demonstrating a synthesis runtime improvement. The directives
and internal thread caps differ, so this is not an isolated thread-scaling
comparison, and final area/timing remain pending.
At the transition, `pids.events` had increased from `max 2` to **`max 3`**,
with `TasksCurrent=TasksMax=48`. The native parent and existing task workers
remained alive, parent CPU time advanced, RAM/swap guards recorded no OOM,
and a scan of native build logs found no `ERROR:` or thread/fork-creation
failure diagnostic. This additional cap event remains a caveat, not a proven
cause of the runtime difference. No live resource limit or pinned input was
changed; all **213** launch pins had been rehashed successfully shortly before
the transition.

The mapping phase then **stalled**: the log remained unchanged from
**05:28:28 EDT**, all compute threads in the synthesis parent and both task
workers were waiting, and the two workers' CPU totals stayed at **10:26 / 10:28**.
Across the subsequent worker-tree samples the scope accumulated only a few
seconds of housekeeping CPU, unlike the earlier CPU-active optimization.
At **09:33:56 UTC**, the log had been unchanged for more than five minutes,
`TasksCurrent=TasksMax=48`, and `pids.events` still reported three rejections.
This is evidence of a task-starved/stalled run, but does not prove the exact
internal Vivado deadlock mechanism; no native thread-creation error was logged.
The controller was deliberately signalled to stop, rather than leaving this
resource-compromised experiment running to its eight-hour limit.

The authoritative close receipt records **2 h 20 min 17.56 s**, native exit
**124**, reason **`controller signal`**, `completed=false`, and
`inputs_unchanged=true`. This was **not** a whole-run/implementation deadline
expiry or a completed timing result. Peak scope RAM was **16,453,775,360 bytes**,
swap remained zero, and no OOM was observed. The owner is terminal and the
Vivado scope is inactive; all five native project/synthesis/helper PIDs were
confirmed gone. All **213** pins were independently rehashed again before any
subsequent tooling edit. The closed-result auditor rejects it as
`native/resource failure`, as required.

Retained SHA256 receipts:

| Artifact | SHA256 |
|---|---|
| `closed.json` | `093f34e6cc438bd774019f38b99b873fe0fd3bf51dc3d6752d22fab0f16a7b56` |
| `started.json` | `23ac8ff5ba7c9b8b5f024daf44568dc61e71c8297e9d0353d37ee1024a321a72` |
| `prepared.json` | `57ae9fb2d1132574cc8cb7a7d65ee6dd4371840c439709b98c56bb3b90460831` |
| `native.log` | `0e4025c619d20eddf21164890d715f9f599036b666577e9f434db279d9f8b506` |

Before retrying, add a reviewed **two-thread task profile** with bounded helper
headroom (128 tasks), retaining the serial/default 48-task profile, one Vivado
family, one native job, and the unchanged RAM/swap/admission/deadline limits.
Add task counts/events to the controller's watch/close receipts and fail fast
on any task-limit rejection; do not wait for a silent mapping stall to reveal
it. Verify both profiles and invalid/oversized overrides with host-only tests.
The task-profile repair is now implemented and passes **32 FPGA-flow tests and
22 resource-guard tests**. These are host-only tooling regressions, not native
full-chip completion or processor acceptance. `serial` stays at 48 tasks;
`parallel2` selects exactly 128, while arbitrary numeric overrides still cannot
expand the selected ceiling and unknown profiles fail closed. The fresh-run
controller selects the profile from its audited one/two-thread setting, records
task occupancy/rejections, and rechecks all three hard limits on every sample.
Any observed task-limit rejection terminates the run even if the CPU remains
busy. The independent result auditor cross-checks the profile, owner limits,
every monitoring sample, sampled peak and close receipt; old receipts remain
explicitly distinguishable as lacking this task monitoring. No live run was
modified to bypass the old cap. The new full-chip retry is recorded below.
The next trial must again start with a new source freeze/project and full
synthesis, never the aborted mapping state.

Disk headroom was restored without losing the aborted run's diagnostics. The
closed internal directory
`build/rk_ao486_system/rk_ao486_system.runs/synth_1/.Xil/Vivado-3183016-AL-MS790S-U26`
was archived in full as `routability-r2/closed-mapping-scratch.tar.gz` and
verified against the original tree with `tar --diff` before its removal.
The owner was terminal, the Vivado scope inactive, and no Vivado process
remained. The original tree occupied **2,507,890,688 allocated bytes**; the
archive occupies **339,185,664**, reclaiming **2,168,705,024 bytes net**
(about 2.02 GiB) and restoring about 8 GiB free. The removed tree is recoverable
from the archive, but must never become a future synthesis input. Frozen
sources, top-level logs and receipts were not removed; the close/native-log
hashes still match the table above. Archive SHA256:
`c31e7bed11c07f835136af06a07b4bf3eab4142ffd6a1de3bfc59f979d96a1db`.

The fresh-source native task-profile probe **passed** at
`/home/yukidama/external/tmp/ventium-native-tasks-oct18.oNGVZM`.
Owner `ventium-fresh-tasks-probe-oct18-r1.service`, invocation
`038571a7fc834f12989a2237a1798ff4`, ran **05:42:48–05:44:35 EDT** (107 seconds),
exiting zero. The actual scope had **TasksMax=128, MemoryMax=4 GiB,
MemorySwapMax=1 GiB**; sampled task-limit and OOM events were zero. Both fresh
native synthesis and the deliberately partial implementation through
`opt_design` passed the exact completion-marker/log checks and serialized
`general.maxThreads=2`, `-jobs 1`. The scope is now inactive and no native
Vivado remains. This verifies the installed launch/profile path, not full-chip
task headroom, routed timing, or FPGA acceptance. No old checkpoint was input.

- Native probe log SHA256: `3d3fb46c4a36d0a818bb46cf35001f3dea772cd4deca8fc345b933d106f0bb1f`.
- Unchanged probe Tcl SHA256: `83d109a2fd496185fac404a9bf1948b82a5d1709cf0e61171011f76cb636df0f`.
- Updated resource guard SHA256: `4f74b4e382663cb13418543a22c8ec51ae09eed2a991a0e8cab8e87778730bbd`.

The full **routability-r3** retry started at **05:45:29 EDT**, owned by
`ventium-fresh-routability-oct18-r3.service`, invocation
`374974fc732549079905f0a00558289b`; scope invocation
`cbe1ae3c456d4499a30422d29d377fa5`. Output:
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/routability-r3`.
Admission recorded **20,579,340,288 bytes available RAM** and
**8,494,608,384 bytes disk free**. Actual scope limits are **16 GiB RAM /
6 GiB swap / 128 tasks**. The new watcher records the exact limits and task
events, with no rejection observed at startup. All **213** launch pins were
rehashed: the 200 source files and 159 defines retain the same deployed CPU
profile, full P5 L1s, UV-fast `cycle_mode=1`, and **40 MHz core / 100 MHz AXI**.
The native synthesis configuration audit passes `AlternateRoutability`, rebuilt
hierarchy, timing-driven synthesis, `general.maxThreads=2`, disabled IP cache,
and no incremental/old-checkpoint input. This is a genuinely new source freeze,
project and synthesis run; neither r2's aborted state nor its archive is input.
The whole-run eight-hour and APR 3 h 50 min limits are unchanged. Synthesis/APR
completion, routed timing and physical acceptance remain unproven.

While r3 synthesis was active, source-level inspection narrowed the earlier
eight-pin `no_clock` question without waiving it. In r3's generated
`rk_ao486_bd_ps8_0/synth/rk_ao486_bd_ps8_0.v`, the four
`emio_enet[0-3]_mdio_mdc`, two `emio_sdio[0-1]_clkout`, and two
`emio_spi[0-1]_sclk_o` instance outputs are explicitly unconnected. Its XCI
sets all eight corresponding `PSU__{ENET0..3,SD0..1,SPI0..1}__PERIPHERAL__ENABLE`
values to `0`. This is consistent with the historical PS8 pin list, but is
**not current routed-netlist coverage evidence**. If the final report again
lists eight pins, check their exact identities and prove that none feeds a
fabric clock, sequential endpoint or top-level port; a matching count alone
does not qualify them. The reporting/audit code remains unchanged and
still rejects nonzero `no_clock`. No clock constraint or exception was added.

- Generated PS wrapper SHA256: `a1f5dd59e3dff22c97c3586e2760c0f76173eac5ef1bb226cbcb38cf2b4e19fc`.
- Generated PS XCI SHA256: `7cbc25e17748783b83916edf34202cf4cc10446cb55cdbafbee2829319d6946e`.

### r3 controlled memory stop and next resource configuration

The r3 owner closed at **08:00:20 EDT Oct18**, after **2 h 14 min 51.49 s**.
Native timing optimization finished at **2:13:13** elapsed / **2:12:27** CPU
and technology mapping began. The controller then stopped the family when
sampled RAM plus swap reached **22,558,818,304 bytes**, just over its **21 GiB**
early-stop threshold. Peak sampled RAM was **17,179,762,688 bytes**, peak swap
**5,379,145,728 bytes**. There was **no OOM / OOM kill**. Across 1,616 samples,
the peak task count was **40** and task-limit rejections stayed **0**; the
observed r2 task-limit symptom did not recur, but this does not prove its exact
deadlock mechanism. No completed synthesis checkpoint, APR or timing result
was produced. The independent result auditor correctly rejects this run as
`native/resource failure`, not as a timing pass or failed-frequency result.

The owner is terminal, the Vivado scope is inactive, and all native processes
are gone. All **213** input pins were rehashed unchanged before further work.
The next fresh attempt uses the same synthesis/APR strategies with
`--threads 1` (native maximum of one synthesis process, the existing serial
48-task profile), retaining the 16 GiB RAM / 6 GiB swap caps and 21 GiB stop.
The earlier single-process performance trial completed synthesis; that is
evidence for trying the lower-process configuration, **not a guarantee** that
this directive will fit. No RTL, timing constraints, acceptance checks or
resource safeguards are relaxed. No old checkpoint will be an input.

To restore launch headroom, only the closed native scratch directory
`synth_1/.Xil/Vivado-3210237-AL-MS790S-U26` was removed **after** archiving its
entire contents and passing `tar --diff` against the original. Its
2,507,956,224 allocated bytes became a 339,230,720-byte archive: **2.02 GiB net
reclaimed**, recoverable from `routability-r3/closed-mapping-scratch.tar.gz`.
Sources, top-level logs, receipts and generated configuration evidence remain;
the archive is forensic evidence, never input to a later build.

- Closed receipt SHA256: `e540ce3547948ea213bcb182c17ebdb0fb04d8f93982a4f1c91b48f6f0e6cbe8`.
- Started receipt SHA256: `b306f886cea6d1ccecbeba174a67b26a3610b624e8004cce4fddc6704f4061bd`.
- Native log SHA256: `cd2bd28b605d85e5259b595ec383187f8dd924f290af43f0b494537fbfb30509`.
- Recoverable scratch archive SHA256: `9a67f40d799844ecf2ef18a956f9c77ff1a0b680d1ac53cbd519cc261c09beee`.

The **routability-r4** retry started at **08:04:00 EDT Oct18**, under
`ventium-fresh-routability-oct18-r4.service`, invocation
`003ed60f8bff4318b967929faa8f2510`; scope invocation
`f5751f29c5dc4583aef034402018c616`. Output is the new sibling directory
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/routability-r4`.
Admission recorded **20,915,437,568 bytes available RAM** and
**8,059,953,152 bytes disk free**. The actual scope is capped at **16 GiB RAM /
6 GiB swap / 48 tasks**. All **213 pins** were rehashed unchanged; the new
source copy has 200 files / 159 defines, the same deployed CPU profile and
full P5 caches, UV-fast `cycle_mode=1`, and **40 MHz core / 100 MHz AXI**.
The native synthesis configuration audit passes `AlternateRoutability`,
rebuilt hierarchy, timing-driven synthesis, `general.maxThreads=1`, empty
incremental-checkpoint input and no extra synthesis options. IP cache remains
disabled. Only the existing repaired full-width clock differs from the frozen
ancestor; no CPU/cache RTL or flow code was changed for this retry. This is a
new project and synthesis, not a continuation of r3's aborted mapping state.
This trial is now closed; results follow. It did not reach routed timing or
physical acceptance.

### Routability-r4 closure and next strategy (Oct18)

The owner stopped at **15:05:41 EDT**, after **25,300.60 s (7 h 01 min 41 s)**,
with native exit 124 and reason `implementation 3h50m deadline`. Implementation
started at 11:15:37. It was in **physical optimization phase 15**, before routing.
There were **zero OOM/OOM-kill and task-limit events**. Peak RAM was
17,179,840,512 bytes, peak swap 3,728,154,624 bytes and peak sampled tasks 27.
All **213 input pins** were independently rehashed unchanged after termination
and before subsequent tooling edits. The independent completion auditor rejects
the run as a native/resource failure. The owner and its scope are terminal;
no old checkpoint will be used for the next trial.

| Measurement | Performance-r4 | Routability-r4 |
|---|---:|---:|
| Native synthesis wall time | 2 h 16 min 26 s | 3 h 07 min 15 s |
| Synthesis LUTs | 186,064 | 194,204 |
| Unplaced core setup slack | −1.011 ns | −4.200 ns |
| Placement wall time | 1 h 43 min 24 s | 55 min 01 s |
| Placed LUTs / occupied CLBs | 185,184 / 34,029 | 192,762 / 34,125 |
| Global estimated post-placement WNS | −3.089 ns | −3.810 ns |
| Routing completed | No | No |

These are **intermediate**, not routed frequency results. Both retain the
**40 MHz core / 100 MHz AXI** clocks. Routability synthesis used more LUTs and
had worse unplaced setup; the overall strategy placed faster. This combined
comparison does not isolate the cause of the placement runtime difference.
Routability-r4's worst unplaced core path is EIP[1] to `pipe_mem_v_hit_q/D`,
**99 logic levels**, 28.989 ns data delay (5.226 ns logic plus 23.763 ns estimated
routing). Final route delay and achievable frequency remain unknown.

`Explore` repeatedly revisited fanout, single/multi-cell placement, rewiring
and critical-cell optimization. Completed passes consumed **2 h 36 min 22 s**
plus initialization, improving estimated global WNS from −3.810 to −2.977 ns;
another placement pass was running when the deadline expired. Critical-cell
passes alone cost 22 min 22 s and 21 min 23 s. No route runtime can be inferred
from this timeout. The serial resource profile successfully completed synthesis
and mapping in this trial; this does not prove all later strategies fit.

Terminal evidence SHA256:

- `closed.json`: `81f3d2de1f858ece175b123f8033aef4d26401377b78ab0f233f732e41228a79`
- `started.json`: `2e132bd36c915b41e8c76d586b6c537d0ef243391780c630892fdc0cd2d6c039`
- `native.log`: `a1f111d6408590f49c7bff8190a6b6a3f2dbcbb34a09457c4b0cda58b9e37802`

The next proposed combination is **`performance-retime-bounded`**:
`PerformanceOptimized` synthesis with explicit `GLOBAL_RETIMING=on`, rebuilt
hierarchy; `AltSpreadLogic_medium` placement; one explicit pre-route physical
operation set (`-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt`);
`NoTimingRelaxation` routing; one explicit post-route set
(`-placement_opt -routing_opt -restruct_opt -hold_fix`). The existing
`RuntimeOptimized` logic-optimization crash workaround remains. No RTL, clock
constraint, timing exception or resource limit is changed.

This is a **combined candidate**, not an isolated retiming A/B experiment: any
eventual gain cannot be attributed to retiming alone. The operation sets avoid
the repeated Explore flow; they do not promise a fixed duration. The unchanged
3 h 50 min implementation deadline remains authoritative. Synthesis retiming
must be present in the native command and property report; actual full-core
transformations, routed timing and architectural/debug behavior require evidence.
AMD documents that explicit physical-operation flags select only those
operations and cannot be combined with a directive; the native probe checks
that Vivado omits the `Default` directive when emitting these flags.
[AMD 2025.2 physical optimization reference](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/phys_opt_design),
[AMD 2025.2 synthesis retiming](https://docs.amd.com/r/2025.2-English/ug901-vivado-synthesis/Running-Synthesis-with-Tcl).

A fresh tiny native capability probe ran under
`ventium-fresh-bounded-probe-oct18-r1.service`, invocation
`1b1bd25be6824c05b13e2a1588697a13`, at
`/home/yukidama/external/tmp/ventium-native-bounded-oct18.lnWhZRiT`.
It uses 4 GiB RAM / 1 GiB swap / 48 tasks, one internal thread, `-jobs 1`,
and a ten-minute limit. It starts from new RTL/project with IP cache and
incremental input disabled, and exercises synthesis through post-route physical
optimization. The first probe completed synthesis (four forward register moves)
but stopped before implementation because `launch_runs -to_step` expects the
native label `{phys_opt_design (Post-Route)}`, not the internal property/marker
name `post_route_phys_opt_design`. It is retained as a failed probe, not a pass.
Native log SHA256:
`821d660f7419942bff7c85a23ebcb2a3269cd1e32d28c4c1f4aa86ec2ea863ea`.
The corrected probe starts again from new source/project under
`ventium-fresh-bounded-probe-oct18-r2.service`, invocation
`3767969ca3574cac8de7a908668226c2`, at
`/home/yukidama/external/tmp/ventium-native-bounded-oct18.AalwzbNF`.
The corrected native probe **passed**, owner exit zero at **16:13:59 EDT**
(4 min 16 s wall). Native status is `phys_opt_design (Post-Route) Complete!`;
both stage-end markers and successful command logs were checked, followed by
`FRESH-BOUNDED-NATIVE-OK`. The generated synthesis command contains
`-global_retiming on`; the synthesis log reports four forward register moves.
The generated pre/post-route physical commands contain exactly the requested
operation flags and no directive. The independent native-command parser also
accepts the actual implementation script and properties.

The tiny circuit has ample setup slack, so its physical setup optimization was
skipped. This is **native option/flow capability evidence**, not evidence of
full-core physical transformations, runtime reduction or timing gain. No old
project/checkpoint was imported; implementation used this probe's own fresh
synthesis. The owner is exited, scope inactive, and no Vivado process remains.
**34 host-only flow tests plus 22 resource-guard tests pass**. None is CPU or
physical standard-suite acceptance.

Passing probe SHA256:

- `native.log`: `6549e4368a18fd532c5e2d0725c635101edc3476089ff31d5eb95066b8b3c897`
- `test_native_bounded_phys.tcl`: `3c0de1b91e61a2fc77b4673b51045445b0aef76209d7ca69102f6771c269da7f`
- Shared `fresh_bounded_phys.tcl`: `3933335a4c9ee007270773d91139e8da082e14dd8409c7875522d19e94ce504a`

The full-chip candidate was initially **prepared, not launched**. Immediately after the
probe exited, host `MemAvailable` was **18,477,488 KiB (17.62 GiB)**, below the
unchanged **18 GiB** full-build admission threshold. Swap and external disk
headroom were sufficient. The safeguard was not lowered and desktop apps were
not killed to force admission. Current verified
gameplay remains **0.496499864 total U+V** on older `2886d24c`, cycles
625,021,130,428–629,480,208,865; this candidate is unmeasured.

### Fresh retiming trial launched after RAM admission recovered

At **16:50:57 EDT Oct18**, `performance-retime-r1` started from a new source
copy/project under `ventium-fresh-retime-oct18-r1.service`, owner invocation
`208873ff07164253bd143f38108c92c3`, scope invocation
`a00c03f141204d85b0c6681c910f7f43`. Output:
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/performance-retime-r1`.
Started receipt records **25,360,371,712 bytes available RAM** and
**7,660,527,616 bytes free disk** after source preparation. Actual scope limits
are **16 GiB RAM / 6 GiB swap / 48 tasks**, one internal thread and `-jobs 1`.
The eight-hour whole-run and **3 h 50 min implementation** deadlines remain.

All **214 source/tool pins** were independently rehashed unchanged after
launch. There are **200 source files / 159 defines**; only the known repaired
`ven_pll_ctrl.sv` differs from the frozen ancestor. CPU/cache RTL is the same
deployed profile, not the dirty checkout. The source contract checks retain
full P5 caches, UV-fast `cycle_mode=1`, and **40 MHz core / 100 MHz AXI**.
No old checkpoint, previous project or IP cache is an input. This is the
`performance-retime-bounded` strategy committed in `5898177d`; it does not
resume the failed routability implementation. Native synthesis/APR completion,
routed timing and candidate physical standard-suite acceptance remain pending.

- `prepared.json` SHA256: `57ae9fb2d1132574cc8cb7a7d65ee6dd4371840c439709b98c56bb3b90460831`
- `started.json` SHA256: `91d61a96f8d957f7c39549ef0b495672bfea95cbd89ab4892cc4dbfc04353d65`

The native synthesis configuration audit passes: the actual command contains
`-directive PerformanceOptimized -global_retiming on`, rebuilt hierarchy is
confirmed by its run property, and IP cache/incremental inputs are disabled.
Cross-boundary/area optimization finished at cumulative **25 min 05 s**;
timing optimization followed. Neither is a completed synthesis/timing result.

At the **18:33 EDT Oct18** observation, native timing optimization had finished
at cumulative **1 h 40 min 38 s wall / 1 h 39 min 56 s CPU**, and synthesis had
entered **Technology Mapping**. The same owner/scope remained live; the existing
synthesis helper resumed CPU work as mapping began. It is part of this build,
not an orphan or a second independent Vivado run. No OOM or task-limit events
were recorded at this transition. All **214 input/tool pins** were independently
rehashed unchanged again at 18:34 EDT. Full-core register-retiming
transformations have not yet been reported; the enabled switch alone does not
prove their occurrence or any timing gain. Synthesis completion, utilization,
clock-pair timing and routed 40 MHz closure remain pending.

During early timing optimization, disk headroom briefly fell to about 4.93 GiB.
Four unused `.gch` compiler caches from the completed `parallel-write-core-r1`
and `parallel-write-soc-r1` builds were archived, compared byte-for-byte with
`tar -dzf`, and then removed. **315,351,040 bytes (300.74 MiB) net reclaimed**;
both source headers and simulator binaries were rehashed unchanged. All **214
live FPGA source/tool pins** were independently rechecked unchanged afterward.
No active build source, simulator executable, log or acceptance evidence was
deleted. The caches remain recoverable from
`/home/yukidama/external/tmp/ventium-closed-pch-oct18.pODGoWYy/caches.tar.gz`,
SHA256 `9d1fa46534ec97edb0e99b1f7810a422932e9a272c0e1721d047693e9129aa69`;
the adjacent README records exact paths and recovery details. Vivado subsequently
released additional scratch space itself; that release is not counted as this
cleanup's gain. No resource guard or pinned flow file was changed.

### Retiming-r1 controlled memory stop and resource-profile retry

At **18:41 EDT Oct18**, the owner stopped r1 during technology mapping after
**6,619.833 s (1 h 50 min 20 s)**. The terminal owner is failed, its scope is
inactive, and no Vivado process remains. `closed.json` records native exit
**124**, reason **`combined memory early stop`**, and inputs unchanged. All
**214 pins** were independently rehashed unchanged after closure, before the
following tooling edits. The independent completion auditor correctly rejects
the run as a native/resource failure. No synthesis DCP or APR result is accepted.

Maximum sampled simultaneous RAM+swap was **22,742,892,544 bytes (21.18 GiB)**,
above the 21 GiB early-stop threshold. At that sample RAM was 17,179,160,576 bytes,
swap was 5,563,731,968 bytes, and host available RAM was 8,560,295,936 bytes.
There were **zero OOM/OOM-kill events and zero task-limit rejections**; peak
task count was 27. Memory-hard-limit reclaim events are not OOM or task failures.
The enabled retiming option still has no completed full-core transformation or
timing result. This failure does not establish that retiming cannot improve fmax.

Terminal evidence SHA256:

- `closed.json`: `07d001334eec895656c4c273dbdea31ae76ab973d6e8cd7e3cd0a6d34e5cbda8`
- `started.json`: `91d61a96f8d957f7c39549ef0b495672bfea95cbd89ab4892cc4dbfc04353d65`
- `native.log`: `dd74ab0047f50a3641369b6c48738c8ef801be5b89b33503ff0af79f4ce91143`

The next retry keeps the same synthesis/APR strategy but uses the named
**`serial20` memory profile: 20 GiB RAM / 6 GiB swap / 25 GiB combined early
stop**, with one internal thread and 48 tasks. The exclusive launcher's existing
reviewed 20 GiB RAM ceiling is unchanged. Admission now requires more than
**22 GiB MemAvailable / 10 GiB SwapFree**, retaining the two-GiB live host
RAM/swap reserve, four-GiB disk reserve, one-GiB combined-limit headroom,
one-build lock, eight-hour whole limit and 3 h 50 min APR limit. The default
`standard16` profile remains 16/6 GiB. The independent auditor verifies named
profile receipts, actual limits, admission and runtime reserve evidence; it does
not infer acceptance from the profile label. **36 fresh-flow/audit tests plus
22 exclusive-launcher tests pass.** These are tooling checks, not CPU acceptance.
Before launching the next full run, disk admission was restored by archiving and
byte-comparing r1's closed, unopened
`synth_1/.Xil/Vivado-3306894-AL-MS790S-U26` directory, then removing only that
uncompressed directory. **1,803,542,528 bytes (1.68 GiB) net reclaimed**; sources,
native log and terminal receipts remain intact, with receipt/log hashes
rechecked afterward. Recovery archive: `performance-retime-r1/closed-mapping-scratch.tar.gz`,
SHA256 `f12d898c799f7c5078fb774729c00c065e273c46ba6745ae4e129368089622c3`.
Adjacent `closed-mapping-scratch.md` records the exact target and restore
command. Free disk was then **7,625,326,592 bytes**, above the unchanged 7 GiB
admission threshold; all resources must be rechecked at the next launch.

### Fresh retiming-r2 launch with the named serial20 profile

At **18:48:30 EDT Oct18**, a new full-source trial started under
`ventium-fresh-retime-oct18-r2.service`, owner invocation
`9c99f901cb4d451f81f943a625fa43d8`, scope invocation
`fecfc8474c764e4aa01ad1492e4d5f75`. Output:
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/performance-retime-r2`.
The actual live scope was verified as **20 GiB RAM / 6 GiB swap / 48 tasks**.
The launch receipt records **25,617,764,352 bytes MemAvailable** and
**7,578,423,296 bytes free disk** after source preparation. The combined early
stop is **26,843,545,600 bytes (25 GiB)**, with all existing reserve and
whole-run/APR deadline checks retained. Resource-profile tooling is committed
in `a077488b`; no exclusive-launcher ceiling was raised.

The **200-file / 159-define** source closure is identical to r1's prepared
closure; all **214 source/tool pins** were rehashed unchanged after launch.
Only the previously documented clock-controller repair differs from the frozen
ancestor. CPU/cache RTL, synthesis/APR parameters and 40 MHz core / 100 MHz AXI
targets are unchanged. This is a new project with IP caching disabled, not a
restart of r1 or an import of its archived mapping cache. No old checkpoint is
an input. Native synthesis/APR completion, timing and physical acceptance remain
pending; this candidate has no gameplay measurement.

The native synthesis configuration audit passes on r2's generated script and
properties: `PerformanceOptimized`, `GLOBAL_RETIMING=on`, rebuilt hierarchy,
one thread, timing-driven synthesis, disabled IP cache and no incremental or
pre-synthesis checkpoint input. This verifies configuration, not completion.

At **19:16 EDT Oct18**, native area optimization had finished at cumulative
**26 min 01 s wall / 25 min 38 s CPU**; XDC timing application finished at
**26 min 20 s wall / 25 min 57 s CPU**. Timing optimization then started.
No synthesis completion, retiming-transformation count or routed result is
claimed from this phase transition.

At **20:29 EDT Oct18**, native timing optimization finished at cumulative
**1 h 39 min 38 s wall / 1 h 38 min 54 s CPU**, and synthesis entered
**Technology Mapping**. The existing helper resumed CPU activity within the
same Vivado family. All **214 source/tool pins** were independently rehashed
unchanged at this transition. The fixed **20 GiB RAM / 6 GiB swap / 48-task**
profile remains active, with no OOM or task-limit events. This is the stage
where r1 reached its smaller combined-memory guard; r2's mapping completion,
retiming-transform count, utilization and clock-pair timing remain unverified.

At **19:26 EDT**, two closed Oct16 diagnostic `branch/` trace directories were
archived and their expanded copies removed after `tar -dzf` byte comparisons
and open-file checks. The parent failed-run summaries remain in place; all
traces, receipts and generated fixtures are recoverable. Inode/link accounting
gives a conservative **715,501,568-byte (682.36 MiB) net gain** after archive
costs, excluding externally hard-linked copies and Vivado's independent scratch
release. No source, simulator model, FPGA product or live pinned input was
removed. Exact targets, archive hashes and recovery instructions are retained in
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/closed-branch-evidence-oct18.md`.
All **214 live input/tool pins** were independently rehashed unchanged before
and after cleanup. The active synthesis continued without OOM or task-limit events;
40 MHz timing closure and candidate gameplay measurement remain pending.

- `prepared.json` SHA256: `57ae9fb2d1132574cc8cb7a7d65ee6dd4371840c439709b98c56bb3b90460831`
- `started.json` SHA256: `c2ad6f6185861ea38801c20967e75dd73ba37a4be41e028603ccd1b9a336a45a`

### Retiming-r2 controlled memory stop

At the **20:39 EDT Oct18** closure audit, the owner was terminal with MainPID 0,
the Vivado scope was inactive, and no Vivado process remained. Native exit was
**124**, reason **`combined memory early stop`**, after **6,624.152 s
(1 h 50 min 24 s)**. All **214 source/tool pins** were independently rehashed
unchanged after termination, before any subsequent tooling changes.

The largest simultaneous sample was **26,941,095,936 bytes (25.09 GiB)**:
21,473,136,640 bytes RAM plus 5,467,959,296 bytes swap, crossing the fixed
26,843,545,600-byte early-stop threshold. Host available RAM was still
5,028,052,992 bytes and free disk 6,220,402,688 bytes. OOM/OOM-kill and task-limit
event counters stayed **zero**. The 1,058 `memory.events max` events indicate
reclaim at the configured RAM cap, not OOM. Peak sampled tasks were 34 of 48.

The larger envelope allowed mapping to exceed r1's 21 GiB limit but still did
not complete synthesis. No retiming transformation count, final utilization,
clock-pair timing, APR result or hardware acceptance is available. The independent
result audit correctly rejects this receipt as `native/resource failure`.
Neither this attempt nor r1 establishes that retiming improves or worsens fmax.

- `closed.json` SHA256: `b5a82a277f2a8f4b712ceba791288649ce12dcd2378b14cdfdbcc821dc4d8575`
- Native log SHA256: `2db639be1acffbf0dfb8e08042fb67a3034ace70d9756da2bc07e1bcfe5d62b4`

The closed mapping cache was recoverably archived and removed at **20:44 EDT**:
only `synth_1/.Xil/Vivado-3325673-AL-MS790S-U26` under this r2 project was
removed, after open-file checks and `tar -dzf` byte comparison. All files were
private single-link files; no symlinks were present. Expanded allocation
2,105,692,160 bytes became a 302,022,656-byte archive: **1,803,669,504 bytes
(1.68 GiB) net reclaimed**. All 200 frozen source hashes and native/closure
hashes remained unchanged. `performance-retime-r2/closed-mapping-scratch.md`
records recovery; archive SHA256 is
`6e72c8d7250f77cf00ddc6cad6c0556dfd5ee16599ccba90d19c9fc9d050f127`.
It is forensic storage, never an input to the next fresh build.

### Next combination: performance synthesis and bounded physical operations

`performance-bounded` explicitly sets `GLOBAL_RETIMING=off`, keeps timing-driven
`PerformanceOptimized` synthesis and rebuilt hierarchy, and combines them with
`RuntimeOptimized` logical optimization, `AltSpreadLogic_medium` placement,
the exact bounded pre/post-route physical operations above, and
`NoTimingRelaxation` routing. Core/AXI constraints remain **25 ns / 10 ns**.

Rationale: the earlier non-retimed performance synthesis completed, whereas both
retiming-enabled attempts exhausted their guarded mapping envelopes. Earlier
unbounded Explore physical passes consumed the APR deadline before routing.
This new combination is intended to obtain a complete routed comparison under
the same **20/6 GiB** envelope; it does not establish that retiming alone caused
the memory increase or that the new combination meets 40 MHz. CPU/cache RTL,
defines, UV-fast mode, incremental/cache prohibitions, deadlines and resource
reserves are unchanged. No result or hardware acceptance is claimed yet.

The launcher, native-command audit and independent final audit recognize the
new strategy. Tests require explicit native/property `off` agreement and the
same exact bounded physical commands; omitted/changed/duplicate policy, added
directives, repeated passes and missing hold repair are rejected. **37 flow/audit
tests and 22 exclusive-launcher tests pass** (59 total), plus shell syntax and
diff-whitespace checks. These are tooling tests, not CPU acceptance.

The fresh native retiming-off probe completed **20:43:09–20:47:33 EDT Oct18**,
owner exit 0, with native status `phys_opt_design (Post-Route) Complete!` and
`FRESH-BOUNDED-NATIVE-OK retiming=off`. Its actual synthesis command explicitly
contains `-global_retiming off`; independent inspection accepted the exact
bounded pre/post-route commands and run properties. Both native stages have
completion markers, no error markers, and all four source/tool hashes remained
unchanged. The probe's owner/scope are inactive; no Vivado process remains.
This tiny circuit proves configuration support only, not CPU correctness,
full-core runtime, or 40 MHz timing closure.

- Artifacts: `/home/yukidama/external/tmp/ventium-native-bounded-off-oct18.17YslRAE/`.
- Owner `ventium-fresh-bounded-off-probe-oct18-r1.service`, invocation
  `7eb597d2f5b64b3bb2fc485559d99494`; scope invocation
  `def34e21ad2e4d309bdb107a303c3cca`.
- Read-back limits: 4 GiB RAM / 1 GiB swap / 48 tasks, one thread and one job.
- Native log SHA256:
  `5e7f18dc4b942f40b3834badc1a847a5835418141b2e3e4133acfcce51e4ce56`.
- Probe Tcl SHA256:
  `963a110532e7ea407ecb2035764f9578a85f25b00d8f47bcf96079a8fadf8d70`.

Full **`performance-bounded-r1`** started at **20:48:55 EDT Oct18**, using
tooling commit `a87dac2f` (probe/closure documentation `e8b812c9`, both pushed).
The owner is `ventium-fresh-bounded-oct18-r1.service`, invocation
`468e67477808475288f6ede0e0bbd5c1`, PID 3351330. Actual Vivado scope invocation
`c2233179446c4682944fd147493a1686` read back **20 GiB RAM / 6 GiB swap /
48 tasks**, `MemoryHigh=infinity`; one internal thread and `-jobs 1`.
The native synthesis command and run-property audit confirm explicit
`-global_retiming off`, `PerformanceOptimized`, rebuilt hierarchy,
incremental checkpoint reuse disabled, and the IP synthesis cache disabled.
There are no previous-checkpoint inputs. All **214 input/tool pins** were
independently rehashed unchanged after launch; the 200-file source closure and
159 defines are the same frozen CPU/profile described above.

Admission evidence: external ext4 mounted read/write, available host RAM
26,439,180,288 bytes, free swap 29,674,745,856 bytes, free disk after source
preparation 7,972,454,400 bytes. At the 20:50 EDT check synthesis was active,
with no OOM/task-limit events or swap use. This is launch/configuration evidence,
not a completed synthesis, routed timing, or physical acceptance result.

- `started.json` SHA256: `38889dedde18918e21d0be8955b1e8a959d1de83a04e0193515be68ed0984cf7`
- `prepared.json` SHA256: `57ae9fb2d1132574cc8cb7a7d65ee6dd4371840c439709b98c56bb3b90460831`

At **21:15 EDT**, this same run finished cross-boundary/area optimization at
cumulative native **24 min 49 s wall / 24 min 28 s CPU**, applied timing
constraints by **25 min 09 s wall**, and entered timing optimization. All
**214 input/tool pins** were rehashed unchanged after the transition. The latest
sample charged 9,988,681,728 bytes RAM, zero swap, with zero OOM/OOM-kill or
task-limit events across 320 samples. Peak sampled tasks were 27 of 48. This is
still live synthesis: there is no final netlist, utilization, clock-pair timing,
routed result, or new gameplay measurement yet.

At **21:24 EDT**, the same timing-optimization worker remained active. Its
helper processes were traced to this exact synthesis directory and guarded
scope, not orphan runs. Charged RAM was 16,335,585,280 bytes, swap zero, and
OOM/task-limit counters zero. To maintain disk headroom, only the closed
`integer/` cases of `raw-prime-storage-core-checks-r1` and
`prime-width-core-checks-r1` were recoverably archived and their expanded copies
removed. Both failed parent diagnostic summaries remain unchanged; these are
not acceptance passes. Archive byte comparisons and repeated open-file checks
preceded removal. Conservative net reclamation is **303,616,000 bytes
(289.55 MiB)**, excluding externally hard-linked files. All **214 live pins**
were independently rehashed unchanged afterward. Exact archive/parent hashes,
targets and recovery instructions are in
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/closed-integer-evidence-oct18.md`.

At the **22:29 EDT Oct18** observation, native timing optimization had finished
at cumulative **1 h 38 min 50 s wall / 1 h 38 min 08 s CPU**, and synthesis had
entered **Technology Mapping**. The same owner/scope remained active; all
**214 input/tool pins** were independently rehashed unchanged at 22:30 EDT.
The transition sample charged **18,460,688,384 bytes RAM**, zero swap, with
zero OOM/OOM-kill or task-limit events; free disk was 6,062,649,344 bytes.
The existing 20/6 GiB limits and 25 GiB combined early-stop threshold remain
unchanged. Mapping completion, final utilization, all clock-pair timing and
routed 40 MHz closure remain pending. Finishing the timing-optimization
algorithm is not evidence that the clock target is met; there is still no
candidate gameplay IPC or physical standard-suite acceptance.

At **22:58:57 EDT Oct18**, the native synthesis stage completed successfully;
its completion marker, finished child log and new synthesis checkpoint are
present. `synth_design` took **2 h 08 min 15 s wall / 2 h 01 min 40 s CPU**,
with **zero errors and zero critical warnings**. Technology mapping finished
at cumulative **2 h 05 min 25 s wall / 1 h 58 min 49 s CPU**. All **214 pins**
were independently rehashed unchanged at **22:59:54 EDT**.

Synthesized utilization is **186,064 LUTs (54.52%), 54,917 FFs, 277.5 BRAM
tiles and 47 DSPs**, matching the earlier performance-r4 control. The native
design checksum also matches (`b06dfdfa`); this text-report consistency is not
formal equivalence or a timing result. No old checkpoint was opened for the
comparison. Peak sampled simultaneous charged memory through this stage was
**19,757,408,256 bytes (18.4005 GiB)**, with zero swap, OOM/OOM-kill and task-limit
events. This run completed mapping inside the fixed resource envelope, unlike
the retiming-enabled trials; it does not prove a retiming-only causal explanation.

The owning project reopened **only its own newly generated synthesis output**
and reported `clk_pl_0=10.000 ns`, `mmcm_fb=10.000 ns`, and
`mmcm_clk=25.000 ns` at **23:00 EDT**. Pre-APR timing/utilization reports are
complete, with `FRESH-SYNTH-CLOCKS-OK core=40MHz AXI=100MHz` before the
implementation launch. Neither clock presence nor synthesis completion proves
routed 40 MHz closure or physical acceptance.

The **unplaced** timing report matches the performance-r4 control:

| Clock pair | Setup slack (ns) | Hold slack (ns) |
|---|---:|---:|
| Core → core | −1.011 | −0.101 |
| AXI → AXI | +6.785 | −0.108 |
| Core → AXI | +3.415 | −0.243 |
| AXI → core | +3.814 | −0.455 |

The ordinary 25 ns core path again runs from `q_pc_reg[0]` to FPU
`status_reg[10]`, with 90 logic levels and estimated delay 25.800 ns
(5.882 ns logic / 19.918 ns routing). Its conditional **unplaced estimate is
38.445273 MHz**, not routed fmax or a lower clock target. Setup and hold are
not yet closed. There are zero unconstrained internal endpoints, but eight
`no_clock` findings and four missing output delays still require the final
pin/output-level coverage review; clock presence does not waive them.

The recorded **APR start is 23:01:24 EDT Oct18** (native launch 23:01:28),
so the unchanged 3 h 50 min implementation deadline is **02:51:24 EDT Oct19**.
Native worker **3367708** is active in the same owner/scope. Independent
configuration inspection accepts spread placement and the exact bounded
pre/post-route physical operations; it does not claim those stages completed.
The only DCP added by the generated implementation script is this trial's new
synthesis output. No earlier trial's checkpoint is a build input. Routing,
final timing/CDC/bus-skew/coverage audits and physical acceptance remain pending.

Stable synthesis-stage evidence, under `build/rk_ao486_system/rk_ao486_system.runs/synth_1/`:

- `runme.log` SHA256: `a95a2e5a43a47fe34ef151abca970b3983b02bb416b9bb954921e7eb38bebfa7`
- `rk_ao486_bd_wrapper_utilization_synth.rpt` SHA256: `919e34fefa736ba137fa62e44b60356f1ce89b3fc4268c93df6965cc6f6524aa`
- New output `rk_ao486_bd_wrapper.dcp` SHA256: `41864c844865ec4aef4b3b5213319538bfddac2185f55925a050ce00e6813548`

Owning-project pre-APR evidence under `build/`:

- `synth-clocks.tsv` SHA256: `870f414ded70ac63dedb4a92d89b654237dac82f156e7bcb5871f0e452f55d81`
- `synth-timing.rpt` SHA256: `b99c536e9b749266b9abe73c386c325b913d47c2bdef039b2f3f492ef45cdb2c`
- `synth-utilization.rpt` SHA256: `6c76a0f3c544ed4c8ec8fb5ce3f67d08d65569c7c4289d4728a46133dedbaeec`

### Bounded trial: completed placement

At **23:56 EDT Oct18**, `place_design` completed successfully in **52 min
23 s wall / 52 min 18 s CPU**, with zero errors and zero critical warnings.
This is **49.34% less placement time** than performance-r4's 1 h 43 min 24 s;
it is not a whole-flow speedup or routed timing result. The placed design has
**185,011 LUTs, 55,179 FFs and 32,271 occupied CLBs (75.65%)**, compared with
34,029 CLBs (79.77%) in performance-r4: **5.17% fewer occupied CLBs**.
Its estimated post-placement WNS is **−1.385 ns**. The native placer summary
does not identify that path's clock pair, so no core fmax is inferred from it.
The implemented clock target remains 40 MHz; final routed frequency is pending.

Estimated congestion regions are still substantial: north/east global 32×32,
south/west global 16×16; long north/south/east 32×32 and west 8×8; short
north/south 16×16 and east/west 32×32. Lower CLB occupancy alone therefore
does not establish that routing congestion or timing is solved.

The native script has now executed the intended command
`phys_opt_design -fanout_opt -placement_opt -restruct_opt -equ_drivers_opt`.
This is its start, not its completion. All **214 source/tool pins** were
rehashed unchanged after placement, and independent native-script/property
inspection again accepted the exact pre/post-route operation sets. The same
owner/scope and 02:51:24 EDT implementation deadline remain in force. There
have been no OOM or task-cap events; some swap is now charged. The candidate
still has no gameplay IPC or physical acceptance.

Stable placed utilization evidence:
`build/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_utilization_placed.rpt`,
SHA256 `e6da354604dae83b9f71b9659ccd03ada468317d999f7db860ada6a6e0063771`.

### Bounded trial: native checkpoint-writer crash, Oct19

The run **closed unsuccessfully at 00:55 EDT Oct19**, native parent exit 1,
after **14,784.939 s (4 h 06 min 24.9 s)** total. Native implementation ended
at **00:55:14**, approximately 1 h 53 min 50 s after its recorded start.
This was **not the deadline or a resource-guard stop**: `closed.json` has
`reason=null`; all 2,952 resource samples have no stop reason, zero OOM/OOM-kill
and zero task-cap rejections. Peak simultaneous charged RAM+swap was
19,757,408,256 bytes; minimum sampled free disk was 5,577,216,000 bytes.
All **214 pins** were independently rehashed unchanged after closure.
The service is failed, its Vivado scope is inactive and no Vivado process
remains. The earlier 01:45–02:45 completion estimate is superseded by this
terminal failure; it was an estimate, not a completed or accepted result.

`phys_opt_design` itself reported success in **57 min 50 s wall / 57 min
48 s CPU**, with zero errors and zero critical warnings for that command.
The completed physical-synthesis task's cumulative stamps yield:

| Completed operation | Elapsed between phase stamps | Estimated WNS before → after (ns) | Estimated TNS after (ns) | Native phase detail |
|---|---:|---:|---:|---|
| Fanout | 12m03s | −1.385 → −1.376 | −2774.219 | 13 nets; 25 new instances |
| Single-cell placement | 9m52s | −1.376 → −1.339 | −2718.507 | 39 nets; 39 moved instances |
| Multi-cell placement | 10m04s | −1.339 → −1.306 | −3122.468 | 40 nets; 82 moved instances |
| LUT restructuring | 19m21s | −1.306 → −1.291 | −2259.781 | 61 nets; phase detail reports 61 removed instances |
| Equivalent-driver rewiring | 3m53s | −1.291 → −1.291 | −2242.315 | 141 nets; 27 deleted cells |

These elapsed differences include per-phase sorting overhead; the native
aggregate table separately reports 55m08s of optimization work. That table
counts zero removed cells for LUT restructuring despite the phase detail
reporting 61; do not reconcile those two counters into an invented total.
Overall estimated WNS improved only **0.094 ns**. These are pre-route global
estimates without a worst-path clock-pair attribution, **not routed core fmax**.

The generated native script next calls
`write_checkpoint -force rk_ao486_bd_wrapper_physopt.dcp`. After
`Write ShapeDB Complete`, worker 3367708 received **SIGSEGV (11)**. The retained
stack is in `libxv_constraints.so`, including
`NetlistNameCache::getStoredName`, `HDPLPlaceDBImpl::SiteContents::writeToFile`,
then `DcpWriter::exportXdef`. This localizes the observed failure to placement
database/checkpoint serialization. It does **not** establish which preceding
optimization created the bad state, nor that the netlist is functionally valid.
Routing never started (`stages.tsv` contains only synthesis and implementation).
There is no new bitstream, routed frequency, 40 MHz sign-off or physical pass.

Closed evidence in `performance-bounded-r1/`:

- `closed.json`: `e52022441ff28ddd01b238703fe967054a2be51c92d45d0dad013e2dcdc795b0`.
- `native.log`: `51faa99c0c39e961f1d360c7767d88a6dd7c1517fcf5d7c47b36cf8daf8c3be0`.
- `build/rk_ao486_system/rk_ao486_system.runs/impl_1/hs_err_pid3367708.log`:
  `7557b765c93aabd43ac170d47fc8b1f82279134d9def49c14c4dbc7c3fa91ef9`.

Next strategy decision: do **not** repeat this exact physical-operation mix
or bypass checkpoint writing to conceal the failure. A fresh source-only
route-first control can retain the successful performance synthesis/spread
placement, omit optional pre/post-route physical optimization, and retain
the 40/100 MHz constraints, final checkpoint and full timing/legality reports.
Its purpose is to obtain an actual routed comparison, not to redefine success
below 40 MHz. Separately validate a stage-specific thread policy (serial
synthesis, parallel APR) before the next full launch; retain one Vivado family,
fixed RAM/swap limits and independently audited native commands. Neither change
has been implemented or launched at this entry. No old checkpoint is authorized
as the next trial's input.

### Route-first implementation and native probe, Oct19

The decision above is now implemented as `performance-route-first`. It keeps
`PerformanceOptimized` synthesis, rebuilt hierarchy, explicit global retiming
**off**, `RuntimeOptimized` logic optimization, `AltSpreadLogic_medium`
placement and `NoTimingRelaxation` routing. Both optional physical-optimization
steps are disabled, with their extra options cleared. Checkpoint export,
bitstream generation, and all final timing/coverage/CDC/skew/DRC reports remain
enabled. No constraint, RTL or source-closure change accompanies this strategy.
The checkpoint crash is not caught or treated as success.

The full-run contract is **one synthesis thread, four APR threads, `-jobs 1`**,
one Vivado family, the named `serial_apr4` **128-task** profile, and the existing
`serial20` **20 GiB RAM / 6 GiB swap** envelope. The 25 GiB combined early stop,
host/disk reserves, 3 h 50 min whole-APR bound and 8 h whole-run bound remain.
Four threads are a maximum for supported APR work, not a promised fourfold
speedup. Synthesis stays serial because prior parallel mapping exceeded the
memory budget. Each newly emitted receipt records synthesis and APR thread
counts separately, and both generated native scripts are audited. Old equal-
thread receipts retain their original interpretation.

**76 host-only tooling tests pass:** 42 fresh-flow/source/audit tests, 11 APR
timing-parser tests and 23 resource-scope tests. Negative cases cover mismatched
stage counts (including booleans/string/float values), wrong task/memory caps,
missing completion evidence, native optional physical commands (including a
bare `phys_opt_design`), enabled stage properties, old checkpoint inputs and
unknown/unbounded policies. Shell syntax and scoped `git diff --check` pass.
These tests are not CPU, full-design timing or physical acceptance.

A tiny **fresh-source** native probe was launched at **01:05:53 EDT Oct19**:

- Artifact root: `/home/yukidama/external/tmp/ventium-native-route-first-oct19.4fA3m1kB`.
- Owner: `ventium-fresh-route-first-probe-oct19-r1.service`, invocation
  `05f2c4672e5f4145aafeb9f8f4360c64`.
- Scope invocation: `ff9bbd7b30fc47849f79b40056f90ef8`; actual limits checked:
  **4 GiB RAM / 1 GiB swap / 128 tasks**; timeout ten minutes.
- Probe Tcl SHA256:
  `4ab568f453d444df34f7d4d36e481d3a32d7aca74efd8bc81c7ce5d3f75160d8`.
- Shared route-first helper SHA256:
  `4a3fac932b1cd25bf9f0e65c11c73c96ac0c3e7b8229aeb3b357bb0e73b7afc0`.

The probe **passed at 01:08:50 EDT**, owner exit zero after **2 min 57 s**.
Native synthesis reports a maximum of **one process**, placement and routing
each report a maximum of **four CPUs**. Both native scripts and the independent
implementation auditor agree. The native `route_design Complete!` status,
success log, run/stage end markers and routed checkpoint are present. The probe
and shared helper/launcher/scope hashes remained unchanged. The scope is now
inactive and no Vivado process remains.

No optional `phys_opt_design` command is emitted. The placer's own internal
optimization still prints a `Physopt` multithreading message; that is not an
enabled standalone pre/post-route stage and is not suppressed. Sampled scope
events showed no OOM or task-limit denial; RAM reached the 4 GiB cap with reclaim
events. The short-lived scope's final counters disappeared on exit, so these
samples are not a complete peak-memory or final-event audit.

- Final native log SHA256:
  `589cf49b38519ff5e38bde4b9c791152d84c8e106dbfd42fbf88bda700e9567a`.
- Generated routed probe DCP SHA256:
  `37570367463fcd1ebaf9d28cf031fda4ebc4845a3631973175d8074e59c720dd`.

This proves native synthesis=1, APR=4, disabled optional physical passes and
successful routing/checkpoint serialization **for the tiny fixture only**.
It does not prove that the full design's crash is repaired. It uses its own
new synthesis output only; no old project/netlist/checkpoint/IP cache. It does
not generate an unpinned-I/O bitstream or qualify full-core timing. At this
entry the full route-first trial has **not launched**.

### Fresh route-first full trial launched, Oct19 01:10 EDT

Tooling/native-probe evidence was committed and pushed as **`1e3f851c`** before
launch. The new trial `performance-route-first-r1` started **01:10:30 EDT Oct19**
from a new source copy/project, not a checkpoint from the crashed run or probe:

- Owner `ventium-fresh-route-first-oct19-r1.service`, invocation
  `aaa4a70348b541a0ab27e30b01a8fb71`, controller PID **3391464**.
- Vivado scope invocation `271089ef2c8d423abe26e15fbd438063`; native parent
  PID **3393914** (its shell launcher is in the same family).
- Actual scope readback: **20 GiB RAM / 6 GiB swap / 128 tasks**.
- Launch receipt records **synthesis=1 / APR=4**, `serial_apr4`, `serial20`,
  25 GiB combined early stop, 13,800 s whole-APR and 28,800 s whole-run bounds.
- Admission: **26,597,117,952 bytes MemAvailable**, **29,563,265,024 bytes
  SwapFree**; after freezing sources, **7,777,882,112 bytes free disk**.
- **200 source/metadata files, 159 defines, 215 total source/tool pins**.
  All pins were independently rechecked unchanged after launch.
  Only `ven_pll_ctrl.sv` differs from the pinned source ancestor; the wrapper
  already matches. CPU/cache RTL is unchanged from the deployed source profile,
  not taken from the dirty checkout.
- The native source checks report 40 MHz MMCM, UV-fast hardwiring, relocated
  load/store and pipelined FP. This is configuration evidence, not execution
  or physical acceptance; generated worker commands still need stage-by-stage
  checks when those workers are created.
- `started.json` SHA256:
  `467271c5e5aa3767b47eb13bc82f1f65549a3f61ecaa8f0b78d2cbeb1863f919`.
- `prepared.json` SHA256:
  `57ae9fb2d1132574cc8cb7a7d65ee6dd4371840c439709b98c56bb3b90460831`.

Artifacts are under
`/home/yukidama/external/tmp/ventium-fresh-strategies-oct17.67YRDIRh/performance-route-first-r1/`.
Its controller monitors the actual resource scope every five seconds and
owner-checks any safety stop. Do not launch another Vivado while it is active.
No live source/tool pins may be edited. The **40 MHz timing objective remains
unproven**, and this candidate has no gameplay IPC or physical standard-suite
acceptance. The older deployed gameplay baseline remains **0.496500 U+V**,
`2886d24c`, cycles **625,021,130,428–629,480,208,865**.

### Runtime accounting at 23:56 EDT Oct18

The nine closed fresh-trial receipts sum to **85,701.723 s (23 h 48 min
21.7 s)** of run elapsed time, excluding the live bounded trial (about 3 h
7 min), probes and gaps between runs. This is not one 20-hour routing job.

| Closed attempts | Combined elapsed | Outcome |
|---|---:|---|
| performance-r4 + routability-r4 | 13 h 12 min 37 s | Both exhausted the APR deadline during pre-route physical optimization |
| performance-retime-r1/r2 | 3 h 40 min 44 s | Mapping stopped at combined-memory guards |
| routability-r2/r3 | 4 h 35 min 10 s | Mapping stall with task-limit events, then memory guard on retry |
| performance-r1/r2/r3 | 2 h 19 min 52 s | Launcher/reporting defects, including an invalid post-synthesis clock-reporting context |

The defects and repeated long Explore passes were avoidable workflow costs,
not evidence that this design intrinsically requires that cumulative runtime.
One internal thread also trades throughput for memory containment; the
single-Vivado-family rule does not itself require single-threaded APR.
The current trial already removes the repeated Explore passes and explicit
synthesis retiming. It must reach routing before its timing benefit can be
judged. No live inputs, resource settings or clock constraints were changed
in response to the runtime review.

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

A more targeted **future fresh-run experiment**, if the active routability
trial also exhausts APR time, is:

```tcl
phys_opt_design -fanout_opt -placement_opt -restruct_opt -equ_drivers_opt
```

The same AMD reference states that explicit options replace the default pass
selection and cannot be combined with `-directive`. This deliberately omits
critical-cell replication while retaining fanout, placement, LUT restructuring
and equivalent-driver rewiring. It also omits other defaults, including
DSP/BRAM register optimization; this is a tradeoff, not an equivalent preset.
Any implementation must clear the directive, audit the actual native command
and completed phases, and compare routed timing under the unchanged 25 ns
constraint and APR deadline. No runtime or fmax gain is established. This
alternative is **not implemented or queued**, and the active run is unchanged.

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
