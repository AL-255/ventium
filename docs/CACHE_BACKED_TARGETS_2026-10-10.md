# Cache-backed performance targets — October 10

Acceptance remains **open**: at least **2.1 CM/MHz**, at least **0.48 Quake
U+V retirement-event gameplay IPC**, the error-free standard suite, green
differential gates, and a working FPGA deployment. U-only/STEP/global slow
fallbacks are not acceptance. REP retirement events are not P54 macroinstructions.

**Latest verified measurement, 14:55 UTC:** `bfb867f7` reaches **0.54372556 IPC**
over clocks **2,600,065,237–2,700,065,237**: 40,833,583 U + 13,538,973 V
retirement events. All fifteen consecutive windows from
1,200,065,237 average **0.4899940033**, retaining the **0.34569625** dip at
2,100,065,237–2,200,065,237 as well as the earlier two sub-0.48 intervals.
The margin above 0.48 is now small; this is not a completed-demo average.
This is the same cache-backed model with
qualified **2.101890118 / 2.107616105 CM/MHz** below, not a score borrowed from
another build. Latest raw-pixel/counter/ownership audit:
`ventium-store-admit-gameplay-r10.HAHogVZt/audit.json`. The two added windows
are 0.47674197 and 0.54372556; all 734,991,005 events over 1.5B clocks count.
Both unchanged-pixel endpoint images show rendered first-person stone rooms
with a nailgun, changed viewpoint/ammunition and a target down the corridor in
the second image. HUD health remains zero as in
earlier captures; no living-player or render-correctness claim is inferred.
Full timedemo and physical FPGA remain open.
New area candidate `751139e1` remains gameplay-unmeasured; its own standard
suite is running. Its **own two 900-iteration CoreMark seeds now pass** at
2.101890118 / 2.107616105 CM/MHz, independently audited at 12:49 UTC; the exact
428,186,037 / 427,022,738 ticks match the performance parent, with all original
CRCs, native 0/EOF/reaping, actual V retirement, 3,361 stable pins per seed and
no OOM. Evidence: `ventium-ic-prefix-capture-soc.Vkt5yyAz/coremark-900-{performance,validation}/audit.json`.
This does not qualify its still-running Quake/Win95 or physical FPGA.
The newer registered-invalidation candidate `322bc855` also remains
gameplay-unmeasured. Its own two short CoreMark diagnostics now pass with
identical parent cycles/CRCs; these ten-iteration runs are duration-invalid,
not qualified scores. See [the synthesis/diagnostic record](FPGA_FETCH_CONGESTION_2026-10-10.md).
Its own 900-iteration seeds now **both pass**, independently audited at 14:40
UTC: **2.101890118 / 2.107616105 CM/MHz**, exactly 428,186,037 / 427,022,738
ticks and unchanged CRCs, native 0/EOF/reaping, 3,567 stable pins each and no
OOM. Evidence: `ventium-cacheinv-soc.sxytw4Fn/coremark-900-{performance,validation}/audit.json`.
The performance run takes 3,599.31 host seconds, just inside the unchanged
3,600-second cap; no time-limit relaxation or continuation was used.
Synthesis closes at 195,242 LUTs, but the next unplaced timing path still
estimates only 18.236 MHz; no new FPGA deployment has occurred. A separate
state-selected FP payload candidate (`35c8cc6c` directed core) passes 384 cold
x87/system microcases with identical complete cycle streams. That timing
proposal has no gameplay or qualified CoreMark score. Its FPGA export now
synthesizes at 196,673 LUTs; its independently audited unplaced timing estimate
is **18.961 MHz**, still far short of 40 MHz sign-off. The critical path now
crosses the early-load FP payload selector rather than the direct-command
payload selector. [The exact candidate record](../fpga/FP_PAYLOAD_EXPORT.md)
retains the area increase and unresolved timing, not just the small improvement.
Older timestamped results below remain historical evidence.

