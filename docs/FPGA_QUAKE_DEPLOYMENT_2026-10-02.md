# RK FPGA Quake deployment — October 2, 2026

## Current status (2026-10-03 02:01 UTC)

Administrator access and the boot-time DDR reservation work. The board remains
held in reset on the historical image. At the user's request, a new **40 MHz**
current-source image has completed synthesis; no new bitstream is deployed yet.
The original run was stopped after read-only debugger evidence identified a
deadlocked vendor helper. A replacement with the same frozen RTL/defines is
closed with native exit **0** under the corrected fixed task cap. Read-only
checkpoint inspection also closed with exit **0**. Implementation launched
from that same completed project at 00:29 UTC, **without RTL resynthesis**.
Placement completed in 29m10s and pre-route physical optimization in 17m42s,
but routing **failed** with `Route 35-3` / `Route 35-4445`. The implementation
runner closed with actual native exit **1**, observed at 01:37:35 UTC. There
is no new bitstream. This was congestion, **not an OOM**: the last retained
resource observations have zero memory/task-limit events and zero build swap.
Placed occupancy is 65.73% LUT / 89.11% CLB; regional routing demand reaches
158.487% north and 135.603% south, with 1,153,331 overlapping nodes in the
failed live router. A separate report-only inspection of its error checkpoint
closed with native exit **0**; this proves report completion, not a valid route.
The completed synthesis and failed-run checkpoints are retained. A separate
congestion-focused run, **`impl_area_cong2`**, launched at **02:00:14 UTC**
from the same synthesis checkpoint and is live. It changes only the
implementation-stage area optimization and router directives, not the RTL,
defines or cache geometry. Preliminary timing is also severely
negative: the constrained
40 MHz target is not yet a demonstrated operating frequency or timing pass.
The first daemon's SIGBUS has an instruction-level cause (`DC ZVA` on Device
memory), and an isolated scalar-access successor is built and microtested,
and staged on the board. Its control-only `--ident` probe exits zero; DDR
initialization and cold guest startup are not yet qualified. No FPGA
timedemo/movie is accepted.

Verified **simulation** gameplay IPC is **0.42633263**, model
`5c2491f3b2eb73243e47cb614ae6d2e36012eb36f4f402e32fa3e9da27290033`,
clocks **7,099,999,637–7,199,999,637**. This predates the FPGA candidate;
no FPGA gameplay IPC is measured.

A key-only, read-only board-availability receipt from **22:02 UTC** is
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/board-availability-audit/BOARD_AVAILABILITY_2026-10-02T220221Z.md`,
SHA `6857a4865b9dd32e053d918671c0287de4ca20bf6b7f61e1f4a954b0b96e36a6`.
It records manager state `operating`, the same boot ID, 374 MiB free on the
shared root/tmp filesystem, and matching hashes for the staged device-safe
daemon, widened probe, and cold disk. At **22:07 UTC**, root separately
rechecked the root IOMEM view, with no guest running. At **22:19 UTC**, root
also read the live DT node `reserved-memory/guest-ram@60000000`: its 16-byte
`reg` selects base `0x60000000`, size `0x10000000`, and its zero-length
`no-map` property exists. The unchanged boot ID and root IOMEM independently
show `[0x60000000, 0x70000000)` reserved outside System RAM. These are readiness facts
only; they neither identify a newly programmed bitstream nor qualify its clock
or performance.

## Fresh 40 MHz build

The frozen source snapshot and original preserved output are under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-vco1g.3vpbYB/`.
The replacement synthesis/implementation output is under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-task48-retry.5ZayIg/`;
it reads the original frozen source paths, not today's dirty worktree.
Its frozen-input manifest SHA is
`adfb6ff13531761637599ec837527a788483706413b78735666023460f121c1c`:
179 explicit source/evidence files, the verified simulator's exact 107 defines,
plus only `SYNTHESIS`, `VTM_NO_DPI`, and `VEN_ALTSYNCRAM_XPM` for hardware.
The legacy FPGA default missed 79 verified defines and added three unverified
uop-cache defines; it is not used. Full P5 caches remain selected.
Common RTL/source pins were checked unchanged from the accepted 5c build.
The host resource guard is intentionally updated, not an RTL/profile change.

The new clock is a real MMCM derivative of PL0: **100 MHz × 10 / 25 = 40 MHz**,
with a 1 GHz VCO and output gated until LOCKED. Its source SHA is
`7d156871987abc06ee09412016ddb305d6551d6adf4a19e4159e131179d041aa`.
Genuine AMD Unisim simulation checked startup gating and 200 exact 25 ns
periods (actual exit 0, 0.13 seconds). The initial M8/D20 prototype was
superseded because the modeled PL0 rate of 99,999,001 Hz put its VCO slightly
below the 800 MHz minimum. The new VCO is safely inside range. This is not
routed timing or a silicon-clock measurement.

The external PL top now feeds its actual `CLK_HZ` to PIT/RTC/VGA; accelerated
4 MHz/80 kHz/90 MHz simulation defaults are not copied into physical hardware.
The hosted PS/2 sender scales its existing timing with that same parameter,
using 64-bit arithmetic and appropriately sized counters. Ordinary-pin tests
checked both legacy and 40 MHz profiles: 12 frames, 132 bits, phase lengths,
byte order, framing/parity and prelaunch host inhibition. These are narrow
tests, not full keyboard/controller acceptance. No arbitration fixes added.

The template PS preset produced catalog validation errors. The preliminary
run was explicitly stopped (actual outer exit 143), and the documented
**PCAP-only, preset-free** flow is now used: booted Linux keeps PS DDR/MIO
configuration; PL overrides retain 100 MHz PL0 and native 128-bit HP0 with
the explicit 64-to-128-bit converter. The final BD validated at 40 MHz,
and HP0 remained 128 bits after propagation.

Synthesis started at 20:11 UTC, `balanced` profile (Default synthesis), one
run job/internal worker. Scope invocation is
`1e9b119f6c8744988529c6382906ac20`; initial limits were 8 GiB memory,
2 GiB swap and 32 tasks. Timing optimization grew beyond that working set.
After repeated actual host-headroom checks, the **same invocation** was
extended to 9 GiB (soft limit 8 GiB), then 11 GiB (soft 10 GiB), and finally
13 GiB hard / 12 GiB soft, then 14 GiB hard / 13 GiB soft,
retaining 2 GiB swap, 32 tasks and one run.
At 20:31:29 it used 12.37 GiB; swap was full and the soft limit was throttling
it. Host available memory was about 3.1 GiB. No memory-max/OOM/kill event was
recorded; one task-cap event occurred without a corresponding tool error.
This is resource pressure, not useful completion evidence or permission to
expand indefinitely. The user then authorized terminating Chrome; by the
actual process check it had already exited, so no signals were sent.
With 7.5 GiB host-available memory, the same scope was extended to
**18 GiB hard / 17 GiB soft**, still bounded by the reviewed 20 GiB ceiling.
At 20:35:07 memory was 14.927 GiB, anonymous memory 13.357 GiB and host
available memory 7.650 GiB. Pressure stopped accumulating and synthesis
recovered to approximately one productive CPU core. No OOM/max/kill event
occurred. The independent resource/source audit is under
`vivado-resource-watch.rryo52rB/resource-watch.json` in the task directory.
Chrome restarted at 21:02:45, reducing host headroom to roughly 4.4 GiB.
Under the user's explicit instruction, root verified the browser main PID's
UID and exact `/opt/google/chrome/chrome` executable, then sent it SIGTERM.
At 21:03:48 browser processes were gone and headroom was 8.4 GiB. Unrelated
applications and tiny old crash-report helpers were left alone. At 21:07:29
the same Vivado invocation used 15.146 GiB with 8.615 GiB host headroom;
worker CPU remained productive and no new limit/OOM/pressure event appeared.
At that original-run checkpoint, preliminary runs were gone and routing had
not started. Those process-progress observations were not a synthesis/timing pass.
Inspect area before implementation; then check routed DRC/setup/hold and
clock reports, hash/program the artifact, measure silicon MHz, and run the
unmodified cold timedemo with the matching widened capture tool.

### Completed replacement synthesis and implementation milestones (October 3)

The corrected replacement finished at **00:23:56 UTC**, native session 74097,
exit **0**, reporting `SYNTH OK` / `DONE` and 2h26m elapsed. At 00:24:17 root
observed the scope inactive and no remaining Vivado executable family. All 179
frozen-input hashes were rechecked successfully. The generated synthesized
checkpoint is `output/rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.dcp`
under the replacement directory, SHA
`43cfcc3146f07bb7021a5a46978ce0ab4be6a165d820da5f4f6773988c53910c`.

Inspection ran separately, after closure, under the same exclusive launcher
and a 540-second outer bound. Native session 95691 exited **0** at 00:26:56,
with `synth_1 PROGRESS=100%`, `STATUS=synth_design Complete!`,
`NEEDS_REFRESH=0`, and nine reports. Reports and root's closure receipt are in
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/synth-inspection-oct03.2MjGyf5U/`.
The source, checkpoint and report hashes are recorded in
`ROOT_CLOSED_SYNTHESIS_INSPECTION_RECEIPT.json`; its completion flags deliberately
do not assert routed timing, hardware deployment, timedemo or movie acceptance.

