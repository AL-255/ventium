# Ventium: performance evolution from the original 0.1x baseline

Report date: **2026-10-10** (initial consolidation 19:39 UTC; later evidence
updates identified below). This consolidates the early September
CPI work, September structural/CoreMark work, and October FPGA backport and
cache-backed optimization work. It includes measured gains, unsuccessful
experiments, correctness repairs, and the limits of the attribution. Historical
results below are retained measurements, not tests rerun for this report.

## Executive result

- **Latest verified simulated gameplay:** **0.49366456 U+V retirement-event
  IPC**, model `bfb867f7`, cycles **5,200,065,237–5,300,065,237**. All **41
  consecutive 100M-clock windows**, starting at 1,200,065,237, average
  **0.498471873**: 2,043,734,681 events / 4,100,000,000 clocks. No low window
  is discarded. This is not a complete-timedemo average.
- **Same model, valid-duration cache-backed CoreMark:** **2.101890118 /
  2.107616105 CM/MHz**, performance/validation seeds, with original CRCs.
- **Last verified physical-FPGA gameplay:** **0.167990963 primary/U-event
  IPC**, installed image `fe9f539d`, measured **39.999826 MHz**. Its complete
  original Quake timedemo reports **969 frames / 288.6 seconds / 3.4 FPS**.
  This ABI does not expose total U+V. These are still the hardware results;
  the new simulated performance has **not** been demonstrated on the board.
- **Newest candidate:** `2b4d7a48`, incorporating subsequent logic-sharing,
  x87 C1 and packed-BCD negative-zero corrections, has **no gameplay
  measurement or physical pass**.
  Its own two **900-iteration, duration-valid CoreMark seeds** now independently
  pass at **2.101890118 / 2.107616105 CM/MHz**, with exactly the parent's TSC
  clocks and original CRCs (closure checked 21:21 UTC). Thus these repairs have
  **0% measured CoreMark throughput cost/gain**. Its matched FPGA source export
  and strict CPU-hierarchy lint pass. Synthesis and the native unplaced audit
  have closed; implementation is routing and its Quake/Win95 tests continue,
  with no new bitstream yet. See [the source-matched handoff](../fpga/ZERO_C1_EXPORT.md).

**There is no defensible measured “0.16 to 0.54, therefore 3.3× faster FPGA”
claim.** Those endpoints differ in counter definition, platform, build and
work window. The work has produced substantial demonstrated local improvements
and a substantially better simulated processor, but the end-to-end hardware
gain remains to be measured.

## 1. What the original 0.1x numbers mean

The history contains two distinct low-IPC starting points. Both are included
to avoid silently choosing the more flattering denominator.

| Starting point | Actual measurement | What it proves / does not prove |
| --- | --- | --- |
| September 7 cold Quake-startup simulation, 45 MHz board-delay model | 18,378,743 retires / 99,999,637 counted clocks, approximately **0.183788 IPC / 5.441 CPI** | Startup/checksum work, not rendered gameplay. The later fixed 100M-clock cold comparisons are useful within this cohort, not against October gameplay. |
| October hardware baseline `53f129e9`, 37.499870 MHz | **0.165995778 primary/U IPC**, 1,631,525,491 events / 9,828,716,788 qualified clocks; 127 intervals within 8,721,490,845–19,169,282,165, frames 37–898 | Real active-timedemo hardware measurement, with gaps between accepted intervals. V retirement is missing from the numerator. It does not mean the CPU executed U-only. |
| Later bank64 hardware `fe9f539d`, 39.999826 MHz | **0.167990963 primary/U IPC**, 397,461,413 events / 2,365,969,019 qualified clocks; 59 intervals within 2,648,748,396–5,129,027,099 | Real completed-run hardware profile. Different scenes prevent treating the small numerical change from 0.165996 as a speedup. Total U+V remains unknown. |

Sources: [early CPI log](../CPI_PROGRESS_Sep05.md),
[initial hardware measurement](FPGA_CMP_BRANCH_LOCALIZATION_2026-10-05.md),
[closed bank64 hardware profile](UV_FAST_BANK64_2026-10-08.md).

There is a second instruction-count distinction: legacy retirement callbacks
can count **REP elements**, not one completed x86 macroinstruction per REP.
Consequently, current “U+V IPC” is explicitly **retirement-event IPC**. A
primary-only counter must not be compared with U+V, and neither should silently
be advertised as canonical P54 macroinstruction IPC. QEMU supplies functional
reference state, not an independent silicon cycle/IPC oracle.

## 2. How gain is attributed in this report

Every change below has a gain or an explicit **not isolated / not established**
entry. Unknown gain does not mean zero gain.

- **Matched work:** with the same completed work, throughput gain is
  `100 × (old_clocks / new_clocks − 1)`; clock reduction is
  `100 × (1 − new_clocks / old_clocks)`. These are different percentages.
- **Microbenchmark gain:** causal evidence for that instruction/service
  pattern, not its weighted contribution to Quake.
- **Fixed-clock gameplay observation:** `new_IPC / old_IPC − 1` describes the
  observed intervals. Different instruction/scene/interrupt progress prevents
  automatically interpreting it as equal-work speedup.
- **Bundles:** the aggregate can be measured without establishing each member's
  contribution. Bundled gains are not divided arbitrarily among fixes.
- **Area/timing:** LUT reduction and estimated frequency are separate from
  IPC. Unplaced estimates are not routed sign-off or measured core frequency.

Successive throughput percentages **compound, not add**. Profiler occupancy
percentages also do not establish removable stalls: cache wait, pipeline wait
and FP-owner wait can describe the same clocks.

## 3. Gameplay milestones, without hiding reversals

This is a chronology, **not one controlled cumulative speedup experiment**.
Early models used different cache/transport/timebase profiles; some included
uop-cache or enhanced-pairing experiments absent from the current raw-byte
profile. The October board-faithful simulation lineage is listed separately.

### September simulation lineage

