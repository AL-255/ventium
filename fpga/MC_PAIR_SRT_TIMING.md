# Combined divider normalization and paired-response timing cut

**Private candidate; synthesized estimate 28.88838 MHz, below target and not FPGA-qualified.** Target remains
at least **40 MHz synthesized Fmax**, with UV, relocated/system fast pipes,
fast loads/stores and full P5 L1 caches unchanged.

## Why these two changes

The closed [read-hint candidate](MC_READ_COMMIT.md) measures **29.58405 MHz**,
below the best retained **30.34809 MHz** readiness candidate. Its 30 reported
worst paths all end in SRT input state. A separate paired-response capture
report limits that path to **30.43955 MHz**. Both need attention; fixing only
the divider cannot establish 40 MHz.

Existing full-clock setup reports, without another Vivado launch, partition
the worst 33.591 ns data path as follows. These are segments between named
netlist markers, **not RTL-module ownership or physically routed delays**:

| Through marker | Segment delay | Cumulative data delay |
| --- | ---: | ---: |
| Decode `d_len[0]` | 12.457 ns | 12.457 ns |
| `seg_access_fault` | 6.869 ns | 19.326 ns |
| L1 read data | 3.313 ns | 22.639 ns |
| FP operand selection | 5.721 ns | 28.360 ns |
| SRT exponent register | 5.231 ns | 33.591 ns |

Report: `ventium-mc-read-commit.PNi1O0xm/clock-r2/core_setup_unplaced_estimate.rpt`
under `/home/yukidama/external/tmp`, SHA-256
`39a740afd622e3aae83951d4f1de03e39162614cc7b7942644c64f7bd6ebf4a2`.
[`analyze_setup_paths.py`](analyze_setup_paths.py) verifies continuous data-path
rows, matching endpoint clocks and a single-period requirement before deriving
the frequency. The 40 MHz constraint itself is not a performance result.

## Exact integration

[`build_mc_timing_pair_srt_core.py`](../verif/srt/build_mc_timing_pair_srt_core.py)
derives from measured read-hint model
`64dadfc92c708c49d45e8c0f3b7704e1c24dff48f8d525956dc4624946a07695`.
It retains all **195 source files / 150 simulator definitions**, changing only:

1. `rtl/fpu/fpu_srt_div.sv`: the existing
   [balanced input-normalization recipe](SRT_INPUT_NORMALIZATION.md). Its exact
   source parent is present in the measured image; the tested replacement was
   absent. Three serial first-one searches become six-decision searches.
   Zero/no-known-one keeps shift zero, including the original X/Z behavior.
   No state, control, rounding behavior, FDIV-bug behavior or clock count changes.
2. `rtl/core/core.sv`: the existing
   [paired-response read-commit recipe](PAIR_RESPONSE_READ_COMMIT.md). Only the
   raw-prime/no-dual-prime consumer uses a read-only commit predicate. It retains
   fragment-qualified ACK, orphan draining and all architectural commit guards.
   Other profiles keep their old equation; live owner/equality assertions remain.

Both recipes reject source drift and reapplication. Each generated file must
equal its independently tested leaf artifact byte-for-byte. Neither change
disables UV or fast execution, adds an execution cycle, changes a cache size,
introduces a timing exception or recognizes a particular guest.

## Evidence and current state

Evidence root: `/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS`.

Before integration, the previous exact-source evidence was rehashed rather
than described as a new run: **378,852 helper comparisons** (16,514 four-state),
**4,544 actual SRT operations / 162,282 cycle comparisons / 24 resets**, and
**77,834 source-extracted paired-response clocks**, plus their negative tests
and the abstract ownership proof. Those tests do not instantiate this combined
processor, and their equivalence oracles are not independent numeric oracles.

Six new builder/admission tests pass, as do the three existing normalization
recipe/proof tests against the measured image's exact SRT file. An initial
host-test invocation omitted its required `SRT_INPUT_PARENT` environment
variable and failed; the corrected invocation passes without a source change.

The private whole-core build closes native zero in **19.40 seconds**, under
the exclusive guarded-32 profile after actual Vivado closure. Outer owner:
`ventium-mc-pair-srt-core-oct12.service`, invocation
`c12e1d9ce57142f2b4780a3e36b81a91`. Preparation checks the retained clock owner,
native exits, source closure and both mutation-test receipts. The actual nested
build invocation is `d9be8d02b92e4935b5b9e5922f8ddc38`. The unique local C++
object's dependency names this model's generated header; all started input pins
independently rehash unchanged. Model SHA-256:
`eefa9d57c41c5eb5154d0319fb2e82240f90469b7ce119ae0abe36d6aada9702`.
Build receipt: `bc6ae1644f1990694540a8e60b4857bb22c8f8d5ea20e5fe154daf78dc914e37`.