The new dip is associated with **more slow-FSM work, not a larger total memory
wait count**. Compared with the preceding 100M-clock window, S_FETCH/S_DECODE/
S_EXEC residency rises from 8.020M to 32.642M clocks, while S_PIPE falls from
69.394M to 46.352M. Total request-active memory-wait clocks fall from 25.650M
to 23.961M; V's retirement share drops from 23.86% to 19.23%. These are direct
counter differences, not a cache-miss attribution or a same-work speedup.
Counters overlap; the figures must not be summed into one CPI breakdown.
The available sample does not identify the responsible opcode distribution.

## Current combined candidate

Model `bfb867f7844b467eeafba12fe6d5035e89d0d2cf03111911cbdd599d7fb204e6`,
`/home/yukidama/external/tmp/ventium-store-admit-soc.kW7Vv7Mr`.
Full 8 KiB P5 L1s, 256 KiB platform L2, posted-16 DDR transport model,
40/40/80 MHz CPU/RTC/video timebases, UV and system/relocated fast pipeline,
fast loads/stores. No guest patch, checkpoint or pairing suppression.

The previous directed-core candidate already contained the leaf-tested
`VEN_P54_WBUF_ADMIT_DISPATCH` master, but the full-PC derivative did not.
This backport changes exactly `rtl/mem/ven_axi_master.sv` and adds that flag.
The master is byte-identical to `ventium-wbuf-admit.D1XyDU1j/r2/master.sv`,
SHA `ed11478bcf7898e410b5d9bd4f1952d8d3291037f38987c3c01eb935b9b13e38`.
Its closed 39-profile/123-run leaf matrix retains 120 positive runs and three
specific required negatives: ordering, two-slot admission, split/masked/fused
stores, slot reuse, independent AW/W progress and response errors/IDs.

Every intersecting processor RTL file matches the already tested directed
core `ventium-store-warm-core.QQBHmz8z/candidate/rtl`. Its full define set is
contained in the SoC's; the four SoC additions are XPM RAM fidelity,
read-through Avalon transport, posted DDR and the platform integration flag.
The SoC build closes native 0 with matching private harness/generated-header
ownership and all source pins stable. The 98 inherited platform structural
warnings remain, not a clean whole-platform lint result.

## Matched ten-iteration diagnostics

Same GCC 13.4 compiler/port, original disks/ROMs, seeds and geometry throughout.
**These are duration-invalid diagnostic ratios, not qualified scores.** Both
seeds match all five unchanged QEMU CRC references; minimum-duration errors
are preserved. Current native runs close 0, are reaped, have verified CPU 3
affinity and no OOM. Independent `coremark/audit.json` checks 295 pins and
retained supervisor invocation `41aa2611dd15404f84ab2070bff5c692`.

| Change in succession | Performance ticks | Validation ticks | Matched throughput gain, performance / validation |
| --- | ---: | ---: | ---: |
| Demand-fetch parent `958f7ec4` | 5,096,514 | 5,085,420 | baseline |
| Protected-client PREFIX66 | 5,013,253 | 5,001,043 | 1.66082% / 1.68719% |
| Exact-byte RET capture | 5,012,733 | 5,000,796 | 0.01037% / 0.00494% |
| Branch-fallthrough resident read hint | 4,954,588 | 4,939,299 | 1.17356% / 1.24506% |
| Independent saved-window invalidation | 4,927,211 | 4,912,277 | 0.55563% / 0.55009% |
| Register-prefix/EX overlap | 4,919,533 | 4,905,555 | 0.15607% / 0.13703% |
| Qualify the overlap's INTR veto with IF | 4,862,426 | 4,847,492 | 1.17445% / 1.19779% |
| Coherent writes to existing saved windows | 4,853,587 | 4,837,758 | 0.18211% / 0.20121% |
| Shared byte memory-CMP decode | 4,801,536 | 4,787,479 | 1.08405% / 1.05022% |
| Warm an existing window on a committed resident store | 4,782,160 | 4,768,125 | 0.40517% / 0.40590% |
| Bring the SoC AXI admission handoff up to the tested core | **4,767,218** | **4,753,406** | **0.31343% / 0.30965%** |