| Stage | Measured gameplay IPC / window | Attribution limit |
| --- | --- | --- |
| Early baseline versus byte-MOV/system-corrected v6 | **0.213052 → 0.236256**; roughly 1.30–1.40B | **+10.89% observed interval IPC**; slightly different endpoints and bundled changes, not isolated byte-MOV gain. |
| Frontend-boundary/paired-carry repair cohort | **0.228761 → 0.266919**; 1.30–1.80B | **+16.68% observed interval IPC**, not a frame-aligned throughput comparison. |
| Load-result forwarding | **0.27185417 → 0.27188452**; 1.20–1.30B | **+0.011% observation: negligible gameplay benefit**, despite a strong directed bypass result. |
| Cross-line decode priority/capture | **0.27188452 → 0.28845722**; 1.20–1.30B | **+6.10% observation**; includes the console transition and is not fixed work. |
| MOVS continuation/CROSS2 | **0.28845722 → 0.29337930**; 1.20–1.30B | **+1.71% observation**; the subsequent load-fusion flag is not in this measured build. |
| Memory-FP admission/final-response handoff bundle | **0.29337930 → 0.30841317**; 1.20–1.30B | **+5.12% observation**, not an isolated handoff gain. |
| Tag-policy versus early-command asynchronous FP | **0.346822 → 0.362346**; approximately 1.30–1.35B | Broader windows than the 1M diagnostics; different start states. |
| FP-stream candidate | **0.37142514**, 100M gameplay window | Its separate 1M diagnostic is only **0.258432**; neither substitutes for the other. |
| Corrected queued FXCH, then generalized cache streaming | **0.39207514 → 0.39233706**; approximately 1.05–1.10B | Tiny change; **no substantial isolated gameplay gain established** for generalized streaming. |
| Wave7 integrated frontend/memory/FP work | **0.44145741** over 1.00–1.10B; **0.44455543** over 1.05–1.10B | Bundle result. The adjacent 1.100–1.101B trace is **0.297507**, retained rather than hidden. |
| Integer branches overlapping outstanding FP | **0.44414178 → 0.44963946**; matched-start 1.10–1.15B replay | **+1.24% fixed-clock IPC**. Separate common 50,000-retirement prefix finishes 2,316 clocks earlier; full timedemo not qualified by replay. |
| September 27 structural/fidelity repairs | **0.426371504**, 1.15–1.40B | Exactly the historical control's count and five identical frame pairs: **zero observed gain in that comparison**. |
| September 28 P54 candidate | **0.439444155 → 0.454503465**, matched 200M-cycle windows near 1.15–1.35B | **+3.43% observed IPC**; 2,783,347 of 3,011,862 additional events are V events. Not proof that pairing alone caused the gain. Longer candidate window gives **0.457219**. |

Sources: [early CPI history](../CPI_PROGRESS_Sep05.md),
[load forwarding](../verif/issue_uv/LOAD_ISSUE_IPC.md),
[cross-line frontend](../verif/uopcache/CROSSLINE_EXPERIMENT.md),
[MOVS](../verif/rep_sfetch/MOVS_CONTINUATION.md),
[memory FP](../verif/issue_uv/FP_MEMORY_ADMISSION.md),
[FP/integer overlap](../verif/issue_uv/FP_INTEGER_OVERLAP.md),
[September 14 trace](IPC_STATE_TRACE_Sep14.md),
[September 20 trace](IPC_STATE_TRACE_Sep20.md),
[September 26 A/B](IPC_STATE_TRACE_Sep26.md),
[September 27 status](P54_IPC_IMPLEMENTATION_STATUS_2026-09-27.md),
[September 28 measurement](P54_IPC_CANDIDATE_QUAKE_TIMEDEMO_2026-09-28.md).

### October board-faithful simulation lineage

Unless stated otherwise these are first declared 100M gameplay windows near
1.20–1.30B; actual periodic-counter offsets are retained in the source records.
All numbers in this table count U+V, unlike the old hardware primary-only ABI.

| Model / included milestone | Gameplay IPC | What the comparison says |
| --- | ---: | --- |
| `3c8779f4`: actual RTL DDR bridge, posted-16 transport | **0.37582311** | First board-faithful posted16 window. **Not** a measured hardware jump from 0.167991. Its 1.2–3.0B aggregate is only **0.37026314**. |
| `ba2463bf`: protected reference dispatch | **0.38065044** | Modest observation; no isolated whole-demo gain. |
| `4b5fb92f`: primed-U/V ownership repair and combined source | **0.37798811** | Retained lower result; correctness repair did not establish a gameplay speedup. |
| `e44e3176`: memory-FP forwarding/under-fill combination | **0.38064497** | Much smaller gameplay movement than its favorable arithmetic microloops. |
| `50f37229`: L2 replacement-owner repair | **0.38588696** | Cold-run observation, not an isolated LRU percentage. |
| FP-pop drain, then instruction-word reuse | **0.38776687 → 0.39002079** | Small successive observations; word-reuse model `f3be9a11`. |
| `05611d6c`: compact tags, D hits during I fill, short x87 fetch | **0.39555990** | Combined changes; not separable from this measurement. |
| `139121ae`: REP continuation independent of uop-cache enable | **0.43739106** | **+10.58% observed IPC** versus preceding window, not equal-scene attribution. |
| `1f2583cb`: multi-page instruction-permission shadow | **0.44513116** | **+1.77% observed IPC** versus REP window. |
| `59650fe2`: checked target pre-read | **0.44468922** | **No observed gameplay gain**. |
| `15f56054`: read-retirement priming | **0.44004644** | **No observed gameplay gain**; sample offset is 12,763 clocks. |
| `652de481`: scalar FP dispatch + m64 queue | **0.44183623** | Small observation; strong micro gains do not establish a large Quake contribution. |
| `f780b331`: final scalar handoff + reference/AGI priming | **0.44439995** | Approximately **+0.58% observed IPC** versus combined-FP window. |
| `e9097d96`: AXI read-command forwarding | **0.43894030** | **No observed gameplay gain**. |
| `86731249`: 256 KiB platform L2 + initialization backpressure repair | **0.49083588** | **+11.82% observed IPC** versus read-through window; not equal-work attribution. Longer 1.2–3.0B aggregate is **0.47771903**, including the 0.26103520 dip. |
| `958f7ec4`: 16-bit demand fetch | **0.486272178** over 28 consecutive windows, 1,200,048,811–4,000,048,811 | Longer aggregate, not the same window as the row above. |
| `bfb867f7`: final cache-backed performance backports | **0.51030715** first window; **0.498471873** over all 41 windows | Latest single window **0.49366456**, exact endpoints in the executive result. Full demo still not completed in this audit. |

Sources: [October 8–9 hardware/transport chronology](UV_FAST_BANK64_2026-10-08.md),
[October 9–10 optimization record](UV_FAST_TARGET_STATUS_2026-10-09.md),
[current cache-backed measurements](CACHE_BACKED_TARGETS_2026-10-10.md).

### Matched-build IPC / FPS table — follow-up checked October 10

The user requested an empirical relationship between IPC and gameplay FPS.
Two earlier 40 MHz simulations have both a verified gameplay window and a
subsequently closed, completed original 969-frame timedemo. Their model hashes
and actual `--rate 40000000` launch arguments were rechecked for this table.