The **actual combined model** passes the following cold whole-core comparisons,
including complete QEMU state and identical parent/candidate cycle streams at
AXI latency 0/7. No golden, C1 mask, terminal record or cycle band changes:

| Corpus | Cases | Candidate architectural records | Observed execution |
| --- | ---: | ---: | --- |
| Paired reads/read-ALU and rejection | 72 | 31,392 | 1,500 memory V retirements |
| Load/store pairs and readback | 72 | 32,112 | 456 memory V retirements |
| FP/integer/memory overlap | 72 | 39,024 | 144 paired V events; 7,220 early FP accepts |
| #NM TS/EM and architectural debug | 2 | 7,244 | 8 model/latency comparisons |

All four native owners are terminal zero and their input pins independently
rehash unchanged. The FP matrix serializes its QEMU port-selection/launch while
retaining 32 RTL workers; its 21.61-second runtime is a host duration, not guest
speed. Memory/store take 19.11/19.62 seconds and debug takes 9.28 seconds.
Receipts are respectively `memory-r1`, `store-r1`, `fp-r1/matrix`, `debug-r1`.
These checks establish no observed cycle-count change, not a gameplay IPC gain.

The aligned FP fault/fragment matrix subsequently closes **PASS: 16 fixtures /
32 model comparisons / 23,585 candidate architectural records**. Every original
gate and additional complete UV comparison exits zero; full parent/candidate
architectural records match. It covers aligned split-page retry, EM/TS priority,
pending FP owners and DS/SS relocation, **not all unaligned/reset scenarios**.
All source pins and generated artifacts independently rehash unchanged. Outer
owner `c16be5915aa746758fb32b99d657d204` is terminal zero; actual guarded invocation
is `743bb02c0d5547f2862a7339da216d0b`, with measured affinity CPU 12. Receipt:
`fe64637f0adf225cddffa38b7074bbcc0670568d22221edbd7d65fc4f7202e72`.

The unchanged canonical gate closes **FAIL**, native `make` exit 2 and
controller exit 1: **7 PASS / 101 FAIL** functional programs. The independent
inventory finds 101 length mismatches, including 10 programs with field
mismatches. These failures are retained, not waived by A/B equivalence. All
**20 complete parent/candidate cycle streams match**. The 645.69-second
controller duration includes waiting for the shared build lock; the canonical
parallel phase takes 367.6 seconds with one effective worker. Canonical owner:
`ventium-mc-pair-srt-verify-oct12.service`, invocation
`dd3e24bdc74b4efdb6f91ff8c2740da4`.

Separate canonical invocations have different QEMU initial stack addresses:
only one of their 108 complete RTL streams is identical. The subsequent
**same-input replay passes all 108 programs / 80,800 records**, reproducing
each candidate trace and the parent trace completely in 75.56 seconds. Native
owner `ventium-mc-pair-srt-same-input-oct12.service`, invocation
`4faddb219f7c4b0f8bccf6a66b7a0836`, is terminal zero. Its receipt explicitly says
`same_input_regression_passed: true`, **not** canonical correctness PASS.

[`build_mc_pair_srt_soc.py`](build_mc_pair_srt_soc.py) prepares the full-PC
derivative, preserving the posted-16 transport and 154 simulator definitions.
All **102 shared core/FP inputs** match the directed model, with exactly these
two changes relative to the measured read-hint PC. Its actual build now closes
native zero in **22.35 seconds**, preserving the parent's 98 platform structural
warnings without introducing another one. The private harness dependency names
this model's generated header; all inputs rehash unchanged. Model SHA-256:
`8277a36e4fc3e85411bbd1e82f9bccc900bceabb78f1779da5f29786014f759d`.
Owner `ventium-mc-pair-srt-soc-oct12.service`, invocation
`55a63ccd1a464b0b9b286a6f8b8e3e02`.

