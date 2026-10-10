# Independent saved-window invalidation — October 10

Private, default-off proposal. **Not standard-suite or FPGA acceptance.**
Verified Quake gameplay remains **0.49510940 U+V retirement-event IPC** on
parent `958f7ec4`, clocks **2,000,048,811–2,100,048,811**. This candidate has
no gameplay measurement. REP elements are events, not P54 macroinstructions.

## Defect and fix

The primary and shadow read windows already have separate physical owners
and store-overlap checks. However, the primary's invalidation block also
unconditionally clears the shadow. Thus writing the primary discards an
unrelated, valid shadow line and adds a resident-read capture clock.

`prepare_independent_windows.py` changes only that redundant shadow clear,
behind `VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE`. Existing shadow U/V overlap
checks retain priority. Flush, snoop, uncached access, golden mode, stream
mode, miss/fill and reset still cancel both. Current resident-tag and access
checks still qualify reuse. No data writer, store acceptance, memory port,
storage, cache capacity or execution latency changes. Hardware area/timing
of this delta have not been measured.

## Directed verification

Leaf root: `external/tmp/ventium-independent-windows.M7Saw2ae/leaf-r2`.
The complete 137-flag parent SoC profile is used, not a reduced cache model.

- Original, candidate-disabled and candidate-enabled each pass the existing
  150 accepted-chain checks plus **568 read checks / 567 stores**.
- All 32 offsets × 16 write masks, crossing writes, primary/shadow/neither
  owners, paired U/V stores, delayed ACK, U-load/V-store pairs, cache-update
  policy zero/all-ones, global invalidation, demand miss and reset are covered.
- No DUT cache state is written hierarchically; ordinary requests warm it.
  A separate byte-addressed backing oracle checks returned data and writes.
- Original and disabled candidate have 16 immediate shadow reads; enabled
  has **512**. A required-failure build of the original reaches the exact
  `PRIMARY-ONLY-STORE-LOST-SHADOW` assertion, native 1.
- The initial `leaf/` run is retained as failed: its three positive variants
  passed, but its driver incorrectly required abort status 134/-6 instead of
  this Verilator version's native `$fatal` status 1. The revised checker still
  requires the exact fatal marker; it does not accept arbitrary failure.

Core root: `external/tmp/ventium-independent-window-core.1I9OR3Ub`, model
**`1abbf89e`**, exact one-file/one-flag derivative of `9d9fb54a`.
All six structural error classes pass; the unique host object is checked
against its own generated model header.

`matrix/` adds **256 cold paged fixtures**, flat/relocated segments, four
write-owner cases and all 32 instruction offsets. Two AXI latencies and both
models produce **1,024 complete QEMU architectural comparisons plus 1,024
cycle runs**, all passing in 63.04 s. Real paired-V retirement is required;
the signature written to memory changes each round. No records are trimmed.
Of 512 matched totals, **224 improve, 288 equal, none regress**. Representative
warm loops improve **10 → 9 clocks**, with the post-store shadow read
**2 → 1 clocks**. This is a microbenchmark, not gameplay or whole-CoreMark IPC.

SoC root: `external/tmp/ventium-independent-window-soc.TMZk8YR6`, model
**`8a9cabcd`**, exact derivative of `d4cd589b`. Source closure and unique
host/header ownership are checked. Its 98 inherited platform structural
warnings are unchanged.

## Matched bootable CoreMark result

Same original ten-iteration disks/ROMs, compiler/port, 40/40/80 MHz calibration,
full P5 L1s, 256 KiB L2 and posted-16 board-memory transport:

| Seed | Parent ticks | Candidate ticks | Removed | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,954,588 | **4,927,211** | 27,377 | **0.55563%** |
| Validation | 4,939,299 | **4,912,277** | 27,022 | **0.55009%** |

Short diagnostic ratios are **2.029545721 / 2.035715820 CM/MHz**, below 2.1
and **not duration-valid scores**. Both five-CRC sets match QEMU. The existing
minimum-duration errors remain. Each native closes 0 in about 89 seconds,
with real V retirement, explicit CPU-3 affinity, no OOM and reaped children.
`coremark/audit.json` independently rechecks 288 source/media/model pins and
the retained successful supervisor `ac6d219a5cb042e19298979d01037617`.

Unchanged generic `make verify` remains **FAIL**, native 2, **7 functional
PASS / 101 FAIL**, with terminal/bounded-record length mismatches and hard
cycle failures retained. No trace trimming, fabricated goldens, relaxed masks
or cycle-band changes. Receipt: `generic.log`, supervisor
`43b89befa44d4c3e8766b85f85dcbe97`. Directed passes do not override this gate.

The production checkout, original guests, full-P5 cache geometry and UV/fast
mode remain unchanged by this proposal. Full standard-suite and FPGA
qualification are still required before promotion.