The synthesized netlist uses **225,368 LUTs (66.04%)**, 58,958 registers,
**221 BRAM tiles (29.70%)**, and 127 DSPs (3.60%). The largest logic consumers
are the core: icache 88,737 LUTs and shared FP 72,452 LUTs. This is preliminary
fit evidence, not final placed utilization. The clock report confirms a
**40 MHz core / 100 MHz PS-AXI constraint**, not measured silicon frequency.

Timing is a substantial risk: pre-route WNS **−23.863 ns**, TNS
−491,471.562 ns, 70,291 failing setup endpoints; WHS **−0.108 ns**, 28,531
failing hold endpoints. The worst setup cone runs from `eip_reg[0]` through
instruction/control logic into the shared FPU SRT `result_q_reg[9]`: **195
logic levels**, 48.652 ns estimated data delay, including **37.846 ns unplaced
routing**. Placement may improve that routing estimate, but the long logic
cone must not be dismissed or called 40 MHz-ready. Wait for routed setup,
hold, CDC and bus-skew evidence before timing sign-off; no RTL/latency patch or
timing waiver was introduced to hide it.

Default `report_drc -no_waivers` reports no errors or critical warnings; all
513 findings are DSP pipelining/power warnings or advisories. `check_timing`
finds no unconstrained internal endpoints, loops, multiple clocks or detached
generated clocks. Eight unused PS EMIO clock outputs lack clocks and four LED
outputs lack I/O delays; five ignored false paths target nonexistent
synchronizer cells. These are retained findings, not waived clean reports.
Vivado also requests **`report_bus_skew`** because bus-skew constraints exist;
that report must be added to the closed-implementation inspection.

