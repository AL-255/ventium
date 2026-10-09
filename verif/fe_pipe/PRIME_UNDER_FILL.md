# Resident priming during an independent fill — October 9

**Private candidate, not production/FPGA acceptance.** Verified Quake gameplay
remains **0.38065044 total U+V IPC**, dispatch-only `ba2463bf`, cycles
**1.2–1.3B**, predating the ownership and FP/priming repairs. No newer candidate
gameplay measurement exists; 0.48 remains open. Full CoreMark 2.10736/2.11041
CM/MHz results belong to the earlier direct-memory `cbdf278a` model.

## Observed cause and change

The new event/store microfixture returned the correct QEMU architectural state
but failed its actual-prime requirement at AXI latency 7. A host-only probe,
linked against the exact frozen RTL archive, observes **all 56 FP admissions**
with valid translation, checked admission and offered/committed hints while
L1 is in `L1_FILL`. The original query requires `L1_IDLE`, so none captures.
Most queries address a different physical set from the fill. This explains
that fixture; it is not a measurement of the complete gameplay bottleneck.

Probe evidence: `ventium-fp-prime-diag.V5QTxp0j` and
`ventium-fp-prime-diag-r2.rfXVdTkS` under `/home/yukidama/external/tmp`.
No clock, guest state, RTL, bus transaction or result was modified by the probe.

`prepare-prime-under-fill.py` changes only `rtl/mem/ven_l1d.sv`, behind the
default-off `VEN_L1D_PRIME_UNDER_FILL` flag. It permits a cache-only query using
the existing read port while an unrelated data fill retains the backing port.
The query must hit a resident **different physical set**. Bypass, poisoned
fills, code fills, an armed response, critical response and a live demand
request are excluded. Existing cacheability, extent, flush/snoop and commit
checks remain. The ordinary registered response retains exact address/data
ownership; no combinational ACK, extra port, early tag allocation or second
backing operation is added. The query's LRU update is disjoint from the fill's
set, including its final beat.

## Closed directed evidence

Root: `/home/yukidama/external/tmp/ventium-prime-under-fill.dS3Yp4kv`.

- Core model: `8f1a57643bb866b90928a1c00ec3a353421058a6e74b7ca4feb04e4e72ff15f3`.
- Full-address user model:
  `e3d9aa6909bce5d66f84c3a999fdbe2cb8163444c3134e61f6801b98d6f0f0db`.
- Both builds close native zero, stable pins, assertions, six hard structural
  checks and verified model-local C++/generated-header ownership.
- `leaf-r2/closed.json`: both control and candidate pass the previous **150
  accepted handoffs**, **three primed-U/V ownership scenarios**, and **51 new
  under-fill cases**. Tests use real cold demand fills and a paused backing
  slave, never forced DUT state. They cover every byte/aligned dword, withheld
  commit, same-set/miss/MMIO/split/partial-strobe rejection, existing demand
  ownership, snoop on capture, snoop/flush/reset after capture and capture on
  the final backing beat. Backing address/transaction ownership is checked.
  The earlier `leaf` run passed its smaller 47-case extension separately.
- `matrix/result.json`: **88 measurements / 176 complete QEMU comparisons**.
  Warm timings are unchanged from arithmetic-only priming (12 clocks for the
  positive m32 loop); this optimization has no additional warm-loop gain.
- `events-store`, `events-remap`, `events-page-fault-r2`, `events-ts-r2`,
  `events-em-r2`: **40 measurements / 80 complete QEMU comparisons** across
  flat/relocated clients, two code alignments and AXI latencies 0/7. Each has
  eight actual INT3 entries. Fault cases also require eight genuine #PF/#NM
  entries and retry through the normal architectural handler. All positive
  shapes require actual prime witnesses. No architectural records are filtered.
  Store/remap scenarios have at most about **0.53% fewer measured loop clocks**;
  interrupt/handler overhead dominates, so this is not a gameplay projection.
- `system-matrix/result.json`: **76/76** full system comparisons pass.
- `generic-user-r2-closed.json`: **FAIL**, native 2 with stable pins. All 108
  functional reports were inspected: seven equivalent and 101 length-only
  failures, with no earlier architectural mismatch reported. The same depadd,
  indepadd, dmiss, imiss and nearbr cycle bands fail. No terminal filtering,
  fabricated QEMU state or band/comparator changes were used.

The first fault-driver attempts (`events-page-fault`, `events-ts`, `events-em`)
fail the timing-marker count: a faulting first operand has both exception and
retry records. The correction uses the nonfaulting **last operand** solely as
the interval marker. Every exception/retry record remains in the unchanged
whole-state QEMU comparison; the failed receipts remain separate.