Current ratios: **2.097659474 / 2.103754655 CM/MHz**. Performance seed is
still below 2.1. Gains are successive matched ratios, not additive shares of
all wasted cycles. The direct-memory scores from another compiler/environment
are not substituted for these cache-backed results. NP-prefix/EX P54 resource
qualification remains open; directed ISA correctness does not waive it.

The store-warming parent's exact 1M-clock trace is
`ventium-store-warm-state.bxHr2c3F`: native 0, original CRCs and exact
4,782,160 benchmark ticks reproduced. All state buckets reconcile to counters.
It found repeated one-clock stalls among cache-hit PUSHes, motivating the
missing admission backport. The compressed 21.94 MB trace is a core/bus
observation, **not** a complete retained-model differential dump.

## Duration-valid CoreMark: both seeds exceed 2.1

Both cold 900-iteration runs on **`bfb867f7`** closed successfully and passed
the separate `audit_soc_seed.py` checker. This is the cache/DDR-backed UV-fast
SoC simulation, **not** the older direct-memory score or a silicon measurement.

| Seed | Raw TSC ticks | Actual guest seconds | CM/MHz | Five reference CRCs |
| --- | ---: | ---: | ---: | --- |
| Performance | 428,186,037 | 10.704650925 | **2.101890118** | e9f5 e714 1fd7 8e3a 4983 |
| Validation | 427,022,738 | 10.675568450 | **2.107616105** | 18f2 e3c1 0747 8d84 9808 |

Score uses `900 * 1,000,000 / raw_TSC_ticks`, not the console's integer-rounded
seconds or iterations/second. Both complete consoles say `Correct operation
validated`, all five CRCs match the respective unchanged 900-iteration QEMU
references, and each has native exit 0, EOF, reaped child, actual V retirements,
294 stable source/input pins and zero OOM events. The retained supervisors also
closed successfully with the invocation IDs below. Performance took 3,269.55
host seconds, within its 60-minute cap. No algorithms, compiler flags, guest
timers, pair mode or media changed between launch and closure.

Evidence: `coremark-900-performance/{closed,audit}.json` and
`coremark-900-validation/{closed,audit}.json` under the candidate root. The
auditor's 16 synthetic positive/negative controls and the six existing console
checker tests pass; these tests are not benchmark runs. They reject wrong CRCs,
cross-screen assembled results, missing V retirement, faults after completion,
missing EOF/reaping, timeout/OOM, pin drift and incorrect supervisor identity.

The CoreMark component and **simulated** 2.1 target are now met. This does not
close the generic differential gate, Win95, Quake or physical FPGA acceptance.

## Standard-suite runs and resource bounds

Two 900-iteration CoreMark seeds use the same unmodified algorithms/compiler
and port. `verif/bench/coremark_boot/run_soc_seed.py` requires >=10 guest
seconds, validated output, all five same-iteration QEMU CRCs, consistent raw
TSC endpoints, actual V retirement, native 0/EOF/reaping and stable pins.
The host stop request is created only after the complete validated console.
Each native is bounded to 60 minutes, 450M guest clocks, one actual CPU,
2 GiB RAM/no swap, 16 MB log and a 2 GiB external-disk reserve.

| Retained service | Actual CPU | Invocation |
| --- | ---: | --- |
| `ventium-store-admit-cm900-perf-oct10` | 15 | `239888e9ac4c47798ec0d46d92b34b43` |
| `ventium-store-admit-cm900-valid-oct10` | 16 | `87ac267ed6be484c8f6acd7fac720f73` |
| `ventium-store-admit-quake-oct10` | 7 | `269309d3eff44055992bfa8f557fd575` |
| `ventium-store-admit-win95-oct10` | 8 | `6e6de576ced749eab1e029e1dd8ba99d` |