The prepared bus-skew-complete inspection helper is now
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/inspection-root-bus-skew.jeblFlLT/inspect_completed_impl.tcl`,
SHA `6b7f3c7dda3a83878c1945fb3162e4d2ce1aac741ea6c3287ed60ad3b776fb06`.
Root read the full helper and independently ran **120 Tcl stub cases** with
native exit **0** in 0.22 seconds, preserving all 119 previous cases and adding
failure of `report_bus_skew`. Its receipt is `clone_stub_audit_receipt.json`
in that leaf, SHA
`63a1260612e4ee6c1b59009cb313f5bce82457928c3aef2f41f1667e2e55b8fb`.
The helper retains the exact XPR/fresh-run/clock/full-route checks, read-only
project opening, protected output directories, unfiltered/no-waiver reports,
and native-close-before-completion-marker semantics. It adds only the raw
`report_bus_skew` report; no RTL, timing exception or regeneration was changed.
These are host-only control-flow tests, **not** native Vivado reporting or
timing/CDC acceptance. Run the real helper under the exclusive guard and a
540-second outer deadline **only after the implementation family has closed**;
require exit 0 and review the reports separately from its report-completion marker.

At approximately **01:02 UTC**, `place_design` completed successfully with
zero errors or critical warnings, CPU 29m05s / elapsed **29m10s**. The placed
checkpoint is `output/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_placed.dcp`
under the replacement output, 86,585,115 bytes, SHA
`a85bda9f8dca7e679abc2366e2cc0c0a729428e7e7fb4ad615e7ae7721fd21e0`.
Its native utilization report has SHA
`2f6ade7307f905365db23d02b0baaa45b84501dcba45a4f9d46ac130c393a0f4`:
**224,334 LUTs (65.73%)**, 59,009 registers, no latches, **38,013 CLBs
(89.11%)**. This is placed, not final routed utilization.

The placer reports **WNS −22.180 ns** and `Place 46-14`: the design is highly
congested and may be difficult to route. Estimated global congestion regions
are 32×32 in every direction; some long-congestion regions reach 64×64.
This warning increases the uncertainty of the earlier remaining-time estimate;
neither placement success nor continued CPU activity proves 40 MHz operation.
At 01:04 UTC the same live worker was executing **pre-route `phys_opt_design`**,
with no resource-limit events. Routing and bitstream generation remained pending.
For a later closed-run diagnostic, installed Vivado 2025.2 supports
`report_design_analysis -congestion -min_congestion_level 3 -file <fresh-path>`
on placed or routed designs. It is whole-design analysis (not scoped by
`-cells`); the default level 5 hides level-3/4 hotspots. Do not open another
Vivado against this active run, overwrite existing reports, or treat a
congestion report as route/timing/CDC acceptance.

Pre-route `phys_opt_design` subsequently completed successfully, with zero
errors or critical warnings, CPU **17m41s** / elapsed **17m42s**. Its checkpoint
was written at **01:20:53 UTC**:
`output/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_physopt.dcp`,
86,100,278 bytes, SHA
`f8f9bef610610f6ae1d94c761dfa6651933cfbb8eb538e1bf649eb7b9d6c88d6`.
The same worker then entered `route_design`; its precondition DRC reported
zero errors. By **01:26:50 UTC** it was still CPU-active in **Phase 4.1 Initial
Net Routing Pass**, using 7.19 GiB scope memory with zero swap and zero
memory/task-limit events. Root rechecked all 179 frozen-file hashes at
01:27 UTC; no resynthesis, source edit or replacement run was performed.

Routing's intermediate timing summary is **WNS −19.465 ns**. `Route 35-445`
reports local congestion/high pin utilization in at least **329 CLBs**, which
may affect runtime and timing closure. Initial unrouted/partially routed net
counts are expected before initial routing and are not a terminal tool failure.
Routing completion, final setup/hold/CDC/bus-skew review, bitstream generation,
deployment and physical 40 MHz qualification remained pending at that observation.

The then-live implementation native session was **66620**, scope invocation
`d4a69c016ef5448ab10a01a303a752ad`, outer PID 1814754 / implementation PID
1815196. It resumes the existing XPR with `VEN_FPGA_CORE_MHZ=40`, one run job
and one internal worker; no BD regeneration or resynthesis. Launcher logs/CWD
are `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/impl-current-oct03.MGgQvIXl/`.
The explicit launch RAM cap is **20 GiB**, runtime soft cap **19 GiB**, swap
**2 GiB**, fixed task cap **48**. The old mapping-only 8 GiB swap exception
ended with its closed scope and is **not** inherited by this phase.

At **00:32:34 UTC**, the same implementation reached **45 / 48 task slots**,
mostly sleeping vendor library threads. The generated implementation Tcl
explicitly retains `general.maxThreads=1` and `-jobs 1`; the thread count is not
45 useful CPUs or multiple top-level builds. Before another partial vendor
thread-pool failure, root extended **only the live `TasksMax` to 64** (native
property-command exit 0, readback 64, `pids.events.max=0` before and after).
RAM and swap caps remain 19/20/2 GiB. No source, active launcher or launch
environment was edited, and the future guard stays fixed at 48. The separate
`ROOT_LIVE_TASK_HEADROOM_RECEIPT.json` under the implementation CWD links the
unchanged closed-synthesis receipt and records this phase-local exception.

At 00:23 UTC, key-only board preflight separately confirmed the unchanged boot
ID, no guest/probe/capture process, 374 MiB free, matching staged daemon/VHD/ROM
hashes, and the exact 256 MiB `no-map` DT property. This is readiness only;
the board still holds the historical reset-held image. Hardware IPC, cold
startup, full 969-frame timedemo and continuous movie coverage remain unmeasured
or unproven. Simulation gameplay baseline remains **0.42633263** on frozen
5c2491f3, cycles **7,099,999,637–7,199,999,637**, predating the FPGA candidate.

### October 3: terminal routing failure and checkpoint recovery

The original implementation's `route_design` failed after **16m07s**; the
parent's implementation wait took **1h08m22s**. Root observed native session
66620 exit **1** at 01:37:35 UTC, then confirmed the old family and scope were
gone. `Route 35-3` reports global congestion level **6**; `Route 35-4445`
explicitly says these initial-routing issues cannot be resolved later in
that invocation. The router reports 1,153,331 node overlaps despite zero
failed-net counts, and estimated global/short and timing congestion level
**7 (128×128)**. Zero DRC errors are not successful routing. Do not force
bitstream generation or present the historical image as this candidate.

Preserved checkpoints under the original XPR's `.runs/` directory:

| Checkpoint | Bytes | SHA256 |
| --- | ---: | --- |
| `synth_1/rk_ao486_bd_wrapper.dcp` | 189,588,385 | `43cfcc3146f07bb7021a5a46978ce0ab4be6a165d820da5f4f6773988c53910c` |
| `impl_1/rk_ao486_bd_wrapper_placed.dcp` | 86,585,115 | `a85bda9f8dca7e679abc2366e2cc0c0a729428e7e7fb4ad615e7ae7721fd21e0` |
| `impl_1/rk_ao486_bd_wrapper_physopt.dcp` | 86,100,278 | `f8f9bef610610f6ae1d94c761dfa6651933cfbb8eb538e1bf649eb7b9d6c88d6` |
| `impl_1/rk_ao486_bd_wrapper_routed_error.dcp` | 88,018,240 | `78bc871cb523d4165e2f49a9a7839953705b436218135b9c725bc5b8588b46df` |

Root launched a separate bounded, exclusive **report-only** inspection at
01:42:54 UTC, after the failed family was gone. Its source and eleven native
reports are under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/route-failure-inspect-oct03.ScF3bypa/`.
Native session 22371 returned **0**, observed at 01:49:39 UTC, and its
completion marker follows `close_design`. A subsequent inventory at
01:50:13 UTC found no surviving Vivado family and an inactive scope. It used
18 GiB RAM / 2 GiB swap / 48 tasks, with one worker and a nine-minute outer
bound. The error checkpoint has discarded invalid signal routes: its native
route-status report has **242,219 unrouted / 242,223 routable nets**, only
four fully routed nets and zero routing errors. Therefore its timing reports
are **not final routed timing**, and zero routing errors are not acceptance.

