# UV-fast performance target status — October 9

Acceptance remains **open**. U/V, relocated fast pipeline and fast load/store
paths stay enabled. No U-only/STEP/global-slow fallback, guest modification or
snapshot is used for the current cold full-PC runs.

| Requirement | Verified result | Remaining |
| --- | --- | --- |
| CoreMark ≥2.1 CM/MHz | Current `b5453f16` full direct-memory seeds: **2.107843209 / 2.110905243**, correct CRCs | Not a DDR/cache/FPGA score |
| Quake ≥0.48 total U+V IPC | Latest **0.49639177**, repaired 256 KiB-L2 `86731249`, 2.6B–2.7B clocks; **0.47400567** over all 1.2B–2.7B | Sustained target still open; original fixed window 0.49083588; full timedemo and silicon pending |
| Standard suite | Current full direct-memory CoreMark seeds pass; larger-L2 Win95 closed at a visually clean desktop | Independent desktop acceptance, complete timedemo and remaining differential failures |
| FPGA | Old image still deployed; 40 MHz synthesis stopped by resource watchdog on October 10 | No accepted new synthesis/bitstream; timing/resource qualification and deployment remain open |

## October 10: demand-fetch implementation and later gameplay

Newest timestamp-selected gameplay is **49,639,177 U+V retirements / 100M
clocks = 0.49639177 IPC**, cycles 2.6B–2.7B on unchanged `86731249`. The exact
endpoint images show the nailgun view advancing from the red wall target to a
door. Source/runtime/native identity, raw pixel equality and no OOM are checked
in `external/tmp/ventium-l2-gameplay.VedZVnwA/latest-2700000000/audit.json`.
All 15 consecutive windows from 1.2B now average **0.47400567**; the real-mode dip
is retained and sustained ≥0.48 is still unproved. This does not replace the
original predeclared 1.2B–1.3B gate or count as timedemo completion.

The [16-bit demand-fetch candidate](../verif/fe_pipe/SFETCH16_DEMAND.md) reuses
the checked length decoder and existing request owner, fetching four bytes at
a time only inside the previously legal 16-byte extent. True page/CS/wrap
boundaries stay byte-exact. No opcode/guest-specific rule, extra cache port,
global 16-bit pairing enable or U-only fallback is introduced.

Model `3dcf4cbb`: 2,880 fixtures / 11,520 A/B measurements pass full QEMU traces;
another 360 cache-enabled fixtures / 1,440 measurements and 88 exact fetch-fault
checks pass. A cache-enabled real-mode short loop falls 89→58 clocks; four long
prefix cases in the larger matrix add one clock per warm loop. These are not
gameplay or CoreMark gains. Generic verification remains FAIL on 101 terminal
lengths and four timing bands, with no earlier field mismatches; all 20 cycle
record streams match the control. Detailed limits and receipts are in the note.

Source-matched SoC `958f7ec4` preserves the measured parent's repaired 256 KiB L2,
P5 L1s, posted16 and UV-fast configuration, adding only demand fetching plus
the estimator-width reduction. Its cold full Quake run uses unchanged media
and completion criteria. Native PID 201252 on CPU27 is independently audited
under invocation `dc6c0bb3294b4056a2015a9a29ab9c21`, with 244 source pins and
17 runtime pins, no STEP/snapshot and no OOM. **Neither new model has a gameplay measurement**;
no standard-suite or FPGA acceptance is claimed. C1 and RET remain independent,
unpromoted candidates. Closed microcase data is losslessly archived, byte-
verified before deleting unpacked copies; source snapshots and receipts remain.

## Earlier October 10: longer gameplay exposes a real-mode fetch dip

The newest timestamp-selected window is **48,007,471 U+V retirements / 100M
clocks = 0.48007471 IPC**, cycles **2.4B–2.5B** on unchanged model `86731249`.
Source/runtime/native identities and endpoint pixels are rechecked; both
unchanged frames visibly show advancing gameplay. Receipt:
`external/tmp/ventium-l2-gameplay.VedZVnwA/latest-2500000000/audit.json`.

The preceding **2.3B–2.4B** interval drops to **0.26103520**, lowering all
thirteen consecutive windows since 1.2B to **0.47084103**. It is retained,
not excluded or replaced by the earlier high-scoring interval. The original
predeclared 1.2B–1.3B result remains 0.49083588, but **sustained ≥0.48 is not
established**. Full 969-frame timedemo completion remains open.

The audited prefix's `dip-diagnostic.json` identifies a substantial real-mode
stretch: 111/197 sparse progress samples have CR0.PE=0, CS=05f7, from sampled
cycle 2,343,465,200 through 2,398,465,200. This is not exact mode residency or
proof of which DOS function is executing. S_FETCH residency in the dip is
**34,702,072 clocks** (34.70%), compared with 1,865,361 and 2,214,862 in its
adjacent windows. It performs **21,615,725 fetch acknowledgements**, with
13,005,687 request-wait clocks. These are overlapping views, not additive
stalls or a measured cache-miss percentage. The ordinary slow path still fetches
a full 16-byte window per instruction; safe demand-length fetching for 16-bit
code is a concrete next target. Do not enable unqualified global real-mode
pairing or disable U/V to hide this cost.

[Shared-estimator narrowing](../fp_shared/tb/ESTDIV_NARROW.md) is implemented
with unchanged checked cycle behavior: 284,883-clock miter plus 5,004 legacy
cases pass. Matched native synthesis reduces the leaf from 846 to 710 LUTs and
16 to 8 DSPs. Its width-only full-core model `dd094313` builds; generic verification
still fails on 101 terminal-length mismatches (no earlier fields) and four hard
cycle bands. No acceptance rule changes. This is area/timing work, not an IPC gain.
It has no gameplay result; neither do the independent C1 and RET candidates.

The [eight exact canonical C1 sites](../fp_shared/tb/ROUND_C1.md) are now
reconciled against native execution of the unchanged ELFs and exact arithmetic:
their inputs/results agree, and all eight support the candidate's C1 rather
than pinned QEMU's stale rounding bit. Complete C1 semantics and the generic
gate remain open; no mask or golden is changed. The actual `tx_round` opcode
computes 3/10, correcting its misleading 10/3 source comment.

## Earlier October 10 continuation (through 2.3B)

The then-newest complete 100M-clock window, selected by timestamp rather than IPC,
is **51,351,913 total U+V retirements / 100,000,000 clocks = 0.51351913**.
Model `86731249` and native invocation are unchanged. The latest audit
`external/tmp/ventium-l2-gameplay.VedZVnwA/latest-2300000000/audit.json`
rechecks source/runtime identities, log prefix, no OOM and unmodified endpoint
pixels. Both frames visibly show advancing gameplay. This later window is
**not** substituted for the original predeclared 1.2B–1.3B test.

All eleven consecutive windows from 1.2B through 2.3B average **0.48907486**;
individual windows range 0.45969841–0.51351913, so the claim is not that every
scene sustains 0.48. The full 969-frame timedemo remains running, incomplete.
The independent C1 (`6f71bad6`) and RET (`56707c8a`) candidates below have no
gameplay measurement or standard-suite acceptance.

- [RET exact-byte capture](../verif/fe_pipe/RET_SHORT_WINDOW.md) retains normal
  decode/stack/target checks and adds no pipeline stage or buffer. All 256
  ordinary/relocated/SS16/SS32 line-position fixtures pass at AXI latencies 0/7
  against QEMU on both control and candidate. Complete traces and actual U/V
  pairing are checked; 160/512 matched totals improve, none regress. Short
  cache-backed CoreMark removes 53,823/54,418 clocks (about 1.04% throughput)
  with unchanged retirements/CRCs. Its short service-window ratios
  **1.97703/1.98018** remain below 2.1 and are **not valid benchmark scores**.
- [Compact C1 repair](../fp_shared/tb/ROUND_C1.md) passes 15,600 rounder cases,
  912 SRT cases and 2,064 connected-top cases, plus directed full-core SRT/ALU
  output checks with zero value/C1/precision mismatches. It also fixes four
  factor-of-two FSQRT cases. The backport preserves the measured parent's
  shared ADD/SUB operand selection and registered memory forwarding; wholesale
  copying from the checkout would discard them. No performance gain is claimed.
  The directed cases also pass delayed AXI. Canonical verification still fails:
  besides existing length/timing failures, eight x87 tests expose C1-only
  differences from QEMU. Exact-case/oracle reconciliation is pending; no new
  mask or acceptance waiver is applied.