Quake cold-boots the original DOS demo1 disk; **969 frames and native closure**
are required. Win95 cold-boots the standard-VGA fixture installed through
Windows' own installer; the bounded collector cannot grant desktop acceptance.
Closed visual review remains necessary. No snapshot or input script is used.
At 09:37 UTC both CoreMark jobs are successfully closed as audited above.
Quake and Win95 remain active; neither has a completed standard-suite result.
Quake's first declared gameplay window is now verified below.

## Gameplay baseline and blockers

**Historical two-window observation on `bfb867f7`: 0.50705320** U+V retirement-event IPC at
clocks **1,300,065,237–1,400,065,237**. This is 50,705,320 events = 39,071,953 U
+ 11,633,367 V over 100,000,000 clocks. Both consecutive windows from
1,200,065,237 average **0.508680175** (101,736,035 events / 200M clocks),
retaining the earlier 0.51030715 window. This exact model therefore has both
duration-valid CoreMark seeds above 2.1 and a declared gameplay window above
0.48. It is **not** a full-timedemo average or physical FPGA result.

Evidence: `ventium-store-admit-gameplay.MQccS4fZ/audit.json` and the latest
`ventium-store-admit-gameplay-latest.aZbN2LGc/audit.json`. The original
prelaunch receipt selects periodic samples 12/13; all samples and the actual
65,237-clock startup offset are retained. Root independently viewed both
pixel-identical endpoint conversions: a live stone corridor, then weapon fire
and an explosion with changed ammunition. Captures are associated through their
unique adjacent 500,000-clock progress brackets, not selected by appearance.
Frozen build/runtime pins, actual compiler defines, native process/starttime,
supervisor invocation, CPU affinity, cold media, active V retirement and zero
OOM are rechecked. The receipt's inherited `candidate_delta` description is
stale; it is preserved and explicitly rejected as source authority. Actual
frozen sources contain the performance backports above.

Historical parent `958f7ec4`: **0.50530999** at clocks
**3,900,048,811–4,000,048,811**, 50,530,999 events = 38,868,367 U + 11,662,632 V.
All twenty-eight consecutive 100M windows from 1,200,048,811 total
1,361,562,099 events / 2.8B clocks = **0.4862721782**, retaining every dip.
Audit `ventium-sfetch16-latest-r13.B1BPkjih/audit.json` checks counters,
source/native/supervisor identity, unchanged raw endpoint pixels and no OOM.
Latest window and aggregate exceed 0.48; timedemo is unfinished.
This longer parent aggregate is not transferred to `bfb867f7` or its descendants.

The area-sharing derivative **`89b68b62`** has no gameplay measurement either.
Its source, zero-cost short CoreMark A/B result and 66.0% local lookup-cone LUT
reduction are recorded in [the fetch audit](FPGA_FETCH_CONGESTION_2026-10-10.md).
Separate cold standard-suite runs started on this exact derivative; they do
not inherit the performance parent's qualified scores or future boot result:

| Service | Actual CPU | Invocation |
| --- | ---: | --- |
| `ventium-ic-buffered-cm900-perf-oct10` | 15 | `b3464a40253d42ba85a770bd031006dd` |
| `ventium-ic-buffered-cm900-valid-oct10` | 16 | `0931102127864047a66d93e5eae3b7c3` |
| `ventium-ic-buffered-quake-oct10` | 2 | `5cf2e4c42fd645baae8f90773cfeb6f4` |
| `ventium-ic-buffered-win95-oct10` | 4 | `2f70aa78e83a4366b6b595259d641b78` |

All four are active at 10:09 UTC. Actual native admission verifies the model,
argv, PID/starttime, supervisor/cgroup and affinity. Original media/ROMs and
completion criteria are unchanged; no guest patch, input script or snapshot.
CoreMark retains its 60-minute seed cap; Win95/Quake their bounded cold-run
collectors. Evidence is under `ventium-ic-buffered-soc.gsztNdDc` on external
scratch. Existing `bfb867f7` cold runs continue, not restarted or replaced.