The next controlled recovery preserves `impl_1` and reuses completed
`synth_1` in a new implementation run. The proposed recipe is `ExploreArea`
optimization, `AltSpreadLogic_high` placement, default pre-route physical
optimization, `AlternateCLBRouting`, and no post-route physical optimization.
`ExploreArea` includes implementation-stage **netlist area resynthesis**;
it is not a full RTL synthesis rebuild. A separate tiny same-part native
probe checks router-directive acceptance before the full implementation
launch; passing that probe cannot prove Ventium routability or timing.
High-spread placement and default pre-route physical optimization were already
used by the failed run and are retained controls, not new fixes. The intended
changes are the area-optimization directive and alternative router.
No frozen RTL, defines, P5 cache geometry or timing exceptions are changed.
The recipe is a recovery attempt, not a guarantee of closure.

The native same-part router probe subsequently completed with **actual exit
0**, accepting `route_design -directive AlternateCLBRouting` on Vivado
2025.2 / `xczu15eg-ffvb1156-2-i`. Its preserved log is
`/var/tmp/ventium-altclb-native-probe.gviImj/root-guard-probe2.log`, SHA
`3b7969e36126bd714105a601f2dd4ad03f841905608d3060827b61ed9607db41`.
Root confirmed its family and scope were gone at 01:53:44 UTC. This tiny
OOC design checks directive compatibility only, not Ventium timing or routing.

The first retry entry reached fresh-synthesis and clock validation, but stopped
**before `launch_runs`**, with native exit **1**, because Vivado has no run
property `STEPS.WRITE_BITSTREAM.IS_ENABLED`. The optional property was removed;
the explicit `-to_step write_bitstream` and supported `ARGS.BIN_FILE` remain.
The entry also omits unsupported `save_project`; run creation/launch/project
close use ordinary project persistence. The unused `impl_area_cong` metadata,
rejected source and log are preserved; no expensive P&R occurred in that entry.

The corrected entry creates fresh **`impl_area_cong2`**, validates parent
`synth_1`, exact part, complete/fresh synthesis and **40 MHz core / 100 MHz
PS-AXI** constraints before launch, and prints all actual directive readbacks.
Its source/CWD/logs are under `/var/tmp/ventium-impl-area-cong.IfjIKA/`:
`launch_impl_area_cong.tcl`, SHA
`2e9c9c10d6bf054514094f490d6907dd76d138a58871547525f78950d4deb58b`;
`impl-area2.log` / `impl-area2.jou`. Root rechecked all 179 frozen-file pins and
the original synthesis DCP before the retry. The pre-edit 68 KiB XPR backup
is `project-before-area-retry.xpr`, SHA
`950af3492d7dec847ac55c7c051c39444891177c1d8b55dfb8f9b4be69254f11`.

The actual implementation launch is recorded at **02:00:14 UTC**. Native
session **8229**, invocation `d6a070624b484e1e9e0d839469f66037`, is the only
top-level build family. The four-hour outer guard is a safety limit, **not a
completion ETA**. RAM remains **20 GiB hard / 19 GiB soft**, swap **2 GiB**,
jobs/internal workers **1**. Root preemptively extended only this live phase's
task headroom from **48 to 64**, because the prior same one-worker flow used
45 slots and partial vendor pool creation previously deadlocked. Native
property-command exit/readback are zero/correct, with zero memory/task-limit
events. Future launcher source stays at fixed 48. This does not add CPU jobs.
The root headroom receipt SHA is
`6ad9019015ad6172c91a5800a986c540cdc27c6b24a68b422264716d2fc4a9d0`.
At 02:01 UTC the original invocation is live, using 6.28 GB scope memory,
zero build swap and 13 tasks. These observations do not prove routing,
40 MHz silicon operation, timedemo completion or movie coverage.

`opt_design -directive ExploreArea` completed successfully in **6m10s**,
with zero errors/critical warnings. Its resynthesis phase remapped 42 modules,
creating 98,568 cells and removing 102,829; these counts are **not a LUT-area
percentage**. The preserved optimized checkpoint is
`impl_area_cong2/rk_ao486_bd_wrapper_opt.dcp`, **38,483,549 bytes**, SHA
`ca26d69cbe1ae711ea9ca29c101d6c6ec0a22089c34b8f6753a4341139c1644b`.
Placement started at about **02:07:33 UTC**. Do not interrupt the healthy sole
family to inspect this checkpoint in a second Vivado process. Actual area and
regional congestion effects remain unmeasured pending the placement reports.

The bus-skew-complete final inspection helper is prepared for the exact new
run at `final-inspection-prepared/inspect_completed_impl.tcl` under the
recovery CWD, SHA
`3c07905a95067c154ab3510bf387d09df8c87c554ce2073bad488c0c89608e97`.
Root inspected the full original and the diff: only four run-name references
change from `impl_1` to `impl_area_cong2`. This copy has **not** run natively.
Run it only after actual implementation/native closure and family absence;
the existing completed/fresh-run, full-route and zero-route-error checks,
40/100 MHz constraints and raw timing/CDC/bus-skew reports are unchanged.

A separate key-only board check at **02:02:40 UTC** returned native exit 0,
the same boot ID, manager `operating`, 374 MiB free, all staged cold-disk/ROM/
device-safe-daemon hashes unchanged, and the effective 256 MiB reservation's
`reg` and `no-map` intact. This does not deploy or release the guest, and is
not evidence of fresh hardware clock/timedemo/movie acceptance.

The first bounded recovery resource watch completed with **38 samples over
603.45 seconds** (02:01:43–02:11:46 UTC; largest gap 56.15 seconds). It retains
the same invocation and original parent/worker identities, about one busy
CPU, peak sampled **8.045 GiB** scope memory, zero build swap, at most 14/64
tasks and zero sampled memory/task-limit events. Minimum sampled host/disk
headroom is 13.80/15.64 GiB. Its final source check at 02:12:13 UTC holds all
179 frozen files, 110 defines and the exact launch helper hash. Receipt:
`observer-batch.jLBcE9xn/resource-batch.json` under the recovery CWD, SHA
`c9c79efe108ac730ffa98ab8941e53a7b852fd4f8db7cdc6a4ac7d1b52a55ec6`.
Root rehashed/read that receipt and independently rechecked the live family
at **02:13:33 UTC**: the same worker has advanced to **Global Place Phase1**,
CPU time 13m18s, scope memory **9.144 GB**, swap zero and 14 tasks. Native
session 8229 remains live; observer completion is not build completion.

### Vendor helper deadlock and bounded restart

