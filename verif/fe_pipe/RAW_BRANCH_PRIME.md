# Raw branch fallthrough resident-read hint — October 10

**Private, default-off proposal; not standard-suite or FPGA acceptance.**
Latest verified gameplay is **0.46829233 total U+V retirement-event IPC**,
parent SoC `958f7ec4`, clocks **2,500,048,811–2,600,048,811**. All fourteen
consecutive windows from 1,200,048,811 average **0.4782252957**, below 0.48;
the new 0.40860952 and 0.41837727 dips remain included. Raw endpoint frames, counters, native
identity and unchanged inputs are audited in
`external/tmp/ventium-sfetch16-latest-r6.13etykyJ/audit.json`.
The new branch-hint candidate has **no gameplay measurement**.

## Cause and implementation

The [cache-backed every-clock investigation](../bench/coremark_boot/README.md#prefix--ret-every-clock-follow-up)
finds all 39,341 pipeline read waits in a 1M-clock CoreMark slice are resident
L1 hits. Two loads after conditional branches account for 9,772 of them.
The raw frontend excludes branch-successor priming; the old branch option
requires the absent uop cache and cannot simply be enabled.

`prepare-raw-branch-prime.py` adds **`VEN_RAW_BRANCH_FALLTHROUGH_PRIME`** to a
private frozen prefix+RET source closure. It changes `core_mem_chain.svh`
and adds the small `core_raw_branch_mov.svh` function. It does not modify the
production checkout, execution decoder, L1 geometry, AXI latency or guest.

- Only predicted-not-taken conditional branches are eligible. The actual
  outcome gates **commit**, never the query address. Wrong predictions cannot
  capture a new window; unavailable/missing/MMIO lines start no backing read.
- An unpaired U branch can borrow its already checked V descriptor.
- After a paired V branch, a tiny recognizer accepts only unprefixed
  `MOV r32,[base]` / `MOV r32,[base+disp8]`, excluding SIB, literal addresses,
  disp32 and ESP destinations. It selects at most three bytes from the existing
  returned frontend span, not a third full decoder or new cache read port.
- Complete same-page, same-line, CS-bounded code ownership is required, as
  are existing data-segment bounds, resident DTLB permissions, full operand
  line extent and dependencies against **both** older GPR write masks.
- Existing event/debug, invalidation, fragment and active-owner restrictions
  remain. The hint does not retain/execute a uop or bypass ordinary next-U
  admission. The actual L1 ready/commit protocol owns any registered response.

There is additional combinational selection/qualification logic. No new
register, cache or SRAM port is introduced by the source delta, but **physical
LUT cost, congestion and CPU frequency have not been measured**.

## Matched bootable CoreMark result

SoC **`d4cd589b`**, compared with prefix+RET **`1cad4e49`**, using exactly the
same ten-iteration cold disks, ROMs, compiler/port and 40/40/80 MHz calibration:

| Seed | Parent TSC clocks | Candidate TSC clocks | Clocks removed | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 5,012,733 | **4,954,588** | 58,145 | **1.17356%** |
| Validation | 5,000,796 | **4,939,299** | 61,497 | **1.24506%** |

Both five-CRC sets match their reference. Short ratios are
**2.018331292 / 2.024578791 CM/MHz**, still below 2.1 and **not duration-valid
scores**. Do not substitute them for the full-seed correctness suite or the
historical direct-memory 2.1 result. Performance needs another approximately
192,683 measured clocks removed at this iteration count to reach 2.1.

Receipt: `external/tmp/ventium-raw-branch-soc.iwkeeA3o/coremark/audit.json`.
The independent audit rechecks 288 input pins, actual native CPU-3 affinity,
model/header ownership, original media, real V retirements, zero OOM, reaped
children and retained successful supervisor
`568940c3b75c46eea25ea3541ae731e7`. Each seed closes native 0 in about 90 s.
The service initially specifies CPUAffinity 7, but its explicit taskset selects
CPU 3; recorded **actual child affinity [3]**, not that property, is authoritative.

## Verification and retained limitations

Core root: `external/tmp/ventium-raw-branch-core.4jVQ52FQ`, model **`9d9fb54a`**.
Exact source closure is frozen and audited against `80b0937d`; only the two
listed files/one flag change. Unique C++ harness/header ownership is checked.
Core build passes all six structural error classes. The SoC build has the
same 98 inherited platform warnings and no new structural warning.

- `mov-leaf/`: **131,072** actual-decoder comparisons/rejection checks;
  all 23,387 accepted cases have identical complete `fpd_t` packets.
- `guards/`: **4,199** checks of the **actual integration include**, including
  wrong outcome, no retirement, unavailable leaf, older-U/V address writes,
  pending events/debug/flush/fragment, returned-byte ownership, all 4 KiB code
  offsets, CS/data extents and DTLB permissions. Cache identities/translation
  responses are mocked here; this is not architectural interrupt delivery.
- `matrix/`: 512 ordinary-reset fixtures, two AXI latencies, both native
  models: **2,048 complete QEMU architectural comparisons plus 2,048 cycle
  runs**. Flat/relocated code, all 32 line offsets, U/V branches, dependent
  bases, alternating outcomes and excluded load forms. Actual 3,960 hints
  include 1,920 after paired V branches. Of 1,024 paired totals, 332 improve,
  692 equal, none regress. These one-line fixtures mostly save only startup
  clocks; warm reuse already hides the read latency.
- `chase/`: two-node pointer chase, 64 additional fixtures / 256 comparisons
  plus cycle runs. Both lines fit the old reuse windows: warm rounds remain
  unchanged. Keep this zero-steady-gain control instead of treating hint
  activity as a demonstrated speedup.
- `chase-four/`: four-node chase, another 64 fixtures / 256 comparisons plus
  cycle runs. It exceeds the two reuse windows while staying resident in L1.
  Representative steady rounds improve **9 → 8 clocks**, with each post-branch
  load interval **2 → 1**. Initial cache misses still cost 77 clocks at AXI7
  on both models. Of 128 matched totals, 120 improve and eight equal; none
  regress. This micro result is separate from the measured whole-CoreMark gain.
- The first `smoke/` is **failed**, not overwritten: 18 cases lacked the
  fixture's separate final U/V witness because its code alignment moved.
  An explicit aligned pair block repairs the fixture, not RTL or grading.
  Subsequent fixtures are copied into each run directory before execution.
- Unchanged `make verify` is still **FAIL**, native 2: **7 functional PASS /
  101 FAIL**, with terminal/bounded-record length mismatches and hard cycle
  failures retained. No records, masks, goldens or timing bands were relaxed.
  Invocation: `6f6b49c5065f4dbeaa1888aa4562e920`.

The prefix-only cold Quake continues separately on `320c4232`, without this
proposal. Full current-seed CoreMark, Win95 desktop, complete original Quake
timedemo, generic-gate repair and physical implementation/deployment remain
open. Neither a CRC diagnostic nor a passing control qualifies this candidate.

## Subsequent every-clock check

`external/tmp/ventium-raw-branch-state.TvzqsoWC` repeats the same performance
disk/model with **4,954,588 ticks and all CRCs unchanged**, native 0 in 98.00 s.
The lossless 7M–8M-clock observation archive is 22,010,722 compressed bytes;
`analysis.json` reconciles all one million clocks. This is the existing
VENSTATE/VENL1 observation set, not a complete retained-model state dump.

The two targeted branch-successor sites, `10d66` and `10ef2`, now have **zero
read-wait clocks** in this slice. All remaining **27,355 pipeline read waits**
and **7,552 pipeline store waits** still see resident cacheable L1 hits; another
5,673 slow-load waits do too. Equal-time windows execute different amounts of
work, so subtracting occupancy counts is not a causal whole-program speedup.
The matched complete short-seed gains above remain the performance evidence.

The trace also exposes a redundant saved-window invalidation on primary-only
stores, investigated separately in
[independent window invalidation](../l1/INDEPENDENT_WINDOWS.md).