| Build | Platform / core clock | Verified gameplay event IPC | Complete timedemo frames / guest seconds | FPS from printed frame/time totals |
| --- | --- | ---: | ---: | ---: |
| `fe9f539d` | Physical FPGA / 39.999826 MHz | **0.167990963, primary/U only** | 969 / 288.6 | **3.36** (guest prints 3.4) |
| `652de481` | Simulation / 40 MHz | **0.44183623, U+V** | 969 / 138.4 | **7.00** (guest prints 7.0) |
| `86731249` | Simulation / 40 MHz | **0.49083588, U+V** | 969 / 128.1 | **7.56** (guest prints 7.6) |
| `bfb867f7` | Simulation / 40 MHz | **0.51030715, U+V**, first window | Pending | **Not measured yet** |

The simulation IPC column uses the first declared 100M-clock gameplay window
near 1.2–1.3B, **not full-demo average IPC**. The `bfb867f7` window is
1,200,065,237–1,300,065,237; the other two are exactly 1.2–1.3B. Its separately
reported latest window is now **0.49366456**, 5,200,065,237–5,300,065,237;
the prior 4.5–4.6B window was **0.53765810**. Neither is a full-demo mean.
The hardware row uses its 59 qualified intervals described in section 1.
Never fit one U+V IPC/FPS curve through the primary-only hardware row.

Across the two completed 40 MHz simulations, the sampled-window IPC rises
**11.09%**, while complete-demo throughput rises **8.04%**, calculated from
138.4/128.1 rather than the coarsely rounded printed FPS. This is useful
same-build paired evidence, but not a constant IPC-to-FPS conversion or an
isolated attribution to one RTL feature: the models differ by multiple changes
and their IPC samples cover different scene progress.

The exact relationship, when measured over the **same work interval**, is
`FPS = clock_Hz × retirement_event_IPC / retired_events_per_frame`.
The counter definition, workload/settings and measurement interval must match.
For a calibrated comparison, retain total U+V counters at timedemo start/end
alongside the full frame count and core frequency; do not infer FPS from a
short high-IPC scene or from a 15-fps presentation movie.

The closed simulation results and their limits are documented in
[disk-write visibility](../ao486-sim/ven/DISK_WRITE_VISIBILITY.md).
Exact retained closure evidence:
`external/tmp/ventium-code-payload-soc.1oJrvfzN/superseded-controls-closed-audit.json`;
IPC evidence: `ventium-fp-combined-gameplay.ERa7LHqZ/window/audit.json` and
`ventium-l2-gameplay.VedZVnwA/window/audit.json` under the same external scratch
root. Both old simulators exited zero and were reaped; the complete Quake
components do not qualify newer candidates, Win95, or physical FPGA.

## 4. Gain ledger: individual techniques and their evidence

### 4.1 Early cache, translation and dispatch work

These are historical results in their original configurations. They are not
all cumulative, and a boot-only gain is not credited as gameplay gain.

| Change | Measured gain | Scope / current interpretation |
| --- | --- | --- |
| Correct cache enable after ROM left CR0.CD/NW set | Reported **3.77× cold-boot throughput** | Configuration repair in the early boot experiment; not a general cache redesign or Quake gameplay speedup. |
| Page-safe finite-segment fast accesses | **6.55 → 4.73 CPI**, approximately **+38.48% throughput** | Reported cache-enabled boot profile; faults and extents remain checked. |
| Remove obsolete system-mode fast-path exclusion | **13.67 → 9.00 CPI**, approximately **+51.89% throughput** | Early POST profile. The broad 16-bit extension diverged and was not accepted. |
| Associative DTLB instead of conflict-prone direct mapping | Walks **2.411M → 0.198M**, **91.8% fewer**; combined checkpoint **92.56M → 74.43M clocks**, **+24.36% throughput** | Combined checkpoint does not isolate DTLB from other cache work. Separate 100M-clock startup DTLB2 comparison reports **+30.943% retires** versus streamed-L2+ADD7 control. Later design uses P54-sized/banked translation, not this exact 32-entry prototype. |
| Lower-half L2 streaming, retaining one DDR burst | **+2.036% retires** in the matched 100M-clock cold observation | 18,378,743 → 18,752,852; not fixed-work gameplay. |
| Generic seven-byte SIB+disp32 ADD fast packet | **+0.667% retires** over streaming-only cold observation | 18,752,852 → 18,877,858; small, general encoding optimization. |
| Registered already-arrived fill-word forwarding | **+0.141% cold-window retires** | Not a large end-to-end benefit. |
| Add independent-set hit-under-fill to that combination | Combined forwarding+HUF **+0.385% cold-window retires** over their control | The earlier isolated HUF cold A/B was only about **0.3%**; the larger synthetic cache-profile gain was not representative. |
| Repair final response drain in streamed L2 | Deadlock removed; corrected combined cold profile **18,378,305 → 27,374,874 retires**, **+48.95% observed throughput** | This is the **combined DTLB2+ADD7+streamed-L2 profile**, not 48.95% attributable to the one drain-state repair. |

Source: [early CPI log](../CPI_PROGRESS_Sep05.md). The failed split-four-beat
approach and cache-geometry experiment are retained in section 7.

### 4.2 September structural frontend, memory and FP changes