Timing Optimization finished at 21:39:51 UTC and Technology Mapping began,
but productive CPU stopped around 21:40. The cgroup reached its 32-TID cap;
`pids.events.max` advanced to 2. All 17 processes / 32 TIDs remained live,
with no final DCP or completion marker. The same invocation was extended to
20 GiB hard / 19 GiB soft after another headroom check; OOM/max/kill counters
remained zero. A reversible task-cap increase to 36 did not recover it.

Bounded, read-only GDB attachments found the synthesis thread waiting in
`HARTNDb::loadOptimizedGenomes()`. Its task worker was instead deadlocked in
`pthread_cond_destroy` during board-catalog initialization/unwind, while six
Taskflow startup workers still waited on its condition variables. A separate
read-only vector inspection established **eight requested workers, only six
created**. This strongly supports a one-shot partial thread-pool construction
failure at the task cap; no exact rejected pthread errno was captured.
Increasing capacity afterward cannot restart an already-unwinding constructor.
The root diagnosis receipt is `synth-task-cap-deadlock-oct02.md` in the task
directory. Successful debugger probes detached with native exit zero and
disabled core dumps. An earlier debugger-only probe exhausted its own 1 GiB
address-space cap; that was not a Vivado/host OOM.

Root deliberately stopped the original family. Native handle `12327` exited
143; at 21:55:34 the scope was inactive and its cgroup absent, and all 17
recorded PIDs were absent by 21:56:10. The wrapper also emitted a parse warning
after its on-disk guard was edited during cleanup: do not edit a running shell
launcher's source. No synthesis success is inferred from that closure.
The final old resource audit contains 319 observations / 85 pin checks, SHA
`4b1daf1da7c89e0da1c89e02a6926aa1006782ac5e5ddbfcc9449c0e8aeb723f`.

The host guard now has a fixed, non-overridable **TasksMax=48**, leaving a
bounded cushion for metadata/control threads without increasing synthesis
jobs or `general.maxThreads`. Twelve host-only tests passed, including high
and low task-env requests, unchanged non-Vivado profiles, explicit leaf caps,
unlimited/oversized rejection and stale smaller inherited memory requests.
These tests mock systemd and cgroup files; they do not launch Vivado.

The first replacement launch (`88482`) exited 1 before project creation:
the repository's `.Xil` symlink points at the full external volume. Its small
logs are retained. Use the owned replacement directory as **working directory**
as well as output/TMPDIR; changing TMPDIR alone does not relocate Vivado `.Xil`.
Do not alter the external volume or the user's symlink to bypass this.

The corrected native handle is **`74097`**, invocation
**`bb0afade4190423b8903316598a14ded`**. Synthesis launched at **21:57:56 UTC**,
after BD validation retained 128-bit HP0 and the exact 110 defines / 40 MHz
clock. Initial hard memory is **18 GiB**, soft **17 GiB**, swap **2 GiB**,
tasks **48**, one run job. With 21.7 GiB available after old-run cleanup,
starting at the full 20 GiB ceiling would leave too little host reserve.
At 21:58:14 the new synth worker was using a productive CPU core, memory was
3.08 GiB, and task/memory-limit events were zero. Root rechecked all 179 frozen
hashes successfully. Recovery is not proved until it passes the stalled stage
and completes. Preserve the original output; inspect/resume the replacement
XPR below, only after its native synthesis handle closes successfully:

```
/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-task48-retry.5ZayIg/output/rk_ao486_system/rk_ao486_system.xpr
```

At **22:13:50 UTC**, after a fresh host-available-memory check above 5 GiB,
root changed only the live cgroup limits to `MemoryHigh=19 GiB`,
`MemoryMax=20 GiB`, `MemorySwapMax=2 GiB`, and `TasksMax=48`. The launch
environment remains `VENTIUM_VIVADO_MEMORY_MAX=18G`. `memory.events.high` is
16, so this run has encountered the high limit; all OOM counters remain zero.
That resource observation is neither synthesis completion nor timing, fit, or
hardware qualification.

At **23:18 UTC**, timing optimization finished (logged CPU 1:20:02, elapsed
1:20:26) and the same run entered **Technology Mapping**. Mapping helpers made
measurable CPU progress with no task-limit event; the former idle thread-pool
failure has not recurred. The temporary parent/helper working-set transfer
filled the original 2 GiB and then 4 GiB swap allowances. Root changed only
the **live scope** `MemorySwapMax` to **4 GiB at 23:20:24**, then **8 GiB at
23:25:17 UTC**, retaining 19 GiB soft / 20 GiB hard RAM and 48 tasks. No running
launcher, frozen source, define, project or launch environment was edited or
restarted; the future guard still has its original 2 GiB swap ceiling.
At the latter property readback, the host had about 3.7 GiB RAM available and
14 GiB global swap free; scope swap use was 4 GiB. All max/OOM/kill/task-event
counters remained zero. High-limit reclaim events did increase and are not
reported as zero. The observer now alerts above 7 GiB scope swap or below
1.5 GiB host available RAM. This is continued, resource-bounded mapping—not
synthesis completion or hardware qualification. Root receipt:
`fpga40-task48-retry.5ZayIg/mapping-live-swap-adjustments.json`, SHA
`96484fd8c696954004a27c12678132200693e4cebdbdce9394fc7b777626b1a2`.

Preflight found the actual core clock is `mmcm_clk` (25.000 ns), whereas the
old resume reporter searched only legacy divider names. The separately pinned
resume script is now
`impl-resume-current.QSFuiF98/launch_impl_existing.tcl` in the task directory,
SHA `0299790cad0488ef90895bdbb35287c5f67d6bec6ea964fa05fb19d8f98a6f1f`.
It accepts the actual MMCM name, validates an explicitly requested 40/45/50 MHz
target and finite clock/slack values, and prints its completion marker only
after successful reports. All 61 real-tclsh/stub-only cases passed; root
independently reran them. This new resume copy does **not** change the original
179 frozen inputs. Set `VEN_FPGA_CORE_MHZ=40` when resuming the existing XPR;
do not regenerate the BD or repeat synthesis. A completed implementation and
finite negative WNS still do not constitute timing closure.

