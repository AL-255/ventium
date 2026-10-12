# Priming ACK dependency: 40 MHz timing candidate

This is an **unqualified timing candidate**, not a frequency or performance
result. The latest measured combined parent is **28.88838 MHz** (unplaced,
`logic_only` synthesis); the requirement remains **at least 40 MHz** with UV,
system/relocated fast execution, fast loads/stores and full P5 L1s enabled.
See [the measured path](MC_PAIR_SRT_TIMING.md#closed-timing-audit-regression-critical-path-moved-to-cache-control).

## Change and rationale

The measured EIP-to-cache-LRU path crosses general cache ACK, `pipe_mem_wait`
and next-read commit. Integer read-commit already has a request-specific
qualifier, but AGI/reference priming still consumes the shared FP live permit
and therefore inherits the unrelated integer-memory ACK cone.

[`prepare_prime_noack.py`](../verif/l1/prepare_prime_noack.py) creates a private
three-file derivative. It **keeps the shared `pipe_fp_live_arm` unchanged** and
gives only AGI/reference priming a separate permit:

- Keep the FSM, pending-event, frontend, outstanding-owner and stall guards.
- Replace its `!pipe_mem_wait` term with `pipe_agi || fp_sys_bail`.
- Preserve every remaining selector, address/permission check, hazard, poison
  and commit guard. Do not change architectural ACK, retirement or latency.

Why this is safe to test: new integer loads/stores require both `!pipe_agi`
and `!fp_sys_bail`. AGI priming requires AGI; reference priming requires a
nonsimple descriptor (including x87, whose actual fast decoder produces a
nonsimple descriptor). Both selectors reject an outstanding memory packet.
Thus a real priming offer cannot have an integer-memory wait, independent of
ACK. The candidate also carries live old/new commit and no-memory-owner
assertions in the complete core.

Do **not** substitute the FP-only `!is_mem && !is_store` permit: ordinary
integer loads are precisely what AGI priming is meant to prepare. A previous
global substitution suppressed those primes and regressed CoreMark.

The whole-core derivative also retains the separately qualified
[same-line ACK cut](PAIR_NOW_ACK_CUT.md). It adds no instruction-specific
workaround, saved-state dependency, feature switch, cache reduction or bubble.

## Verification procedure and limits

1. `test_prime_noack.py`: six host tests check exact source/guard changes,
   drift/reapplication rejection, extraction, native-proof admission and cold
   adapter contracts. These are not RTL execution results.
2. `run_prime_noack_leaf.py`: compile the **actual fast decoder** and extracted
   original/candidate priming equations under the 150-definition core profile
   plus leaf-only `VTM_NO_DPI`. Check opcode/ModRM combinations, all x87 SIBs,
   owner/frontend/event/ACK combinations and boundary/permission/rejection
   cases. Reference-dispatch inputs are independent leaf inputs; this does not
   instantiate its full decoder. Three runtime predicate-injection negatives
   must fail: FP-only gating, ACK-dependent priming and removed FSM guarding.
3. `build_prime_noack_core.py`: admit only a closed native leaf result, verify
   all 195 frozen source files, preserve all 150 core defines and use a unique
   C++ harness with verified local generated-header dependency.
4. `run_prime_noack_system.py`: reuse the original cold AGI/reference fixtures
   with identical enabled profiles. Each smoke matrix has 20 fixtures, flat
   and relocated paging, AXI latency 0/7, positive and excluded forms. Require
   full QEMU architectural comparisons, identical complete A/B state and cycle
   streams, unchanged real priming counts and actual paired V execution.
   This is explicitly not the original 300-case boundary matrix.
5. Rerun memory/store/FP/held/fault checks and the unchanged canonical gate.
   Equivalence with a failing predecessor never converts canonical FAIL to PASS.
6. `build_prime_noack_soc.py`: copy only the four combined changes into the
   unchanged PC platform; verify all 102 shared core/FP sources, 154 defines,
   posted-16 transport and the private harness. Both short CoreMark seed
   diagnostics must retain their original CRCs and 4,767,218 / 4,753,406 ticks.
   These diagnostics are not duration-valid scores or full correctness seeds.
7. Only after those checks, export source-matched FPGA inputs and measure
   synthesis under the real 40 MHz constraints. An unplaced diagnostic result
   is neither routed timing closure nor physical-board qualification.

[`freeze_prime_noack_rk_candidate.py`](freeze_prime_noack_rk_candidate.py)
prepares that export using the existing **balanced / Default timing-driven**
profile, not the diagnostic `-no_timing_driven` mapper. It preserves the actual
40/100 MHz clock requests, 156 hardware definitions, 190 payloads and posted-16
transport. Three host tests check all four exact recipe outputs, drift and
reapplication rejection, and Tcl expansion without the diagnostic synthesis
option. The first Tcl test lacked the frozen upstream flow in its disposable
fixture; copying that unchanged input fixes the test, not the production flow.
The exporter has not published inputs yet. Future synthesis must retain the
single-family resource monitor and reserves; the timing-driven profile previously
had excessive optimization memory growth. A frequency difference across mapper
profiles cannot be presented as an isolated RTL improvement.

All generated work uses `/home/yukidama/external/tmp`, with the exclusive
guarded-32 compiler profile and no concurrent Vivado family.

## October 12 native results

Evidence root: `/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS`.

The leaf closes native zero in **10.59 seconds**, including compilation:
**6,103,040 samples**, 167,232 actual x87 descriptors, 22,913 AGI accepts,
325,749 integer-reference accepts, 1,376,125 abstract x87-reference accepts,
879,793 ACK-low accepts and 393,216 each of held-owner / blocked-FSM rejection
samples. All three injected negatives fail natively with `PRIME_EQUIV`.
Owner `ventium-prime-noack-leaf-r3-oct12.service`, invocation
`508decc103954b7b9411e1f17aea4d7b`; receipt `prime-noack-leaf-r3/closed.json`,
SHA-256 `ea81001df15e2e41254152d511f4e543f276af237284926ca3884ff0f7cb5c12`.
The first launch rejected missing guard CLI syntax before executing the driver.
The second was stopped while waiting, before any generated output, after a host
test caught an overly broad extractor check; the corrected six host tests pass.
Neither attempt is counted as native verification.

The complete core builds in **19.82 seconds**, retaining 195 files / 150
definitions, with a verified private harness dependency. Only the three priming
files differ from the already-qualified same-line ACK model. Owner
`ventium-prime-noack-core-oct12.service`, invocation
`982683fef75a482296f7a84549e4bab7`; model SHA-256
`e6d2b404b1613b200d673075d4d1b325c3e1c681db4e81516e038dfdef4d5c46`.
Build receipt `prime-noack/core-r1/build-closed.json`, SHA-256
`8294b57cfd6e8efdfb20b8f2840145c005088b91dd7a954e24d0e1a7b6d26b7f`.

Both cold priming matrices close native zero, with 16 workers each:

| Corpus | Fixtures | Candidate state records | Prime observations | Paired V retirements |
| --- | ---: | ---: | ---: | ---: |
| AGI | 20 | 36,960 | 12,096 | 2,560 |
| Reference | 20 | 26,712 | 13,888 | 2,560 |

Prime observations count both the architectural and cycle runs. Each model is
checked at AXI latency 0/7. Full QEMU state comparisons pass; complete A/B state
and cycle hashes, paid AGI counts and priming counts remain identical. These
are no-regression results, **not an IPC improvement**. Receipts are under
`prime-noack/{agi,ref}-r1/`; owners `ventium-prime-noack-{agi,ref}-oct12.service`,
invocations `29c6ccf769d040289a928b331743f2a6` /
`c448c381c3cc4c9c9f0b95e10a89bd63`.

The memory/store/FP/held matrices also close native zero, with 32 total workers
(4/4/16/8). Their complete state/cycle comparisons cover **111,728 additional
candidate architectural records**: 31,392 memory, 32,112 store, 39,024 FP and
9,200 held-read records. All six matrices' source pins independently rehash.
The memory/store/FP cases retain 1,500 / 456 / 144 paired V events respectively;
the held matrix retains 346 held-read primes. The three former matrices have
72 fixtures each; held-read has 24. Native runtimes are 22.69 / 22.68 / 28.09
seconds for memory/store/FP, not guest timings.

The source-matched PC derivative closes native zero in **24.74 seconds**.
Its complete 102-source intersection matches the new core, with four exact
changes from the measured combined PC parent and no define or transport changes.
The parent's 98 full-platform structural warnings remain unchanged, not waived
as new correctness evidence. All 621 started input pins independently rehash.
Owner `ventium-prime-noack-soc-oct12.service`, invocation
`7e1710c461e8446b96cc6189549dd253`; model SHA-256:
`d8c147fe0b1b1bc91c4c9e861298fae66cfee012a926532d02227d2d6469b1aa`.
Receipt `prime-noack/soc-r1/build-closed.json`, SHA-256
`bdf93ec634e84ec8a63b585b82e1008f7a19393036ae3b88db5ee7190e70a1db`.

Canonical verification closes **FAIL: 7 PASS / 101 FAIL**, native make exit 2
and controller exit 1, in 375.53 seconds. All 20 complete parent/candidate cycle
streams match; all 1,700 input pins independently rehash. Owner
`ventium-prime-noack-verify-oct12.service`, invocation
`0f3e0d9931344dd68709ccb88801a36a`. It starts with a byte-identical copy of the
parent's 128 content-keyed original QEMU goldens, then generates 56 new cache
entries as required by the normal keys. It does not use the experimental
pre-exit observer. No oracle state, mask or cycle band is modified.

The subsequent identical-input replay closes native zero: **all 108 programs /
80,800 complete records** match the parent, and the candidate reproduces its
original full traces. It takes 77.39 seconds; all 552 inputs independently
rehash. Owner `ventium-prime-noack-same-input-oct12.service`, invocation
`c120e7e313e6420fb5f36f55b04cbdff`. Receipt SHA-256:
`f0201acdb9ef6879a2c1ab8adbf9712b041d77646ebe4972714578a58e58aa34`.
This is A/B nonregression evidence, **not a canonical pass**.

Both short CoreMark diagnostic seeds are now running sequentially on the new
PC model, with the actual child pinned to CPU 11. Unit
`ventium-v-carry-cm10-prime-noack-oct12.service`, invocation
`58f6ed8b5d3a469b8b1d2bb1bff77839`. The unchanged 16-fixture fault matrix is
running separately on CPU 12 under the shared guarded scope:
`ventium-prime-noack-fault-oct12.service`, invocation
`b89a84004704420bb34b8475560daabd`. These live runs are not counted as passes.
No new FPGA inputs have been published and no synthesis or deployment has begun.

Disk cleanup removes **12 closed compiler PCH caches (1,035,149,312 allocated
bytes)** after exact owner/hash/open-file and pin checks. Binaries, sources,
headers, generated C++, objects, traces, media, logs and DCPs are retained and
rehashed. Those caches require regeneration, not byte-identical restoration.
Exact targets remain in `closed-prime-pch-{plan,closed}.json`. The first cleanup
attempt rejected an incorrect binary basename before deleting anything.

Canonical correctness, original full CoreMark seeds, cold Win95 desktop/UI,
full original Quake timedemo and actual candidate FPGA validation remain
required. No current candidate gameplay measurement exists.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates
this timing candidate and is not physical-board or full-timedemo mean IPC.
