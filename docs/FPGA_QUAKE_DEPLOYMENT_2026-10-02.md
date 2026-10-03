# RK FPGA Quake deployment — October 2, 2026

## Current status (2026-10-03 14:12 UTC)

The first frontend-factored synthesis (native **65164**) closed with exit
**143**, not success. The kernel/user journals identify **CONSTRAINT_MEMCG
OOM at 12:50:43 UTC**, during technology mapping, after timing optimization
completed. Both its **20 GiB RAM / 2 GiB swap** boundaries were exhausted;
the unit records a 20 GiB memory peak and 2 GiB swap peak. The earlier zero
event samples predated the allocation burst. All family processes are gone;
no synthesis DCP or bitstream was produced. Failed logs and sources are retained.

The first unchanged-source retry launched at **12:56:45 UTC**, native **32041**,
under `/var/tmp/ventium-fpga40-icfrontspan-memretry.Gdis4N/`, using the same
179 frozen source payloads and 110 defines from
`/var/tmp/ventium-fpga40-icfrontspan.yqNVao/`. All 179 hashes were checked before
launch; the input manifest remains
`b94db3dc4e6e559f8aa956ec629906d45f88192b627b3793f757a8cb79178270`.
This is still **40 MHz core / 100 MHz PS-AXI**, full P5 caches and balanced
synthesis, not another RTL or directive experiment.

The original admission repair was **`3f1d3e9`**. Attempt 32041 selected
**18 GiB RAM / 8 GiB swap / 48 tasks**, with **MemoryHigh at 90% of RAM cap**.
Its actual manager properties confirmed those limits, invocation
`8125cbd80ab4436ea1936f03f7422cd2`. Admission observed 23,201,869,824 available
RAM bytes and 17,748,029,440 free swap bytes.

The **13:36:24 UTC** live sample and its zero kernel OOM/max counters were
historical, not final success. Timing optimization subsequently completed
(54m50s CPU / 55m35s elapsed), and technology mapping began. At **13:56:52 UTC**,
**systemd-oomd killed all 17 family processes**; native 32041 closed with
**exit 137**. The scope records 16.6 GiB RAM and 8 GiB swap peaks. Its ancestor
`user@1000.service` exceeded its installed 50% memory-pressure policy for more
than 20 seconds; the scope had sustained reclaim/PSI. This userspace kill is
distinct from attempt 65164's kernel hard-cap OOM. A finite soft throttle
coincided with the pressure, but is not proven to be its sole cause. No DCP,
implementation or bitstream was produced. A proposed live 19 GiB increase was
rejected by the fresh reserve check before mutation; 18 GiB remained in force.

The controlled retry launched at **14:11:30 UTC**, native **48145**, under
`/var/tmp/ventium-fpga40-icfrontspan-nothrottle.3ZFR9t/`; synth_1 started at
**14:11:53 UTC**. Guard **`830c1a9`** is committed/pushed, and **20 host-only
tests** pass. It omits automatic MemoryHigh and requires actual
`memory.high=max` when attesting a nested Vivado scope. The hard RAM ceiling
remains 20 GiB, default swap 2 GiB and explicit swap ceiling 8 GiB. Admission
still requires available RAM at least selected cap + 2 GiB and free swap at
least selected cap + 4 GiB. This retry selects the same **18 GiB RAM / 8 GiB
swap / 48 tasks**, without changing host OOM policy or preferring other victims.

Actual cgroup files confirm `memory.max=19327352832`, `memory.high=max`,
`memory.swap.max=8589934592`, `pids.max=48`; invocation is
`3da91b793e324153ba2bdbc86c0de757`. Admission observed **22,465,601,536** available
RAM bytes and **18,425,196,544** free swap bytes. At **14:12:26 UTC**, synthesis
worker **2296983** was live at 97% CPU, scope memory was **5,672,022,016 bytes**,
swap was zero and 19 tasks were present. One Vivado family runs, with jobs=1
and general.maxThreads=1. Exact **110 defines** match both the new XPR and
generated synthesis Tcl; all **179** frozen source hashes were rechecked.
The 40/100 MHz clocks, full P5 caches, balanced profile and RTL are unchanged.
Passing tests/admission does not guarantee that mapping peaks fit. Monitor
native handle, cgroup pressure/events, journal and disk; do not restart merely
because the log is quiet. No new synthesis DCP or bit exists yet.

The stopped OOM run's caches were cleaned only after archive verification and
an exact-file/liveness qualification: **624** regular single-link `.rtd`/`.tim`
files removed, **570** other cache files and all **179** frozen payloads checked
unchanged. No directory, diagnostic log, source, guest media, or live-retry file
was removed. Net reclaimed space is approximately **2.70 GiB**. Recovery archive:
`/var/tmp/ventium-oom-synth-cache-cleanup.7nY8Mt/regenerable-caches.tar.zst`, SHA
`72a7995e0fb6f171ea86c0c90c52938d30c31a6ec1a2b899e81f33aee93a025e`;
cleanup receipt SHA
`4439e2afa40f4d8b95e06d2b62b2d2da2ae85ff0e57397ab086fee75cb5292f5`.

The source audit confirms no CPU clock division after the MMCM: CPU and debug
`perf_cyc` share its output, so the held counter can measure core clock pin
frequency. A fresh read-only five-second sample on the **old held image**
closed with native exit **0**: 15,625,600 counter cycles / 5.000084 seconds =
**3.125067 MHz**, zero retirements, `CTRL=1` before/after. It mapped no guest
DDR and made no control writes. This does not measure the new candidate.
Clock receipt: `/var/tmp/ventium-held-ddr-sweep-prep.SwSZzP/old-image-readonly-clock.json`,
SHA `8752242ea4f6fd0ecdf30d3df1a9ad20dacecbe529b7a148672d33000a5558f1`.

### Movie provenance preparation for this candidate