Read-only preflight of the generated BD/XDC confirms two domains: control and
core interfaces at 40 MHz, and the memory converter/HP0 side at nominal
100 MHz. The failed attempts to override read-only `FREQ_HZ` metadata did not
prevent automatic propagation: the generated core-side interfaces report
40,000,000 Hz and HP-side interfaces 99,999,001 Hz. The persisted constraints
are `clk_pl_0` at 10.000 ns and `mmcm_clk` at 25.000 ns. This is modeled
frequency, not a silicon measurement; PCAP does not reprogram Linux's PS clock.
The memory clock converter is asynchronous; the width converter is synchronous
on the HP domain. The legacy `fpatan_mcp.xdc` is absent. Forty-three narrow
vendor reset/CDC false paths and ten FIFO Gray-bus skew constraints still need
actual exception-coverage and routed timing inspection.

The authored IRQ port lacks a `SENSITIVITY` attribute, but the generated IP
wrapper declares `LEVEL_HIGH`. Its signal is a registered level OR of host
IDE/FDD service requests, not the guest's P5 IRQ bus. The clean daemon polls
host service requests instead of using a Linux interrupt handler; guest IRQs
have their own PIC path. This explains the warning's scope, not interrupt-path
qualification. Preserve it, and check DT/GIC trigger configuration separately
before introducing interrupt-driven host service.

The root-validated, inspection-only synthesis Tcl is
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/inspection-root-task48.PmBU0x/inspect_completed_synth.tcl`,
SHA `e10c7d601e06c7625c0826de766533463421a471bf96d0f7b6b8c07e124dd891`.
It opens only the exact retry project above, rejects incomplete/stale
synthesis, and emits utilization, clock/exception, DRC, and timing reports
outside both protected trees. It must run only after the synthesis process is
closed, under the sole-Vivado/resource guard and an external deadline. It
cannot launch, reset, or regenerate a run, and report completion is not
sign-off. Its completion marker precedes project closure, so require native
exit zero as well as the marker. Root's independently validated 66-case
Tcl-only stub receipt exited zero and hashes to
`14b47be1951cb562de82b044a158e234422d79cf70d909b0d1cf7c4df5b9913a`;
it is not a native Vivado report.

The separate root-validated post-route inspection helper is
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/inspection-root-task48.PmBU0x/inspect_completed_impl.tcl`,
SHA `694d7deea47cfd39125c2f5192ca9bf4c038ce6a9f17995d6d6cfc9059b672cd`.
It requires fresh completed synthesis/implementation, exact 100/40 MHz clocks,
and positively complete, error-free routing. It produces the same nine reports
plus route status, detailed unwaived CDC, and four bounded same-domain
setup/hold reports. Its completion marker follows project closure, but native
exit zero remains required. Root's independently validated 119-case Tcl-only
stub receipt exited zero and hashes to
`7b8ca4e4c8bccadb26b161b8632a3a87e7974aa0a6cde85aad8a3ee43fdd732b`.
No actual routed inspection has run. Optional period-minus-slack estimates are
explicitly conditional, path-local, and withheld when requirement/exception
metadata is missing; they are neither a physical MHz measurement nor sign-off.

Both helpers accept the exact retry XPR
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-task48-retry.5ZayIg/output/rk_ao486_system/rk_ao486_system.xpr`.
They reject the old failed XPR under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-vco1g.3vpbYB/`, even if it is
readable, and reject report destinations within either the frozen or retry
artifact tree. Those guards establish provenance and avoid contaminating the
preserved inputs; they do not make a Vivado result or sign-off claim.

The FPGA's existing retired counter counts primary retire events only; it
omits simultaneous V-pipe retire events. Its read-only cycle counter is valid
for MHz measurement, but its displayed IPC is **not comparable to total
simulator U+V gameplay IPC** without a separately qualified total counter.

Resource cleanup removed only exact reviewed `.o`, `.a`, and `.gch` compiler
intermediates from closed old builds. Binaries, sources, receipts, logs,
media and current model/build directories were preserved. The initial cleanup
recovered 5.11 GiB root-disk space and 1.82 GiB tmpfs space; its SHA/path
manifest is under `/var/tmp/ventium-generated-cleanup-oct02.xy3EgO/`.
Intermediates are rebuildable with matching inputs, not backed up. Additional
old tmpfs-intermediate cleanup recovered another 3.85 GiB without deleting
model executables or sources; its manifest is under
`/var/tmp/ventium-generated-cleanup2-oct02.9fZBVC/`.

## Boot-memory change and rollback

The original board DT was preserved locally and on the boot partition. Only
`/reserved-memory` and its guest-RAM child were added: all 186 original nodes,
1,362 properties and 133 symbols were independently compared unchanged.
BOOT.BIN, Image and boot.scr were not modified.

| Artifact | SHA-256 |
| --- | --- |
| Original DT / `system.pre-ventium-oct02.dtb` | `6363f525e5d440ee78ae7c6dc476131e641b14539fa266fb9fd1885a78d47488` |
| Installed `/boot/firmware/system.dtb` | `6d820ea0755d9f87256a9bc86ee0ca454480951ac403fc91cbdfd0845280e9bf` |

The new boot ID is `2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb`.
Root read the effective DT: `reg = <0 0x60000000 0 0x10000000>`, `no-map`,
and no reusable/pool property. Root `/proc/iomem` reports
`60000000-6fffffff : reserved`; System RAM ends below and resumes above it.
The boot log explicitly reports `nomap non-reusable guest-ram@60000000`.
CMA's separate 512 MiB pool moved to `0x40000000–0x5fffffff`.

Rollback, if necessary, means restoring the hash-verified original DT to
`system.dtb`, syncing and rebooting. **After rollback, the hardcoded guest
aperture is unsafe again: do not launch the daemon or map guest DDR.**
Never substitute a runtime DT overlay for boot-time memory exclusion.

## Programmed artifact and protocol pairing

The board retained `/lib/firmware/rk_ao486_system.vga_capture_20260829.bit.bin`,
SHA `279bc2c0caa14cbea169ddf1b25a60407ef0b44bbc3a92186d96e251895064fd`.
It was copied back to the host and independently hashed, then programmed using
the existing FPGA-manager/configfs loader. Manager state is `operating`;
the control-only clean-daemon IDENT probe returns `a0486501`, CTRL `1` (reset).

This historical RK image targets `xczu15eg-ffvb1156-2-i`; its recorded core
clock is 3.125 MHz, WNS +4.521 ns and WHS +0.014 ns. The live Linux clock tree
reports PL0 about 100 MHz. This was a recovered artifact, not a newly built
image; the current-source build above is separate. It is **not** a
current-5c hardware qualification: the external board flow was untracked and
no exact archived source/daemon pairing proves that ancestry.