| Change | Isolated/local gain where available | Quake attribution and disposition |
| --- | --- | --- |
| Repair uop-map cross-line/entry-boundary behavior | Directed placement cases with the same work reach **2.00 IPC**, from pathological **0.461538 / 0.181818 / 0.250000** cases | Large pathological-loop fix; integrated repair/CF observation is in section 3. Current measured profile has **no uop cache**, so this old mechanism is not credited as an active current optimization. |
| Forward checked load result to dependent V ALU | Directed dependent-loop throughput about **+40%** | Broad gameplay observation only **+0.011%**. Current measured define set does **not** enable `VEN_LOAD_USE_FORWARD`; no current gain assigned. |
| Cross-line decoder capture/priority and MOVS continuation | Gameplay observations **+6.10%** and **+1.71%**, respectively | Not isolated equal-work gains. Later REP admission repair was needed to make continuation active in the raw-byte profile. |
| FP memory admission + final-source-response command handoff | Ordinary-load fixture **8,357 → 8,101 clocks**, **3.06% fewer**; combined arithmetic descriptor/handoff **13,826 → 12,203**, **11.74% fewer** | One dispatch bubble removed where the accepted final beat can feed the existing command. Combined gameplay observation **+5.12%**; not wholly attributable to this bubble. |
| Tag-qualified store coherence and saved-window reuse | **No isolated gameplay percentage established** | Stop invalidating unrelated physical lines; retain useful registered data. Architectural correctness/ownership is part of the change, not a license to bypass coherence. |
| Asynchronous FP ownership permits integer work during FP execution | Directed overlap witnesses pass; early-command wider-window observation **0.346822 → 0.362346** | That observation starts at different instruction phases. The owner still drains before precise events; mere same-clock retirements are not the overlap proof. |
| Stream independent shared-FPU arithmetic with multiple tracked owners | Same 440-instruction micro window **1,650 → 385 clocks**, **76.67% fewer / +328.57% throughput** | Historical independent-arithmetic fixture; dependent control remains 1,650. Not a 4.29× gameplay gain or a claim of one-clock P54 FMUL initiation; the later two-clock FMUL fidelity repair is recorded in section 6. |
| Eliminate redundant inner AXI line replay in the ao486 path | Directed streaming read interval **1,152 → 739 clocks**, **35.85% fewer**. Common gameplay integer-state prefix **981,807 → 889,583 clocks**, **+10.367% throughput** | Stronger matched-work evidence, but only before the first timer IRQ divergence; full x87/memory state is not covered by that prefix comparator. Outer board DDR double-read workaround is a **different layer and remains**. |
| Ordered FXCH and stack-changing FP work | Corrected model's broader gameplay **0.39207514** | No isolated percentage for FXCH; stack mapping, pending RAW/WAW and precise events are required. |
| Generalize L2 early return to both halves and contained burst shapes | Mean first response **28.7188 → 20.125 clocks**, **29.92% shorter**; integrated reads **1,198 → 1,155**, **+3.72% throughput** | Gameplay only **0.39207514 → 0.39233706**: no meaningful isolated gain established. |
| Remove generalized L2 response-drain bubble | Mean completion **35.6875 → 35.2500 clocks**, **1.23% shorter** | Memory microbenchmark only. |
| Acquire younger FP operands while older FP executes | m32/FADD **880 → 825 clocks**; m64/FADD **935 → 825**: **+6.67% / +13.33% throughput** | Forced-FWAIT controls unchanged. Not a measured per-feature Quake contribution. |
| Chain owned resident memory requests | **35,061 → 27,869 clocks** for 24,273 instructions, **+25.81% throughput** | Directed sequence; dependent-address drains preserved. |
| Expand uop descriptor slots 12 → 16 | Same sequence **27,869 → 14,384 clocks**, **+93.75% throughput** | Historical experiment, +33% descriptor storage, **not in current no-uop-cache profile**. |
| Registered FP admission, then final-result forwarding | **1,650 → 1,320 → 990 clocks** for dependent 440-retirement windows: **+25.00%**, then **+33.33% throughput** | Combined **+66.67%** on this microkernel, not +58.33%. Independent 385-clock controls unchanged. |
| Scalar/misc FP response early completion; wide operand service; MOV/CALL store dispatch | Misc response **2 → 1 clocks** locally; wide-load integration was bundled; split CALL can retire one clock sooner with **zero whole-loop gain** | No isolated Quake percentage for these individual changes. Do not assign the whole wave7 increase to any one of them. |
| Integer branch execution during outstanding masked FP | Matched-start 50M replay **+1.24% interval IPC**; common 50,000-retirement prefix **98,997 → 96,681 clocks**, **+2.40% throughput** | The prefix comparison covers reported integer state, not complete memory/x87 state. Cold boot and full-suite acceptance remain separate. |

Sources: [boundary gate](../verif/uopcache/BOUNDARY_IPC.md),
[load/CF gate](../verif/issue_uv/LOAD_ISSUE_IPC.md),
[FP admission](../verif/issue_uv/FP_MEMORY_ADMISSION.md),
[FP overlap/streaming](../verif/issue_uv/FP_INTEGER_OVERLAP.md),
[single-fill trace and matched prefix](IPC_STATE_TRACE_Sep14.md),
[cache diagnosis](CACHE_DIAGNOSIS_Sep14.md),
[integrated class work](IPC_OPTIMIZATION_TASKS_Sep14.md),
[FP admission A/B](../verif/issue_uv/FP_REG_ADMIT_AB.md),
[FP forwarding A/B](../verif/issue_uv/FP_ARITH_FORWARD_AB.md),
[branch overlap](IPC_STATE_TRACE_Sep26.md).

### 4.3 Original CoreMark cycle-reduction work

These are successive **matched ten-iteration direct-memory diagnostics**, not
FPGA/cache-backed scores. The workload retires 3,660,809 instructions. This is
the part of the history with an actual saved-clock attribution summing to 100%.

| Change / bundle | Clocks after change | Saved in step | Step throughput gain | Share of total saved clocks |
| --- | ---: | ---: | ---: | ---: |
| Historical raw control | 9,224,125 | — | — | — |
| Resident tagged-byte frontend, shared decoder capture/direct handoff, short integer/byte forms, actual pre-writeback execution occupancy | 5,527,385 | 3,696,740 | **66.880%** | **84.064%** |
| Correct transfer-width memory penalties, encoding-extent short dispatch, CL occupancy | 5,151,285 | 376,100 | **7.301%** | **8.553%** |
| Exact base/index dependency mask for slow dispatch | 5,126,964 | 24,321 | **0.474%** | **0.553%** |
| Overlap already-paid prefix decode with preceding required AGI | 5,087,263 | 39,701 | **0.780%** | **0.903%** |
| AGI history from real gated GPR writes, including implicit PUSH/POP ESP rule | 4,936,433 | 150,830 | **3.055%** | **3.430%** |
| Paid `66` register admission/pairing + final-ACK MOV retirement + existing I-BRAM target-port steering | 4,826,619 | 109,814 | **2.275%** | **2.497%** |
| **Total** | **4,826,619** | **4,397,506** | **91.109%** | **100.000%** |

The large first and final rows are **bundles**, not individual ablations.
The historical raw control was not fully P54-period-qualified. Correcting a
wrong simulated memory penalty is not proof that a physical cache got faster:
**375,834** of the second row's **376,100** saved clocks come from 125,278
accesses wrongly charged three clocks each. This result must not be added to
the later real-AXI cache-backed gain.

Original source, exact binary identities, fidelity limits and valid-duration
follow-up: [CoreMark gain summary](COREMARK_FIX_SUMMARY_2026-09-29.md) and
[cycle survey](P54_COREMARK_CYCLE_SURVEY_2026-09-29.md).

### 4.4 Why the hardware stayed at 0.1x: transport and modeling repair

The old full-PC `ddr_service()` accepted writes immediately. The actual board
bridge held `DDRAM_BUSY` until each real AXI B response. Stretching reads with
the old `FPGA_DDR=2` option did **not** reproduce this write-response cost.

