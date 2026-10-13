# FPGA-profile cycle diagnostics — October 13, 2026

The explicit ao486 single-fill direct-core model passes **108/108 functional
programs** against the qualified private reference. At zero added slave delay,
**18/19 gated cycle kernels pass**; `mb_imiss` remains red. At the existing
seven-cycle-per-beat delay, **10/19 pass**. The twentieth kernel is INFO-only.
**This is not canonical-gate, standard-suite, timing or FPGA acceptance.**

No production RTL, default parameter, timing band, golden, comparison mask,
guest payload or FPGA image changed in this experiment. The last synthesized
unplaced estimate remains **35.056967572 MHz**, below the required 40 MHz.

## Configuration cause, not a new hardware speedup

The direct `ventium_top` test model had `AXI_LINE_REPLAY=1`. Defining
`VEN_AO486_SINGLE_FILL` alone does not change that parameter: the actual ao486
shim explicitly supplies `AXI_LINE_REPLAY=0`. The new diagnostic model changes
only elaboration with **`-GAXI_LINE_REPLAY=0`**. All 195 source files, the
152 definitions and the C++ harness contents match the FRNDINT parent.

Keep the top-level replay default for its other transports; do not globally
disable it. The board already uses single fills, so the following reductions
are correction of a test/model mismatch, **not FPGA performance gains**.

The existing BFM also applies `AXI_RLAT` before **each beat**, not just once
per burst. Latency 7 adds 56 clocks to a complete eight-beat burst: seven
before the first transfer, plus 49 between transfers. It is not a measured
ao486 bridge/DDR latency. Zero delay is an optimistic diagnostic and does not
replace the default-latency results.

| Kernel | Replay 1 / delay 0 clocks | Replay 0 / delay 0 clocks | Replay 0 / delay 7 clocks | Read bursts, replay 1 → 0 |
| --- | ---: | ---: | ---: | ---: |
| Independent FP + integer | 4,581 | 4,005 | 7,589 | 128 → 64 |
| Dependent FADD | 9,507 | 9,354 | 10,306 | 34 → 17 |
| D-cache misses | 41,023 | 22,573 | 137,367 | 4,100 → 2,050 |
| I-cache misses | 52,260 | 34,170 | 146,730 | 4,020 → 2,010 |

The eight-kernel 0/1/7-delay sweep preserves the full PC sequence and actual
V-retirement counts. At delay 7 the original model's entire cycle trace is
identical with profiling enabled, proving the observer is passive on those
cases. Cycle traces contain PC/order/pipe/clocks, **not architectural state**;
their agreement is not a functional comparison.

## FP/integer overlap is present

In `mb_fpindep`, two complete warm intervals each contain 758 instructions.
They take **762 and 758 clocks** under both replay policies and all three
latencies. The cold interval, by contrast, takes 9,325 clocks with replay 1 /
delay 7, versus 5,230 with single-fill / delay 7 and 1,702 with single-fill /
delay 0. The whole-program CPI had mixed startup fetch cost with overlap.

This is evidence for this directed FP/integer stream, not a claim that every
x87 dependency/exception case or gameplay workload is correct. No overlap
mechanism was added, disabled or credited with a new gain here.

## All cycle bands, unchanged

The complete 20-kernel sweep reruns both delay 0 and delay 7. At delay 0 only
`mb_imiss` fails its gated band: CPI **8.502**, **+41.70%** absolute cycles.
At delay 7 the failures are `mb_depadd`, `mb_indepadd`, `mb_faddchain`,
`mb_dmiss`, `mb_imiss`, `mb_mul`, `mb_imul2`, `mb_rmimm` and `mb_nearbr`.
`mb_fpindep` passes narrowly at **2.499670619 CPI**; its printed 2.500 is rounded.

The existing `m5_metrics.py` delegates integer verdicts to M4. Their absolute
cycle differences are informational, not an extra gate: for example,
`mb_brrandom` passes its misprediction band despite +24.86% absolute clocks at
delay 0. All original per-instruction cycle comparators remain exit 1; the
canonical aggregator already treats those timing differences as non-gating
and separately checks control flow and bands. Nothing was relaxed here.

`mb_agiloop` ends at the canonical golden-derived instruction cap of 1,605,
with one AXI burst outstanding. Its two profiles retain **`valid=0`**, partial
beat counts and unavailable averages. It is INFO-only, not a clean-protocol
pass. The first two full-sweep wrappers refused this case (first requiring a
closed burst, then mistakenly using the manifest's 3,000-instruction upper
bound). Failed outputs and tested wrappers remain separate from R3.