At 11:04 UTC, **both `89b68b62` 900-iteration seeds are closed and independently
audited**: 428,186,037 / 427,022,738 raw ticks, **2.101890118 / 2.107616105
CM/MHz**, identical to the immediate performance parent. All five original
CRCs match; native exits 0, EOF/reaping, actual V retirement, 2,946 immutable
pins per seed and no OOM. Host times 3,552.54 / 3,418.36 seconds remain within
the 60-minute cap. Its Quake/Win95 runs continue. These scores belong to this
model as well as `bfb867f7`, not automatically to the newer prefix derivative.

### Current prefix-sharing derivative

The newest model **`343f0ccd`** (`ventium-ic-prefix-soc.ApbJoeMH`) replaces
16 repeated successor-byte tag lookups with two shared line probes. It retains
all performance fixes, UV/system/relocated fast paths, cache/transport geometry,
and original guest media. Its short CoreMark runs preserve both CRC sets and
exact 4,767,218 / 4,753,406 ticks. Both own 900-iteration scores are now qualified
below; it still has **no gameplay IPC** and cannot inherit its parent's window.
Source/export and closed corner-case tests: [IC_PREFIX_EXPORT.md](../fpga/IC_PREFIX_EXPORT.md).

Its own cold standard suite started at 10:45 UTC; actual native executable,
argv, PID/starttime, supervisor/cgroup and CPU affinity are checked:

| Service | Actual CPU | Invocation |
| --- | ---: | --- |
| `ventium-ic-prefix-cm900-perf-oct10` | 3 | `01017c2e95dd4c91b8aa6f1037c1be30` |
| `ventium-ic-prefix-cm900-valid-oct10` | 5 | `0ee3f8ac369b4e5388882f4cba52d9be` |
| `ventium-ic-prefix-quake-oct10` | 14 | `1ee5755ad73c4f3ab7a31ca85c60d4f6` |
| `ventium-ic-prefix-win95-oct10` | 10 | `4e56e8a830f04245869ef58b8c04ffe2` |

All four are active at 10:49 UTC. The same duration/completion checks and
resource bounds apply; no snapshot, guest patch or scripted input. Older
candidate runs remain independent. Exact-source full synthesis closed native 0
at 11:07:22 UTC, with **221,918 LUTs versus 220,699** for its immediate parent.
The +0.5523% whole-design regression does not confirm the isolated local saving.
The 40 MHz core constraint is not a claimed achieved frequency. Read-only
mapped-logic/project-clock inspection is recorded in the fetch audit; no new
route has been launched.

At **11:45 UTC**, both `343f0ccd` 900-iteration seeds are closed and separately
audited: **428,186,037 / 427,022,738 ticks**, **2.101890118 / 2.107616105 CM/MHz**.
Both unchanged five-CRC sets match, actual guest duration exceeds ten seconds,
native exits are 0 with EOF/reaping, V retirement is present, all 3,160 pins per
seed remain stable and OOM counters are zero. Host durations 3,524.71 / 3,399.18
seconds are within the unchanged 60-minute cap. Evidence is its own two
`coremark-900-*/audit.json` files, not the earlier parent's results.
Quake/Win95 continue. The newer two-consumer `751139e1` does not inherit these
scores or boot acceptance.

Unmodified generic verification remains **red**: terminal/bounded-observation
record discrepancies and cycle-band failures. No golden records, field masks
or bands were weakened. The separate older FPGA route timed out before
completion; it produced no new bitstream. The new source has no routed timing
or silicon acceptance. Neither CoreMark smoke nor partial gameplay closes
these correctness, full-suite or hardware obligations.

### Exact candidate functional recheck, 10:59 UTC

The existing, opt-in [QEMU live terminal-state observer](../verif/qemu-trace/PREEXIT_OBSERVER.md)
was requalified on all 24 microcases with the current producer, then used in
a fresh private golden cache against directed-core model **`bdfa17b4`** (the
same processor source as full-PC `343f0ccd`). All 108 original functional jobs
ran with `--cycle-func --l1-axi`, unchanged worker/comparator/masks and AXI
latency zero. **107 pass; `tx_fprem` fails** at terminal record 300,
PC `08048415`: QEMU FSW `0020`, RTL `0320`. This retains the known stale-C1
correctness obligation, not just an unavailable oracle terminal record.
The previously proposed C1/SRT/FST repairs are **not** in this performance
candidate. Their separate directed results must not be inherited by it.