Read-only sampling of the unchanged board found **61.27% of outer-bridge
samples in S_B**, approximately **18.71 clocks per B response**. This is a
sampled bridge occupancy, not 61.27% independently removable CPU stall time.
It explains why the original simulator was an inadequate hardware-performance
oracle; it does not by itself establish the final speedup.

| Change | Measured gain / effect | Limit |
| --- | --- | --- |
| Ordered posted-write transport, 4/8/16 slots | Actual master→Avalon→L2→DDR path, 64 stores including drain, artificial 20-clock B delay: **1,570.375 → 405.719 → 218.781 → 153.281 clocks** | Serial→16 removes **90.24%** of these path-test clocks (**10.245× throughput**). **Not** a 10× processor or Quake claim. |
| Select 16 rather than 8 slots | **29.94% fewer** path-test clocks at that latency | Standalone routed leaves: 132→131 LUTs, 133→139 FFs, same LUTRAM count. Depth chosen from measured service, not benchmark recognition. |
| Hardware-origin drain barrier for I/O/debug/halt/reset | **No IPC gain claimed** | Prevents inner AXI “accepted” from being mistaken for external DDR completion; CPU computation need not wait for every B. |
| Model actual RTL bridge and B/R delays in full-PC simulation | **0% claimed hardware gain** | Repairs the simulator. Uses explicit delayed memory visibility and preserves ordering; current simulated result is still not board acceptance. |
| Expose actual V counter and capability in debug scan | **0% execution gain** | Fixes future observability. Old images must report total IPC unavailable, not assume V=0. |

The posted transport passed randomized partial writes, independent AW/W
backpressure, read ordering, reset/error handling, actual-path tests and vendor
functional-netlist comparisons. Those are bounded checks, not substitutes for
booting both target guests on the final bitstream.
Source: [bank64/posted-DDR record](UV_FAST_BANK64_2026-10-08.md).

### 4.5 October frontend, memory and FP bubble removal

| Change | Measured local gain | Isolated whole-Quake gain |
| --- | --- | --- |
| Protected/relocated reference-dispatch handoff | Word ALU **5→4**, MOVSX **7→6**, IMUL **14→13** micro-loop clocks: **+25.00% / +16.67% / +7.69% throughput** | Not established; dispatch model's first gameplay observation is 0.38065044. |
| Registered FP result forwarding into memory arithmetic | m32 four-operation loop **16→13**, **+23.08% throughput** | Not isolated. Wide/integer-memory and FLD/pop controls initially unchanged. |
| Add arithmetic-only resident operand priming | Same loop **13→12**, **+8.33% incremental**; combined **16→12**, **+33.33%** | Not isolated. Broad FLD priming was rejected for a regression. |
| Independent-set priming during a fill | Removes a resident capture clock in directed eligible cases | Not isolated; later current-stack short CoreMark saved only **118 clocks/seed**, roughly **0.0023%**. |
| Accept popping FP arithmetic on the last registered response | FLD/pop loop **23→20 clocks**, **+15.00% throughput** | Not isolated; actual older stack mutation must already be committed. |
| Reuse registered instruction words | Staged reads **36→18 clocks**, **+100% local throughput**; I-miss kernel **66,330→52,260**, **+26.92%** | Not isolated; first gameplay movement was small. |
| Serve resident D hits during independent I fill | 640 directed held reads complete in two clocks | No isolated old/new gameplay percentage; included in a bundle. |
| Exact-length short x87 fetch | Selected loops remove **5–6 clocks/iteration** | No aggregate percentage established; denominator varies by instruction. |
| Remove uop-cache dependency from REP continuation admission | Existing MOVS continuation/streaming becomes reachable without enabling uop cache | **+10.58% interval IPC observation**, not isolated same-scene gain. |
| Retain 16 checked instruction-page permissions | Paged CALL/RET **47→31 clocks**, **+51.61% micro throughput** | **+1.77% interval IPC observation**, not the micro percentage applied to Quake. |
| Checked target read | One clock saved on directed warm CALL/RET | **No observed gameplay gain** in measured window. |
| Read-retirement resident priming | Four-read loop **9→6**, **+50% micro throughput** | **No observed gameplay gain** in measured window; first pairing-breaking version was rejected. |
| Scalar x87 direct dispatch | FIADD32 **8→7** (**+14.29%**), FCOM32 **5→4** (**+25%**), FIST32 **8→7** (**+14.29%**), FST32 **9→8** (**+12.5%**) micro throughput | Not isolated. Required execution/exception semantics retained. |
| Extend existing ordered FP operand slot m32→m64 | Eligible loops save **1–8 clocks/iteration**; forced-FWAIT controls unchanged | Not isolated. Adds 32 payload bits and a width bit, not another FPU. |
| Final scalar source-beat handoff | FIADD32 **7→6** (**+16.67%**); FCOM32/64 **4→3** (**+33.33%**) | Not isolated. Uses current accepted operand, no additional memory port. |
| Resident operand preparation at reference dispatch | Short low-RAM AXI CoreMark **5,482,773→5,375,191**, **+2.00% throughput** | No isolated Quake percentage; direct-memory control unchanged. |
| Resident operand preparation during required AGI | Next short CoreMark **5,375,191→5,264,309**, **+2.106% throughput** | No isolated Quake percentage; the required AGI itself is not deleted. |
| AXI read-command forwarding | Removes one command-capture clock when endpoint ready; blocked reads unchanged | **No observed gameplay gain** in first measured window. |
| Platform L2 32→256 KiB | First gameplay observation **0.43894030→0.49083588**, **+11.82%** | Strong observation, but not same-work attribution. P5 L1s unchanged; D-pipeline wait residency about 21.12%→17.19% in those different windows. |
| 16-bit demand-length fetching | Cache-enabled real-mode loop **89→58 clocks**, **+53.45% throughput** | Targets observed DOS/real-mode fetch dip; no isolated whole-demo percentage. Four long-prefix cases add one warm-loop clock. |

Sources and complete corner-case checks:
[October optimization record](UV_FAST_TARGET_STATUS_2026-10-09.md),
[memory-FP forwarding](../verif/fe_pipe/FP_MEMORY_FORWARD.md),
[pop admission](../verif/fe_pipe/FP_POP_DRAIN.md),
[instruction-word reuse](../verif/l1/CODE_WORD_REUSE.md),
[permission shadow](../verif/fe_pipe/IFETCH_AUTH_MULTI.md),
[operand priming](../verif/fe_pipe/REF_OPERAND_PRIME.md),
[AGI priming](../verif/fe_pipe/AGI_RESIDENT_PRIME.md),
[L2 capacity](../verif/l1/L2_CAPACITY.md),
[demand fetch](../verif/fe_pipe/SFETCH16_DEMAND.md).