The first PC continuation fails after the successful replay because it reads
the nonexistent generic `passed` field. Its dependent export queue correctly
stops, rather than claiming completion. Both failed owners and original logs
are preserved. [`resume_mc_pair_srt_checks.py`](resume_mc_pair_srt_checks.py)
checks those terminal owners, reads the actual producer schema, rehashes the
retained evidence and resumes without rerunning the completed checks. Three
host tests cover the schema bug and rejection of incomplete, failed, changed or
waived results. Resume owner `ventium-mc-pair-srt-resume-r2-oct12.service`,
invocation `c14df51299514da5a6d0c8cd89748e67`.

Both unchanged ten-iteration CoreMark diagnostic seeds close native zero under
`ventium-v-carry-cm10-mc-pair-srt-oct12.service`, invocation
`4655a024d9b241f28e7c5d9173c23ce0`, explicitly pinned to CPU 11:

| Diagnostic seed | Expected data CRCs, all matched | TSC ticks, unchanged from parent | Native seconds |
| --- | --- | ---: | ---: |
| Performance | `e9f5 e714 1fd7 8e3a fcaf` | 4,767,218 | 196.12 |
| Validation | `18f2 e3c1 0747 8d84 c64e` | 4,753,406 | 197.72 |

The independent CRC/source/actual-owner audit passes and all 643 started pins
and 15 audit artifact pins independently rehash unchanged. Audit SHA-256:
`b3b8771cda70da05e807f19b76952ab2a7c32a17f610ae62359310eb318946cc`.
These are **not duration-valid scores or full-suite acceptance**; the short-run
duration error is expected and the checker still requires every expected CRC.
The resumed queue itself closes native zero, with no synthesis or deployment.

[`freeze_mc_pair_srt_rk_candidate.py`](freeze_mc_pair_srt_rk_candidate.py)
requires the actual compiled source closure, exact two tested transformations,
190 retained payloads, 156 hardware definitions and unchanged 40/100 MHz clocks.
Its three host recipe/guard tests pass. The actual export also closes native
zero, invocation `03bfc938250f4a6bb5c2121c29f9bccc`; all 801 input pins and 190
published payloads independently rehash. Frozen manifest SHA-256:
`43e940607586e889fe85185d4a12effcc083a1f92b32b7130fc0704304fe48b7`.
Strict frozen **CPU** lint closes native zero in 3.73 seconds, invocation
`8023f209950f479d92e2325a9ff6e0f6`. This is not full-platform lint or acceptance.

The separate [timing-controller derivation](prepare_mc_pair_srt_timing.py)
preserves the closed parent's entire native monitor/stop/reap lifecycle and
resource reserves, and compares against that parent's original DCP and clock
constraints. Four host tests check the exact delta/parent, guard preservation,
source-anchor drift rejection and invalid invocation rejection.

At **00:41:39 UTC on October 12**, the actual Vivado family is admitted and
observed running, not just queued. Synthesis controller:
`ventium-mc-pair-srt-synth-oct12.service`, invocation
`e84c6c6849f149b0a9b8a21c06f6e685`; guarded scope invocation
`98bc42826fc44a6786fca6c0975ca6f7`. The native caps are 8 GiB RAM, 6 GiB swap,
48 tasks, with 13 GiB combined early stop and existing host/disk reserves.
One matched `logic_only` synthesis is followed by original-clock checkpoint
reporting and independent audits, **not placement, routing or deployment**.
Queue `ventium-mc-pair-srt-timing-queue-oct12.service`, invocation
`cc78495efc6d41229c3f285d9223b767`, observes actual child closure. This mapper
profile preserves `-no_timing_driven` for a comparable structural measurement;
the clock constraint alone is not evidence of achieving 40 MHz. Preparation receipt:
`425b430cf9b6b6075d3310984ee7f8a503b9fb46a1f0f9001b37ba22cffd9481`.

Disk admission was below the original synthesis reserve. A closed-artifact
cleanup reclaims **1,418,747,904 allocated bytes (1.32 GiB)**: 814 verified
backups containing only generated compiler intermediates, one archived cache
from the terminated October 9 Vivado run, and this closed PC build's two PCHs.
Retained binaries/headers/build metadata and the failed synthesis's frozen
source payloads independently rehash unchanged. No useful DCP, trace, source,
media, binary or log is removed. Old archive-extraction recovery instructions
are superseded: those caches now require regeneration. Exact targets and hashes
remain in `obsolete-compiler-backup-{plan,closed}.json` and
`closed-native-cache-{plan,closed}.json` in the evidence root. The synthesis
growth-derived disk requirement and 4 GiB emergency reserve are unchanged.

### Synthesis closure