The single Vivado family completed timing optimization but crossed the host's
2 GiB available-memory reserve at technology mapping. The watchdog stopped it
at **01:16:36 UTC**, after 6,688.66 seconds, native exit 143 (SIGTERM), **not an
OOM kill**. Peak cgroup memory was 21,091,545,088 bytes and swap 8,589,918,208;
source pins stayed unchanged. No implementation or deployment started. Receipt:
`external/tmp/ventium-performance-synth40.t5wzn9jz/synthesis-closed.json`.
Do not accept a stale checkpoint or restart the identical flow without reviewing
its memory footprint. The user browser was not stopped.

Remaining: cache-backed ≥2.1 valid CoreMark, new-candidate exception/SMC/event
coverage, differential/timing gates, full standard suite, independent Win95
desktop acceptance, and actual FPGA performance. The direct-memory full-seed
scores in the table do not discharge the cache-backed requirement.

The preceding combined full CoreMark model is
`c93ae26b20685827dacf45b466256e4139bb1d068d7546ec467801c0a8502c0b`;
receipts and `independent-audit.json` are in
`external/tmp/ventium-short-ifill-coremark.qQqbebWo/full-r2`.
Both 1,500-iteration seeds closed with native exit zero, matching all five
CRCs, zero actual fault deliveries, stable 114 input pins, no OOM and all
children reaped. Performance: **711,789,981 clocks / 542,165,413 retirements**,
3,413.01 host seconds. Validation: **710,761,393 / 541,458,835**,
3,326.85 seconds. Scores above use conservative whole-program clocks, not
guest-reported calibration or short-run extrapolation. Both stayed below
the unchanged 3,600-second limit. This model does not contain independent REP
admission or optional prime-under-I-fill; do not transfer its score to them.

The run used CPUs16/17, invocation `2034f3eec45a4ab6830530d668a3baf9`.
Before launch, both short seeds passed
CRC, exact whole-model/mapped-RAM host-optimization equivalence and negative
controls. They save 96 clocks versus the prior RTL; the first stale
parent-clock expectation failed and is retained. The host optimization never
skips a clock edge or changes guest state. The 60-minute full-seed limit still
applies; the optional 75-minute request has not been answered.

Earlier in this round thirteen cold full-PC guests were active: code-word Quake, combined-candidate,
independent-REP, instruction-permission-shadow, checked-target-read and
pair-safe read-retirement-prime
Quake/Win95 pairs, plus the combined scalar/m64 FP pair (`652de481`, CPUs25/26).
Code-word Win95 closed normally at **2,259,200,420 clocks** with a visually
clean Welcome desktop, native exit0, stable pins, no OOM and reaped children.
Its closed raw frame16 is retained; human confirmation/independent desktop
acceptance remains open. `CLOSED_UNQUALIFIED` is not a suite pass.
Superseded XPM/pop pairs closed
normally, with native exit
zero, reaped children and no OOM. Those incomplete timedemos remain FAIL and
the Win95 runs CLOSED_UNQUALIFIED; no suite acceptance is inferred.

The preceding code-word gameplay audit is
`external/tmp/ventium-code-word-gameplay-audit.VyVHIfbs/audit.json`:
39,002,079 total retirements (29,046,965 U + 9,955,114 V) / 100M clocks.
Exact endpoints were visually checked and source/runtime/native identity pins
rechecked (227 source and 17 runtime inputs). Model SHA-256:
`f3be9a112c40dd6637ee404f98c485e04a501f85967394a304f158c8781c8d5f`.
This includes code-word reuse and pop-drain/XPM, not later tag, data-under-I-fill,
short-x87, prime-under-I-fill or independent-REP admission candidates. A completed
window is not a completed timedemo. The preceding pop-drain window was 0.38776687;
equal cycle windows need not cover precisely the same scene progress, so this
is not an equal-work percentage-gain claim.

The preceding combined-candidate gameplay audit is
`external/tmp/ventium-short-ifill-gameplay-audit.tNSWpZfe/audit.json`:
**39,555,990 = 29,484,306 U + 10,071,684 V retirements / 100M clocks**, cycles
**1,200,000,000–1,300,000,000**, giving **0.39555990 IPC**. Exact endpoints
are visually confirmed gameplay with unchanged raw pixels; 236 source and
17 runtime pins plus native identity are rechecked. Model SHA256:
`05611d6c2ac8dc767b162ed18bbf1c63daeff78d760702b4ada03eed83d37d71`.
It includes tag LUTRAM, data-under-I-fill and short x87 fetch, but not later
REP admission, permission shadow, target read or prime-under-I-fill. The
increase from 0.39002079 is small and does not meet 0.48. Equal-cycle bounds
are not an equal-scene-work comparison; no isolated percentage gain is claimed.
Full timedemo completion is still open.

The preceding **REP-enabled** gameplay audit is
`external/tmp/ventium-rep-gameplay-audit.753XgqaN/audit.json`:
**43,739,106 = 32,629,256 U + 11,109,850 V retirement events / 100M clocks**,
cycles **1,200,084,750–1,300,084,750**, giving **0.43739106 IPC**. Model SHA256:
`139121ae7864dd89b3b3cc06096ea51e4a045205497a10f93035d21b848c70ad`.
Both endpoint frames visibly show changing Quake gameplay; RGB is unchanged.
Their capture times are bracketed by adjacent 500k-clock progress records,
not claimed cycle-exact. The audit rechecks 234 source and 17 runtime pins
plus the live native identity. Full timedemo remains open. This supersedes
0.39555990 as the latest measurement, not as a controlled equal-scene-work
percentage gain. Permission shadow, target read and read-retirement priming
are absent from this measured build.

The preceding **permission-shadow** gameplay audit is
`external/tmp/ventium-ifetch-auth-gameplay-audit.XNYeoSR5/audit.json`:
**44,513,116 = 33,416,464 U + 11,096,652 V retirement events / 100M clocks**,
cycles **1,200,000,000–1,300,000,000**, giving **0.44513116 IPC**. Model SHA256:
`1f2583cb1e74a7ca59b07d99db8fd4aefb7b322957d6f6411a36b8898d3a6876`.
The unchanged endpoint captures show advancing Quake gameplay, from shells
to grenade-launcher pickup. Capture times are bracketed by adjacent 500k-clock
progress records, not claimed cycle-exact. The audit rechecks 238 source and
17 runtime pins, live native identity and no OOM. It supersedes the REP result
as the latest measurement, not as an isolated equal-scene-work gain.
The fixed window remains below 0.48; full timedemo and desktop acceptance are
still open. Target read, read-retirement priming and scalar dispatch are absent.

Its disjoint residency audit accounts for every clock. The largest waiting
bucket is D-side pipeline result wait (**21.124151%**); x87 admission occupies
**8.823239%**, `S_FLOAD` **7.831977%**, slow integer load **7.005721%**, and
`S_FETCH` **2.775894%**. These include necessary work, not wholly removable
stalls. For this observed retirement count, reaching 0.48 needs **7.264342%**
fewer clocks. The running read-priming candidate targets the D-side cost;
its directed savings are not yet a gameplay result.

The latest **target-read** gameplay audit is
`external/tmp/ventium-auth-target-gameplay-audit.eunv4nge/audit.json`:
**44,468,922 = 33,415,299 U + 11,053,623 V retirement events / 100M clocks**,
cycles **1,200,000,000–1,300,000,000**, giving **0.44468922 IPC**. Model SHA256:
`59650fe299f7ae07f0227c9d0eae696642000affadf35adf640fdad5e3d58059`.
Both unchanged captures visibly show gameplay advancing from shells pickup
to grenade-launcher pickup. Each capture is bracketed by adjacent 500k-clock
progress records. The audit rechecks 233 source and 17 runtime inputs, live
native identity and no OOM. This is slightly below the preceding permission-
shadow window: **no gameplay gain is established by target read**. Equal-clock
windows are not guaranteed equal scene work. The complete timedemo is open.

The matching disjoint residency audit accounts for all 100M clocks. D-side
result waiting remains **21.120955%**, x87 admission **8.784291%**, `S_FLOAD`
**7.809637%**, slow integer load **7.183039%**, and registered I-cache latency
**1.361018%**. These include necessary work, not all removable stalls. The
same retirement count needs **7.3564125%** fewer clocks to reach 0.48.
Read-retirement priming, scalar dispatch and wide-operand queuing are absent
from this measured build and remain unmeasured.

## Fixes and evidence

- [Last-response FP pop admission](../verif/fe_pipe/FP_POP_DRAIN.md): removes
  response-accounting delay without crossing an unfinished stack mutation.
  Resident load/pop microloops: **23→20 clocks**. Gameplay measured above.
- [Registered instruction-word reuse](../verif/l1/CODE_WORD_REUSE.md): avoids
  recapturing instruction bytes already in a registered, physically tagged
  staging line. Directed staged reads **36→18 clocks**; instruction-miss kernel
  **66,330→52,260 clocks**. Cold gameplay window measured above; full timedemo
  still running, not accepted.