### 4.6 Final matched cache-backed CoreMark steps

This is a separate, internally comparable sequence with unchanged compiler,
algorithms, seeds, media and cache/transport settings. Every row below has both
original CRC sets. The ten-iteration runs measure changes, not valid-duration
scores. Percentages are **incremental throughput gains**, performance/validation.

| Change | Performance ticks | Validation ticks | Step gain, performance / validation |
| --- | ---: | ---: | ---: |
| Demand-fetch parent | 5,096,514 | 5,085,420 | baseline |
| Protected-client PREFIX66 | 5,013,253 | 5,001,043 | **1.66082% / 1.68719%** |
| Exact-byte RET capture | 5,012,733 | 5,000,796 | **0.01037% / 0.00494%** |
| Branch-fallthrough resident read hint | 4,954,588 | 4,939,299 | **1.17356% / 1.24506%** |
| Independently invalidate saved windows | 4,927,211 | 4,912,277 | **0.55563% / 0.55009%** |
| Register-prefix/execute overlap | 4,919,533 | 4,905,555 | **0.15607% / 0.13703%** |
| Qualify overlap's INTR veto with architectural IF | 4,862,426 | 4,847,492 | **1.17445% / 1.19779%** |
| Coherently update existing saved windows on writes | 4,853,587 | 4,837,758 | **0.18211% / 0.20121%** |
| Shared byte-memory CMP decode | 4,801,536 | 4,787,479 | **1.08405% / 1.05022%** |
| Warm existing window on committed resident store | 4,782,160 | 4,768,125 | **0.40517% / 0.40590%** |
| Carry tested AXI write-buffer admission into the full-PC model | 4,767,218 | 4,753,406 | **0.31343% / 0.30965%** |

Performance-seed total: **329,296 clocks removed**, **6.4612% fewer clocks /
6.9075% higher throughput**. No per-row gameplay allocation is established.
The last step came from tracing repeated one-clock stalls between cache-hit
PUSHes and finding a tested core-side admission feature omitted from the SoC
derivative, not inventing a benchmark-specific PUSH path.

The final **900-iteration** same-build runs then established valid-duration
scores, rather than extrapolating those short ratios:

| Seed | Measured raw TSC ticks | Guest duration at 40 MHz | CM/MHz |
| --- | ---: | ---: | ---: |
| Performance | 428,186,037 | 10.704650925 s | **2.101890118** |
| Validation | 427,022,738 | 10.675568450 s | **2.107616105** |

Source: [cache-backed target report](CACHE_BACKED_TARGETS_2026-10-10.md).

## 5. FPGA compactness and timing work: do not book it as IPC gain

The fast implementation created long address→lookup→byte-selection→decode→FP
control paths. Reducing those paths and their routing demand is needed to make
the cycle improvements physically useful. It is not an additional measured
instructions-per-clock improvement.

| Change | Measured resource/timing effect | IPC gain credited |
| --- | --- | --- |
| Replace undersized registered translation experiment with banked 64-entry organization | Routed leaf **782→370 LUTs (−52.69%)**, **1,696→96 FFs (−94.34%)**; query delay **2.758→2.079 ns** | **None** beyond recovering rejected small-cache regressions. Warm timings match original no-cut control through 64 pages. |
| Factor primary L1 registered payload selector | Consumed data equivalent; complete tested cycle counts unchanged | **0% in matched tests**; hardware timing benefit must be measured separately. |
| Compact L1 tag storage into FPGA distributed RAM | Isolated leaf **22,051→13,014 LUTs (−40.98%)**, **6,877→1,691 FFs (−75.41%)** | **No IPC gain claimed**. Not a whole-chip utilization figure. |
| One shared ADD/SUB/reverse-SUB front, operand/sign selection before arithmetic | Isolated leaf **8,093→5,221 LUTs (−35.49%)**, **88→58 DSPs (−34.09%)**; unplaced setup estimate **64.29→61.53 MHz** | **0% in matched cycle tests**. Area win with a slightly worse local timing estimate. |
| Shared front plus automatic DSP mapping instead of forced DSP add/round cascades | Against original: **8,093→5,787 LUTs (−28.49%)**, **88→16 DSPs (−81.82%)**; unplaced leaf estimate **78.59 MHz** | **0% in matched cycle tests**. Preferred sharing variant; trades 566 LUTs against sharing-only for better local timing. These are alternative variants, not additive savings. |
| Six mutually exclusive transcendental packers share one normalizer/rounder | Isolated leaf **32,702→28,695 LUTs (−12.25%)**; unplaced estimate **93.84→81.97 MHz** | **0% in matched cycle tests**. Area/timing tradeoff, not a measured routed-core acceleration. |
| Serialized misc integer conversions share one converter | Isolated leaf **4,452→4,040 LUTs (−9.25%)**; unplaced estimate **77.59→67.40 MHz** | **0% in matched cycle tests**. Another local area/timing tradeoff, not an assumed whole-chip win. |
| Estimator-width reduction | Estimator leaf **846→710 LUTs (−16.08%)**, **16→8 DSPs (−50%)**, checked cycle behavior unchanged | **No IPC gain claimed**. Sharing/narrowing targets area and congestion. |
| Share repeated instruction-residency/prefix lookups in both decode and retirement consumers | Whole design **221,918→197,375 LUTs**, **24,543 fewer / −11.06%** | Matched directed cycle streams and CoreMark clocks unchanged. Incomplete one-consumer integration had increased whole-design area and is not the final result. |
| Registered invalidation and FP/SRT/load/current-response/high-word/code payload selection | Subsequent whole-chip syntheses vary **194,057–196,673 LUTs**; newest closed code-payload parent is **196,627 LUTs** | Matched cycle checks show **no gain/regression in those tests**. Latest **22.799 MHz unplaced estimate**, not routed 40 MHz sign-off. |

The last code-payload step actually **adds 122 LUTs** versus its 196,505-LUT
parent. It must not be reported as another area saving. The subsequent FLD-C1
candidate has not been synthesized, so it does not inherit that utilization.

Sources: [banked translation](../verif/fe_pipe/banked/README.md),
[L1 payload sharing](UV_FAST_L1_PAYLOAD_2026-10-08.md),
[tag LUTRAM](../verif/l1/TAG_LUTRAM.md),
[shared arithmetic front](../verif/fppipe/SHARED_ADD_FRONT.md),
[shared transcendental packer](../verif/fppipe/SHARED_TRANS_PACK.md),
[shared integer converter](../fp_shared/tb/MISC_SHARED_INT.md),
[estimated-divider narrowing](../fp_shared/tb/ESTDIV_NARROW.md),
[congestion and sharing audit](FPGA_FETCH_CONGESTION_2026-10-10.md),
[complete prefix sharing](../fpga/IC_PREFIX_CAPTURE_EXPORT.md),
[latest closed FPGA export/synthesis](../fpga/CODE_PAYLOAD_EXPORT.md).