### Every clock of the remaining zero-delay I-miss case

These mutually exclusive counters sum to **34,170 clocks / 4,019 instructions**:

| Owner | Clocks |
| --- | ---: |
| Reset/initial decode | 3 |
| Remaining I-line fill words (`S_PF`) | 14,070 |
| Missing instruction bytes (`S_PIPE`) | 10,052 |
| Registered I-cache read not yet ready | 2,010 |
| Slow-decode handoff | 1 |
| Branch penalty | 6,023 |
| U/V issue | 2,011 |

There are 2,010 complete single-fill read bursts, 16,080 beats, no overlapping
or orphan responses and no RREADY stalls. The missing-byte bucket includes
8,041 request-wait clocks. Together with the 2,010 registered-read clocks,
those account arithmetically for 10,051 of the 10,056 clocks over the oracle.
This comparison localizes the remaining cost; it is not proof that all those
clocks can safely be removed. In particular, the current `ven_l1d` already
returns directly to IDLE after a fill; a proposed removal of an `L1_DONE`
bubble would duplicate an existing optimization.

## Functional qualification and ownership

The new model cold-runs the unchanged functional corpus using
`--cycle-func --l1-axi`, delay 7, four workers with actual CPU8–11 affinity.
The private [qualified FRNDINT reference](../qemu-trace/frndint/README.md) is
used explicitly; canonical QEMU and its cache are untouched. All **80,800
architectural records** compare successfully, with **30,134 V retirements**.
Without the corpus's existing stack masks, 105 programs pass and the same
three deliberate stack-fault programs fail. No additional mask is introduced.
Native run time: **110.56 seconds**, peak 158,543,872 bytes, no OOM.

Model SHA-256:
`889bae534d468ae9c6ce14aa405e411b86f50a8f3bfbf7436f3bedbc990bb00a`.
Parent: `2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63`.
Private oracle: `da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d`.

Evidence root: `/home/yukidama/external/tmp/ventium-cycle-backend.VAI7femO`.
`audit.json` SHA-256:
`3f46ab49fc09803302e6281d487eebcd4274e4f5a392ba7b51ef13c0a581644f`.
The independent audit rechecks 14,707 input pins, source equality, the sole
parameter delta, private host/header binding, 88 closed diagnostic executions,
all band calculations and all 108 full-state comparisons. Its initial attempt
incorrectly passed cycle-only traces to the functional comparator; that
comparator correctly refused the incompatible headers. R2 distinguishes the
cycle PC check from the separate full-state corpus instead of rewriting traces.

All five successful build/run owners and the R2 audit are terminal, exit 0 /
MainPID 0. The 32-job compile took 20.57 s in the guarded 10/2 GiB RAM/swap
scope; measured scope peak was 3,352,612,864 bytes, no swap. The final 40-run
cycle owner closed in 4.83 s, peak 200,859,648 bytes. No Vivado or board run
was started during this diagnostic.

Drivers: `build_cycle_board_policy.py`, `run_cycle_backend_profile.py`,
`run_cycle_board_policy.py`, `run_cycle_complete.py`, `audit_cycle_backend.py`.
They require the pinned input closure and fresh scratch leaves. Use external
TMPDIR, explicit taskset, bounded retained systemd owners and the shared
guarded compile scope. The owner receipts record actual invocation identities.

Earlier in this diagnostic, eight exact closed October 4/8 owner-event logs
were losslessly compressed and byte-verified before their expanded copies
were removed, recovering about 491 MiB. `owner-archive-closed.json` lists every
path/hash; `gzip -dk` restores them. No model, media, source, architectural
trace or failed-result receipt was removed. No new cleanup is implied by the
later R3 cycle sweep.

## Remaining acceptance

The canonical gate remains unqualified. Do not silently promote the private
reference, replace backend defaults, weaken bands or claim this diagnostic as
an FPGA improvement. Next timing work must transfer the tested segment/x87
repairs into one audited hardware source set and measure the 40 MHz constraint
again; the source/hold/exception contracts must survive any shorter ACK path.
Full CoreMark correctness, Win95 desktop/UI, Quake timedemo and physical
UV-fast acceptance remain required. Existing-bitstream Doom still fails before
gameplay; there is no Doom FPS result.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA/Doom IPC.
