# Parallel write admission — native-qualified timing experiment

Status, 2026-10-16: **isolated RTL derivative implemented; native cache/AXI
tests pass. No whole-core, timing, standard-suite or FPGA acceptance.** The
production checkout and deployed bitstream have not changed.

This follows the rejected [qualified-credit experiment](QUALIFIED_PAIR_CREDIT.md):
35.295779 MHz synthesized/unplaced versus its RAW/input parent's 35.374438 MHz.
Neither result qualifies 40 MHz, and neither is routed fmax.

## Change and intended benefit

`prepare_parallel_write_admission.py` changes exactly two pinned RAW/input
files: `ven_axi_master.sv` and `ventium_l1_axi.sv`. The cache is byte-identical.
`PARALLEL_WRITE_ADMISSION` defaults off; the private wrapper enables it only
with dual-store pairing, without CDC or L2.

The old late request enters alias/extent and queue-admission logic before ACK.
The new branch computes single-store and paired-store admission **in parallel
from payload and existing state**, independently of `m_req`, `m_we` and
`m_pair_req`; the actual request then selects and gates the result. Two kept
combinational nets preserve that synthesis boundary. They are not registers,
extra credits, ACKs, architectural storage or false-path constraints.

Unlike qualified-credit, this does not assume a requested pair already has
credit. Held non-quad pairs still need two slots. Same-edge release, quad
combining, independent U/V address envelopes, strobe spill, BIOS shadow,
fatal containment and shutdown retain the original rules. Queue updates,
AXI packets, ordering, reset and read-response logic are unchanged. An active
nonsynthesis assertion compares enqueue against the full original equation.

No extra buffer, stall, latency or pairing restriction is introduced. This is
a proposed **frequency improvement, not a measured IPC gain**. Whether the
kept cuts improve timing or expose another critical path is unmeasured.

## Native evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Receipts: `parallel-write-{leaf,cache,wrapper,corners,faults}-r1/closed.json`.

| Check | Observed result |
|---|---|
| Host recipe/scope tests | 8 pass: exact parent, default-off, untouched cache/state, independent predicates and wrapper scope |
| Native control enumeration | 16,384 combinations each with quad off/on; **zero exclusions** |
| Native extent vectors | 1,228,800 U/V address/strobe cases; six masks, offsets, boundary crossings and BIOS shadow |
| Negative controls | Six required failures: remove U alias, V alias, fatal, single credit, request or pair credit |
| Full L1/AXI A/B | 2,387 clocks / 4,781 half-edge checks; 68 U stores, 3 V stores, including one load/store pair and one quad enqueue |
| Backpressure and state | 30 blocked / 84 full-queue clocks; cache data/tag/valid/LRU, observed queue state, AXI packets and final 64 KiB RAM agree |
| Real wrapper A/B, each | U=65, V=2, quad=1, blocked=30, full=53, AXI-only reset/retry=1, denials=4, AW=100 |
| Same-edge corners A/B, each | Quad release, split release, SMRAM denial+release, bad BRESP+release and shutdown exercised; U=10, V=4, AW=11 |
| AXI regressions | 18 passes: parent/candidate ID, post-AR RID, orphan B, RRESP, BRESP, narrow replay, quad, quad error and held split pair |

The held split-pair candidate uses the **new branch**, not the generic-default
control used by qualified-credit. No internal ACK, cache or queue state is
forced. Equation enumeration uses Icarus's four-state engine with binary
stimulus; it is not exhaustive X-propagation or sequential formal proof.
Finite address vectors do not exhaust the 32-bit address space.

Native builds use all 158 nonsynthesis hardware definitions (only `SYNTHESIS`
removed from the 159-definition manifest), assertions and hard structural
warning errors. Tests add only explicit BFM/fault-injection definitions.
The shared guard serializes 32-job compilation; native simulator affinity is
observed at CPU 8. All five owners closed successfully; no CAD was launched.

`audit_parallel_write_admission.py` independently reconstructs fixtures and
checks hashes, exact cases and terminal owner identities. Receipt:
`parallel-write-native-audit-r1.json`, SHA-256
`28284dbe29e76fdc130140e752055719256d9a990cae64ccc40131671f8bb5fe`.
It confirms **32 native executions: 26 passes and six required-failing mutants**.
Two initial auditor drafts confused inner/outer invocation IDs and expected an
absent success-log phrase. The final auditor checks distinct IDs, bounded journal
timestamps, native completion and terminal outer exit. No native verdict changed.

| Owner suffix (`ventium-parallel-write-…-oct16-r1.service`) | Invocation | Stage seconds |
|---|---|---:|
| leaf | `1a667e2fc9f74322a1dcec9d54734fcc` | 6.736 |
| cache | `e7f1df58e68448cc9e42a12d75523fcc` | 6.000 |
| wrapper | `f0415d385ca34c7cb052f0b8b5c3511f` | 11.499 |
| corners | `2d17b211e68544799fe7dc24e99744b5` | 11.602 |
| faults | `27b873eabf0b48f7bd72abace62d1784` | 96.633 |

Candidate master SHA-256:
`3a910d67790368c28856bf9ec9e906da35fd2bf2955386bd2408d146f1cbb067`.
Candidate wrapper SHA-256:
`f1c73668e97cf3f80654fbd7365db6559dcc14c506c3b9e3bf3885e833795be5`.

## Remaining gates

1. Recover safe scratch capacity before another whole-core build. External
   storage has about **5.8 GiB free**. Do not lower admission floors or delete
   source/media/accepted binaries to force a launch. About 1.68 GB of compiler
   archives here include substantial regenerable PCH caches; **none were
   removed in this round**.
2. Build the exact RAW-parent whole-core derivative with private harness
   dependency checks; run UV + fast-pipe architectural A/B and differential
   gates. Native cache passes do not substitute for those gates.
3. Measure matched synthesis timing and verify that the kept cuts remove late
   request controls from admission arithmetic. Do not infer fmax from source
   structure or route another below-target result.
4. Complete CoreMark correctness and duration-valid scoring, full Quake timedemo
   and Win95 desktop/UI acceptance, including physical FPGA evidence on the
   exact candidate bitstream.

The candidate has no gameplay measurement. Verified **simulation** baseline:
**0.497040387 total U+V IPC**, binary
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`,
cycles **1,100,065,247–2,100,065,247**; U=384,240,079, V=112,800,308.
It predates this derivative and is not FPGA or full-timedemo acceptance.