- [Tag LUTRAM](../verif/l1/TAG_LUTRAM.md): preserves reset validity/ownership,
  removes reset from invalid payload, flattens indexing. Isolated routed leaf
  **22,051→13,014 LUTs; 6,877→1,691 FFs**. This is not full-chip utilization
  or CPU timing. Local setup estimate **67.385 MHz**, hold still −0.080 ns.
- [Data hits during instruction fill](../verif/l1/DATA_UNDER_IFILL.md): uses
  independent D banks through the existing registered owner path. **640**
  directed held reads finish in two clocks; 76 system/64 boundary cases pass.
  Combined gameplay is measured above; no isolated gain or FPGA timing claim.
- [Exact short x87 byte capture](../verif/fe_pipe/FP_SHORT_WINDOW.md): retains
  ordinary decoder/exception/execution decisions and removes unused suffix
  fetches. 288 full QEMU comparisons, 492 predicate checks, fault/debug and
  CPU-store SMC tests pass. Selected loops lose 5–6 clocks per iteration;
  these are not isolated gameplay gains. Combined model `05611d6c` now has
  the measured gameplay window above; its full Quake/Win95 qualification
  remains open.
- [Resident priming during I fill](../verif/l1/PRIME_UNDER_IFILL.md): an additional
  private candidate removes one capture clock for 640 directed resident hints,
  with ownership/event negative controls and 76 full system cases passing.
  It is **not** in the running combined guest/Full-CoreMark models and has no
  gameplay or full-core throughput claim.
- [Independent REP admission](../verif/rep_sfetch/CONT_NO_UOP.md): removes the
  uop-short-fetch profile dependency without enabling a uop cache. 32 complete
  QEMU comparisons, 76 system cases, four SMI and 36 external-IRQ structural
  cases pass.
  Eighteen halt/resume diagnostics also pass full architectural comparison,
  precise memory-prefix checks and 1,024-clock stable parked state; they are
  not performance/suite acceptance.
  The separate cross-page dynamic-SMC oracle disagreement stays FAIL. Cold
  Quake model `139121ae` runs on CPU29 and Win95 on CPU30; the new gameplay
  window above measures 0.43739106, but neither timedemo nor desktop is accepted.
  Win95 invocation is `06d2598e26e541908ef2f442414ef802`.
  Both full direct-memory CoreMark seeds for model `cb4b2f84` pass with
  **2.107861982 / 2.110913372 CM/MHz**, 711,621,545 / 710,592,874 clocks,
  542,165,465 / 541,458,844 retirements. The independent audit in
  `external/tmp/ventium-rep-no-uop-coremark.Gszccvp5/full-r3` verifies all CRCs,
  zero actual faults, stable 114 pins and clean native closure. Host times
  3,518.21 / 3,503.84 seconds stay below the unchanged 60-minute cap.
- [Instruction-permission shadow](../verif/fe_pipe/IFETCH_AUTH_MULTI.md):
  retains sixteen independently checked code-page permissions instead of one,
  rechecks live CPL, and invalidates on every context flush/I-TLB replacement.
  Directed paged CALL/RET loops **47→31 clocks**; 288 control-loop comparisons,
  76 broad system cases, 16 warm-code fault/remap cases and 44 boundary cases
  pass complete QEMU comparisons. These are not gameplay gains. Cold Quake
  model `1f2583cb` runs on CPU31, invocation
  `56a6b51ae71e4621a589215c80dc3de2`; its native input/CPU/resource admission
  is checked. Cold Win95 runs on CPU27, invocation
  `a01ee6b1971f4f129b5abfad87f5fa19`; both guests remain unaccepted.
  The audited gameplay window above now measures **0.44513116 IPC**. It is
  not a completed timedemo or standard-suite pass.
  Matching direct-memory CoreMark model `53a2b7d8` passes short
  host-equivalence/CRC qualification with identical clocks to the REP parent.
  Its measured host rates are too close to the 60-minute cap for full launch.
  Four additional CPU placements reproduce the exact 4,821,679 clocks and
  3,660,809 retirements, but yield only 193–199k simulated clocks/host-second;
  they do not provide the required launch margin. Full seeds remain unrun.
- [Checked system target read](../verif/fe_pipe/SYSTEM_TARGET_READ.md): after
  the permission shadow removes masking stalls, the existing two-port target
  selector saves one warm CALL/RET clock. 288 control comparisons, 76 system,
  sixteen fault and 44 boundary cases pass; 115,712 real-include checks pass
  in each of original/disabled/enabled variants. Sixteen additional twice-warm
  cross-page privilege comparisons pass, and a deliberately missing boundary
  guard is rejected. FPGA-faithful PC model `59650fe2` now runs cold Quake on
  CPU28 and Win95 on CPU16, with identical core/FP source to the tested model.
  Its fixed gameplay window now measures **0.44468922 IPC**, not an improvement
  over the permission-shadow window and not a suite pass. The original no-permission-shadow
  experiment remains no-gain.
- [Read-retirement cache priming](../verif/fe_pipe/HELD_READ_PRIME.md): private
  repaired candidate reuses the existing next-read port after a retiring U
  read. Four read-ALU loop **9→6 clocks**; 96 full micro comparisons, 76 system,
  sixteen fault/trap/SMC and sixteen pair-ownership comparisons pass.
  The first version lost immediate V pairing and was rejected; the repaired
  version preserves the exact parent V counts. Actual helper enabled/disabled
  passes 239,285 checks each. FPGA-faithful PC model `15f56054` now runs cold
  Quake on CPU17 and Win95 on CPU21, with independently audited native identity
  and resource limits. Its generic gate remains FAIL with the existing 101
  terminal-record mismatches/four cycle bands. No gameplay or FPGA gain claimed.
  Matching direct-memory CoreMark model `9ba1e7ab` passes both short seeds,
  exact serialized-model/mapped-RAM host-equivalence and all fifteen negative
  controls. Performance/validation use **4,821,679 / 4,814,966 clocks** and
  **3,660,809 / 3,655,953 retirements**, with correct CRCs and zero actual faults.
  Short runs are not score-eligible. Measured optimized host rates of about
  192k/190k clocks/second lack the required 60-minute full-seed launch margin;
  the full seeds have not been launched. Receipts:
  `external/tmp/ventium-read-prime-coremark.9e4FfoAo/qualify-r1/closed.json`.
- [Scalar x87 dispatch](../verif/fe_pipe/FP_SCALAR_DISPATCH.md): private candidate
  captures the existing reference packet at the checked slow handoff and
  enters the unchanged operand/pre-probe path directly. FIADD32 **8→7**,
  FCOM32 **5→4**, zero-latency FIST32 **8→7** and FST32 **9→8** steady loop clocks.
  288 long-loop architectural comparisons, 48 precise store-fault comparisons,
  sixteen SMC, four debug/lazy-FP and 76 broad system cases pass, with actual
  U/V and new-path witnesses. The initial short-slice performance gate stays
  FAIL: at high AXI latency a selected slice costs one extra clock, although
  whole-program timing improves and longer steady throughput is unchanged.
  No gameplay, full-suite, production or FPGA acceptance is claimed.
  The complete FPGA-faithful PC model builds as `73ce5538`, with identical
  microtested core/FP source and exactly one added define; no new cold guests
  have been launched for it. Parent/candidate synthesis-guard core lint passes
  all six structural hard classes. The whole-PC build retains the same 98
  third-party warning debt. Its unchanged generic gate has the parent's 101
  terminal-length failures/four hard bands; matched-loader-input replays show
  identical full architectural records for all 108 functional programs.

Closed scratch snapshots were losslessly compressed after checking their
recorded hashes and absence of live users: **2,649,788,416 bytes reclaimed**.
`external/tmp/ventium-closed-snapshot-archive.4fwrK4bP/manifest.json` records
the twenty exact paths and decompression checks. `gzip -dk -- EXACT/end.snap.gz`
recovers each original. No source, disk media or state-delta trace was removed.

Another **1,269,211,136 bytes** were recovered by losslessly compressing sixteen
closed compiler PCH files. Every decompressed SHA256 and all other build files
were checked; use `gzip -dk -- EXACT_FILE.gch.gz` to recover them. Manifest:
`external/tmp/ventium-closed-goldens-archive.YYawVksY/pch-manifest.json`.
Fourteen further closed-build PCHs were losslessly archived, recovering
**1,130,819,584 bytes**. All decompressed hashes and every other build file
are checked; live models, media, traces and frames are unchanged. Manifest:
`external/tmp/ventium-scalar-pch-archive.MF6R3TaC/manifest.json`.
Recover any original with `gzip -dk -- EXACT_FILE.gch.gz`.
An initial historical-golden-cache archive was refused because its files are
hard-linked; that cache was left completely untouched.