## 6. Correctness and observation repairs: gain not interchangeable with speed

These repairs are necessary to retain the faster execution mode. Passing a
directed test does not close the complete standard suite or differential gate.

| Repair | Why needed | Gain attribution |
| --- | --- | --- |
| Width-mask SHLD/SHRD inputs; preserve carry across paired ADD→INC/DEC; correct U shift/rotate flags forwarded to V branch | Real arithmetic/paired-branch defects, including Win95 decompression and UV-fast conditional branches | **No standalone throughput gain claimed**; required correct execution without disabling V. |
| Real U intermediate retirement state, separate from post-pair V state | Old observer falsely gave U the later V register values | **0% execution gain**; verification repair, excluded from synthesis. |
| Restore correct L1 response ownership, including armed early response versus current consumer | Prevent stale/wrong data when requests retarget | **No isolated gain**; an older FPGA source snapshot had omitted an existing committed repair. |
| Enforce P54 streaming FMUL's two-clock initiation interval | Independent FADD/integer work may overlap; FMUL must not acquire unrealistically cheap issue occupancy | Fidelity correction, **no isolated gain**. September 27 combined candidate/control both measured **0.426371504 IPC** over 1.15–1.40B, with identical compared frames. |
| Primed-U / delayed-V ownership repair | Both cold guests hit the orphaned-V assertion | **No global pairing disable**; reject only a response without a retained owner. No isolated gain. |
| Platform L2 replacement/LRU read and write ownership; registered read-first RAM fidelity | Real cache-state races and simulator/FPGA memory-model mismatch | **No isolated percentage**; simulation fidelity is not a hardware acceleration. |
| L2 tag-initialization backpressure | Enlarged cache advertised ready, then dropped first boot fetch | Changes failed boot to progress; **no normal-pipeline speedup claimed**. |
| Segment/EA/FIP/FDP, ENTER/POP, V86/I/O/interrupt and precise-event fixes | Required generic guest correctness; source/stack/protected-mode ownership must survive fast dispatch and FP overlap | **Not quantified as performance gains**. Historical boot repairs do not qualify the newest image. |
| SRT/FSQRT floor-exponent and arithmetic C1 corrections | Four numeric FSQRT errors and rounding-status errors | No added latency in measured fixtures; **no gain claimed**. |
| Register-FST ownership/C1 and masked/unmasked memory-FST range handling | Prevent wrong source/pop/store on overflow/underflow; preserve precision-only completion | Unmasked matrix **448 errors→0**; **no IPC gain claimed**. NaN/general event coverage is not inferred. |
| FLD/FILD/constant-load C1 clear before stack-fault override | Stale C1 after prior rounded arithmetic | Directed matrix **288 RTL errors→0**; same **1,869,470 clocks**. Latest full-PC short CoreMark remains **4,767,218 / 4,753,406 ticks**, **0% measured change**. |
| Flush completed host simulator disk writes; require full writes and flush success | Live observer could miss guest-completed timedemo disk sectors until process exit | **0% modeled CPU gain**. Visibility is not durable `fsync`; caller-level error propagation remains a separate issue. |
| Correct AXI-backend selection, private harness/header ownership, trace phase, runtime identity and native closure checks | Prevent stale/direct-memory/observer artifacts from being accepted as current hardware-backed performance | **0% CPU gain**; makes the evidence trustworthy. |

Sources: [paired-carry regression](../verif/issue_uv/LOAD_ISSUE_IPC.md),
[shift flags](UV_FAST_SHIFT_FLAG_FIX_2026-10-08.md),
[retirement observer](UV_FAST_RETIRE_STATE_2026-10-08.md),
[L1 owner backport](UV_FAST_L1_OWNER_INTEGRATION_2026-10-08.md),
[P54 FMUL fidelity](P54_IPC_IMPLEMENTATION_STATUS_2026-09-27.md),
[primed pair owner](../verif/fe_pipe/PRIME_PAIR_OWNER.md),
[FP correctness bundle](../fp_shared/tb/FP_CORRECTNESS_BUNDLE.md),
[shared-load C1](../fp_shared/tb/FLD_C1.md),
[host disk visibility](../ao486-sim/ven/DISK_WRITE_VISIBILITY.md),
[AXI verification mode](UV_FAST_VERIFY_BACKEND_2026-10-08.md).

## 7. Rejected, uncredited and misleading-looking results

- **Split L2 critical-half-first into two DDR commands:** approximately **2.4%
  worse cold-window retirement throughput**. Paying fixed DDR latency twice
  without useful tail overlap was not a win; that prototype was removed.
- **Change L2 line 64→32 bytes:** sub-0.1% cold-window difference with different
  PIT phase; no useful win established, experimental knob removed.
- **Small translation timing cuts:** one-entry cut adds **10.29% / 5.27% warm
  clocks** in selected fixtures; eight entries add **32–33%** beyond capacity.
  Replaced with banked capacity rather than accepting slow functional success.
- **Broad FP resident priming:** FLD/FADDP **23→24 clocks**, a regression despite
  an earlier operand; restricted to suitable arithmetic, then fixed the actual
  pop-response admission bubble separately.
- **Early read-prime implementation:** lost immediate V pairing. Rejected and
  repaired; local load latency alone was an insufficient acceptance criterion.
- **Target pre-read, read-retirement prime, AXI read-through and generalized
  cache streaming:** local wins did not establish broad Quake gains. Their
  flat/lower gameplay observations remain in the ledger.
- **Incomplete prefix sharing:** local LUT reduction initially coincided with
  higher whole-chip area. Only fixing both consumers produced the measured
  24,543-LUT reduction.
- **Host simulation acceleration:** unchanged-input settle avoidance improved
  host throughput approximately **25–28%** in its qualified configuration;
  O3/private builds and parallel jobs also help turnaround. **0% guest IPC
  gain**. A model running faster on the workstation is not a faster processor.
- **Snapshots:** used for diagnostic matched-start replay, never credited as
  an RTL speedup, cold-boot acceptance, or a workload-specific processor fix.
  Cross-build serializer adaptations in old diagnostics are explicitly marked
  and do not qualify cold Quake/Win95.
- **U-only, STEP or globally slow fallback:** not accepted as fixes or target
  passes. Required architectural serialization remains; arbitrary pairing or
  deleting real execution/AGI costs is not allowed.

## 8. What can actually be said about each change's share of the gain?

