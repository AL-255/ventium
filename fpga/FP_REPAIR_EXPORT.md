# General repair transfer to the FPGA candidate

October 13, 2026. **Unqualified candidate; not deployed.** This transfers the
tested general processor repairs onto the performance/timing candidate without
changing U/V issue, system/relocated fast paths, full P5 L1 geometry, single-fill
ao486 policy, posted-16 transport, or the 40/100 MHz clock constraints.

## What changed

The full-PC parent already contains the [LMSW](../verif/sys/lmsw/README.md),
[obsolete-x87](../verif/sys/obsolete_fp/README.md), and
[segment-extent](../verif/segment_extent/README.md) repairs. Four further files
are composed byte-for-byte from the tested core:

- `core.sv`: real/V86 environment-mode connection.
- `ven_fp_top.sv`: saved FP-pointer restoration, real/V86 save layout, and
  instruction-owned FRNDINT C1/exception commits.
- `ven_fp_misc.sv` and `fpu_x87_pkg.sv`: full-precision, unsigned-magnitude
  FRNDINT rounding with precise special-value and exception behavior.

See the [restore](../verif/sys/fp_env_restore/README.md),
[store](../verif/sys/fp_env_store/README.md), and
[FRNDINT](../verif/sys/frndint/README.md) test reports for exact scope and open
corners. These are ISA repairs, not Doom/Quake workarounds. No extra global
serialization, slow-mode fallback or guest-code patch is introduced.

The last synthesized endpoint-map image predates all these repairs. Its FPGA
derivative therefore changes **eight** payloads, including the five LMSW core
files. All **170 shared native HDL inputs** match the full-PC export; the
complete freeze retains **190 payloads**, 117 filelist units, 49 include edges,
158 hardware defines and 156 simulator defines. The four-file PC transfer
matches all **102 common RTL files** against the tested directed core.

## Closed verification

- Private-host/header full-PC build: native exit 0, **24.28 s**, all inputs
  unchanged. The existing **98 platform structural warnings remain**; this is
  not a whole-SoC lint pass.
- Hardware-profile CPU-hierarchy lint: native exit 0, **3.88 s**; all six hard
  structural classes enabled. No waiver or feature switch was added.
- Five transfer/freezer tests and three synthesis-controller tests pass,
  including drift/reapplication rejection, exact delta sets, preserved guard
  lifecycle and mutation checks against enlarged limits/timeouts.
- Both **10-iteration CoreMark smoke seeds** pass reference CRCs. The
  independent audit rechecks **17,019 inputs**, exact native CPU11 affinity,
  source/model/media identity, terminal owner and child reaping, with no OOM.

| Seed | Parent ticks | Candidate ticks | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

**Measured CoreMark throughput change: 0%.** These short runs are not valid
performance scores or full standard-suite qualification. The shared core's
[private-reference functional corpus](../verif/l1/CYCLE_BACKEND_PROFILE.md)
passes 108/108 programs (80,800 records, 30,134 V retirements), including the
board's single-fill policy. Existing stack masks remain; only 105 programs
pass completely unmasked. Canonical-oracle promotion, failing cycle bands and
remaining system/fault discrepancies are not waived.

## Synthesis and remaining acceptance

The guarded synthesis closed successfully under
`ventium-fp-repair-synth-oct13.service`, invocation
`c6d4e5049a16454496b2f0ecd0902a24`, native exit 0 / MainPID 0, in **1,924.43 s**.
Its independent audit rechecks **18,479 source pins**, 148 native Verilog
inputs, all 158 definitions, the eight intended source changes and the actual
checkpoint. The matched Default logic-only mapper, fixed 40 MHz constraint,
exclusive Vivado family, 8/6 GiB RAM/swap caps and disk guards are unchanged.
Measured peak RAM was **8,374,681,600 bytes**, peak swap **2,006,802,432 bytes**;
no OOM or resource stop occurred.

| Resource | Endpoint parent | Repaired candidate | Change |
| --- | ---: | ---: | ---: |
| CLB LUTs | 187,333 | 186,770 | -563 (-0.30%) |
| Registers | 54,966 | 55,011 | +45 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

Native synthesis reports zero errors, one critical warning and 1,564 warnings.
The critical warning is the same generated PS8 `clk_pl_0` constraint lookup
warning as the parent; it is not silently waived. The subsequent native timing
audit confirms actual `clk_pl_0=10 ns` and `mmcm_clk=25 ns` clocks. No unresolved
DMA generated-control warning is present.