The earlier `runtime-movie-bundle.Oz2wfq` pins the old `adfb6ff…` source
manifest, so it must not be used as authority for a capture from the new
`b94db3d…` frontend candidate. A separately reviewed derivative is prepared at
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/icfrontspan-movie-bundle.UKUNF0/`.
Only its frozen root/manifest pins and explanatory documentation changed;
capture ABI/runtime-client pins, fail-closed checks, geometry, colours and
15-fps presentation are unchanged. The original bundle's hash receipt still
checks clean. A new negative fixture rejects the actual previous manifest and
base provenance before output creation.

The synthetic host-only microtest runner closed with native exit **0** (handle
**21555**), including tiny and 320×200 FFV1 byte-exact roundtrips, partial-tail
retention, malformed record/provenance rejection and streaming deadlines.
Normalizer SHA: `4b4113c1ded1bbe6ff08cf2a9efc2cc40bd82c881eb0c4338af2675a94a4d2f2`;
assembler SHA: `c272e19112fc91fba42778a2143f2c3eeca76344c9c9b941010a70aee5506734`.
These tests do not prove a maximum-quota encoding, board capture or timedemo.

At 32,768 × 320×200, raw RGB332 is exactly **2,098,331,664 bytes** (1.954 GiB).
Raw plus normalized copy, a 2 GiB FFV1 allowance and 1 GiB required free reserve
total **7,417,888,800 bytes** (6.908 GiB). Original retention is a hard link,
not a third raw copy; RGB24 expansion is streamed, not stored. Raw and
normalization must share a filesystem. The 2 GiB movie cap is a fail-safe
bound, not proof of sufficient compression for every 32,768-frame stream.
Recheck actual free space and capture cadence before recording, and retain
independent fresh 969-frame console/clock/release evidence: a lossless movie
of accepted samples alone is not timedemo or continuous-scanout acceptance.

No current-candidate full standard suite, routed sign-off, deployment,
hardware timedemo or movie is complete. Verified simulation gameplay IPC
baseline is **0.42633263**, build **5c2491f3**, cycles
**7,099,999,637–7,199,999,637**, predating this unmeasured candidate.

## Historical status (2026-10-03 12:13 UTC)

The new source-factored **40 MHz** candidate is still in synthesis timing
optimization under `/var/tmp/ventium-fpga40-icfrontspan.yqNVao/` (native handle
65164). No new bitstream, deployed candidate, hardware timedemo or movie exists.
The single guarded Vivado family remains live; observed memory/task-limit
events are zero. At 12:11 its scoped working set was about 16.3 GiB, with the
2 GiB swap allowance nearly full. Do not overlap another heavy build.
The source changes have focused differential/miter evidence, not a completed
current-candidate standard suite.

Board readiness now includes an actual held-core scalar clear over **all
256 MiB** of reserved guest DDR, `[0x60000000,0x70000000)`. Fresh root checks
found the exact non-reusable, zero-length-`no-map` DT node, no other overlapping
reservation/owner or System RAM, no active relevant service/timer, and no
physical-memory FD/mapping users. The root-owned pinned helper issued **4,096
ordered 64 KiB clears**, closing in **14.839 seconds** with actual wrapper
exit **0**. The two boundary 64-bit readbacks were zero; `IDENT=a0486501` and
`CTRL=1` held, and the post-run mapping census was empty. Only reserved guest
RAM was cleared; disks and FPGA control state were untouched. This is not a
full-byte readback test, universal exclusion of a later privileged actor, the
daemon's single-mapping clear, cold guest boot, or timedemo acceptance.

Retrieved evidence is `/var/tmp/ventium-held-ddr-sweep-evidence.suHfUI/`:
receipt SHA `8c401792857dcfd24051931ba909a0c4f65975216e0f9a4623232cdeb91bd282`,
log SHA `3c8e52ec71c40653b4a9c2af679192b2156e3522076800c1f74856bc7fabb017`.
The root SSH command session closed with native exit **0**. The board remains
on the historical held image; no guest was released.

A fresh read-only post-route inspector is prepared under
`/var/tmp/ventium-icfrontspan-postroute.vyHrc7/` (script SHA
`cd7a9bd6fcea7c492a29bbc641b7179cb00481daf1eb98371a6027936d67028f`).
It pins this candidate's project/`impl_1`, requires full placement/routing and
no partial-route errors, and re-queries expanded-clock setup/hold reports
without the ignored `-of_objects`/`-path_type` combination. **121 host-only
stub cases** pass; no native Vivado inspection has run. Conditional path-local
Fmax is not board frequency or timing/CDC sign-off.

Verified simulation gameplay IPC baseline is **0.42633263**, build
**5c2491f3**, cycles **7,099,999,637–7,199,999,637**. It predates the current
candidate, whose gameplay IPC is unmeasured.

## Historical status (2026-10-03 04:40 UTC)

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
from the same synthesis checkpoint. It changed only the
implementation-stage area optimization and router directives, not the RTL,
defines or cache geometry. Preliminary timing is also severely
negative: the constrained
40 MHz target is not yet a demonstrated operating frequency or timing pass.
Retry placement completed in **30m52s**, with **218,494 LUTs (64.02%)** /
**37,885 CLBs (88.81%)**. High congestion persists and placed WNS is
**−24.487 ns**. Pre-route physical optimization subsequently completed in
**1h04m50s**, with zero errors/critical warnings and post-optimization WNS
**−23.574 ns**. Alternate routing also failed with global congestion level 6
and **1,125,751 node overlaps**; native session 8229 closed with actual exit
**1** at **04:00:40 UTC**. A fresh **`impl_area_medium`** attempt launched
at **04:04:20 UTC**, changing only high to medium placement spreading and
retaining the same synthesis checkpoint, other directives and clocks. It is
live. Medium placement completed in **27m45s**, with zero errors and
**218,526 LUTs (64.03%) / 37,513 CLBs (87.93%)**. High congestion remains;
standalone pre-route physical optimization has started. No new bitstream or
hardware timedemo is proved.
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
regional congestion effects were then pending the placement reports.

Retry `place_design` subsequently completed with zero errors/critical warnings,
elapsed **30m52s**. Root read and hashed its completed placed report at
**02:39 UTC**: **218,494 LUTs (64.02%)**, 59,000 registers, zero latches,
**37,885 CLBs (88.81%)**, 221 BRAM tiles and 127 DSPs. Compared with the
original **placed** report, LUTs fall 5,840 (**2.60%**) and occupied CLBs fall
128 (**0.34%**). The F7/F8 counts remain 35,420/14,110. This is a small area
improvement, not a congestion fix or routed utilization result. `Place 46-14`
persists; north/south global estimated congestion regions are now **64×64**,
versus 32×32 in the original placement, and east/west remain 32×32. Placed
WNS is **−24.487 ns**, not final routed timing or a measured Fmax.
The generated placed DCP is **86,412,477 bytes**, SHA
`697f7baf28a2dfddbf9995ca0aa96b3849ab5d50baf408c5e3e5683ba8432992`;
the placed utilization report SHA is
`9b68f0f7a15c3471c119cc81199faaa9d6d7c93c4726cd484fe1d00bd1092305`.
The same native session 8229 then entered default pre-route `phys_opt_design`.
It completed successfully in **1h04m50s**, with zero errors/critical warnings,
77 added cells and 168 optimized cells/nets. Post-optimization WNS is
**−23.574 ns**, still pre-route rather than a routed operating-frequency
qualification. Root read the completed log and hashed the generated
**86,065,623-byte** physical-optimization checkpoint at about **03:44 UTC**:
`impl_area_cong2/rk_ao486_bd_wrapper_physopt.dcp`, SHA
`2953a9a8855c69c2d1abd93127dd5b837e73130a2d4660ca23708ced83261304`.
The worker then entered `route_design -directive AlternateCLBRouting` and
reached Phase 2.2 Pre Route Cleanup. At that milestone, native session 8229 and
the original invocation remained live, without RTL resynthesis or bitstream output. The
pre-route DRC's zero errors do not establish a conflict-free completed route.

The bus-skew-complete final inspection helper is prepared for the exact new
run at `final-inspection-prepared/inspect_completed_impl.tcl` under the
recovery CWD, SHA
`3c07905a95067c154ab3510bf387d09df8c87c554ce2073bad488c0c89608e97`.
Root inspected the full original and the diff: only four run-name references
change from `impl_1` to `impl_area_cong2`. This copy has **not** run natively.
Run it only after actual implementation/native closure and family absence;
the existing completed/fresh-run, full-route and zero-route-error checks,
40/100 MHz constraints and raw timing/CDC/bus-skew reports are unchanged.

Before native use, its bus-skew command was made explicit:
`report_bus_skew -delay_type min_max`. Root read the installed Vivado 2025.2
primary command metadata: `min_max` is supported, whereas the default is
`max`. The prepared helper's current SHA is
`3bdca6472af48333ef1b5d6f3cecde604edc935a01d6961ce5f1e0cea2f26407`;
relative to the protected original it has only the four run-name changes and
this report argument. No active entry, constraint or netlist was edited. This
version still awaits native execution and does not inherit the old copy's
stub-test qualification.

A further fallback was prepared at
`/var/tmp/ventium-impl-area-cong.IfjIKA/impl-area-medium.9i7ufg/launch_impl_area_medium.tcl`,
SHA `a1cefc8f98b4386d10c0a55c6e3d1d85b632f1132c71df528f45ad1302a8fbe8`.
Root read the whole entry and compared it with the previous launch source: only
the usage filename, fresh run name `impl_area_medium`, and placement directive
`AltSpreadLogic_medium` differ. ExploreArea, AlternateCLBRouting, default
pre-route physical optimization, the frozen synthesis parent, 40/100 MHz
checks and native-completion checks are retained. Medium spreading is a
controlled packing experiment, not a promised congestion or timing fix.
It must not launch while `impl_area_cong2` is live. Its final inspection must
target its own run; the `impl_area_cong2` inspector cannot qualify it unchanged.

The high-spread retry subsequently failed routing with `Route 35-3` and
`Route 35-4445`, elapsed **16m20s**. Regional congestion is north **118.100%**,
south **133.842%**, east **130.464%**, west **124.568%**. The live route has
zero failed/unrouted nets but **1,125,751 overlapping nodes**; zero DRC errors
and the successful per-net verification phase do not make it routable.
Root harvested native session **8229**, actual exit **1**, at **04:00:40 UTC**,
then confirmed parent/worker absence and the inactive scope. The final retained
resource sample has zero memory/task events and zero swap: this is another
congestion failure, not an OOM. Its preserved **87,960,506-byte** error DCP is
`impl_area_cong2/rk_ao486_bd_wrapper_routed_error.dcp`, SHA
`02527746a2798cb6d2b2d1d0c4b5f0e685acbc20c1b0f5d382e116b145e9f50a`.

Before launching medium spreading, root renewed all **179** frozen-file hashes
from the frozen CWD (native checksum exit 0), the manifest and synthesis-DCP
pins, and compared the actual XPR's **110** `Verilog_Define` entries with the
manifest (native comparison exit 0). An independent entry review found only
the three intended changes. Through the exclusive launcher, native session
**29785** opened the unchanged synthesis, confirmed **40 MHz core / 100 MHz
PS**, and launched `impl_area_medium` at **04:04:20 UTC**. Its invocation is
`a43ecce4b2354b0c95d2eba695df74f7`; parent/worker identities are
**1886002/32052651** and **1886523/32058699** (PID/start tick). Before worker
fan-out, root set/read back **19 GiB soft / 20 GiB hard RAM, 2 GiB swap,
64 phase-local tasks**, with native property-command exit 0. Future guard source
remains at 48 tasks; CPU job/thread limits stay one. The generated worker reads
the exact synthesis DCP, with no `synth_design`, `read_verilog` or `read_vhdl`;
its script SHA is
`ab5bd8546a53d19dea62277e4ee227cbd8818505a6037dce35a0417c8db75aa3`.
The root launch receipt under the medium recovery CWD is
`ROOT_MEDIUM_LAUNCH_RECEIPT.json`, SHA
`f1c4ab25f638e190b5d6924d7964e0062683680f82dc9c0b1eea3eb61a9d61da`.
This remains an active implementation attempt, not route/bitstream acceptance.

At **04:39 UTC**, medium placement completed successfully in **27m45s**:
zero errors/critical warnings, two warnings. Its fully placed report records
**218,526 LUTs (64.03%), 37,513 occupied CLBs (87.93%), 58,999 FFs,
221 BRAM tiles and 127 DSPs**. Versus the high-spread retry this adds 32 LUTs
but saves **372 occupied CLBs (0.98%)**; F7/F8 counts remain **35,420/14,110**
(F9 zero). Vivado still warns of high congestion: estimated global/long
regions are **64×64 north/south**, **32×32 east/west**. Placed WNS is
**−24.685 ns** at the configured **40 MHz core / 100 MHz PS** clocks; no
qualified operating frequency is inferred from a global pre-route WNS.
The standalone `phys_opt_design` command has started in the same live family.

After the placed-checkpoint generation message, root hashed the completed
**86,545,323-byte** `impl_area_medium/rk_ao486_bd_wrapper_placed.dcp`:
`019a6e6d60c802f5b8efb0a1adbcede7bf2c686dec85a68eea1ab09f33b89e98`.
Its `rk_ao486_bd_wrapper_utilization_placed.rpt` SHA is
`6677760a3aa2f27ff88b303bd73aa413e2cded67f709ede593ebdc442bf63cc3`.
These are completed placement artifacts inside a still-live implementation,
not native-run closure, successful routing, bitstream or hardware acceptance.

At **04:34:05 UTC**, root's existing board SSH session reconfirmed UID 0,
the unchanged boot ID, manager `operating` on the historical image, and
`60000000–6fffffff : reserved` between non-overlapping System RAM intervals.
The staged device-safe daemon, pristine cold VHD, both ROMs and widened probe
still match their recorded hashes; no daemon/capture process was present.
Board root/tmp had **391,041,024 bytes** available. This read-only refresh
does not qualify full DDR clearing, program a new image or start a guest.

The **inactive**, run-bound final inspector is now
`impl-area-medium.9i7ufg/final-inspection-prepared/inspect_completed_impl.tcl`,
SHA `5310b3b89e692741ab991f57caaa5ed5842d251939a5aaef522af9618fc96799`.
Root read all 189 lines and the complete diff: only the four run-name references
change from the min/max-bus-skew-complete helper. It retains all 16 reports and
pre/post full-route/error checks. It has not executed, inherits no old-copy
stub-test qualification, and must wait for actual native closure/family absence.

### Structural follow-ups — read-only, not implemented

The medium attempt remains frozen. Two parallel source/report reviews found
specific follow-ups; neither is a guarantee of routing or 40 MHz operation.

**MUXF packing:** ExploreArea reduced LUTs by 2.60%, but occupied CLBs by only
0.34%, and F7/F8 counts remained exactly **35,420/14,110**. This supports a
packing-pressure hypothesis, not a claim that caches own the absorbed hierarchy
buckets. The installed Vivado 2025.2 primary `opt_design` manual documents
`-muxf_remap` as an opportunistic MUXF-to-LUT3 conversion for routability.
It also explicitly prohibits combining `-directive` with specific optimization
options in one command. If medium spreading fails, the evidence-led next
netlist experiment is separate passes, `opt_design -directive ExploreArea`
then `opt_design -muxf_remap`, after a same-part compatibility check and actual
closure of the live family. No probe, hook or remap has been executed. Compare
MUXF counts, occupied CLBs and congestion before attributing a gain; additional
LUTs or no useful remapping are possible. Do not run a directive sweep or force
bitstream generation around an invalid route.

**SRT request controls:** Root read the frozen `rtl/fpu/fpu_srt_div.sv`
rounder at lines 265–305 and finish states at 454/476: they consume live RC/PC
ports; the accepted request at 324–325 captures mode but not RC/PC.
`fp_shared/ven_fp_top.sv:788–829` defaults these ports to the control word and
overrides PC to 64 bits only for `trans_divide_start`. In the far-ratio FPATAN
path, `ven_fp_trans.sv:979–990` asserts that request for one cycle and waits;
line 403 clears the request subsequently. The requested internal PC64 is
therefore not retained through the iterative divide. This is a proven
request/control mismatch. An architectural wrong-result claim still needs a
non-exact far-ratio oracle case at PC24/53. Normal FDIV/FSQRT admission blocks
control-word changes, so no ordinary-caller RC/PC corruption is claimed.

The completed synthesis report independently shows an EIP-to-SRT-result setup
path with **195 logic levels / 48.652 ns** estimated delay, including live
`srt_rc`, against a **25 ns** requirement. Its **37.846 ns route component is
unplaced estimation**, not measured or final routed delay. The first RTL remedy
to investigate is four RC/PC request flops, captured only at accepted start and
used through finish, with no extra divide cycles or global FPU stall. Required
micros include changed controls immediately after start, non-exact far-ratio
FPATAN at every RC and PC24/53/64, normal divide/sqrt, and reset/busy/back-to-back
ownership. If timing still requires a staged final normalize/jam/round/pack,
preserve single rounding, residual/sticky signs, flags and FP/integer overlap;
that is a separate latency-sensitive change requiring verification. No RTL
change or timing exception has been applied to either follow-up.

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

The second bounded watch has **40 samples over 614.34 seconds**
(02:14:56–02:25:11 UTC, maximum within-batch gap 41.20 seconds). Its final
02:25:40 check holds the original process identities, all 179 source hashes,
110 defines, 40 MHz profile and launch-helper hash. Peak sampled scope RAM is
**8.786 GiB**, swap zero, tasks at most 15/64 and all memory/OOM/task-limit
events zero; average CPU use is one productive core. The explicit gap between
watch batches is retained, not represented as continuous observation. Receipt
`observer-batch.rgvrLnIl/resource-batch.json` has SHA
`3f0f96824d5a22db0bfbfb3a3dc4602625acc3a7f00f76171ad8f9de3acae059`.
Root rehashed/read the receipt and rechecked native session 8229 and its worker;
at **02:27:39 UTC**, placement is in **Small Shape DP / Slice Area Swap**.
There is still no new bitstream or FPGA timedemo/movie acceptance.

At **02:19:06 UTC**, root independently read the board loader and the first
128 bytes of the historical working raw image over SSH (native exit 0).
`/usr/local/bin/load-bitstream.sh` has SHA
`e61f43b393da00d46dbff004e74a0f900bd12a9c5404953dc0bc261f88a3b9d4`;
it installs the supplied bytes unchanged and applies the full-FPGA overlay,
with a legacy manager fallback. Its non-operating-state check is only a
warning: separately require manager `operating`, correct IDENT and measured
held-reset 40 MHz before cold release. The historical raw image has sync bytes
`aa 99 55 66` at offset `0x50`. The new run's `write_bitstream -bin_file`
output must therefore be copied/renamed from `.bin` to a distinct `.bit.bin`
**without conversion or byte-swapping**, then hashed and byte-checked. No new
candidate bytes exist yet; this read-only audit neither programs the board
nor qualifies the old image as the candidate.

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

The final cold-command audit confirms that `--mem 16` only validates the
unchanged 16 MiB backend configuration: startup still maps and scalar-clears
**the full 256 MiB** aperture. Root rechecked its live reservation at
**02:45:05 UTC**: the same boot ID, exact base/size DT cells, zero-length
`no-map`, and root IOMEM `60000000–6fffffff : reserved`, outside both adjacent
System RAM ranges. No guest or capture process was running. The planned
`--secs 600` is a post-release loop budget, **not wall time**; startup and
128 IDE-service polls per iteration are outside its nominal sleep accounting.
Keep a separate whole-run deadline. A hard deadline firing is an unqualified
run, not normal closure. Normal exit closes libc disk handles but neither
checks `fclose` errors nor fsyncs the VHD; after native closure/no writer,
sync and preserve a stable closed copy before console checking. No such
current-candidate cold run has been launched yet.

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

### Generic whole-record capture stop (October 3)

The source-controlled probe now offers opt-in **`--stop-on-sigusr1`** for
`vga-capture`. Its handler only sets a sticky request flag. The capture loop
finishes any in-flight frame, record writes, flush and progress message, then
stops before the next arm. It retains the original declared quota and prints
the actual accepted count and SIGUSR1 close reason. Timeouts, MMIO/drain faults,
broken pipes, KeyboardInterrupt and cleanup failures are not converted to zero.
Previous signal handlers are restored even on error. There is no Quake-specific
producer logic, pacing, guest mutation, RTL change or cleanup MMIO write.

Root independently inspected the complete source diff/test fixture and reran
**19 unittest methods**, actual native exit **0**, **0.009 seconds**, bounded
by 90-second wall / 60-second CPU / 256-MiB address-space limits. Subcases use
both direct handler requests and real own-PID POSIX SIGUSR1 delivery with
mocked MMIO and transport. They cover record boundaries, READY wait/drain,
repeated requests, filtered frames, failures and per-invocation restoration.
This is not real board/SSH/capture or timedemo qualification. Client SHA is
`fd0a83fe16ab6ccce42d6adcaef971c740119326932ec478d21b0393e33c5f68`;
test SHA is `16c0dafc88f44c01142c2154b86858e0ad0b147be06b77695bb47054c9af26fe`.

Send one SIGUSR1 only to the verified live capture PID/unit after the
required endpoint is independently observed; wait for genuine closure. A
request does not bound an in-flight wait/drain/write, so retain outer deadlines
and actual nonzero failure statuses. Successful VSYNC completion naturally
clears capture-active in the RTL; closing the mapping alone does not cancel an
arm, and writing zero to the W1P is not an abort. Header-only/empty captures
cannot become movies or timedemo evidence.

The frozen image manifest **adfb…** and original client **cd284…** remain
unchanged. The old helper bundle deliberately rejects this new runtime client;
use separately reviewed/pinned derivatives which distinguish frozen hardware
ABI ancestry from the new host-side tool SHA. The old normalizer/assembler
accept integer nonzero producer/transport exits for **forensic prefixes** and
retain all acceptance/coverage flags false; that is not clean-capture success.

At **05:17 UTC**, after host headroom had fallen to about 4.8 GiB, root followed
the user's existing Chrome-termination instruction. It verified main PID
**1899606**, UID 1000, `/opt/google/chrome/chrome`, no renderer `--type`, and
start tick **32412723**, then sent SIGTERM (native exit 0). The PID was absent
afterward and host available memory recovered to **14,343,245,824 bytes**.
Vivado's original worker remained productive and unswapped, with zero
memory-max/OOM events. Its idle parent had filled the unchanged **2-GiB** swap
cap, recording **6,596 max/fail swap events**; do not call all resource events
zero. No Vivado restart or limit increase was made.

The separate runtime movie bundle is
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/runtime-movie-bundle.Oz2wfq`.
Root reviewed its provenance/decoder changes and independently reran the
bounded host gate (actual exit 0): normalizer SHA `e062bf67…`, assembler
`d03a2be8…`, unchanged RGB decoder `ef46…`. Fixtures prove byte-exact decoded
RGB at 15 fps, partial-tail preservation and rejection of wrong runtime/base
pins; all timedemo/coverage acceptance flags remain false. At 05:26 UTC the
new client was staged as root-owned mode 0444
`/tmp/ao486/ven_board_probe.sigusr1-oct03.py`; its board SHA matches `fd0a83…`
and its help command recognizes the new option. The old `cd284…` client is
unchanged. No board guest, capture, new programming or hardware qualification
has occurred at this point; the original Vivado implementation is still live.