Evidence: `ventium-ic-prefix-functional.LiwgNIsW/{closed,audit}.json`, supervisor
`9ce8a02962e34ee3a23f21bfa7e4bf5e`, native diagnostic exit 1, 220.69 seconds,
stable inputs. Independent audit checks all 108 actual cycle-func trace headers,
full equal record counts, real L1 backing activity and unchanged comparisons.
`mb_jmppair` completes all 5,204 records, with 2,604 U + 2,600 V retirements.
The initial launcher incorrectly searched stdout for the mode; the retained
audit uses its actual trace-header location. One interleaved stdout/stderr
counter line is recognized literally; raw logs and architectural traces remain
unchanged. The whole subgate is still **FAIL**, not an accepted partial pass.

The separate canonical latency-seven gate also retains **12 failed cycle
bands** out of 19 graded kernels (one additional informational kernel). These
are real measurements of a different memory-service environment from the
legacy oracle; they have not been widened, filtered or called timing passes.

### Complete two-consumer sharing, 11:25 UTC

Source review of the area regression found the decoder was updated but the
included retirement task still instantiated the old sixteen-byte lookup gather.
The corrected full-PC model **`751139e1`** changes only that task's byte-copy RHS
to the same shared bytes. It retains all performance flags, guards, state and
latency. It is **gameplay-unmeasured**, with no inherited qualified CoreMark score.

Its 384-fixture directed matrix closes 1,536 full QEMU comparisons and 768
identical complete cycle-record A/B lists. Full active preprocessing now proves
no generic prefix-byte calls remain anywhere in the included core. The new
canonical gate still fails the 101 terminal-record comparisons and 12 cycle
bands; all 20 cycle-kernel record lists equal its parent. No failure was waived.

Exact-source hardware export, 91 freezer tests, 35 real-Tcl profile checks,
actual compiler-command/source audit and strict hardware CPU lint are recorded
in [IC_PREFIX_CAPTURE_EXPORT.md](../fpga/IC_PREFIX_CAPTURE_EXPORT.md). Short
CoreMark diagnostics now close both seeds, all original CRCs and exactly
4,767,218 / 4,753,406 ticks, independently audited with 3,362 stable pins,
native exits 0, EOF/reaping, actual V retirement and no OOM. These short runs
are duration-invalid, not qualified scores. Whole-design synthesis started
11:26:43 UTC under the sole-Vivado guard (8 GiB RAM / 6 GiB swap, 30-minute
cap), comparing the immediate 221,918-LUT parent. It closed native 0 at
11:48:18 UTC and independently audited **197,375 LUTs: 24,543 fewer / 11.06%**.
BRAM/DSP counts remain 277.5 / 47; registers change 54,631 → 54,663. All 3,722
pins, actual source/defines, supervisor and DCP integrity are rechecked; no OOM.
No new route or board deployment. This is a real whole-chip area saving,
distinct from the earlier 83.40% local experiment. Its own cold standard suite
started 11:50:53 UTC; admission and exact service identities are in the export
document linked above. Current verified gameplay is `bfb867f7`'s **0.50705320**
above; this `751139e1` descendant remains gameplay-unmeasured.

Read-only clock/netlist inspection closes native 0 with original 40/100 MHz
constraints, no black boxes or structural DRC errors. Its **unplaced core
estimate is 18.87 MHz**, versus 18.09 MHz for the immediate parent. No routed
frequency is available; the large area saving does not by itself close timing.
The separate balanced-remainder-CLZ experiment mapped almost identically to the
original (87 → 85 LUTs, both seven levels), so it is **not** being advanced as
a timing fix. [Closed negative result](../fp_shared/tb/REM_CLZ_TREE.md).