The read-only matched timing audit closed under
`ventium-fp-repair-clock-oct13.service`, invocation
`e72b965246744935a0bac9cfb5d7a7ac`, native exit 0 / MainPID 0, in **469.83 s**.
The independent closure audit rechecks **17,424 input pins**, the same parent
checkpoint, native clock definitions, report contents and terminal ownership.
Peak RAM was **4,777,619,456 bytes**, with no swap or OOM. Structural checks
find zero black boxes, multiple-driver errors or combinational-loop errors;
these checks do not replace functional verification.

| Timing metric | Endpoint parent | Repaired candidate |
| --- | ---: | ---: |
| Unplaced core frequency estimate | 35.056967572 MHz | **35.856430851 MHz** |
| Setup slack at 40 MHz | -3.525 ns | -2.889 ns |
| Worst setup path logic levels | 97 | 93 |

The estimated frequency improves **2.28%**, but **does not meet 40 MHz**.
This is the combined eight-file comparison, not an isolated measurement of
any one repair. Candidate unplaced hold slack is -0.101 ns. Neither these
unplaced estimates nor a 40 MHz constraint establishes routed timing or
physical operation; no implementation or new board programming occurred.

The worst path starts at `q_pc[0]` and reaches the integer multiplier's DSP
operand input. It traverses fetch/prefix/decode, demanded byte count, segment
extent/fault checks, fragment controls, code-versus-data classification,
paired-store admission, backing AXI ACK and register-file forwarding. Data
delay is **27.389 ns**, comprising **5.661 ns logic** and **21.728 ns estimated
interconnect**. The latter is an unplaced estimate, not measured congestion.
This identifies a cross-module control dependency, not evidence that the
multiplier arithmetic itself is the bottleneck.

The next structural cut must preserve precise faults, request/response
ownership and same-cycle read/store-pair acceptance. The existing early code
payload hint is explicitly not an admission/ACK signal; substituting it there
without proving equivalence would be unsafe. No false-path exception, global
pipeline bubble or U-only fallback was introduced to hide this path. Existing
cold Quake and Win95 jobs continue against their unchanged frozen model.

`prepare_fp_repair_synthesis.py` generates, but does not launch, the matched
synthesis and read-only timing controllers. Their independent audits must
close after the same native invocations; failed or resource-stopped runs may
not be replaced by a successful launcher receipt. Implementation and board
programming are not performed by these controllers.

Still required: >=40 MHz synthesized Fmax, implementation/timing checks,
duration-valid >=2.1 CoreMark/MHz, complete CoreMark correctness seeds, Win95
cold desktop plus UI interaction, full Quake timedemo, and physical FPGA
Win95/Quake validation in UV-fast mode. The installed `fe9f539d` image is
unchanged; its [Doom startup failure](../docs/FPGA_DOOM_2026-10-13.md) remains.

## Cold Quake verification in progress

The exact repaired model cold-started FreeDOS Quake demo1 at **19:43:34 UTC**
under `ventium-fp-repair-quake-oct13.service`, invocation
`56b52d8499764820923836107f97ffd2`. Native PID 859279 was observed with the
expected executable hash, CPU11 affinity and owner cgroup; merely starting
the launcher is not the admission evidence. Output is under
`soc-r1/quake-cold-fp-repair-oct13.1` in the evidence root below.

The flow preserves the existing completion checker: **969 frames**, native
exit/wait, complete log EOF, no sticky capture failure, closed process group
and rechecked private disk are required. It uses original cold media, 40 MHz
core/RTC, 80 MHz VGA, 16 MiB RAM and DDR3 transport, without saved-state restore
or guest modifications. A cycle or wall-time limit is not a pass.