A further **1,429,360,640 bytes** were recovered from eighteen explicit closed
compiler PCH files, with decompression hashes and every other selected build
file checked unchanged. Manifest and recovery details:
`external/tmp/ventium-read-prime-pch-archive.dY9LZoDR/{manifest,closed}.json`.
These remain losslessly recoverable with `gzip -dk -- EXACT_FILE.gch.gz`.

## Current profiling lead

The measured combined build defines `VEN_REP_MOVS_CONT`,
`VEN_REP_MOVS_LOAD_FUSE` and `VEN_REP_MOVS_STREAM`, but not `VEN_UOP_SFETCH`.
Their shared `rep_stos_cont_profile` is therefore constant zero: all three
MOVS paths are disabled despite the feature flags. The private
`VEN_REP_CONT_NO_UOP` recipe changes only that admission dependency. It does
not enable the uop cache or change existing continuation, invalidation, event,
fault, partial-progress or rollback checks. Directed qualification above does
not replace the open differential gate, full standard suite or hardware checks.

In the preceding code-word gameplay interval, MOVSD contributes **758,808 / 2,918,429
slow-decode clocks (26.00%)**. Exclusive state accounting in the audit's
`residency.json` sums to 100M clocks; the largest categories are successful
S_PIPE issue 20.83%, pipe-memory wait 16.36%, S_FETCH 13.81%, S_LOAD 8.02%,
S_PIPE FP admission bail 7.39%, and S_FLOAD 6.63%. These include productive
and architecturally required clocks, not solely removable stalls. Holding
the same retirement work fixed would require **18.75% fewer clocks** to
reach 0.48; microbenchmarks alone cannot establish that result.

Preceding combined-build exclusive accounting also sums to exactly 100M clocks:
successful S_PIPE issue **21.14%**, pipe-memory wait **16.99%**, S_FETCH
**13.18%**, FP admission **7.56%**, S_FLOAD **6.77%**, S_LOAD **6.35%**,
slow/system admission **5.88%**, S_EXEC **4.30%**, S_DECODE **2.93%**. The
complete list is in that build's audit `residency.json`. Holding retirement
work fixed would still require **17.59% fewer clocks** for 0.48; occupancy
is not a promise that those clocks can all be removed.

Latest REP-build accounting in `ventium-rep-gameplay-audit.753XgqaN/residency.json`
also partitions all 100M clocks: successful issue **23.43%**, pipe-memory wait
**20.37%** (load **19.54%**, store **0.83%**), FP admission **8.17%**, S_FLOAD
**7.35%**, S_LOAD **6.97%**, S_FETCH **5.97%**, slow/system admission **5.64%**.
The remaining same-retirement-work reduction needed for 0.48 is **8.88% of
clocks**. These are residency measurements, not guaranteed removable stalls;
different gameplay progress prevents assigning the entire change to REP.

## Gates that must not be hidden

Canonical UV-fast/AXI `make verify` is still failing: historical runs show
101 user terminal-record mismatches and four hard cycle-band failures. The
separate pre-exit observer is diagnostic and still has two x87 discrepancies;
neither it nor passing directed tests replaces a green differential gate.
No trace trimming, new exception masks, widened cycle bands or oracle-state
fabrication is accepted. These fixes are not declared complete.

Next: finish candidate gameplay measurement; qualify the combined candidate
with architectural fault/SMC tests, resolve the generic gate, then complete
the full standard suite and FPGA deployment. Keep each measured binary,
source closure, settings and native receipts separate.

## Ordered m64 queue and saved-pointer correction

The next isolated prototype widens the existing ordered FP slot from m32 to
m64: 32 added payload bits and one width bit, no additional arithmetic unit
or speculative stack state. The regression uncovered an older protected-mode
saved-FDP defect (`dbase + q_ea` instead of the segment offset). A separate
metadata-only correction preserves real/V86 pointer values and leaves actual
translated memory addresses unchanged. Both are private; production/full-PC
and FPGA integration remain open. See
[implementation and evidence](../verif/fe_pipe/FP_MEM64_QUEUE.md).

Final micro model `d1811627` in
`external/tmp/ventium-fp-mem64-r2.LCJyV4S0` passes 256 complete QEMU overlap
comparisons, 24 first/second-operand-page fault comparisons and 76 broader
system comparisons, each with a cycle execution. All forced-FWAIT controls
remain unchanged; eligible directed loops save 1–8 clocks per iteration.
The actual leaf passes 25 enabled checks, 12 disabled/parent checks and a
real unchanged-parent negative control. Three synthesis-guard lint profiles
pass. The generic gate still fails with 101 terminal mismatches/four cycle
bands; all 108 complete functional traces match a fresh same-input parent
execution. No masks, guest changes or widened bands were used.

This does **not** change the gameplay baseline: **0.44513116**, `1f2583cb`,
1.200–1.300B clocks. Neither the m64 change nor scalar dispatch has a gameplay
measurement; no share of Quake improvement is attributed to their micro gains.
Post-queue INT3 and #GP now pass 128 complete QEMU comparisons each. All
536 overlap/fault/event cases were rerun with a unique-port oracle driver;
a preparation-stage port collision is retained as failed evidence. Relocated
external IRQ/debug-event, full standard-suite and FPGA qualification remain required.
The exact three-file full-PC integration compiles as `842f0c7d` in
`external/tmp/ventium-fp-mem64-soc.nqs8uA9x`, with unchanged platform settings
and third-party warning debt. It has not launched guests or produced a
performance measurement.

Twenty-two additional explicitly selected closed-build PCHs were losslessly
archived, recovering **1,578,122,581 bytes**. Their decompressed hashes and all
other selected build files were checked. Executables, guest inputs and traces
are unchanged. Recovery: `gzip -dk -- EXACT_FILE.gch.gz`; manifest and receipt:
`external/tmp/ventium-mem64-pch-archive.MSxyFXMj/{manifest,closed}.json`.

## Combined FP integration and external IRQ coverage

`external/tmp/ventium-fp-combined.gkqX3v51` combines scalar dispatch with the
pointer-corrected m64 queue. Board model **`7bfb9e32`**, full-address user model
**`3f637315`**; only scalar dispatch is added to the wide-queue parent. Native
build/source/header checks pass. It remains a private, unaccepted candidate.

The combined model passes 356 scalar and 536 wide-operand complete QEMU
comparisons, plus their cycle executions, 76 broad system comparisons and
three synthesis-guard lint profiles. Neither the ordinary architecture checks
nor UV pairing requirements are relaxed. The unchanged generic gate still
fails: 101 terminal-record mismatches and four hard cycle bands. Fresh replay
matches all 108 complete parent architectural traces; this is nonregression,
not a generic-gate pass.

New real-PIC/held-pin IRQ tests pass 64 instruction-stream and 64 entry-state
comparisons **on each** of the wide-only and combined profiles. Eight m64
forms, FWAIT controls, AXI 0/7 and actual V retirement are covered. Every
candidate overlap combination records fourteen IRQ requests with two pending
FP owners; all sixteen INTA handshakes occur only after drain. Entry ABI
records are compared separately, not discarded. This closes the flat-CS
standalone IRQ case, not full-PC or relocated/debug-event acceptance.

Latest verified gameplay remains **0.44468922 total U+V IPC**, target-read
`59650fe2`, cycles **1.200–1.300B**, predating both candidates. Neither has a
combined CoreMark, gameplay, standard-suite or FPGA result. Details and exact
model hashes: [m64 queue qualification](../verif/fe_pipe/FP_MEM64_QUEUE.md).

The next user-model build was initially refused by its unchanged 4-GiB disk
guard before starting a compiler. Eight confirmed closed-build PCHs were
losslessly archived, recovering **616,544,045 bytes** with verified recovery
hashes and unchanged remaining files. Receipt:
`external/tmp/ventium-combined-pch-r2.OfLtdenl/closed.json`. The first archive
selection refused already-compressed files before changing anything.

Combined full-PC build **`652de481`** also passes native/source/header and
four-way registered-XPM checks, with unchanged platform settings and warning
debt. Root: `external/tmp/ventium-fp-combined-soc.WPpVLjvn`. No combined guest
or FPGA measurement is implied. Six additional closed-build PCH archives
recovered **472,079,414 bytes**, verified recoverable by their original hashes;
receipt: `external/tmp/ventium-combined-soc-pch.xmOyE6vW/closed.json`.

## Read-prime result and next combined measurement

Read-prime model
`15f5605496acfed016b5af95d66e315eb1e01db04d9475c8c4b67203945ff453`
measures **0.44004644 total U+V IPC**:
**44,004,644 = 33,710,278 U + 10,294,366 V** retirements over exactly
100M clocks, **1,200,012,763–1,300,012,763**. Source/runtime pins (237/17),
live native identity and zero OOM were rechecked. Both unchanged endpoint
images visibly advance from shells to grenade-launcher pickup during gameplay.
Root: `external/tmp/ventium-read-prime-gameplay-r2.EmjPrsx7`.