### Medium-run timeout and explicit MUXF fallback (October 3)

At **08:03:18 UTC**, the medium-spread implementation's actual native handle
`29785` closed with **exit 124** at its existing four-hour deadline. It was
still in pre-route critical-path optimization; no routed checkpoint, bitstream
or BIN was produced. This was a timeout, **not an OOM**: the final original
resource samples had no memory-max/OOM/pids event, worker swap remained zero,
and historical scope swap max/fail counters remained 6,596. At 08:03:29 UTC
root confirmed the original PIDs absent, scope inactive and no executable
under the Vivado installation left in `/proc`. The placement remains only
placement evidence (218,526 LUTs, 37,513 CLBs, WNS −24.685 ns), not routed Fmax.

The closed run retained stale `Running phys_opt_design...` metadata. After
independent family closure, a separate guarded batch used supported
`terminate_runs impl_area_medium`, **never `reset_runs`**. Native handle
`78741` exited zero and the status changed to `phys_opt_design ERROR`; the
tool's attempt-to-kill warning reflects the already absent process. The
placed/opt checkpoint and original run-log hashes were unchanged afterward.
This metadata recovery does not convert the original timeout into success.

Before another full attempt, root ran the explicit same-part structural probe
at `/var/tmp/ventium-muxf-remap-explicit-probe.fJUEkE` through the exclusive
guard, with a 180-second deadline. Native `97812` exited **0**. Actual MUXF
inventory was **16 F7 + 8 F8** after both synthesis and `ExploreArea`, then
**zero** after the separate `opt_design -muxf_remap` call. Tiny routing reported
`ROUTED_FULLY=1`, `ERRORS_IN_ROUTES=0`, zero node overlaps, and the final close
marker. Its out-of-context warnings/unconstrained external paths mean this is
**tool compatibility only**, not Ventium timing, functionality or routability.

