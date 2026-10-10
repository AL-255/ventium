# Coherent saved-window writes — October 10

Private, default-off proposal; **not a completed processor repair or suite/FPGA
qualification**. Latest verified Quake gameplay: **0.46829233 U+V retirement-event
IPC**, parent `958f7ec4`, clocks **2,500,048,811–2,600,048,811**. All fourteen
consecutive windows from 1,200,048,811 average **0.4782252957**, below 0.48.
Evidence: `external/tmp/ventium-sfetch16-latest-r6.13etykyJ/audit.json`.
This candidate has no gameplay measurement; REP elements are events, not exact
P54 macroinstruction IPC.

## Implementation

After an acknowledged cacheable resident store, the existing primary/shadow
read windows can retain ownership if their changed bytes are updated too.
`prepare_window_write_update.py`, flag `VEN_L1D_WINDOW_WRITE_UPDATE`, reuses the
bank writer's actual rotated byte masks/data and U/V arbitration. There is no
new SRAM port, line storage, cache capacity, speculative backing request or
store-ACK change. Added data/control multiplexing has **not** been synthesized
or timed; no FPGA area or frequency gain is claimed.

Only already valid physical owners are updated. Current tag hits still gate
reuse. Stalled and withdrawn requests do not change bytes. Cross-line stores,
skipped cache-update policy, nonresident tags, flush/snoop, uncached access,
golden/stream mode, misses/fills and reset retain conservative invalidation.
An assertion forbids a store update colliding with a new read capture. U-load/
V-store reads the old U value; only the acknowledged V write updates its bytes.

## Verification

Leaf root: `external/tmp/ventium-window-write-update.gGtvDDPq/leaf-r2`.
`run_window_write_update.py` uses the complete 140-flag parent SoC profile and
all six structural warning classes as hard errors.

- Original, candidate-off and candidate-on each pass **68,262 read checks /
  1,137 stores**, plus the existing 150 accepted read-chain checks.
- Covers both owners, all 32 offsets × 16 strobes, real crossing extents,
  independent U/V tags, partial update policy, delayed ACK, withdrawal, global
  poison, miss and reset. An independent byte-memory oracle checks data;
  cache state is warmed only by ordinary transactions.
- Immediate checked reads: original/off **0**, on **959**. Required-failure
  original closes native 1 at the exact `WRITE-UPDATE-REUSE-MISSING` assertion.
  Arbitrary nonzero exits do not count.
- The first `leaf/` attempt failed before compilation because its source
  anchor also matched an indented scratch declaration. The corrected anchor
  includes the unique bank `wr_row` declaration; failed artifacts are retained.

Core: `external/tmp/ventium-window-update-core-r2.ZvXU1hOO`, model **`068a1def`**,
exact one-file/one-flag derivative of `9b3011f4`. Strict structural build and
private C++ object/generated-header ownership checks pass. The earlier
`ventium-window-update-core.ptcgREx8` launcher failed before compilation (it
treated the make variable's embedded `--assert` as a separate argv item); it
is retained separately, not counted as a successful build.

`run_window_update_core.py` / `window_update_core.S`: **256 cold paged BIOS
fixtures**, flat/relocated segments, all 32 instruction alignments and four
store/read-owner classes. Two AXI latencies and both models yield **1,024
complete QEMU comparisons + 1,024 cycle runs**, all passing in 58.91 s. Actual
V retirement and changing written values are required. Of 512 matched totals,
**376 improve, 136 equal, zero regress**. Representative post-store reads fall
2 → 1 clocks and loops 10 → 9. No golden records are trimmed.

SoC: `external/tmp/ventium-window-update-soc.xwdSthN7`, model **`d37df58c`**,
one-file/one-flag derivative of `252109e4`. Full source closure and private host
header ownership pass. All 98 inherited platform structural warnings remain
unchanged; they are debt, not a clean-platform-lint claim.

## Matched CoreMark result and remaining work

Same original ten-iteration boot disks, ROMs, compiler/port, full P5 L1s,
256 KiB L2, posted-16 board-memory transport and 40/40/80 MHz timebases:

| Seed | Parent ticks | Candidate ticks | Removed | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,862,426 | **4,853,587** | 8,839 | **0.18211%** |
| Validation | 4,847,492 | **4,837,758** | 9,734 | **0.20121%** |

Short ratios **2.060331874 / 2.067073219 CM/MHz** are below 2.1 and **not valid
CoreMark scores**. Both five-CRC sets match the pinned QEMU reference; the
minimum-duration errors remain. Both native children close 0, CPU-3 affinity
is verified, children are reaped and no OOM occurs. `coremark/audit.json`
independently rechecks 291 pins and retained successful supervisor
`f54d25d16a5743bfb75f2b7b750ec4b0`.

The unchanged generic `make verify` remains **FAIL**, native 2; terminal/
bounded-record mismatches and cycle-band failures are retained. No masks,
goldens or bands are relaxed. Receipt: core `generic.log`, supervisor
`85321931705e4d7dbe6c9490fb41e539`. Directed passes do not override that gate.
Inherited register-prefix/EX P54-resource qualification is also still open.
Duration-valid CoreMark, error-free Win95 desktop, the original complete
969-frame Quake timedemo and a routed/deployed FPGA remain required.