The initial exact 1.2B/1.3B extraction correctly refused: this run's periodic
profiler is offset by 12,763 clocks. R2 retains the predeclared sample indices
12/13, frames6/7 and exact 100M width, reporting the actual endpoints rather
than interpolating or selecting a better window. Frames remain bracketed by
500k progress records, not cycle-exact captures. No gameplay gain over target
read's 0.44468922 is established. Equal-clock windows are not equal-work proofs.
Exclusive residency still includes 21.075% pipeline memory wait, 9.009% FP
admission and 7.905% FP load. The equivalent-work clock reduction needed for
0.48 is 8.324%; these categories are not all removable overhead.

Combined FP model `652de481` now has both cold original-workload candidates
running, under unchanged resource, disk and completion guards: Quake CPU25,
invocation `78a96c0143a2408aa724836afc3fdb3f`; Win95 CPU26,
`f8bab538127049f88b3bfa73fda3914e`. No combined IPC or acceptance yet.
Sixty-two explicitly inventoried closed historical snapshot/disk artifacts
were losslessly compressed, recovering **5,180,596,224 bytes**. Original
hashes, decompressed bytes and untouched remaining files were checked.
Recovery is `zstd -d -k -- EXACT_FILE.zst`; manifests/receipts are in
`external/tmp/ventium-old-state-archive.jnTyxZ6C` and
`external/tmp/ventium-old-state-extra.mEmIHBHE`. Sources, executables, current
runs and existing trace archives were preserved. Earlier inventory refusals
changed nothing.

The standalone CoreMark AXI diagnostic also exposed a **host harness** bug:
undriven store-update masks invalidated ordinary cached RAM on every store.
Correcting that, and generating ordinary low-RAM entry images through QEMU's
loader, gives reproducible cache-backed diagnostics with zero uncached bypasses.
The corrected 10-iteration ratios are 1.823895/1.826804, **not accepted scores**.
Both CRC sets, 24 complete QEMU-state micro comparisons and 24 UV-cycle runs
pass. No RTL or full-PC policy changed, so no Quake/FPGA gain is attributed.
See [backend diagnosis](../verif/bench/COREMARK_BACKEND_DIAGNOSTIC.md).

## Scalar final-operand handoff

The next private candidate, core `9fa1b292` / corrected-host user `09aa12d9`,
adds FIAR32 and FCOM32/64 to the existing checked final-source-beat handoff.
It saves one command-dispatch clock without changing FPU execution latency,
queue classes, storage or memory ports. Directed FIADD32 loops improve
**7→6 clocks**, FCOM32/64 **4→3**. The 568 complete architectural comparisons,
24 precise operand-fault cases, 12 debug/lazy-FP cases, 76 broader system
comparisons and three synthesis-guard lint profiles pass. Actual predicate/
payload leaves pass 114,688 checks each enabled/disabled and a deliberately
broken implementation fails the expected negative control.

The generic gate still fails with the existing 101 terminal mismatches/four
bands; complete same-input parent parity passes all 108 functional programs.
Both short CoreMark seeds retain identical clocks and CRCs on direct and
corrected low-RAM AXI backends. No full-PC run or FPGA image contains this
latest flag; **0.44004644 remains the verified gameplay baseline**, not a
result for either later candidate. The existing combined cold pair continues;
no additional cold pair was launched. Details, retained failed test attempts
and remaining acceptance: [scalar operand handoff](../verif/fe_pipe/FP_SCALAR_LOAD_CMD.md).

## Reference operand resident priming

Private user model **`12d078a7`** now borrows the checked reference-dispatch
edge for a resident-only operand read using the existing D-cache/DTLB port.
Normal S_LOAD/S_FLOAD still owns exact widths, permission/fault checks and
execution; required MOVSX/IMUL latency is unchanged. No extra memory port,
queue or arithmetic unit is added. In matched ordinary low-RAM short CoreMark,
AXI0 performance clocks improve **5,482,773→5,375,191 (−1.9622%)** and validation
**5,474,040→5,369,188 (−1.9154%)**. Both CRC sets pass; direct-memory clocks are
identical. These are **not score-eligible runs** and not physical DDR results.

The 1,200-comparison boundary matrix, 24 scalar and 24 integer precise-fault
comparisons, 12 FP debug/lazy-state comparisons and 76 broader system checks
pass, alongside enabled/disabled/board synthesis-guard lint. All 108 original
generic architectural sequences match the parent exactly; the unmodified
generic gate still fails its existing terminal mismatches and four hard cycle
bands. No failure was converted into a pass by changing the oracle.

**0.44004644 remains verified gameplay IPC** on `15f56054`, clocks
1,200,012,763–1,300,012,763, predating this candidate. Combined `652de481`
continues cold startup; no new full-PC pair or FPGA rebuild was launched for
the follow-up. Full suites, measured 0.48 gameplay IPC and hardware deployment
remain pending. Reproduction, exact results and retained failed experiments:
[reference operand priming](../verif/fe_pipe/REF_OPERAND_PRIME.md).

## Read preparation during required AGI

Private model **`d2a117e7`** additionally uses an already-required address
interlock clock to prepare the current resident U operand. No AGI clock,
fault check or retirement boundary is removed, and no memory port or queue
is added. Short cache-backed CoreMark performance/validation clocks improve
**5,375,191→5,264,309 / 5,369,188→5,257,586**, or **2.1063% / 2.1227% higher
throughput**. Direct-memory timing is unchanged; all CRCs pass. Short ratios
**1.899585 / 1.902014 are not score-eligible results**.

The 1,200 complete boundary comparisons, 24 precise-fault cases, 24 debug/
cacheability event cases, 76 broader system checks and three synthesis-lint
profiles pass. All 108 generic architectural sequences match the parent;
the original generic gate still fails the existing terminal mismatches and
four hard bands. Earlier failed checker/fixture attempts are retained, not
relabelled as passes. Closed failed matrix traces were losslessly archived,
recovering 1,100,840,960 bytes after decompressed-hash checks.

Verified gameplay remains **0.44004644** on **`15f56054`**, clocks
**1,200,012,763–1,300,012,763**, predating this candidate. The combined cold
pair continues; no additional full-PC pair or FPGA rebuild was started.
The requested cache-backed 2.1 score, 0.48 gameplay IPC, full-suite completion
and hardware deployment are still open. Details and reproducible inputs:
[AGI resident read](../verif/fe_pipe/AGI_RESIDENT_PRIME.md).

## Latest integrated cold pair and resource closure

The complete scalar-load-command, reference-prime and AGI-prime source is now
integrated in full-PC native **`f780b331`**. Its core/FP source matches the
qualified `d2a117e7` microtest model; it preserves 132 defines, full P5 L1s,
32 KiB platform L2, posted16 writes and registered read-first XPM-fidelity RAM.
Build and independent live-admission receipts are in
`external/tmp/ventium-agi-prime-soc.lpcpUJXu`. This is a **simulator, not a new
FPGA bitstream**. The inherited 98 third-party structural warnings are unchanged.

Fresh, unchanged-media cold runs started at 15:42 EDT, with UV/system-relocated
fast paths and fast loads/stores enabled, no snapshot, guest patch or STEP:

| Guest | CPU | Service invocation |
| --- | ---: | --- |
| Quake | 22 | `4d85b68dea0c4a3e9f094dd41e1d5c42` |
| Win95 | 23 | `9845ebf942414198a8e9e7781bba02cc` |

Both have one-CPU, 2 GiB RAM, zero-swap, 32-task and 4 GiB-per-file bounds.
`gameplay-plan.json` fixes periodic sample indices 12/13, a 100M-clock window
and endpoint frames 6/7 before measurement; actual clock offsets must be
reported. The independent admission audit binds the plan to the actual service
and native executable. No gameplay IPC or guest acceptance exists for this build.

Nine superseded guests were gracefully host-stopped and their actual children
reaped with native exit zero; logs/media/frames/models remain intact. These
are **not passes**: incomplete Quake runs stay FAIL, Win95 stays
CLOSED_UNQUALIFIED. Exact targets and closure audit:
`external/tmp/ventium-superseded-run-closure.BTmHZC65`.
The read-prime control and combined `652de481` pairs continue independently.
There are now six live guests, not thirteen; no Vivado run was launched.

Lossless archival recovered **9,978,458,112 bytes (9.29 GiB)**: 5,400 closed
reference/AGI matrix traces and 60 historical August 17 `qk5c_snap.*` files.
Each compressed file was decompressed and hash-checked before its raw copy
was removed. Manifests/receipts are in `ventium-qualified-trace-archive.cqVKfhRc`
and `ventium-aug17-snapshot-archive.QSAKm2kZ` under external scratch. Restore
one artifact with `zstd -d -k -- EXACT_FILE.zst`; live runs and source were
not deleted. Do not remove the whole symlink-backed `external/ventium_run` tree.