Actual read-only hardware-counter measurement while reset is held:
6,250,569 cycles over 2.000077 seconds = **3.125164 MHz**, zero retire events.
Counter endpoints are 1,382,828,105–1,389,078,674. This is clock evidence,
not gameplay IPC or performance acceptance.

Use the tools at commit `f2ffc0106b0ba42ec3fa2020ad61675cfe440212`:

| Tool | SHA-256 |
| --- | --- |
| `fpga/board-tools/ven_board_probe.py` | `1dd0baf6909f7f767cea639568b059698511cc96b34ca1193b95b678295dc857` |
| `fpga/board-tools/ven_vga_stream_to_video.py` | `dae7ff6512889f9075153ce4b8c0be32e471f60f3ed9f63cea8a99335d2c8649` |

These decode the 64 KiB RGB332 recorder, 9-bit width/height and 17-bit pixel
count. Today's widened tools are **not** compatible with that metadata packing.
Prepared host copies are under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/historical-vga-f2ffc01/`.

## First cold attempt

The isolated clean daemon SHA is
`3feafe09a07b397cec4a61b435383f8c603f6e60db267e10958388ccad3e931c`.
It removes the default BDA LED rewrite/cache-flush intervention and rejects
injection/flush/debug workarounds. It checks manager state, unmasked iomem,
input identity and ROM completion before releasing the core. Its compile and
host-stub checks are not board qualification.

Cold disk SHA is
`2df14ac9ae5f927cab2410e784d14c655f0e96644ca80ced3c0b012df7a36e4c`.
This is FreeDOS DOS Quake 1.06 shareware with CWSDPMI, starting ordinary
`quake -nosound -nocdaudio -condebug +timedemo demo1`; no snapshot or guest-code
patch was introduced. ROM hashes are `dca915c5…dd26a3` (general P5 cache-enable
BIOS bootstrap) and `fb0d673a…e08296` (VGA BIOS).

Service `ventium-quake-cold-oct02.service`, invocation
`c3c79a6d275744b8b652495aff9a9653`, failed at 19:40:11 UTC with
`ExecMainCode=2`, `ExecMainStatus=7`, `Result=signal`. Its last log line is
`zeroing 256 MB guest RAM...`; the core was not released. Memory limits were
512 MiB, zero swap, 32 tasks and a two-hour host safety deadline.

The static daemon's `__memset_generic` uses `DC ZVA` for large zero fills.
Linux 6.12 ARM64 maps non-map-memory `/dev/mem` pages as Device-nGnRnE,
not Normal-NC. This is a suspected access-attribute mismatch, pending exact
fault-PC evidence at first inspection; do not weaken exclusive guest-memory
ownership to bypass it.
See [ARM64 /dev/mem protection](https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm64/mm/mmu.c)
and [memory-type definitions](https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm64/include/asm/pgtable.h).

At 19:48 UTC the guarded bounded probe
`devmem_sigbus_probe.aarch64` (SHA
`5f25cbbb7cfa56458a52098098f9af2c07dabf1f5b932002d12c91a3c7013760`)
independently checked manager/DT/root-iomem/IDENT/CTRL=1. Aligned read64 at
`0x60000000` succeeded. An explicitly requested 64-byte `DC ZVA` experiment
faulted with SIGBUS, si_code 1, ESR `0x92000061`, PC `0x400bac`, exit 135.
Root disassembled that exact PC as `dc zva, x0`. A scalar 64 KiB clear at the
same address returned zero using `str xzr` and `dsb sy`. Neither experiment
released the guest or changed its disk. This confirms the instruction/mapping
mismatch; it does not yet qualify the complete replacement daemon.

The successor ARM binary is `/tmp/ao486/ao486d.device-safe-oct02`, SHA
`03e1860ffb80a4b3113e2644259933a95650e687fc0ca57ebf69ee04ad94c4b6`.
It uses explicit scalar Device-memory loads/stores and normal-memory file
bounces instead of libc bulk operations on `/dev/mem`. Bounded host tests
checked sizes, aliases, partial overlap, short reads and file transfers;
cross-compilation and disassembly also passed. At 20:20 UTC its `--ident`
returned zero, IDENT `a0486501`, CTRL `1`, and explicitly left DDR unmapped.
That is control-path evidence only; do not count it as guest startup.
The updated host-stub startup gate also passed in 1.5 seconds: non-operating
manager/System-RAM overlap are rejected before mapping, malformed/short ROM
loads and rejected Device aliases/bounds do not release the guest, and a valid
stubbed startup holds then releases exactly once. Its proof is under
`startup-guard-hoststub-axi-audit/` in the task directory. It uses ordinary
host RAM and stubbed x86/IDE, not real ARM Device execution or ROM correctness.

## Movie requirements

### Separate closed FAT-console evidence

Do not call the simulation checker's final `check` command on the board daemon
log or fabricate simulator `RESET`/`PROGRESS`/`DONE` lines: those grammars are
simulation-specific. Do not use a whole-VHD regex scan as acceptance either;
deleted FAT clusters can contain old completion strings.

The final root-reviewed offline helper is
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga-console-root-final.hhhpbilJ/check_closed_console.py`,
SHA `be2f8fd8733e677bab456bd1d1594d7367c2da64158f2721dc80d7790f834900`.
It executes only the exact hash-pinned common parser bytes
(`427d9e7471eb4d6a65361fc468646307c66df4fe70fe8001e51977307bb85ad7`),
without changing that parser or its simulation acceptance gate. It requires a
bounded, owned, one-link, closed local VHD copy and a SHA-pinned root receipt,
binds both FAT parsing and `mtype` to the held original descriptor through
`/proc/<helper-pid>/fd/<fd>`, and checks inode metadata and disk SHA before and
after extraction. Only FAT `::/QUAKE/ID1/QCONSOLE.LOG` is evidence.

The immutable pre-run input has SHA
`2df14ac9ae5f927cab2410e784d14c655f0e96644ca80ced3c0b012df7a36e4c`;
its saved 465-byte console has SHA
`a5884526b232055e67c512d68b6da6ea09ef6b7f00218617c8e0440e3cec7364`.
That console already has an old demo1 marker but no result. An unchanged log
is **PENDING**; a fresh result relying solely on the unchanged old marker
requires attribution review. Every retained result must contain 969 frames,
positive finite seconds/fps and mutually consistent printed rounding. Errors,
malformed records, a nearest demo2 marker, and CR/LF joining fields or marker
words across physical lines fail closed. Ordinary DOS line endings and
horizontal tabs remain valid.