At **08:07:04 UTC**, root launched fresh `impl_area_muxf` (native `7139`) from
the unchanged `synth_1` checkpoint **43cf…**, with all 179 frozen input hashes
matching and exactly the same 110 defines. It preserves the 40-MHz core /
100-MHz PS clocks, medium spreading and `AlternateCLBRouting`; the new
optimization post-hook runs the separate supported MUXF remap operation after
`ExploreArea`. This is a post-synthesis netlist transform, not an RTL rebuild.
The sole new family is bounded to one job/thread, 20-GiB resident memory,
2-GiB swap and initially 48 tasks, with a four-hour deadline and 75-second
cleanup allowance. The deadline is **not a completion estimate**. No new
hardware image, cold guest run or movie acceptance exists at launch.

At **08:15 UTC**, the actual full-design hook completed successfully after
the 6m06s `ExploreArea` pass. Vivado reported **47,926 MUXFX primitives
transformed into LUT3**, with zero errors; the separate remap pass took 24s.
The generated worker sources this hook once, before the opt checkpoint and
placement. This proves the full transform executed, **not** that utilization,
congestion, routing or timing improved; those require downstream reports.

Placement completed by **08:48:42 UTC**, in 32m56s with zero errors/critical
warnings. Root read the complete 257-line placed utilization report. The
remap **increased** LUTs from 218,526 (64.03%) to **262,059 (76.79%)**, and
occupied CLBs from 37,513 (87.93%) to **41,062 (96.25%)**. That is +43,533
LUTs and +3,549 occupied CLBs; it is not an area reduction. F7/F8 counts fell
to 1,092/512, while BRAM tiles/DSPs remained 221/127. The placer still warned
of high congestion: global regions N/S/E/W were 64×64 / 32×32 / 32×32 /
16×16, and long-congestion regions 64×64 / 64×64 / 32×32 / 64×64.
Placed WNS estimate was **−29.714 ns**, versus medium's −24.685 ns, at the
unchanged 40-MHz core constraint; neither number establishes routed Fmax.
The placed checkpoint SHA is **ff8bb02f…**, utilization report **f7708e94…**,
and opt checkpoint **0c0afa9f…**. The same live worker then entered standalone
pre-route physical optimization. It remains under the original deadline;
no route, bitstream, deployment or timedemo acceptance follows from placement.