`prepare_fp_repair_cold.py` freezes the tested helper sources and rechecks the
full compiled-input ledger. Its only host-flow changes are a 160-task startup
budget (the simulator's initial thread pool exceeds 32) and a live **4 GiB
free-disk stop floor**. Actual execution remains confined to one CPU with
2 GiB RAM and no swap. Admission requires 6 GiB free disk; evidence is bounded.
The imported Win95 resource helper deliberately refuses Win95 launch; the
separate reviewed launcher below does not change that helper.

Two preparation tests and **39 runner tests pass**, including low-disk failure
remaining a failure even if a simulated completion marker appears. The board
fixture explicitly checks DDR3, clock rates and memory size; completion,
error-detection and log-integrity checks are unchanged. Tests do not constitute
guest acceptance. The later measured gameplay window below is not a completed
timedemo result.

## Cold Win95 verification: closed, unqualified

`prepare_fp_repair_win95.py` prepares the same previously reviewed cold Win95
flow against this model, preserving its original native command, pristine
standard-VGA fixture, 40/40/80 MHz clocks, 16 MiB RAM and DDR3 transport.
It rechecks the compiled source ledger before launch. Four host tests pass,
including unchanged native command/environment, exact resource constraints,
and a low-disk stop that cannot become desktop acceptance.

Native PID **864153** started at **19:52:25 UTC**, with observed CPU10 affinity
and the expected model hash. Owner `ventium-fp-repair-win95-oct13.service`,
invocation `0cb50f29741b40fc91f3d6618f37be82`, confines it to one CPU,
2 GiB RAM, no swap and 160 startup tasks. Output is under
`soc-r1/win95-cold-fp-repair-oct13.1`. The 8 GiB admission reserve and live
4 GiB disk stop floor remain enforced. There is no snapshot, injected guest
patch, STEP or slow-mode control.

This wrapper **never awards desktop PASS**, even on normal native exit.
The closure and remaining acceptance blockers are recorded below. The closed
Win95 checker now has a separately tested schema-5
`board-posted16-40mhz-parentpolicy160` profile for this launcher. Its original
32/128-task profiles, native command, clocks, memory, log limits, source checks,
closed-process requirement and externally pinned human desktop review remain
unchanged. **46 host checker tests pass**, including the existing negative
matrices exercised on the new profile. These are synthetic host fixtures, not
desktop evidence. A retained active/exited service is not accepted; after
native closure its supervisor must also be closed to inactive/dead.

`freeze_fp_repair_win95_expectation.py` independently verifies the live model,
owner invocation, actual CPU affinity, resource caps, compiled source ledger,
UV-fast definitions and `cycle_mode=1`. It freezes `win95-expectation.json`,
SHA-256 `bc52dd9351740e46d4c34d5aaf5e92c08826880d7ea7dbd02d6b673de811c640`,
without opening live guest media/frames or generating a visual verdict. The
launcher was invoked through the external-directory symlink; schema 5 records
that exact argv spelling separately and checks it resolves to the canonical
pinned launcher before and after grading. Wrong, missing or retargeted aliases
are rejected. Initial admission-audit attempts caught a Path/string adapter
error and this command-spelling mismatch before writing any acceptance record;
the guest was neither restarted nor modified.

## First measured gameplay window, run still active

The unchanged cold Quake run now reaches visible gameplay. Its completed
`frame_00003.ppm` and `frame_00004.ppm` captures show different positions in
The Necropolis, not the loading console. The native `[FBCAP]` messages directly
precede the **800,065,237** and **900,065,237** cycle performance samples.
The live executable was rehashed as model `c7b95b78...6384afd`; native PID
859279, CPU11 and owner invocation `56b52d8499764820923836107f97ffd2` match
admission. No guest restart, patch, snapshot restore or FPGA write occurred.

| Counter | Start | End | Difference |
| --- | ---: | ---: | ---: |
| Core clocks | 800,064,874 | 900,064,874 | 100,000,000 |
| U retirements | 189,745,433 | 228,096,362 | 38,350,929 |
| V retirements | 42,593,840 | 54,732,851 | 12,139,011 |
| Total retirements | 232,339,273 | 282,829,213 | 50,489,940 |

Both endpoints satisfy total = U + V. Thus this **verified counter window**
measures **0.5048994 total U+V gameplay IPC**. It exceeds 0.48 in this window,
but is **simulation on this FP-repair model**, not physical FPGA performance
or a pass for subsequent data-size/current-tag/next-line-tag candidates.
The cold timedemo is still running: no 969-frame completion, final FPS or
error-free standard-suite acceptance has been established. Different gameplay
windows/builds are not a controlled gain comparison.

Evidence is `soc-r1/quake-cold-fp-repair-oct13.1/run/run.log` under the root
below. The complete as-is frames have SHA-256:

- `frame_00003.ppm`: `858f2b66964f7c92e75d02894b6b36ee76b6ccf95b5afbfbe47fbe24db209289`.
- `frame_00004.ppm`: `90247eb0fa791b2bd8f8a807d097f52ac959784cdc9f9894c04337f50e7dfd95`.

PNG copies `frame_00003-as-is.png` / `frame_00004-as-is.png` are format-only
conversions, without color adjustment or resampling. The complete Win95
`frame_00003.ppm` now shows icons and the taskbar without a visible error,
but retains an hourglass. At that checkpoint its run was still active; this
did not meet the separate closed-desktop/UI/human-review requirements.

## Reproducible identities

Evidence root: `/home/yukidama/external/tmp/ventium-fp-repair-transfer.a8nzrjHu`.

| Artifact | SHA-256 |
| --- | --- |
| `soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted` | `c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd` |
| `fpga-r1/input-manifest.json` | `bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93` |
| `soc-r1/coremark/audit.json` | `0d5166bc36cc1f0d58133f8279f623702c33aa502ff7d4d13a4e9644d9be2f69` |
| `synthesis-r1/audit.json` | `ffea1bc1e015606cc3af050580f28e9b09631aaeb885f6fc0da39d81d4034bc3` |
| `synthesis-r1/native-synthesis/rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.dcp` | `d801ced570e78057204df123ad72a899b0dc2ed6ed5e22490efdaa0ce61d1b97` |
| `clock-r1/audit.json` | `c747c58d77a0268ec86a9cf87ffbcdf74db363911e5a31bc1664466b7f52f8c0` |

The CoreMark owner is terminal, invocation
`c65abc7c1e764fef9e364fd0074eada9`, MainPID 0 / native exit 0.
`build_fp_repair_soc.py` and `freeze_fp_repair_rk_candidate.py` reject unknown
parent hashes and compare the exact source closure; they do not overwrite the
unrelated dirty root RTL. The isolated repair recipes remain the source of
each delta.

For build space, **246 inactive metadata files** were gzip-compressed with
full decompressed SHA checks, freeing **1,608,589,312 bytes**; use `gzip -dk`
on the exact archive listed in `metadata-archive-closed.json` before historical
re-audits. **Eleven obsolete PCH-only archives**, 529,537,483 bytes, were pruned
after checking all members and retained matching generated headers. They are
regenerable compiler caches, not byte-recoverable archives. A mixed archive
containing traces was rejected and retained. Current input pins, sources,
models, media, DCPs and all failure evidence are preserved. Failed cleanup
attempts stopped before deletion and remain separate from successful receipts.

To admit the new Win95 run, a later cleanup removed **14 superseded diagnostic
synthesis DCPs**, totaling **2,493,652,543 bytes**. Every synthesis and timing
owner was checked terminal against its original invocation; exact file hashes
and inodes were recorded, no live process held the targets, and all current
input pins were rechecked unchanged. Current candidate, endpoint-map and
prime-reg comparison checkpoints were excluded. Sources, projects, reports,
logs and closure evidence remain. These old generated checkpoints can be
regenerated, but are **not byte-recoverable**. Exact targets and hashes are in
`superseded-dcp-plan.json`; `superseded-dcp-closed.json` records completion under
`ventium-superseded-dcp-prune-oct13.service`, invocation
`9f7268291341471cb3498f7f8e9d0775`, native exit 0 / MainPID 0. An initial dry
plan refused the unlaunched prime-CS clock folder; the successful plan names
its actual closed `prime-cs-clock-swap4-r1` owner. No deletion preceded that
successful plan.

The first measured gameplay IPC for this FP-repair model was **0.5048994 total
U+V**, cycles **800,065,237–900,065,237**. This superseded the older simulation
reporting baseline `2b4d7a48` / 0.51030715 (cycles
1,200,065,237–1,300,065,237), without implying a gain or regression between
different windows. Error-free timedemo completion and physical FPGA acceptance
remain open. This is not a Doom measurement.

### Next complete gameplay window: 900M–1,000M

The same continuously running native model and CPU11 owner were rechecked.
The next complete 100M-clock window measures **0.49236929 total U+V IPC**:

| Counter | Start | End | Difference |
| --- | ---: | ---: | ---: |
| Core clocks | 900,064,874 | 1,000,064,874 | 100,000,000 |
| U retirements | 228,096,362 | 265,862,407 | 37,766,045 |
| V retirements | 54,732,851 | 66,203,735 | 11,470,884 |
| Total retirements | 282,829,213 | 332,066,142 | 49,236,929 |

Reported cycle endpoints are **900,065,237–1,000,065,237**. Both satisfy
total = U + V. Frames 4 and 5 show different gameplay views; frame 5 displays
the grenade-launcher pickup. Its unmodified PPM SHA-256 is
`cb4b790fa1b8243d20caedd8c526eb8f9d00ff0fb62a2961ff8dbc31c8895f6d`.
The stable, complete-line log prefix and read-only audit are retained as
`gameplay-900m-1000m-prefix.log` and `gameplay-900m-1000m-audit.json` in this
evidence root. Audit SHA-256:
`5b408ebd20fd75f25dd12554e37c5cd4772f4d8f21fa7e5e6ab3d15e887401d8`.

This was the next verified reporting baseline, still simulation model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`.
It predates the current next-tag/FP-classifier candidate, which remains
gameplay-unmeasured. Window variation is not a controlled build regression.
The timedemo remains active; no final FPS, physical result or completion pass
is established.

Win95 frame 5 now shows readable Welcome text, icons, taskbar and an ordinary
pointer, without a visible error. Repeated vector-6 records at `FCB2:2FF7`
match the already documented [ROM-ARPL callback aliases](ZERO_C1_EXPORT.md),
not evidence by themselves of a new crash. Its harness has no live UI-input
channel. The native run was subsequently closed as described below; ordinary
UI interaction and separate human acceptance are not inherited from an older
run or inferred from the clean image.

### Gameplay window: 1,000M–1,100M

The unchanged, continuously running `c7b95b78` model now measures
**0.49721089 total U+V IPC**, cycles **1,000,065,237–1,100,065,237**.
The live executable hash, native PID 859279, CPU11 affinity, exact cold-start
command and original owner invocation were rechecked.

| Counter | Start | End | Difference |
| --- | ---: | ---: | ---: |
| Core clocks | 1,000,064,874 | 1,100,064,874 | 100,000,000 |
| U retirements | 265,862,407 | 304,559,167 | 38,696,760 |
| V retirements | 66,203,735 | 77,228,064 | 11,024,329 |
| Total retirements | 332,066,142 | 381,787,231 | 49,721,089 |

Both endpoint totals equal U + V. Frames 5 and 6 show distinct gameplay views,
with combat/death visible in frame 6; this is not a startup window. Frame 6
raw SHA-256 is
`594c3a999137d2361203eaf8af689bbb3db4939decee617d29adb24666761e10`.
The format-only PNG preview has no color or size adjustment.

`audit_gameplay_1100m.py` retains a stable complete-line log prefix and
`gameplay-1000m-1100m-audit.json`, SHA-256
`917796b44ab611478a23584ccfdf7b697fa477b84e15bca122cc1402b4a90540`,
under the evidence root above. This is a verified historical gameplay window,
still an older simulation model: current data-size/current-tag/next-tag/
FP-classifier candidates remain gameplay-unmeasured. The timedemo is still
running; no completion, final FPS, physical FPGA or standard-suite PASS is
claimed.

### Gameplay window: 1,100M–1,200M

The same continuously running `c7b95b78` simulation model measures
**0.48176594 total U+V IPC**, reported cycles
**1,100,065,237–1,200,065,237**. The native executable SHA, PID859279,
CPU11 affinity, exact cold argv and original supervisor invocation were
rechecked. This is a later scene window, not a controlled build comparison.

| Counter | Start | End | Difference |
| --- | ---: | ---: | ---: |
| Core clocks | 1,100,064,874 | 1,200,064,874 | 100,000,000 |
| U retirements | 304,559,167 | 342,191,900 | 37,632,733 |
| V retirements | 77,228,064 | 87,771,925 | 10,543,861 |
| Total retirements | 381,787,231 | 429,963,825 | 48,176,594 |

Both endpoint totals equal U + V. Frame 6 shows combat/death and frame 7
shows hallway gameplay with weapon/HUD, not loading. Frame 7 original PPM
SHA-256 is `7a6f977ecf74f8c3277c8c3f3846e5368a3813131fdf1cc6712aad6461d847df`;
its PNG preview is format-only, with no color or size adjustment.

`audit_gameplay_1200m.py` retains the 423,315-byte stable complete-line prefix
`gameplay-1100m-1200m-prefix.log`, SHA-256
`adc07ff8e678d021761ec1f66776411426f222779920b3047089670b8c76fc64`.
The audit `gameplay-1100m-1200m-audit.json` has SHA-256
`39946af7cfec14cc216957244f7c988632dfc6234df7156cedc98d7f45882875`.
This superseded the reporting baseline, **not** earlier retained measurements.
The newer timing/tag-bank candidates remain gameplay-unmeasured. The timedemo
is still running; no final FPS, physical FPGA/Doom result or suite pass follows
from this window.

### Latest gameplay window: 1,200M–1,300M

The same continuously running `c7b95b78` simulation now verifies at
**0.51027341 total U+V IPC**, reported cycles
**1,200,065,237–1,300,065,237**. The audit rechecks the actual executable hash,
PID859279, CPU11 affinity, exact cold argv and original supervisor invocation.

| Counter | Start | End | Difference |
| --- | ---: | ---: | ---: |
| Core clocks | 1,200,064,874 | 1,300,064,874 | 100,000,000 |
| U retirements | 342,191,900 | 381,420,663 | 39,228,763 |
| V retirements | 87,771,925 | 99,570,503 | 11,798,578 |
| Total retirements | 429,963,825 | 480,991,166 | 51,027,341 |

Both totals equal U + V. Frame 7 shows hallway gameplay; frame 8 shows a weapon
firing at an enemy, particles and HUD. Its unmodified PPM SHA-256 is
`f7518c17ae7354adda652356a494b934052217f5e5b69eb8aeae8522e2a3e34a`.
The PNG preview is format-only, without color or size changes.

`audit_gameplay_1300m.py` retains the stable 456,605-byte complete-line prefix
`gameplay-1200m-1300m-prefix.log`, SHA-256
`10d2460c104ed5b2af7c0699ffdce7d7db0267814eb7d6494a42acdc2cf9f5c6`.
`gameplay-1200m-1300m-audit.json` SHA-256 is
`e472ed5c3c3513721f1d472c326d923d0e187458d822c46d12e3583a8ac84bd2`.
This is the latest reporting baseline, not a controlled gain over the previous
scene. The [combined way-banked/fetch-page candidate](../verif/l1/WAY_BANKED_CORE.md)
is newer and gameplay-unmeasured. The timedemo remains active: no final FPS,
timedemo completion, physical Doom result or suite acceptance is established.

### Win95 native closure and evidence-protocol failure

The old model's cold Win95 run closed gracefully at **2026-10-14 00:49:35 UTC**,
cycle **1,090,616,618**, with **232,322,147 retirements**. Native exit is 0,
the child was waited/reaped, the process group is absent and no OOM occurred.
The retained owner has MainPID 0 / `active (exited)`, not `inactive (dead)`.
Six raw captures and the complete 8,544,997-byte EOF-closed log remain.
Frame 5 shows readable Welcome text, desktop icons and taskbar with an ordinary
pointer; it is not evidence of keyboard/mouse interaction.

**This run is `CLOSED_UNQUALIFIED`, not desktop or suite acceptance.** The
manual stop operation incorrectly wrote a 211-byte explanation into
`stop.request`; the strict checker requires an empty, owned regular marker.
The marker remains unchanged, SHA-256
`30695692eac715a1648adb7bf1f3af2203648626f93dc782f92cfa1c9bdf3af6`.
It must not be truncated afterwards or accepted by relaxing the checker.
For future stops, use the launcher's existing `request_stop` protocol, which
creates the empty file exclusively; put any explanatory note in a separate
receipt. No RTL or acceptance criterion was changed to hide this mistake.

The independent native-closure-only audit checks all 24 wrapper pins, native
closure, all six raw-frame hashes and the closed private disk. The canonical
log parser accepts all 2,157 complete progress records and matching footer;
the empty-marker invariant explicitly rejects the retained marker. The full
acceptance checker was **not** invoked with fabricated human-review data.
`win95-native-closure-audit.json` SHA-256:
`0308372f5a0a34a97dfb561a7d4565defac523433c38cae3c090797dc9941ad9`.
Native result SHA-256:
`b5fa7bfe29f469f76b3ba08f84b8e23017ca0ab071ed3b0cf684be32292b9701`.

Ordinary live UI input, a separately reviewed closed desktop, supervisor
closure and the stop-protocol failure remain acceptance blockers. Do not
launch another long Win95 run without a qualified input path. Existing
`verif/ps2_ui` host input and controller proposals are isolated tests, not
integrated or qualified full-PC/FPGA UI support.