Verified gameplay remains **0.44004644 total U+V IPC**, model **`15f56054`**,
clocks **1,200,012,763–1,300,012,763**, predating both later candidates.
Its fast D-side waiting partitions into **20,178,479 load clocks (20.178479%)**
and **896,702 store clocks (0.896702%)**, exactly the 21,075,181-clock bucket.
These are wait exposure, not all removable cycles. Cache-backed 2.1 CM/MHz,
0.48 gameplay IPC, generic-gate repair, complete same-source standard suite and
FPGA deployment remain open.

## Read-command forwarding and passive memory diagnosis

[AXI read-command forwarding](../verif/l1/AXI_READ_THROUGH.md) now removes the
AR-capture bubble when the existing Avalon endpoint is ready, without changing
ARREADY, memory ownership, narrow lanes or older-write ordering. The default-off
candidate passes **63 native runs**, including 7,803 focused transaction checks
and the real platform L2/XPM/reset corpus. Ready reads save one clock; blocked
reads are unchanged. The real-L2 corpus saves 31 aggregate clocks (completion
1,128→1,097); this is not a measured CPU gain. The original randomized-reset
fixture failures are retained and explained in the linked evidence.

Full-PC native **`e9097d96`** is built, not launched or deployed. It differs from
`f780b331` only in the bridge and its added define. The six existing cold guests
continue; no additional guest or Vivado run was started for this bridge change.

A read-only sample of unchanged baseline model `15f56054`, bracketed at
2,293,423,334–335 and 2,305,263,998–999 clocks, finds 21.474480% L1 read-wait
exposure during fills, 9.296953% idle-state read-wait exposure and 16.096792%
L2 stream-state residency over 11,840,664 clocks. These views overlap and must
not be summed. L2 word-hit counts are not transaction hit rates. There are
26,039 L2 misses and 52,076 outer reads in this window, consistent with the
retained double-read policy and in-flight boundary effects, not permission to
remove that hardware workaround. Evidence and identity/pin checks:
`external/tmp/ventium-read-prime-cache-probe.TJcVRufy/analysis.json`.

Verified gameplay is still **0.44004644** (`15f56054`,
**1,200,012,763–1,300,012,763** clocks), predating the later candidates; the
passive cache sample is diagnostic, not a new acceptance IPC measurement.

### Read-through cold qualification and desktop closure

`e9097d96` has now started unchanged-media cold Quake/Win95 qualification on
CPUs28/29, invocations `fa4189beba1e4f438494237b9dfec7f0` and
`bd39a4aeaf774e3693c1a9b29099edcc`. Independent source/runtime/native/resource
admission passes, including zero OOM. Both preserve the existing bounds and
UV/system-relocated fast pipeline, fast memory paths and 40/40/80 MHz clocks.
No guest acceptance, gameplay result or FPGA deployment exists for this model.

The older `15f56054` Win95 run was gracefully stopped after viewing a clean
Welcome desktop. Native exit0, actual child wait, EOF capture, unchanged input
pins and successful service closure are recorded at **2,478,622,041 clocks**.
Raw frames17 and final18 both show readable text/icons/taskbar and no visible
error; PNG conversion preserves every RGB byte. The repeated `FCB2:2FF7`
vector6 records match the previously documented ROM-ARPL V86 callback and the
older code-word control, not a newly identified corruption symptom. Evidence:
`external/tmp/ventium-win95-ud-audit.4iD1TkK7` and the closed run's `result.json`.
Independent/human desktop acceptance remains pending: **CLOSED_UNQUALIFIED is
not a suite pass**. Seven full-PC guests remain live, not eight.

`tools/prepare_gameplay_window.py` replaces repeated private audit adapters:
it selects predeclared periodic sample indices, preserves actual offsets,
checks complete counter invariants/pins/native ownership, rejects missing or
reset samples and checks frame timing brackets plus pixel-identical previews.
Eleven unit tests pass. It deliberately leaves `gameplay_ipc=null` and does
not grant visual, standard-suite or hardware acceptance.

Verified gameplay is unchanged at **0.44004644 total U+V IPC**, `15f56054`,
**1,200,012,763–1,300,012,763** clocks, predating all three newer candidates.

The matched old/off/on isolated FPGA bridge check is now closed: **149→175
CLB LUTs, 71→72 registers**, no RAM/DSP addition. The setup-limited leaf estimate
is **451.67→445.83 MHz**; this is not CPU Fmax. All profiles still fail isolated
hold constraints (−0.049/−0.050 ns), so no timing sign-off is claimed. The single
bounded Vivado family used 4.18 GB peak RAM, zero swap/OOM, took 255.49 seconds
and has exited. No processor bitstream or deployment was performed. Raw reports:
`external/tmp/ventium-read-through-physical.ou0amfh0`; see the
[bridge evidence](../verif/l1/AXI_READ_THROUGH.md).

### Preserve actual supervisor closure, without changing acceptance

The read-prime desktop's later `audit_closed.py` correctly refuses a missing
supervisor invocation: systemd had already garbage-collected the successful
transient service. Its native exit/EOF/result and matching journal invocation
remain, but **no inactive supervisor receipt was reconstructed** and this
strict audit is not called a pass.

`tools/hold_supervisor_closure.py` prevents that evidence-loss race for the
seven still-live guests. It holds a D-Bus `RefUnit` for each exact expected
invocation, archives the manager's actual inactive/failed properties after
exit, then immediately releases that reference. It cannot launch, stop,
restart, step or modify any guest. Failure closures are archived too and are
not relabelled as successful runs. The existing closed-suite checker's optional
externally hashed supervisor receipt remains unchanged.

Six unit tests and a real ten-second transient-service fixture pass, including
preserving its actual invocation/exit code after process exit. Evidence:
`external/tmp/ventium-supervisor-closure.E7WfTQP6`. The keeper itself is a single
96 MiB/no-swap, 10%-CPU, 16-task, bounded service, invocation
`97a85ec493694c80acba70e20680e1b6`. Its live-admission record binds all seven
owners before closure. This is metadata retention only, not a new CPU test or
desktop acceptance. Current gameplay remains **0.44004644**, `15f56054`,
**1,200,012,763–1,300,012,763** clocks; newer candidates remain unmeasured.

## Latest verified combined-FP gameplay window

**0.44183623 total U+V IPC**, model
`652de481d967acee7a3bf48c419136053ec8625e93566fb1091a4a1ca66dc350`,
clocks **1,200,000,000–1,300,000,000**. This supersedes the read-prime
0.44004644 measurement as the current verified gameplay number. It still
misses **0.48**; no meaningful closure of the performance gap is claimed.

The predeclared sample indices12/13 retire **44,183,623 = 33,874,666 U +
10,308,957 V events** over exactly 100M clocks. Both unmodified endpoint
captures visibly show advancing gameplay, from shells to grenade-launcher
pickup. The captures bracket the endpoints within adjacent 500k-clock
progress records, not cycle-exact image timestamps. Source/runtime pins
**240/17**, live executable/PID/service identity, UV/system-relocated fast
paths, counter invariants and zero OOM are rechecked. Evidence:
`external/tmp/ventium-fp-combined-gameplay.ERa7LHqZ/window/{audit,residency}.json`.
No completed timedemo, same-source standard-suite pass or FPGA score follows
from this window. Equal-clock windows do not prove equal scene work or an
isolated percentage gain.

Exclusive residency accounts for all 100M clocks. D-side pipeline result wait
is **21.136523%**, x87 issue/occupancy **9.149561%**, `S_FLOAD` **8.010433%**,
slow integer load **6.939883%**, `S_FEXEC` **3.478284%**, and `S_DECODE`
**1.699117%**. These buckets include necessary work, not wholly removable
stalls. Holding this retirement count fixed requires **7.9507854% fewer clocks**
to reach0.48. The platform L2's resident-hit path already emits one word per
clock; it is not a newly found two-clock-per-word bottleneck.

This measured build contains scalar dispatch and m64 operand queuing, but
**not** the later scalar final-load handoff, reference/AGI operand priming or
AXI read-through. Their cold qualification continues on `f780b331`/`e9097d96`.
The last full direct-memory CoreMark scores remain **2.107861982/2.110913372**
on `cb4b2f84`; no current cache/DDR-backed2.1 score is established. Generic
gate repair, complete standard suite, ≥0.48 gameplay IPC and deployment remain
open. No U-only/STEP/global-slow fallback is counted as progress.

## Platform capacity and a newly exposed cold-boot protocol bug