By **09:14:42 UTC**, standalone `phys_opt_design` completed successfully in
**24m53s**, with zero errors/critical warnings and two warnings. Its final
pre-route WNS estimate was **−28.899 ns** (TNS −1,085,318.392 ns); this is
not a routed clock-frequency qualification. The physopt checkpoint SHA is
**0897118e215e4a49295c673823809650a773f99adf68b2a531ce886ccc518bdb**.
The same worker then actually entered `route_design -directive
AlternateCLBRouting`; the preceding route DRC reported zero errors, but
routing itself was still incomplete. No new Vivado instance was launched.
The sealed resource watch through 09:13:41 UTC retained all 179 input hashes,
exactly 110 defines and the original process identities, with zero current
memory/swap/pids-limit events and zero worker swap. Its receipt SHA is
**8d82268319597626c67d2016e9e3e8e02427f4c59aae5679ae85426e079cc1f2**.
Neither this phase completion nor the route command proves a valid route,
bitstream, hardware timedemo result or full movie.

The global-remap attempt **failed routing** and native `7139` exited **1**
at **09:31:07 UTC**. `route_design` took 16m29s and reported global congestion
level 6, estimated global/short and timing levels 7 (128×128), and
**1,173,350 node overlaps**. Its zero unrouted-net count does not make that
overlapping route valid. The failed checkpoint SHA is **3d015b41…**, worker
log **d88e8259…**. No BIT/BIN exists. The final original observer retained
all pins, zero worker swap and zero current memory/swap/pids-limit events;
this was **not an OOM**. Root harvested the actual failure, confirmed both
original PIDs absent/scope inactive, then found **zero** executables under
the Vivado installation at 09:31:38 UTC before another launch.

