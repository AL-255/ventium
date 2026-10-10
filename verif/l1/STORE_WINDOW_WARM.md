# Committed-store read-window warming — October 10

Private, default-off candidate, **not a standard-suite or FPGA pass**.
Verified gameplay baseline remains parent `958f7ec4`: **0.46829233** total
U+V retirement-event IPC at clocks 2,500,048,811–2,600,048,811; all fourteen
consecutive 100M windows average **0.4782252957**. This candidate has no
gameplay measurement. REP events are not exact P54 macroinstructions.

## Change

`prepare_store_window_warm.py` adds `VEN_L1D_STORE_WINDOW_WARM` to the coherent
write-window parent. A committed single-U store to a resident cache line can
warm the existing primary read window, saving the previous primary in the
existing shadow. The asynchronous bank read supplies the before-image;
actual acknowledged bank masks/data merge the after-image. It adds neither
storage, cache capacity, RAM ports nor speculative memory transactions.

Admission requires an actual bank write, current safe cacheable hit, nonzero
strobes, no crossing, pair, diverted dual-read port, early owner, code access,
flush or snoop, and neither saved window already owning the target line.
Already-owned lines use the previous coherent-update mechanism. Warming does
not set `rd_armed` or manufacture a read response. Global invalidation retains
priority. An assertion rejects overlapping capture/fill/paired-write owners.
The extra enable/data multiplexing remains physically unqualified.

## Evidence

Artifacts below are under `/home/yukidama/external/tmp/`.

- Leaf: `ventium-store-window-warm.DyEcg4eq/leaf`. Full 142-define parent and
  six fatal structural warning classes. Original/off/on retain the existing
  150 chain checks plus 68,262 reads / 1,137 stores. New tests add **15,913
  checked reads / 535 stores** each: all offsets/strobes, policies, crossing,
  delayed ACK/withdrawal, paired-store exclusion, global poison and reset.
  Original/off have zero immediate reads; enabled has **448**. An independent
  byte oracle checks data after ordinary transactions, without writing cache
  internals. Required-negative original fails at precisely
  `STORE-WARM-REUSE-MISSING`, not merely any nonzero exit.
- Core: `ventium-store-warm-core.QQBHmz8z`, model **`4b432373`**, one-file/flag
  derivative of `ecc6fa47`. Strict structural build and private harness/header
  ownership pass. **256 cold paged fixtures**, flat/relocated and all 32 code
  offsets, produce **1,024 complete QEMU comparisons + 1,024 cycle runs**.
  All pass, including actual V-retirement witnesses. Of 512 matched totals,
  **234 improve, 278 equal, zero regress**. No golden records are trimmed.
- SoC: `ventium-store-warm-soc.jBqDoDos`, model **`a7903f06`**, one-file/flag
  derivative of `54651745`. Source closure and private harness/header checks
  pass; 98 inherited platform structural warnings remain unchanged, not waived
  as a clean platform. Initial core/SoC launch attempts failed disk admission
  before source copying or compilation. Distinct `-r2` units succeeded after
  verified lossless compression of closed evidence; failed logs are retained.

## Matched short CoreMark

Same unchanged ten-iteration disks, ROMs, compiler/port, full P5 L1s, 256 KiB
L2, posted-16 board-memory model and 40/40/80 MHz timebases; enforced UV plus
system/relocated fast pipeline and fast loads/stores:

| Seed | Parent clocks | Candidate clocks | Removed | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,801,536 | **4,782,160** | 19,376 | **0.40517%** |
| Validation | 4,787,479 | **4,768,125** | 19,354 | **0.40590%** |

Ratios **2.091105275 / 2.097260454 CM/MHz** remain below 2.1. They are
**duration-invalid diagnostics, not scores**. All five CRCs match each pinned
QEMU reference; minimum-duration errors are retained. Both children close 0,
are reaped, execute on verified CPU 3, and have no OOM events. Independent
`coremark/audit.json` rechecks 293 pins and retained successful supervisor
`e5df35cbe95e41588899573f09678894`.

Unmodified generic `make verify` remains **FAIL**, native 2, supervisor
`04f5059ba44a4e8ca54d57906f990779`: terminal/bounded-record discrepancies and
cycle-band failures remain visible. No comparator, oracle or band was relaxed.
Inherited NP-prefix/EX P54 resource qualification is still open. Duration-valid
CoreMark, clean Win95 desktop, complete original 969-frame Quake demo and routed
FPGA deployment all remain required before acceptance.
