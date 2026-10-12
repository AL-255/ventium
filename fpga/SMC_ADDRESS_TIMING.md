# SMC address-selection timing experiment — October 12

**Private recipe and leaf contract checked; not compiled into a whole core,
not synthesized, not deployed.** The running resident-query synthesis is
unchanged. This is a possible next cut if its timing report retains this cone,
not an assumed 40 MHz result or a replacement for the current experiment.

## Measured reason to investigate

The completed memory-divide parent estimates **29.077375 MHz**, setup
**−9.391 ns** at 25 ns. Its worst path contains the following cumulative data
delays after subtracting the launch-clock contribution:

| Point | Cumulative data delay |
| --- | ---: |
| `core_store_pair_req` | 27.263 ns |
| Second I-cache snoop hit | 29.259 ns |
| `c_next_commit` | 31.922 ns |
| D-cache LRU register input | 34.180 ns |

These are **unplaced synthesis estimates**, not routed delays. The exact
report is `memdiv-clock-r1/core_setup_unplaced_estimate.rpt` under
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

Source inspection identifies two late address selectors before the second
physical I-cache snoop lookup:

1. `ventium_l1_axi.sv` selects paired V's physical address versus U's final
   byte using `core_store_pair_req` (which includes downstream pair readiness).
2. `core.sv` selects that external address versus its own crossing-store address
   using `ic_snoop_valid2` (which includes the same paired request).

The core's I-cache, fetch-bypass and REP-bypass snoop consumers compare physical
line identity, bits `[31:5]`; the low five address bits do not identify a line.
Do not remove same-cycle invalidation, register the snoop, or waive this path.

## Private transformation

[`prepare_smc_payload_cut.py`](../verif/l1/prepare_smc_payload_cut.py) requires
the exact two memory-divide/query source hashes and rejects drift/reapplication.
It replaces only the two address assignments and adds simulation assertions:

- Select V's address when U's physical address is dword-aligned; otherwise
  select U's final byte. A paired U is aligned, whereas a crossing beat of at
  most four bytes cannot be aligned. Existing snoop-valid generation is intact.
- In the core's paired-store profile, prefer the own crossing-line address
  whenever its snoop is valid; otherwise use the external address. Simultaneous
  own/external U snoops must identify the same physical line, and a paired V
  cannot collide with an own crossing U. Other profiles retain the old mux.

There are no new pipeline registers, cycles, requests, feature flags, timing
exceptions or permission relaxations. An accepted L1 address must remain
bit-identical. An accepted core snoop must retain the same physical line;
idle payloads and the core snoop's unused low bits may differ. Assertions check
these properties on actual clock edges when integrated into the whole core.

**The ownership assumptions are not yet proved for the whole processor.**
The leaf theorem requires aligned paired U addresses, equal physical/linear
line offsets, and a positive beat size no larger than four bytes. Its abstract
controls deliberately over-approximate valid combinations within that contract.
Before promotion, real UV-fast tests must establish the active-source contract,
including split-page fragments and fault/abort paths. The core's generic ports
must not be assumed interchangeable without those checks.

## Executed preliminary checks

[`test_smc_payload_cut.py`](../verif/l1/test_smc_payload_cut.py) extracts the
actual predecessor/candidate assignment expressions and predecessor final-byte
arithmetic. It does not hand-format architectural traces or replace an ISA
oracle. The native SystemVerilog miter passes **49,152 samples**, exhaustively
sweeping all line offsets, all 16 strobe masks, sizes 1–4, independent valid
sources, and three high-address patterns including linear aliases and physical
32-bit wrap. Observed overlapping coverage classes:

| Class | Samples |
| --- | ---: |
| U-read / V-store pair | 3,072 |
| U-store / V-store pair | 3,072 |
| Crossing U external snoop | 1,632 |
| Own-only crossing snoop | 708 |
| Simultaneous own/external copies | 444 |
| Intentionally different idle payload | 40,128 |

Three separately compiled mutations—always V, always U, and dropped own
snoop—fail with native exit 1 and actual address/line mismatches. They are not
timeouts or build failures. An all-bit Z3 contract proof reports `unsat` for an
accepted mismatch. Removing each of paired alignment, matching line offsets,
or the beat-size bound produces `sat`; an idle difference also produces `sat`.
These negative controls explicitly prevent an unrestricted equivalence claim.

The first harness attempt failed to compile because its assignment extractor
consumed the next assignment after an inline comment. That harness bug was
fixed; the failed `smc-payload-contract-r1` evidence is retained separately and
is not counted as a design-negative test.

Successful evidence: `smc-payload-contract-r2`, native owner
`ventium-smc-payload-contract-r2-oct12`, invocation
`e6097ef5116347309c9c701204d203b4`. It closed native zero in **0.54 seconds**,
CPU 12 only, peak memory **45,543,424 bytes**, with stable source pins.
The file set changes are also checked to reverse exactly to the predecessor;
source drift and reapplication are rejected. This light job did not launch
Vivado, alter the live synthesis inputs, or occupy the heavy-build lock.

## Next acceptance work

Wait for the existing resident-query timing audit and inspect its actual
critical path before choosing this experiment. If selected, build a private
whole-core derivative with these assertions and the unchanged UV/fast/P5-cache
profile. Run canonical verification, complete parent/candidate state and cycle
comparison, paired executable-store tests, cross-line/page SMC, aliasing,
REP-continuation invalidation, and fault/abort tests. Retain original source
inputs and compare CoreMark cycles before another synthesis. A leaf proof
cannot replace any of those checks.

The inherited canonical **7 PASS / 101 FAIL** remains unwaived. Full original
CoreMark seeds, Win95 cold desktop plus keyboard/mouse interaction, and full
FreeDOS Quake timedemo are still required; FPGA acceptance must be physical.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older build `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. Neither the
running timing candidate nor this proposed derivative has a gameplay result.

## Deferred after the query-selector timing audit

The [resident-query audit](PRIME_QUERY_PAYLOAD.md) subsequently closes at
**30.676729 MHz**, still below 40 MHz. Its worst setup path now runs through
backing-write ACK to immediate paired-load acceptance/GPR writeback; it does
not traverse the second-snoop lookup. Consequently this SMC proposal remains
uncompiled and unpromoted. The next selected experiment targets that measured
[read-only ACK consumer](PAIR_NOW_READ_COMPLETION.md). Retain this proposal's
proofs and caveats for a later report that actually makes its cone critical.