After actual daemon/disk and transport closure, preserve the native properties
and make the root-authored receipt described by the helper. Use a whole-helper
30-second outer deadline as well as its inherited 15-second `mtype` deadline;
JSON, disk and console bounds are 64 KiB, 128 MiB and 16 MiB, respectively.
Console parsing streams physical lines, keeps only the nearest marker and
caps results at 1,024. The final root microtests passed **14 methods**, native
exit 0, 2.54 seconds process wall time and 28,692 KiB peak RSS, with a 256 MiB
address-space / 20 CPU-second limit. Actual CLI extraction of the closed
**pre-run** copy returned native exit 1 / PENDING; a wrong receipt pin was
also rejected. Receipt:
`fpga-console-root-final.hhhpbilJ/ROOT_FINAL_MICROTEST_RECEIPT.json`, SHA
`42eed0a7c343a51706dc822cc9eddd4325308afb28fba01be6f679f6e5b35101`.

Exit 0 means only `CLOSED_CONSOLE_EVIDENCE_VALIDATED_NOT_FPGA_ACCEPTANCE`.
All FPGA/native-closure/hardware-provenance/cold-reset fields remain false.
The root receipt is a caller assertion, and copied/shifted historical text is
not fresh execution proof. Root must separately establish the real cold
release, bitstream/daemon/source/clock ancestry, native shutdown observations
and continuous movie coverage. No actual final hardware disk has passed this
helper yet.

The passive recorder is private BRAM: arming/draining it does not modify guest
RAM, halt execution or flush caches. Stream binary VENVCAP1 over **non-PTY**
SSH directly to the host; keep progress on stderr and credentials out of
commands/scripts/logs. The armed first capture has not produced a frame while
the guest remains in reset. That failed old capture is a 16-byte header-only
archive, not a movie. No capture process remains active.

The newly staged wide probe is `/tmp/ao486/ven_board_probe.wide-oct02.py`,
SHA `cd2842b6da87df26a5fa16840903f8347c628d718239a1d183aba578c038b102`.
It belongs to the new 512 KiB capture interface, **not** the currently loaded
historical image. After programming, use observed CSR dimensions as authority;
`video_lores=1` decimates scanout but does not force Mode 13h. A uniform
320×200 stream should explicitly request that geometry and `--skip-unmatched`
to skip BIOS/text modes without resizing them. Confirm the actual geometry
before interpreting its pixels. The current decoder's default lossy H.264
output is not a lossless RGB movie, and the old private FFV1 assembler pins
historical tool provenance; neither is automatic acceptance for the new run.

Current-pinned host helpers are prepared under
`movie-root-micro.Oki6CEec/` in the task directory. Root independently reran
the synthetic gate successfully. The normalizer requires an exact root-authored
producer/transport closure receipt, verifies current probe/decoder/manifest
pins, preserves the original raw stream and any partial terminal record, and
rejects malformed geometry, CRC or ordering. The FFV1 assembler presents every
validated accepted record once at 15 fps without resizing or color changes,
then decodes it and checks byte-exact RGB equality. Its limits are 2 GiB input,
6 GiB **streamed** expanded RGB (not a stored buffer), 2 GiB movie output and
1 GiB disk reserve; FFmpeg has two threads, 512 MiB address space and an
enforced per-stage pipe/exit deadline. These host-only tests include stalled
pipes and do not prove a real capture or timedemo. Use an outer whole-helper
deadline as well. Do not reuse the historical assembler's old-source claim.

### Board-to-host transport qualification (22:15–22:16 UTC)

Root ran two **synthetic-only** FIFO tests on the actual Debian/systemd 252
board. Neither opened MMIO, armed capture, started a guest, nor produced a
hardware movie. The complete receipt is
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/board-fifo-transport-root.wLdy2xHK/ROOT_SYNTHETIC_TRANSPORT_RECEIPT.json`,
SHA `ab033a55279a289e3b74cb7f46863c86792a3f1fb3bfc58675fdfd8993a69849`.

The positive test used a private `root:riguke` directory (0750), a binary
FIFO (0640), a non-PTY key-authenticated SSH reader started **first**, and a
direct-exec root transient service with separate stderr. All 192,124 synthetic
bytes arrived unchanged (SHA
`293fe0156e98c902860c5f089b22f75822001ababb4f9ca07c216b5d357aa269`).
The producer's observed native exit and the reader's actual exit were both
zero; byte comparison passed and stderr was empty. The negative test closed
the consumer after the 16-byte header: its reader still exited zero, but the
Python producer exited **1** with `BrokenPipeError`. Header/reader success must
therefore never substitute for completed producer evidence. Both test units
were subsequently stopped/unloaded and their PIDs are absent; their completed
properties and the failed-test stderr are retained on the host.

For the real producer, use `Type=exec`, `PrivateTmp=no`,
`StandardOutput=file:<private FIFO>`, and separate `StandardError=append:`.
Set **`RemainAfterExit=yes`** to retain a successful transient unit until its
native exit is recorded; omitting `--collect` alone does not retain a successful
unit. Do not combine this with `--wait`. A retained `active/exited`, `MainPID=0`
unit means the main process has **closed**, not that capture is still running.
Set `TimeoutStartSec=20s` for the reader-first FIFO rendezvous, independently
of the running-service bound. A real capture bound must cover the 600-second
pre-release/frame wait, the admitted 7,200-second workload, and closure margin;
the synthetic test's 60-second runtime is not the real-run bound.

At 320×200, one RGB332 record occupies 64,036 bytes. The current single-stream
helpers accept at most 32,768 records (1.954 GiB per raw/normalized stream), so
two-hour coverage requires an average below 4.551 accepted records/s. Monitor
actual timestamps and remaining quota; **15 fps is presentation, not a capture
rate limit**, and no complete-time-span claim follows from this capacity cap.
Keep the producer's natural cadence; do not silently pace/drop records to fit.
The maximum raw/normalized/movie budget plus disk reserve is about 6.91 GiB,
and the small fixtures do not establish maximum-scale encoder throughput.

Preserve raw colors and dimensions. Presentation is 15 fps, with no gamma,
brightness or contrast processing. Retain capture-cycle timestamps; a
constant-rate presentation is not measured silicon FPS. One recorder buffer
does not guarantee capture of every game-engine frame. A full movie needs
continuous temporal coverage through the visible 969-frame completion result,
plus separately checked timedemo completion. Never count 969 scanout samples
as proof that the game completed 969 timedemo frames. Use bounded compressed
lossless output to avoid filling the host or board filesystem.