Current verified gameplay is still **0.44183623**, `652de481`, clocks
**1,200,000,000–1,300,000,000**. The ≥0.48 target is open. Full direct-memory
CoreMark remains **2.107861982/2.110913372**, older `cb4b2f84`; these do not
qualify a new cache/DDR-backed score.

The [256 KiB platform L2 candidate](../verif/l1/L2_CAPACITY.md) preserves the
P5 L1s, four ways, 64-byte lines, registered read-first RAM, UV/system-fast
execution and the existing DDR workaround. It passes 512 capacity/order/reset
cases plus 45 store tests (313,344 stores, all byte masks and all sets). The
geometry-only leaf costs +3,314 CLB LUTs/+56.5 BRAM tiles, with setup-limited
isolated frequency 214.09→164.26 MHz. Both still fail isolated hold: not CPU
Fmax, full-chip sign-off or deployment.

Its first cold full-PC model `e5b4b41b` **failed**, with no retired instruction
in either guest past18M clocks. Increasing depth exposed a real protocol bug:
L2 advertised request-ready during its tag-initialization state, then dropped
the early first fetch. The repair applies normal backpressure only during
reset/tag initialization; it does not extend a harness delay or slow the normal
pipeline. 576 early-request/reset outcomes reproduce the old failure and pass
the fix. All 512 capacity and 45 store cases pass again with the repair.

Repaired model **`86731249`** is now cold-booting Quake and Win95 on CPUs24/26;
both execute BIOS instructions with the unchanged reset sequence. Evidence:
`external/tmp/ventium-l2-init-soc.tt7Ma9rk`; source/runtime/native/resource
admission passes, with 133 unchanged defines and existing UV-fast paths.
The 98 inherited full-SoC structural warnings remain unchanged, not waived as
clean. No gameplay or standard-suite pass exists yet. The separate bounded
physical leaf rerun has closed: repaired32/256KiB use **1,167/4,459 CLB LUTs**,
8/64.5 BRAM tiles, and have **203.50/160.33 MHz isolated setup estimates**.
Both still fail hold, not CPU timing sign-off. Native exit0, stable pins,
387.16 seconds, 3.98GB observed peak cgroup RAM and zero OOM/swap; Vivado exited.
No full FPGA rebuild or programming occurred.

The older combined-FP Win95 run (`652de481`) closed normally at
**1,483,622,041 clocks**, 228,426,889 retirements, after a readable Welcome
desktop capture. Native exit0, reaped processes, EOF, unchanged pins and actual
successful supervisor closure are retained at
`external/tmp/ventium-fp-combined-desktop.MWjmSoWU` and
`ventium-supervisor-closure.E7WfTQP6/live`. Its independent/manual desktop
acceptance remains open: CLOSED_UNQUALIFIED is not a suite pass. Its Quake
timedemo continues. The two failed capacity-only guests are closed as FAIL.

The current standalone CoreMark diagnostic remains a separate performance
problem, not something the platform L2 experiment can fix. On `d2a117e7`,
performance seed10 retires the same 3,661,024 instructions in 4,821,818 direct
versus 5,264,309 AXI0 clocks: **442,491 extra clocks**. D-pipeline waiting is
**220,926 load + 126,189 store = 347,115 clocks**, about78.4% of that net gap;
those waits are absent on the direct backend. Other state/pairing changes have
signed contributions, so this is not a universal miss-rate estimate. L1 reports
6,511 miss starts and zero uncached bypasses. Evidence:
`ventium-agi-prime.Fn1fJVfX/coremark-r1/{closed.json,performance-axi/run.log}`.
These are existing ten-iteration diagnostics, **not a new valid CoreMark score**.

## Write-buffer dispatch: measured small gain, not target closure

The [registered empty-queue dispatch prototype](../verif/l1/WBUF_EMPTY_DISPATCH.md)
removes one launch bubble without increasing the two-entry P54 write buffer.
Its 39-profile leaf matrix passes 120 positive runs and three expected negative
witnesses. Full-core `f75ccf1d` passes both short CoreMark seeds/all CRCs:
AXI clocks **5,264,309→5,245,654** and **5,257,586→5,239,192**, roughly0.35%
fewer clocks. Direct-memory controls, retirement counts and cache miss counts
are unchanged. These are ten-iteration diagnostics, not ≥2.1 score acceptance.

The unchanged generic gate remains red with 101 terminal-length mismatches
and four cycle-band failures. Same-input parent replay is architecturally
identical for all108 traces; that is not a gate pass. The isolated hardware
cost is +135CLB LUTs/no extra registers; setup-only leaf frequency falls
359.71→240.10MHz, both failing isolated hold. No CPU timing sign-off follows.
This candidate is not promoted/deployed.

Observation-only model `2527ec8f` reproduces all four CoreMark runs exactly.
Remaining performance-seed store waits predominantly occur with both P54
slots occupied: 48,322 clocks awaiting W acceptance and 60,108 awaiting
dispatch/final issue; no delayed-B head wait is counted. The standalone slave
serializes AW/W, unlike the platform's enabled write-through bridge. These
numbers are not an FPGA DDR-latency measurement or cache-miss percentage.
The extended same-edge admission/issue handoff is under separate testing;
its byte-lane aligner is shared rather than duplicated.

Verified gameplay is still **0.44183623 total U+V IPC**, `652de481`, clocks
**1,200,000,000–1,300,000,000**. All later candidates remain unmeasured;
≥0.48, current cache/DDR-backed CoreMark qualification, standard-suite closure
and deployment remain open. Existing cold UV-fast guests continue unchanged.

## Current full CoreMark validation and measured marginal cache change

The WBUF admission-handoff extension is now leaf-qualified: 120 positive runs,
three old empty-dispatch failures and three additional handoff-negative
witnesses. The isolated enabled master uses654CLB LUTs/467registers; setup-only
leaf estimate301.84MHz, still failing hold and **not CPU Fmax/sign-off**.
Both short AXI CoreMark seeds improve about0.43% versus the original current
master. See [the full evidence](../verif/l1/WBUF_ADMIT_DISPATCH.md).

The full-address current model **`b5453f16`** is running both **1,400-iteration**
standard seeds on CPUs2/3, each capped at3,600seconds. The unchanged pinned
QEMU/ELF produced reference-checked ordinary entry images, final CRCs5275/f9c3.
The 1,500-iteration projection exceeded the cap; no time limit or correctness,
minimum-duration, guest-clock or scoring check was weakened. Current-rate
launch projections are3379.6/3370.5seconds; projections are not scores.
Evidence: `ventium-current-coremark-host-r2.3ixLJTn1/full1400-r3`, invocation
`2ea5a68a3a0148d9bb4df1655e85309b`. Its
[host-only optimization](../verif/tb/INACTIVE_L1_SETTLE.md) passed byte-exact
same-model final-state/RAM comparisons and 15 negative native controls. It
saves host evaluation time, **zero guest clocks**. Full results remain pending.

Separately, the already-tested resident-D priming during I-fill change was
retested on the current WBUF stack (`d6d85104`). All nine leaf runs and both
short CoreMark seeds pass, but each seed saves just118AXI clocks (~0.0023%).
Direct controls are identical. No meaningful target progress or full-PC
promotion is claimed. The unchanged generic gate remains red; all108 complete
same-input parent traces match. See [integration evidence](../verif/l1/PRIME_UNDER_IFILL.md).

Current verified gameplay is **0.44183623 total U+V IPC**, `652de481`, clocks
**1,200,000,000–1,300,000,000**. Newer scalar-load/ref/AGI, read-through, L2 and
WBUF candidates remain unmeasured. Both targets still require qualification on
the accepted current implementation; the older full direct-memory scores
2.107861982/2.110913372 (`cb4b2f84`) do not establish current FPGA/cache throughput.

## New verified gameplay window and wide-response prototype

The scalar-load/ref/AGI-priming full-PC model **`f780b331`** has now completed
its predeclared gameplay window: **0.44439995 total U+V IPC**, clocks
**1,200,000,000–1,300,000,000**. That is44,439,995 retirements:
34,184,100U +10,255,895V. This supersedes the0.44183623 baseline, but is only
about0.58% higher as a window measurement, not an isolated equal-work speedup.
Reaching0.48 for this amount of work requires about7.42% fewer clocks.

Evidence: `external/tmp/ventium-agi-prime-gameplay.5lgzu8Xr/window`.
All243 source inputs and17 runtime inputs rechecked; native/service ownership,
UV/system/relocated fast pipeline and fast loads/stores, no STEP/snapshot, and
zero OOM verified. Root viewed both pixel-identical raw-frame conversions:
the shells-pickup scene advances to the grenade-launcher scene. Captures bracket
their counter endpoints within500,000 clocks. The timedemo is still running;
this is neither completion nor FPGA-board performance.