The lower-expansion follow-up first used a separate, bounded same-part probe
at `/var/tmp/ventium-muxf8-property-probe.gj50Fu`, through the exclusive guard.
Native **10165 exited 0** at 09:35:35 UTC. Unchanged explicit RTL retained
16 F7 + 8 F8 after synthesis and `ExploreArea`; marking only actual `MUXF8`
leaf cells with `MUXF_REMAP=TRUE`, then separately running
`opt_design -property_opt_only`, produced **16 F7 + zero F8**, with the
original F7 names intact. Final tiny routing remained 16/0, fully routed
17/17 nets with zero route errors, and no-waiver DRC found zero checks.
Root confirmed all Vivado executables absent again at 09:36:18 UTC. This
proves **installed-2025.2 selective tool behavior only**: OOC warnings and
unconstrained external paths preclude a frequency qualification, and it
does not establish Ventium area, routability, timing or guest correctness.

At **09:41:31 UTC**, root launched fresh **impl_area_muxf8**, native **87162**,
from the unchanged frozen synthesis checkpoint. Before the exclusive guard,
an exhaustive scan again found zero Vivado-installation executables; all 179
inputs still matched. The launcher/hook SHAs are **59e9a721… / 96ec087f…**.
Root fully reviewed both, including the final hook revision: only actual F8
leaves are marked, original F7 names/count must remain, and F8 count must
decrease. LUT3 delta is recorded, not capped by an unproven one-LUT-per-remap
assumption. All four prior run directories are preserved; none is reset.
The existing area/medium-spreading/default-physopt/AlternateCLB flow remains,
with no post-route physopt, unchanged RTL/caches and no RTL-synthesis rerun.
The same 20-GiB RAM / 2-GiB swap / 48-task caps, one job/thread, four-hour
deadline and 75-second cleanup allowance apply. They are not an ETA.
The actual worker is **2048306** under invocation **10bfa34c…**. Root reviewed
its entire diff against the previous generated worker: only run names and
the one hook path changed (worker SHA **05c83a1e…**). Creation legitimately
changed XPR SHA to **06bdffc5…**, while exactly 110 unique defines remain.
The launcher confirmed **40-MHz core / 100-MHz PS constraints**, not measured
hardware frequency. Placement, route, bitstream and hardware acceptance are
still pending at this launch record.