## Cold full-PC candidate

`/home/yukidama/external/tmp/ventium-fp-prime-fill-soc.3glP2yRo` contains a fresh
full-PC model, SHA
`e44e3176c915a275cfd644a0cfe6cd7bc487d45b2d2cc5a3378a52d6a18c928e`.
Exactly three RTL files differ from ownership-repaired `4b5fb92f`:
`fp_shared/ven_fp_top.sv`, `rtl/core/core_mem_chain.svh`, `rtl/mem/ven_l1d.sv`.
All other common RTL is byte-identical to the directed model, apart from the
deliberately preserved full-PC shim. Three new flags enable forwarding,
arithmetic-only priming and independent-set fill overlap. Native build exits
zero with stable pins and private C++/header ownership. The **98 inherited
third-party structural warnings** are unchanged; this is not a clean whole-SoC
structural-lint result.

Both cold services are launched and their actual child executable hashes,
arguments, CPU ownership and process groups have been checked:

| Guest | Service | Invocation | Native PID / CPU |
| --- | --- | --- | --- |
| Quake | `ventium-fp-prime-fill-quake-oct09.service` | `f0bf75259dbb4aef9031876de03728ae` | 3410605 / 29 |
| Win95 | `ventium-fp-prime-fill-win95-oct09.service` | `025ea65a33e7498a8af11a5a6ca22df5` | 3410615 / 30 |

Each has one CPU, 2 GiB RAM, no swap, bounded tasks/files/runtime and fresh
unchanged media. UV + relocated system fast path, full P5 L1s, posted16 DDR
transport and 40/40/80 MHz simulation clocks remain enabled. No debugger STEP,
pair suppression, saved state, input script or guest patch is used. These runs
are **in progress**, not standard-suite or performance passes. Same-build
CoreMark validation remains required as well.

For disk headroom, 17 closed cache files were removed: 16 GCC PCH files and
one temporary timing database from the stopped Vivado run, **3,354,774,685
bytes**. Plan/receipt: `ventium-closed-cache-reclaim.RpDtgDu3`. Another 12 PCH
files from the completed under-fill builds recovered **1,038,692,057 bytes**
(`pch-prune-{plan,closed}.json` in the micro root). Files were independently
validated as regular, single-link and unopened. Sources, models, objects,
archives, headers, dependencies, logs and results remain; the deleted caches
are regenerable from retained build commands.

Full generic gate, same-build standard suite, gameplay and hardware acceptance
remain required. No acceptance is inherited from any earlier model.

## Same-source CoreMark qualification and full seeds

`ventium-fp-prime-fill-coremark.cw0NJAWN` builds the exact 116-definition
under-fill board-core source with a model-local host harness. Executable SHA:
`e3dbf68a7229a8f6c79e5999aba3a77520e94545205fd89f7b1c11b53c5de9f4`.
Native build exits zero with stable inputs and matching generated headers.
This uses **direct memory**, not the FPGA cache/DDR backend.

Both ten-iteration seeds match between ordinary host settling and the existing
inactive-input settle optimization: complete serialized model state, mapped
memory, clocks, retirements, all CRCs and zero delivered faults. No clock edge
or architectural state is skipped or restored. Fifteen negative launch guards
also pass. `qualify-r2` and the separate CPU-placement repeat `qualify-r3` both
close successfully. Performance/validation take **4,823,423 / 4,816,710 clocks**;
these short checks are not the required full CoreMark score.

The full 1,500-iteration seeds are running under
`ventium-fp-prime-fill-coremark-full-r4-oct09.service`, invocation
`25d8d2d8c8294a5397c36a9db2654413`. Actual children 3412103/3412102 use
CPUs 20/21 and the SHA above. Each retains the **3,600-second hard cap**;
the service has 2 CPUs, 2 GiB RAM, no swap and 160 tasks. Native closure and
scores remain pending, with evidence under `full-r4`.

Launch planning changed explicitly: measured rates of 213,977 / 213,197
simulated clocks/s missed the previous arbitrary 215,000 floor, even after
moving CPUs. The revised floor is the target's 714,285,714-clock ceiling
divided by 3,360 seconds, reserving four minutes of the unchanged hard cap:
212,585 clocks/s. Projected durations are 3,338 / 3,350 seconds. This is an
estimate, not guaranteed completion or relaxed correctness/scoring acceptance;
`host-admission.json` retains both thresholds and the calculation. Full CRC,
fault, source-pin, native-exit and score checks are unchanged.