Exclusive clock accounting still puts D-side pipeline waiting at21.033965%,
x87 issue/occupancy9.274313%, FLOAD8.036797% and LOAD6.598098%. These are
residencies, not all removable stalls. Later AXI read-through, repaired larger
L2, WBUF and wide-response variants remain without verified gameplay windows.

The [wide resident response prototype](../verif/l1/LOAD64_UNDER_FILL.md)
passes its leaf ownership/cancellation matrix, old-implementation negative,
and216 full-core native runs with complete architectural comparisons. It
saves32 clocks across16 aligned resident x87 operands behind independent
AXI0 data fills, but no total clocks when the longer backing refill dominates.
Short integer CoreMark is exactly unchanged. No representative gain, suite
pass, physical timing improvement or deployment is claimed for this prototype.
Current full1,400-iteration CoreMark seeds continue with the unchanged60-minute
native cap; they have not yet produced final scores.

A separate **passive, non-acceptance** diagnostic on this unchanged live model
sampled10,332,062 clocks around1.346–1.356B without a pause, signal, debugger
attachment or guest write. Each endpoint has a one-clock sampling bracket.
L1 read-wait-during-fill is22.03%, read-wait-idle9.19%, and platform-L2 streaming
residency16.95%. These overlapping counters must not be added together.
There are75,290 L1 miss starts and23,948 platform-L2 misses. The outer adapter
issues47,895 read addresses and383,152 returned beats, consistent with its
retained two-eight-beat-read policy plus an endpoint in-flight transaction.
Evidence: `ventium-agi-prime-gameplay.5lgzu8Xr/counter-interval.json`, with the
exact model-local compiled layout and both raw counter samples. This supports
prioritizing cache/backing service; it does not justify deleting the hardware
priming workaround or claiming a removable miss percentage.

The matching AGI-prime Win95 run subsequently closed normally at
**1,456,140,480 clocks /223,476,443 retirements**, native exit0 and real
supervisor closure, stable inputs, complete log EOF and no remaining child.
The separately viewed frame8 is a clean, readable Welcome desktop; its raw
SHA256 is`0589d29b72d19308e5eb7eb4d62d0c96348cf6eb949d96c236f5d6a202f5f36c`.
Evidence: `ventium-agi-prime-desktop-oct09/closure-audit.json`. Human visual
confirmation has been requested separately. Status remains
`CLOSED_UNQUALIFIED`, not a standard-suite pass or evidence for later models.

The wide-response prototype additionally passes split-page FADD/FLD/FILD
fault/retry tests with older FP work pending, plus504 read-prime/fill-edge
checks per reset seed. The first edge test over-required a wide response
while another owner armed its critical word: data was correct, and the
existing exclusion remains. The corrected tests verify42 such exclusions
and462 eligible wide responses, with unchanged RTL and backing counts.

## Current full CoreMark closed; read-through gameplay did not improve

Both current **1,400-iteration** standard CoreMark seeds completed with all
five reference CRCs correct, zero actual fault deliveries, normal guest/native
exit, complete output and no OOM. Independent audit rechecks141 input pins,
the model, actual service closure, absent owner/children, raw CRCs and scores.
Model:`b5453f16119f8b59d744cd2bb26eef38b683cbddf20bf3f215d259d5baa577f9`.
Evidence:`ventium-current-coremark-host-r2.3ixLJTn1/full1400-r3/independent-audit.json`.

| Seed | Whole-program clocks | Retirements | CM/MHz | Host seconds |
| --- | ---: | ---: | ---: | ---: |
| Performance | 664,186,024 | 506,024,925 | **2.107843209** | 3,355.90 |
| Validation | 663,222,570 | 505,363,204 | **2.110905243** | 3,354.09 |

Guest reports10.061/10.045seconds, satisfying minimum duration. Scores use
1,400,000,000 divided by actual whole-program RTL clocks, not guest timer
calibration, short-run extrapolation or host evaluation counts. Both finish
under the unchanged60-minute cap. This closes current **direct-memory core**
qualification, not the FPGA/cache/DDR score or the entire standard suite.

The newer read-through gameplay window measures **0.43894030 total U+V IPC**:
43,894,030=33,974,927U+9,919,103V retirements over100M clocks, **1.2B–1.3B**.
Model:`e9097d96159c60f8605c6f499c19dfb6f357edf00a12485483927a29c9bb4f88`.
Evidence:`ventium-read-through-gameplay.vnfwAGcz/window/{audit,residency}.json`.
Both unchanged images show advancing gameplay, shells pickup to grenade
launcher; each capture brackets its counter endpoint within500k clocks.
236 source/17 runtime inputs, live native/service identity, UV+fast mode,
no STEP/snapshot and zero OOM are checked. Timedemo completion remains open.

This is below the parent's0.44439995: **no representative speedup is
established by read-through**. Equal-cycle windows are not equal-work trials,
and endpoint pixels differ, so this is not an isolated regression percentage.
Disjoint residency still accounts for every clock: D-pipeline wait20.786749%,
x87 issue/occupancy9.792194%, FLOAD8.249466%, LOAD6.373721%. For this observed
work,0.48 requires8.554104% fewer clocks; these residencies are not wholly
removable. The repaired256KiB-L2 run continues and remains unmeasured.

The [checked FPGA export](../fpga/PERFORMANCE_EXPORT.md) now contains the
actual larger-L2 model's performance sources, including five new core headers
absent from the old hardware bundle. Its186 payloads/135definitions pass source
closure and30 real Tcl profile checks while preserving40MHz, UV+fast and the
16-slot posted transport. This is **UNQUALIFIED source preparation**, not
simulation acceptance, clean lint, timing sign-off or deployment. No Vivado
was started; external free space remains below the build-admission floor.

Read-through Win95 subsequently closed normally at
**1,469,201,965 clocks /231,707,344 retirements**, with stable inputs, complete
log EOF, native/supervisor exit0 and no OOM or remaining child. Its separately
viewed final capture is a readable Welcome desktop, raw SHA256
`0589d29b72d19308e5eb7eb4d62d0c96348cf6eb949d96c236f5d6a202f5f36c`.
Evidence:`ventium-read-through-desktop.pMbjpek1/closure-audit.json`. It remains
`CLOSED_UNQUALIFIED` pending independent desktop acceptance; the later L2
candidate and full timedemo are not accepted by this result.

## Larger-L2 candidate clears the fixed gameplay target

Latest verified gameplay is **0.49083588 total U+V IPC** on model
`86731249748f06e2baa1ba59ea3a92d5fb1313ca12b70935006374aad859c6df`.
The predeclared counter window remains exactly **1.2B–1.3B clocks**:
**49,083,588 = 38,108,606 U + 10,974,982 V** retirements /100,000,000 clocks.
This supersedes read-through `e9097d96` at0.43894030, not the separate full
direct-memory CoreMark results of **2.107843209 /2.110905243 CM/MHz**.
The latter model contains WBUF admission; this full-PC model does not.

Evidence: `external/tmp/ventium-l2-gameplay.VedZVnwA/window/{prepared,audit,residency}.json`.
Both unmodified endpoint images were independently viewed: grenade-launcher
pickup followed by projectile impact/explosion in the corridor. Actual frames7/8
bracket the endpoints at1,199,965,200–1,200,465,200 and
1,299,965,200–1,300,465,200. The capture-index correction was declared before
the first endpoint in `frame-association-plan.json`; it changes no counter,
window, guest state or runtime setting. The audit binds that declaration and
rechecks242 source/17 runtime inputs, native/service identity, no OOM, UV plus
system/relocated fast pipeline and fast loads/stores, with no STEP or snapshot.

All100M clocks remain accounted for. Exclusive D-pipeline waiting is17.185345%,
successful fast issue26.883629%, x87 issue/occupancy11.497952%, FLOAD8.000016%
and ordinary LOAD4.565042%. These are residencies, not entirely removable
stalls. Equal-cycle windows cover different scene progress: this does not
establish an isolated percentage speedup from L2 capacity.

The same larger-L2 Win95 model closed normally at **1,230,059,901 clocks /
211,454,200 retirements**, native/supervisor exit0, complete log EOF, unchanged
pins, no OOM and all children gone. Its final frame7 is the same readable
Welcome desktop (raw SHA256`0589d29b72d19308e5eb7eb4d62d0c96348cf6eb949d96c236f5d6a202f5f36c`).
Evidence: `ventium-l2-desktop.DFtvNkAx/closure-audit.json`. Independent human
confirmation is requested; status remains `CLOSED_UNQUALIFIED`.

**Not final acceptance:** cold Quake continues to full timedemo completion;
the generic differential gate still fails, and no FPGA score or successful
new deployment is claimed. No control run replaces UV+fast acceptance.