1. The original **CoreMark matched sequence** has a quantitative saved-clock
   decomposition: section 4.3 sums to 100%, but several rows are bundles and
   some savings correct the old model's accounting rather than physical RAM.
2. The latest **cache-backed CoreMark sequence** isolates the incremental steps
   in section 4.6 and establishes **+6.9075% total throughput** on its matched
   short performance workload. Valid-duration scores are separately measured.
3. Several **microkernels and memory paths** have strong causal A/B evidence:
   posted writes, FP streaming/forwarding, permission retention, fetch reuse,
   request chaining and operand priming. Their Quake weights are not measured.
4. Most historical **Quake IPC differences** are fixed-clock, different-progress
   observations. They cannot supply an honest percentage-of-total-gain chart.
   Single-fill's common pre-IRQ prefix and the FP-branch prefix are stronger
   limited matched-work evidence, with their comparison scopes stated above.
5. **Physical FPGA gain from the original 0.1x point is not yet established.**
   The current installed image still supplies the old primary-only result.
   Dividing new simulated U+V IPC by it would combine incompatible quantities.

The engineering explanation supported by the data is: first reduce needless
frontend/slow-FSM work and translation conflicts; then remove memory-service
bubbles and allow correctly owned FP/integer work to overlap; finally address
the real board's write-response serialization and make the fast source small
enough to implement. The evidence does **not** support assigning all the gain
to multi-issue, all to cache misses, or all to the FPU.

## 9. Current qualification and remaining work

| Requirement | Current evidence | Status |
| --- | --- | --- |
| Cache-backed simulated CoreMark ≥2.1 CM/MHz | `bfb867f7` and newest `2b4d7a48`, both 900-iteration seeds, original CRCs, >10 guest seconds | Met **for these two models**, not automatically other sources or hardware |
| Simulated Quake ≥0.48 IPC | All-window `bfb867f7` mean **0.498471873**; latest **0.49366456** | Observed measured prefix; not a completed-demo average or every-scene guarantee |
| Gameplay CPI <1 / IPC >1 | Current aggregate event CPI approximately **2.006** | **Not achieved**; normalized macroinstruction accounting is also distinct |
| Canonical differential gate on latest corrected source | **7/108 functional passes; 12/19 scored cycle failures** | **FAIL**, no masks/goldens/bands waived; directed/native x87 evidence does not replace the gate |
| Latest `2b4d7a48` own valid-duration CoreMark | **2.101890118 / 2.107616105 CM/MHz**, exact parent ticks, original CRCs, actual V activity, native 0/reaping, no OOM | Both simulated seeds independently closed at 21:21; not complete-suite or FPGA acceptance |
| Newest matched hardware source | Manifest `b28ce916…`; 190 payloads, 156 hardware defines, 170 non-wrapper native source matches; strict CPU lint | Source/lint pass, **not bitstream or physical pass** |
| Latest completed synthesis | Source-matched `2b4d7a48` export: **195,617 LUTs**, **21.786 MHz unplaced estimate**, requested 40 MHz core | Implementation running; not routed 40 MHz sign-off |
| Win95 on final FPGA | Must cold boot to clean desktop and survive keyboard/mouse, menu/window interaction | **Pending** |
| Quake on final FPGA | Must complete original timedemo, retain closed result, full unmodified-frame movie, measured clock and UV-fast evidence | **Pending** |

No complete new-candidate standard-suite pass is claimed. Some older simulation
timedemos completed and some Win95 desktop captures are clean; neither qualifies
a different candidate or substitutes for the required physical tests.

## 10. Evidence anchors and reproducibility

The current headline numbers were checked against the actual retained receipts,
not copied solely from a stale status paragraph. Roots are below
`/home/yukidama/external/tmp/`:

| Evidence | Receipt / identity |
| --- | --- |
| Current gameplay, exact U/V totals, all retained windows | `ventium-store-admit-gameplay-r21.7wFYXH7w/audit.json`; full model SHA `bfb867f7844b467eeafba12fe6d5035e89d0d2cf03111911cbdd599d7fb204e6` |
| Same model's valid CoreMark | `ventium-store-admit-soc.kW7Vv7Mr/coremark-900-performance/audit.json` and `coremark-900-validation/audit.json` |
| Closed hardware 0.167991 profile | `ventium-bank64-perf-oct08.gz8UKP/board-profile-qualified.json`; bitstream SHA `fe9f539dfcfd9a1d909a33b561d5b7b6a0febf6e90c54b339f568d0cd496f71e` |
| Newest source-matched full-PC build and short-seed audit | `ventium-zero-c1-soc.FTbYSn0L/{build-closed.json,coremark/audit.json}`; model SHA `2b4d7a48453fb8f901730d70b5731d9fb6a5459a83fc36f69241f441a7ab298e` |
| Newest model's independently closed 900-iteration CoreMark seeds | `ventium-zero-c1-soc.FTbYSn0L/coremark-900-{performance,validation}/audit.json`; **2.101890118 / 2.107616105 CM/MHz**, exact parent TSC clocks, original CRCs, native zero, no OOM |
| Newest FPGA source and strict CPU lint | `ventium-zero-c1-fpga40.rQeGd6ln/{input-manifest.json,audit.json}`; manifest SHA `b28ce916c8ce276546ac85384dd4959452aad439a14e283d1b2339692465b603`; `ventium-zero-c1-hw-lint.Jg7OncrJ/closed.json` |
| Latest closed full synthesis and unplaced timing | `ventium-zero-c1-full-synth.yROXoFK0/audit.json`; `ventium-zero-c1-clock-audit.QVKu9JRQ/audit.json` |

Older linked reports preserve their original timestamps, scratch paths,
negative controls and failed attempts. Some historical `/tmp` paths may no
longer exist; this report does not claim every old artifact was revalidated.
The latest builds are explicitly frozen derivatives of the dirty worktree,
not assertions that every current checkout file matches every reported binary.

Thirteen historical source documents linked above are **local-only/untracked**
at this report's creation: `CPI_PROGRESS_Sep05.md`; the September 14 cache,
optimization and trace reports and September 20 trace report; the linked
`verif/issue_uv/` admission, forwarding, overlap and load reports; MOVS
continuation; and uop boundary/cross-line reports. Their relevant numbers and
qualification limits are reproduced here, but those links will not resolve in
a remote checkout lacking the local records. They are not silently added to
this documentation commit. All linked paths exist in the audited local tree.

To turn the unknown Quake contribution entries into causal percentages, run
one-feature-off variants from the **same validated state/input**, compare a
defined common work boundary and complete timedemo, retain event/REP accounting,
and finally repeat the aggregate comparison on physical FPGA with total U+V
visibility. None of those missing measurements is fabricated here.