The actual synthesis owner closes native zero at **2026-10-12 01:14:44 UTC**,
after **1,988.98 seconds**, with no resource stop or OOM. Independent audit
checks 2,777 source pins and the two intended changed payloads. Compared with
the measured MC parent, utilization is **183,770 LUTs (-291), 54,644 registers
(+34), 277.5 BRAM tiles (unchanged), 47 DSPs (unchanged)**. Synthesis reports
zero errors, one critical warning and 1,558 warnings; the critical warning is
the generated PS XDC attempting to constrain an unknown clock pin. The pending
clock audit must independently establish the actual core/PL clocks; synthesis
success alone does not resolve clock coverage or establish Fmax.

Synthesis DCP SHA-256:
`edeeb26299d0cb2b85e71a1567e09440e566726e544d0c4c084a520d28a93ffd`.
Independent audit: `synthesis/audit.json`, SHA-256
`95100e2dd38e295531657fb31cbad324ca8c747874904786e6f1ee14808b2330`.
The existing continuation has launched original-clock reporting as
`ventium-mc-pair-srt-clock-oct12.service`, invocation
`e28134f278734c45bd674ab6af9a63de`.

### Closed timing audit: regression; critical path moved to cache control

The original-clock report closes native zero in **486.75 seconds**. The
independent audit passes and checks 1,050 retained input pins, actual 40/100 MHz
clocks, native reports and DCP identities. **Fmax is 28.88838 MHz**, from
**-9.616 ns** setup slack at 25 ns; hold is -0.101 ns. This regresses from the
MC parent's 29.58405 MHz and remains below the best retained 30.34809 MHz.
The small area saving is not timing success. Audit SHA-256:
`362cbfcfdca12395a1bc871fee416564facd09e870462cf51be8a5549c30345e`.
Both controllers and their queue are terminal zero; the queue explicitly
records `synthesized_40mhz_requirement_met=false` and `qualification=UNQUALIFIED`.

The 30 worst setup paths now contain **29 cache-LRU data endpoints and one
GPR endpoint**, rather than SRT endpoints. Worst: `eip[0] -> dc_lru[16]/D`,
118 logic levels, **34.405 ns data delay = 6.617 ns logic + 27.788 ns estimated
routing**. Named-marker segments from the full-clock report are:

| Through marker | Cumulative data delay |
| --- | ---: |
| V decode length | 12.021 ns |
| Next-read preparation | 22.311 ns |
| Next-read request | 24.534 ns |
| Paired-store readiness | 25.080 ns |
| General cache ACK | 30.235 ns |
| Next-read commit | 31.407 ns |
| Cache LRU endpoint | 34.405 ns |

These are netlist markers, not module area ownership or physical route delays.
Report SHA-256:
`66178a98d89711f3dd806c6665fcedaafcbf3683251d1fed979c2a11ef4c41c8`.
The separate V-response capture path is **29.76102 MHz**, 115 levels; it
likewise traverses paired-store/backing ACK into paired-bank readiness.

Source inspection identifies the already-tested, not-yet-integrated
[same-line return ACK cut](PAIR_NOW_ACK_CUT.md), whose exact L1 parent is still
present here. Its saved-window predicates already imply read ACK. Its
whole-core derivative is now queued behind the real-cache payload-hint gate,
under the same exclusive guarded-32 lock. Owner:
`ventium-mc-pair-srt-pair-now-core-oct12.service`, invocation
`6f1d5f1c060449b4aa9c089d15973eb0`; output `pair-now-core-r1/`.
This is **not another synthesis launch**. The unrelated generic-overlap draft
is still excluded, because its target integration excludes lane-1-only requests.

The LRU path also retains `pipe_mem_wait` through AGI/reference priming's shared
`pipe_fp_live_arm`, although the previous change only cofactors integer
next-read commit. This is a separate candidate dependency to prove, not yet an
implemented fix. Do not reuse the previously rejected global FP-only permit:
AGI legitimately primes integer-memory descriptors. The prepared payload-kind
whole-core build is deferred: it does not address the newly measured worst
cache-control path. Its independently queued cache test may still qualify the
payload change, but that alone cannot justify another synthesis.

Canonical verification remains **FAIL**, not waived by the component checks.
Complete differential/cycle gate closure, both original CoreMark correctness
seeds, Win95 cold desktop/UI, full Quake timedemo and physical FPGA validation
remain required. No new frequency or performance gain is claimed.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates
this combined candidate, which has no gameplay measurement.
