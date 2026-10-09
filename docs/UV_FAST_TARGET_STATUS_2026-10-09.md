# UV-fast performance target status — October 9

Acceptance remains **open**. U/V, relocated fast pipeline and fast load/store
paths stay enabled. No U-only/STEP/global-slow fallback, guest modification or
snapshot is used for the current cold full-PC runs.

| Requirement | Verified result | Remaining |
| --- | --- | --- |
| CoreMark ≥2.1 CM/MHz | REP full direct-memory seeds: **2.107861982 / 2.110913372**, correct CRCs | Later permission-shadow candidate pending; not a DDR/cache/FPGA score |
| Quake ≥0.48 total U+V IPC | **0.44513116**, permission shadow `1f2583cb`, 1,200,000,000–1,300,000,000 clocks | Below target; later target-read/read-priming/scalar candidates not measured |
| Standard suite | REP full CoreMark seeds pass; code-word Win95 closed at a visually clean desktop | Independent desktop acceptance and complete timedemo; newer candidates pending |
| FPGA | Old image still deployed | Selected source, full timing/resource qualification and deployment |

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

Eleven cold full-PC guests remain active: code-word Quake, combined-candidate,
independent-REP, instruction-permission-shadow, checked-target-read and
pair-safe read-retirement-prime
Quake/Win95 pairs.
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

The latest **permission-shadow** gameplay audit is
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
  It is not gameplay-measured or accepted; the original no-permission-shadow
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
a preparation-stage port collision is retained as failed evidence. External
IRQ/debug-event, full standard-suite and FPGA qualification remain required.
The exact three-file full-PC integration compiles as `842f0c7d` in
`external/tmp/ventium-fp-mem64-soc.nqs8uA9x`, with unchanged platform settings
and third-party warning debt. It has not launched guests or produced a
performance measurement.

Twenty-two additional explicitly selected closed-build PCHs were losslessly
archived, recovering **1,578,122,581 bytes**. Their decompressed hashes and all
other selected build files were checked. Executables, guest inputs and traces
are unchanged. Recovery: `gzip -dk -- EXACT_FILE.gch.gz`; manifest and receipt:
`external/tmp/ventium-mem64-pch-archive.MSxyFXMj/{manifest,closed}.json`.
