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

Current verified parent `958f7ec4`: **0.49630560** at clocks
**3,600,048,811–3,700,048,811**, 49,630,560 events = 38,045,168 U + 11,585,392 V.
All twenty-five consecutive 100M windows from 1,200,048,811 total
1,212,043,748 events / 2.5B clocks = **0.4848174992**, retaining every dip.
Audit `ventium-sfetch16-latest-r11.S0xEqGEw/audit.json` checks counters,
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

Unmodified generic verification remains **red**: terminal/bounded-observation
record discrepancies and cycle-band failures. No golden records, field masks
or bands were weakened. The separate older FPGA route timed out before
completion; it produced no new bitstream. The new source has no routed timing
or silicon acceptance. Neither CoreMark smoke nor partial gameplay closes
these correctness, full-suite or hardware obligations.
