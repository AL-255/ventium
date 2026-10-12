# Read-only instruction-fill ACK — October 12, 2026

**Private timing derivative; not FPGA-qualified.** The requirement remains
**at least 40 MHz post-synthesis Fmax**, retaining UV, the system/relocated fast
pipeline, fast memory paths and full P5 L1s. The measured parent remains
**28.88420323 MHz**, an unplaced estimate, not routed or silicon timing.
See [the measured path](PRIME_NOACK_TIMING.md#remaining-measured-paths-and-next-fixes-to-qualify).

## Change and scope

[The exact-parent recipe](../verif/l1/prepare_ic_fill_read_ack.py) changes two
read-only fill consumers from `mem_ack` to the existing `mem_read_ack`:
S_PF words 0–7 and S_PIPE miss word zero. This cuts unrelated paired-store ACK
selection from the fill-control dependency. It does not change actual ACKs,
request/translation authority, fault diversion, fragment suppression, held
ownership, flush, fill data, LRU touches, cache geometry or cycle latency.
The read ACK falls back to the original ACK without `VEN_FP_LOAD_EARLY_CMD`.
New simulation assertions check complete old/new fill-enable equality and
reject a write owner on a fill. No timing exception or guest-specific behavior.

The isolated source derives from the measured priming/same-line candidate,
not the unrelated dirty working-tree RTL. All **195 source files** and **150
UV-fast defines** are retained; only `rtl/core/core.sv` changes. The C++ harness
has a unique basename and a verified model-local generated-header dependency.
No production checkout RTL, pinned parent, bitstream or board was modified.

## Closed evidence

Root: `/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS`.

| Check | Result and scope |
| --- | --- |
| Source/admission host tests | Four pass; reject drift, repeated application, missing coverage and undetected mutants |
| `ic-fill-read-ack-leaf-r1` | Native zero, 49.65 s including both builds; **50,331,648 vectors per profile**, early-read ACK and fallback |
| Four native negative controls | All fail with exit 1: raw fragment ACK, forced ACK, lost held-owner guard, lost flush guard |
| `ic-fill-read-ack-core-r1` build | Native zero, 20.05 s; strict structural-warning classes retained |
| Cold memory matrix | 72 fixtures at AXI latency 0/7; **31,392 candidate records**, **1,500 V retirements**, full QEMU state and exact parent/candidate clocks |
| Held-read matrix | 24 fixtures, 48 latency cases; **9,200 candidate records**, **346 held primes**; complete state/cycle equality |
| FP/memory fault matrix | 16 fixtures, 32 model comparisons; **23,585 candidate records**; complete QEMU UV traces and same-input parent/candidate equality |
| Canonical `make verify` | **FAIL**, native make exit 2; all 20 complete cycle streams match the parent, no oracle/mask/band change |
| Identical-input canonical replay | Native zero, **108 programs / 80,800 records**, complete parent/candidate equality in 74.73 s; not a canonical pass |

The leaf extracts the actual frontend/request equations, full S_PIPE bus arm
and both fill arms. Its 24 Boolean guard bits are exhaustive across idle,
S_PIPE and S_PF; payload/word patterns vary deterministically. Translation and
late cancellations are abstract inputs, **not a whole-core formal proof**.
Per profile it observes 1,048,576 S_PF fills, 40,960 word-zero fills, 131,072
completions, fragment/ACK stalls, FSM diversions, flushes, held data owners and
16,384 legacy direct-bus bypass fills. These are directed-test counts, not IPC.

Independent rehashing confirms all **1,911 whole-core build input pins**,
19 memory input pins, 11 held-read input pins, and **1,920 fault input / 609
fault artifact pins** unchanged. All completed service owners have native zero.

Retained identities:

- Core source: `853bcdaaa61c25dac567774d4aeb67219af2b7367199a527a850142e4e72ecaf`.
- Model: `4f7a740c471cfe9e81ca7d6d86dbbaf00c24c5987d95ff6688ae1338d1649f02`.
- Leaf closure: `69d3e221fb59a86e1b0f0025146a718c9b36930d01cdf4b6db81d4eac99c78d6`.
- Build closure: `5a8a49e2a7d218ebb42a815ec9db1a9601e5a5ab5b9c02df24b90086bd4f20ba`.
- Memory closure: `c00ead11c85eaa4abf9f07f84d74ec8c44c2bf137a37e26b6cc4d34f89bd8cf9`.
- Held closure: `3e42003258a2faeb7bb209a74cd87bd63b05161cea2a61761040ee65bc41df52`.
- Fault closure: `d78dd6b86f0db9eff9cd5151e747dcca818bfbf02406c7003295b835bebad37d`.

## Still open

The unchanged canonical gate closes **FAIL** as
`ventium-ic-fill-verify-oct12.service`, invocation
`d4467ee172104d6687716c24f2e6b9fb`. Same-input replay closes native zero as
`ventium-ic-fill-canonical-ab-oct12.service`, invocation
`f94ce175bac34f5a83ebefe614571fd1`; receipt
`ic-fill-canonical-ab-r1/closed.json`, SHA-256
`61e4325d5299f216efb5fddbc1746337cf9faf183e412188e5a5d57d528a50a6`.
Canonical FAIL is not waived by that equivalence. No golden, field mask,
terminal trace or cycle band was changed.

Do not spend another synthesis on this fill-only change: the measured parent
also has SRT paths around **29.03 MHz** and V-capture around **29.71 MHz**.
The payload-kind proposal must be rebased/qualified for SRT. The
[guarded overlap cut](PAIR_OVERLAP_ACK_CUT.md) now has an
[exact-current rebase](../verif/l1/prepare_pair_overlap_current.py), preserving
the existing same-line ACK fix. Three host tests establish source composition
and byte-identical old proof equations, not full-cache acceptance.

The latest mapped V-capture path still traverses general ACK into bank
readiness. Two LUTs along it (`owner_q[1][15]_i_15`, INIT
`64'hEEEEEE0EEEEEEEEE`, and `_i_10`, INIT `64'h0000F20000000000`)
suggest contradictory request qualification. Rebuilt-hierarchy aliases alone
are **not a proof of a false path** and do not justify a timing exception.
The safe proposal removes ACK only under the already-proved read ownership
and idle/non-stream/non-flush/non-snoop guards, not from store acceptance.

The first native overlap-cache run fails because its new fixture incorrectly
assumes a completed warm read leaves a live one-cycle response owner. This is
not an old/new cache mismatch. Its generated source/logs remain in
`pair-overlap-current-cache-r1`; service invocation
`7ea21c02c1dd419ab07291cca6255952` closes with exit 1.

The corrected fixture creates an actual registered response through public
requests, checks unmatched/matched ownership in that response's live cycle,
then captures two independent paired responses and backpressures/drains them.
No DUT state is forced and the candidate RTL is unchanged. A public flush
isolates this addition from the original store/coherence/same-line corpus.
Both FF-primary and LUT-primary/shadow variants close native zero; a compiled
mutant dropping read-owner matching exits 1. Each positive observes three
overlap checks, two returned owners and three held-response cycles, alongside
the retained historical corpus and full old/new cache miter.

Owner `ventium-pair-overlap-current-cache-r2-oct12.service`, invocation
`a5d89ba6fb814021a108b3630742474c`, closes zero in **14.25 s** including builds.
Receipt `pair-overlap-current-cache-r2/closed.json`, SHA-256
`6ec6e60ed910d62a4c4c0c36011337ba162562cfd6cbd1d1b390e1dfae689787`.
These are cache tests, not combined-core or timing acceptance. The subsequent
combined candidate is described in [PAYLOAD_CURRENT_TIMING.md](PAYLOAD_CURRENT_TIMING.md).

Canonical correctness, original full CoreMark seeds, cold Win95 desktop/UI,
full original Quake timedemo, synthesized timing and actual candidate FPGA
verification remain required. No current-candidate gameplay measurement exists.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This predates
both changes and is neither measured board IPC nor a full-timedemo average.