By **09:50:05 UTC**, the full-design property-only hook completed in **24s**,
with zero errors: F7 **35,420→35,420**, F8 **14,110→512**, other MUXF types
zero. Exactly 14,110 F8 leaves and no F7 were marked; **13,598 F8s** actually
converted, adding 13,598 LUT3s, with original F7 names/count preserved.
This is substantially less remap expansion than the failed global pass's
47,926 conversions, **not proof of a downstream utilization or routing gain**.
The completed opt checkpoint SHA is **4a5d7f25…**, rechecked after its write
completion marker. By 09:51:54 UTC the same worker was in global placement
under `AltSpreadLogic_medium`. Route/timing/hardware acceptance remains false.

Placement completed by **10:20:40 UTC**, in **30m27s**, with zero errors or
critical warnings. Root read the entire 257-line placed utilization report:
**230,966 LUTs (67.68%)**, **38,639 occupied CLBs (90.57%)**, 59,005 FFs,
zero latches, 35,420 F7 / 512 F8, 221 BRAM tiles and 127 DSPs. Selective F8
remapping uses 31,093 fewer LUTs and 2,423 fewer CLBs than global remapping,
but **12,440 more LUTs and 1,126 more CLBs than the no-remap medium baseline**.
It is therefore not an area improvement over that baseline. High-congestion
warning `Place 46-14` remains: global regions N/S/E/W are all 32×32, and
long-congestion regions are 64×64 / 64×64 / 32×32 / 32×32. These placement
estimates do not establish routability or routed Fmax. The completed placed
checkpoint SHA is **9a3fff99b5935b92d36be7930a5c5ea34b2956c50dd504f30b67a1bbafd41902**;
utilization report SHA is **1faaadb4b834374c0268cd82f419563be9491dbb60c8045f50c31764a80a16ad**.
The same worker entered standalone pre-route `phys_opt_design`; routing,
bitstream, deployment, timedemo and full-movie acceptance remain pending.

By **10:50:38 UTC**, standalone `phys_opt_design` completed successfully in
**28m53s**, with zero errors/critical warnings and two warnings. Final
pre-route estimated WNS/TNS were **−23.090 ns / −729,131.629 ns**; these do
not establish a routed Fmax or qualify the 40-MHz constraint. The completed
physopt checkpoint SHA is **12d2c8c0de2563a7981a0fe0fabf3134b27b272c666f4b42f18f8d0e6fa8868c**.
The same worker actually entered `route_design -directive AlternateCLBRouting`
and route phase 1. Pre-route DRC reported zero errors, but this is not route
acceptance. Root's direct cgroup checks showed zero current memory, swap and
task-limit events and zero swap use. The original build remains live; no
second Vivado job, new bitstream, deployment or hardware timedemo is claimed.

The selective-F8 attempt **also failed routing**. Root harvested native
**87162 exit 1 at 11:06:47 UTC**; `route_design` took **15m55s** and reported
global congestion level **6**, global/short and timing congestion estimates
**7**, and **1,115,370 node overlaps**. Zero unrouted/partially routed nets
and zero post-failure DRC errors do not make this an electrically valid route.
Peak global directional demands were N **96.4841%**, S **123.004%**,
E **106.004%**, W **119.746%**. No BIT/BIN exists. The failed checkpoint SHA
is **78a72ef003ef2072a0559c76b1e986f424cc7aed02f54a3e69fcd73d6ff5ffdb**;
closed worker log SHA is **3a8e6086fbc5b88ee046fe8d706679ef6349549fad29a535d9968942e0cb13e2**.
Root confirmed both original PIDs absent/scope inactive and independently
enumerated **zero Vivado-installation executables** before any subsequent
tool launch. The final bounded observer retained all 179 input hashes,
110 exact defines and all script/XPR pins, with zero worker/parent swap or
current limit/OOM events. Its final sample predates root's native closure;
neither is substituted for the other. This was congestion, **not an OOM**.
The next action was a bounded read-only failed-checkpoint inspection and
source-structure audit, not another unsubstantiated implementation variant.
Routing, deployment, hardware timedemo and full movie remain unachieved.

