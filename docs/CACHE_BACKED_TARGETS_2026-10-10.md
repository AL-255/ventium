# Cache-backed performance targets — October 10

Acceptance remains **open**: at least **2.1 CM/MHz**, at least **0.48 Quake
U+V retirement-event gameplay IPC**, the error-free standard suite, green
differential gates, and a working FPGA deployment. U-only/STEP/global slow
fallbacks are not acceptance. REP retirement events are not P54 macroinstructions.

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
Quake and Win95 remain active, progressing through cold boot; neither has a
completed standard-suite result or a gameplay IPC measurement for this build.

## Gameplay baseline and blockers

Current verified parent `958f7ec4`: **0.50530999** at clocks
**3,900,048,811–4,000,048,811**, 50,530,999 events = 38,868,367 U + 11,662,632 V.
All twenty-eight consecutive 100M windows from 1,200,048,811 total
1,361,562,099 events / 2.8B clocks = **0.4862721782**, retaining every dip.
Audit `ventium-sfetch16-latest-r13.B1BPkjih/audit.json` checks counters,
source/native/supervisor identity, unchanged raw endpoint pixels and no OOM.
Latest window and aggregate exceed 0.48; timedemo is unfinished.
**The newer `bfb867f7` candidate has no verified gameplay measurement.**

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
exact 4,767,218 / 4,753,406 ticks. It has **no qualified 900-iteration score or
gameplay IPC yet**; it cannot inherit either parent's performance acceptance.
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
mapped-logic/project-clock inspection follows; no new route has been launched.

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
CoreMark is running; performance seed closes native 0 with all CRCs and exactly
4,767,218 ticks. Validation and whole-design area remain pending. No new route
or board deployment; the earlier 83.40% local result is not a whole-chip saving.