Verified gameplay IPC remains **0.42633263**, simulation build **5c2491f3**,
cycles **7,099,999,637–7,199,999,637**. It predates this FPGA candidate; the
current candidate's gameplay IPC is unmeasured.

### Source-led repair after the routing failures (October 3)

The read-only failed-F8 checkpoint inspection closed with native exit **0**
at **11:13:48 UTC**. Reloading its error checkpoint reports **271,369 unrouted
nets / only four fully routed nets**; the failed router's overlap state is not
a legal routed design. The reported 178-level, 48.008-ns segment-base-to-SRT
path mixes estimated delays and is **not routed Fmax**. Vivado also explicitly
ignores `-path_type` when combined with `-of_objects`; the requested expanded
clock-path coverage must not be claimed from that command.

Two independent source audits selected the repeated frontend tag queries as
the first bounded RTL area experiment. The candidate computes two pre-edge
`{present,way}` lookups and a shared 22-byte window for raw U/V decoding and
16-byte reference/slow captures. It preserves full P5 caches, every pipeline
cycle, last-match way/bypass priority, returned BRAM identity/collision checks,
stale-A fallback, and generic PrefixEX/endpoint queries. The first leaf-only
area measurement is recorded below; a whole-chip gain is still unmeasured.

Strict lint of the actual 110-define hardware profile additionally exposed a
**preexisting synthesis-only functional defect**: the sole `seg_ext_size`
assignment was inside `ifndef SYNTHESIS` instrumentation, although the
functional protected-mode limit check consumes it. The unchanged assignment
is now next to its unconditional declaration. Both the actual hardware profile
and the 107-define simulation profile plus DPI suppression close strict lint
with native **0**, including fatal UNDRIVEN/LATCH/UNOPTFLAT checks. The cache
snoop gate, all three alias-discrimination configurations, and issue-UV gate
also close with native **0**. These do not substitute for the differential
gate or standard suite.
The first `make verify` attempt stopped before compilation because its default
scratch symlink points to the full external volume; subsequent scratch uses
`/var/tmp`, leaving that volume unchanged.

The production-extracted span miter passes with and without fetch bypass;
both non-BRAM variants pass explicitly labelled generic-byte smoke tests.
Retained span logs are under
`/var/tmp/ventium-frontend-factor-oct03.RYgdDXkl/ventium-ic-front-span.IHNavI/`.
That first umbrella invocation failed because its segment-test coroutine
counter printed zero. The corrected, segment-only retry closes with native
**0** under `ventium-ic-front-span.ooabZN/`: both preprocessing modes retain
exactly one driver and both mux tests check all **8,192** combinations, with
elapsed-time coverage. It does not rerun or replace the retained span logs.
The independent segment-driver repair is committed and pushed as **f24909e**.

The same-part old/new OOC comparison closes with native **0** at **11:48 UTC**,
in `/var/tmp/ventium-ic-front-span-ooc-synthopts.FhSGPv/`. Isolated frontend
LUTs fall **40,863 → 4,881 (88.05%)**, F7 muxes **17,866 → 1,584**, F8 muxes
**8,112 → 752**, and CARRY8s **184 → 16**; both have **304 FFs**, zero latches,
and no BRAM or DSP. Identical capture registers are merged in both models.
These are **synthesized leaf-model counts, not whole-chip area, routed CLB
occupancy, timing, or Fmax**. The exact production section/oracle include is
generator-pinned to core SHA **630663db…520053**. The two earlier probe attempts
closed with native **1** before synthesis because their non-project Tcl used
unsupported `read_verilog` options; both original logs are preserved.
Fresh default and BRAM differential TB builds use **32** compiler jobs within
the fixed **16 GiB / 128-task** scope, isolated under
`/var/tmp/ventium-verify-current.0hQwc7/`. Both builds and both `make verify`
invocations close with native **0**: **108 functional programs**, including
x87, and every required M4/M5 cycle metric band pass in each configuration.
The 20 structural per-instruction cycle diagnostics remain labelled divergent
and non-gating; this is not a claim of exact per-instruction cycle equivalence.
Default TB SHA is **70e4b7d…978bfb**; BRAM TB SHA is **f27bd70c…e5f3f4d**.
No canonical TB or full FPGA implementation is launched by these focused tests.

A new explicitly **UNQUALIFIED** frozen candidate is
`/var/tmp/ventium-fpga40-icfrontspan.yqNVao/`: all 179 parent inputs are checked,
177 are unchanged, and only `core.sv` and `core_fetch_decode.svh` are replaced.
The exact 110 defines, full P5 caches, shared FPU and 40/100 MHz clocks remain
unchanged. Candidate manifest SHA is **b94db3dc…178270**; original manifest
**adfb6ff1…21c1c** is retained independently. All new frozen-file checks and the
pure-Tcl wrapper contract test pass. Live source comparison finds only the two
previously recorded **host-tool** differences (implementation reporting and
SIGUSR1 capture stop); the frozen RTL/flow inputs have no additional drift.
The synthesis profile stays **balanced / Default**, matching the actual
previous synthesis transcript rather than the wrapper's legacy default.

The frontend change and focused tests are committed/pushed as **659b4c0**;
unrelated preexisting V86/debug changes remain unstaged. Fresh **synthesis
only** launched at **11:54 UTC** in the new candidate's owned `output/`
directory, through the sole-Vivado guard with **20 GiB RAM / 2 GiB swap / 48
tasks**, one worker and a four-hour deadline. The deadline is not an ETA or
acceptance criterion. No implementation or deployment is authorized by a
pre-route result alone; inspect the fresh area before proceeding to routing.
The current-source standard suite, final routed frequency/CDC and DRC, cold
board boot, exact hardware 969-frame completion and complete movie remain
unachieved.

The candidate is unqualified and not deployed. Gameplay IPC baseline remains
**0.42633263**, build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**;
it predates these changes, whose gameplay IPC is unmeasured.
