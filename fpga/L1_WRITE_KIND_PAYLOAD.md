# Backing write-direction payload experiment — 2026-10-11 UTC

**Private candidate: 24.33504 MHz unplaced synthesized estimate, not qualified.**
The objective remains **at least 40 MHz synthesized Fmax with UV dual issue,
system/relocated fast pipeline and fast memory enabled**. The best retained
prior unplaced estimate is 23.58546 MHz; the immediate read-ACK parent is
23.50176 MHz. This candidate is now the fastest measured diagnostic netlist,
but remains below the 40 MHz requirement.

## Critical-path change

The read-ACK parent's worst path runs through next-read decode/address/lookup,
paired-store readiness, backing alias/credit checking, ACK, next-read commit
and L1 LRU update. Its data delay is 42.339 ns (148 logic levels), including
32.906 ns estimated unplaced routing. This experiment cuts one dependency;
it does not claim to solve the entire path.

In the L1 load-U/store-V backing branch, the only possible transaction is V's
write. The old code derives both request and write direction from late pair
readiness:

```systemverilog
m_req = c_pair_req && c_pair_ready;
m_we  = m_req;
```

The candidate prepares `m_we = 1'b1` in that branch, leaving `m_req` unchanged.
This removes pair readiness from ahead of the AXI master's extent arithmetic.
For every active request, the old direction is already 1. Only idle direction
can differ. All address, data, strobe, request, ACK, ownership and state-update
equations remain unchanged; no pipeline stage, serialization or define changes.
The master's direction-dependent state changes and alias-error latch remain
request-qualified. Pending AXI responses are not canceled by the idle payload.

[The guarded recipe](../verif/l1/prepare_l1_write_kind_payload.py) makes exactly
this one reversible edit in `rtl/mem/ven_l1d.sv`. Production checkout RTL is
untouched; the candidate derives from the frozen read-ACK inputs, not arbitrary
dirty worktree files. It does not include the rejected next-query experiment.

## Verification

Evidence root: `/home/yukidama/external/tmp/ventium-l1-write-kind.sxvBsfBb`.

- Four recipe tests pass. The actual source-extracted backing blocks compare
  16,384 samples: 4,608 active requests agree, and 384 idle direction differences
  are observed. Every other interface bit agrees. Deliberately clearing active
  write direction fails the negative control with native exit 1.
- The private full-core build retains all 150 RTL defines and a separately
  compiled harness using its own generated class header. Only L1 changes.
- [The cold paged load/store matrix](../verif/l1/run_l1_write_kind_system.py)
  adds 72 cases across relocation, six instruction offsets and AXI delays 0/7.
  Post-loop ordinary loads observe the stored values. Same-line and other-line
  load/store shapes each produce 228 actual V-store retirements. Bank-conflict,
  alias and split-line forms must not pair.
- Together with 72 memory, 72 FP and 12 AGI cases, the independent
  [auditor](../verif/l1/audit_l1_write_kind.py) rereads **228 cases and 107,304
  candidate architectural records**. Complete original-QEMU comparisons and
  full parent/candidate architectural and cycle streams agree. It also checks
  1,500 targeted V-load retirements, 350 AGI accepts, native exits, retained
  owners, actual feature profiles and source hashes. Nothing is truncated.

The auditor's first attempt incorrectly expected the default build-scope name;
the build actually used the configured `ventium-ipc-parallel32.scope`. The
corrected check matches the retained service configuration and exact scope
invocation's journal closure. No simulator result or RTL was changed to pass it.

Audit SHA: `ce1c327b836ab554873cf356234f3cd4ebbcee48f8263e79b6c89d795617620a`.
Full-core model: `1bfb1bb2f6179ba13384cfdd3f4ded7ac5742108ef21add23e6da1f301286e8c`.
L1 source: `279590e09f07f0dfb7b588143678d750371d80356e71517da54c7c7a14139989`.

### Canonical gate still fails

The unchanged canonical gate closes with native make exit **2**, not a pass:
7/108 functional passes, 91 length-only failures and 10 first-field C1
differences accompanied by length failures. The retained failure inventory
checks all 108 traces (80,800 records); only one independent-input functional
parent/candidate stream is identical. All 20 complete same-input parent/candidate
RTL cycle streams remain identical. No golden,
comparator, terminal record, C1 mask or cycle band is changed. Directed A/B
equivalence does not repair the pre-existing canonical failures or establish
whole-processor correctness. The reset and fault sweeps of the older read-ACK
candidate are not claimed as new tests of this candidate.

## Full-PC and synthesis preparation

The full-PC model builds in 15.25 seconds, native exit 0:
`fb0631c5cf5f03d5439baa71b9b14a4eb9b5801c1f00f4a4c694fee0ebbb254d`.
All 102 shared directed RTL files match; 154 simulator defines, posted-16
transport and 98 inherited SoC structural warnings are unchanged. This is
not a full-SoC lint pass.

The source exporter preserves 190 payloads, all 156 hardware defines, full P5
L1 geometry and the 117-unit/49-include source closure. Only L1 changes from
the immediate parent. Four exporter tests pass; an independent check rereads
52,189 input pins. Strict CPU-hierarchy lint of this exact export passes.
Export manifest:
`bc49f682f794c2f5d5faf7cf4635b2c6a2cc5d4202988d55f7c1cf1e10483ae3`.

The initial export invocation used the external symlink spelling; the strict
path checker rejected it before copying. Reinvoking with canonical resolved
paths succeeds without weakening the path checks.

Both original short (10-iteration) cold CoreMark disks now pass:

| Seed | Parent cycles | Candidate cycles | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

Original data CRCs match QEMU; this is **0% cycle-throughput change**, not a
duration-valid score or the standard suite's long correctness seeds. The
independent auditor checks 52,029 source pins, native CPU-11 affinity, original
ROM/media, real posted-16 AXI activity, clean native closure and no OOM.
Audit SHA: `eeb64e832717dd4efbd7856e2a48809230f58c053f6655d50a319ed0d7ecf4a6`.

Matched diagnostic synthesis starts **02:02:59 UTC**, controller
`ventium-l1-write-kind-full-synth-oct11.service`, invocation
`a7acd105b3d644fdb192a00b9c0a5367`. The actual exclusive Vivado scope is observed
live, invocation `1fae2af284c3421780e0272459b1029e`, with 8 GiB RAM / 6 GiB swap
limits and a 30-minute native cap. Disk admission requires over 6 GiB and
twice the immediate parent's measured 1,235,304,448-byte growth above a 4 GiB
stop floor. Host memory and swap reserves remain enforced.

The queued audit, invocation `3098cb636c5442d2bdefd0edfa88cab6`, checks that
exact synthesis closure before measuring original 40/100 MHz clock timing.
The timing comparison retains the faster carry parent as its reference.
It never retries a failed synthesis or starts placement/routing/deployment.
Synthesis closes natively with exit 0 after **1,009.58 seconds**, with no OOM
or resource stop. The independent source/area audit checks 52,405 input pins
and confirms the single L1 payload delta:

| Resource | Immediate read-ACK parent | Write-direction candidate |
| --- | ---: | ---: |
| CLB LUTs | 197,169 | 196,749 |
| Registers | 54,631 | 54,605 |
| BRAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |

The native clock audit closes with exit 0 after **244.44 seconds**, invocation
`9531e1f26ca541048b38c2cfd2eaa60f`, with original 40/100 MHz constraints,
zero structural errors/black boxes and no OOM. It compares both synthesized
netlists under the same diagnostic `-no_timing_driven` flow:

| Timing metric | Best previous carry parent | Write-direction candidate |
| --- | ---: | ---: |
| Unplaced synthesized Fmax estimate | 23.58546 MHz | **24.33504 MHz** |
| Setup slack at 25 ns | -17.399 ns | -16.093 ns |
| Worst path logic levels | 146 | 143 |

This is **+3.18%** over the previous best, or **+3.55%** over the immediate
read-ACK parent; it is not a routed or measured-board frequency. The new worst
path starts at `q_pc[0]`, passes through address/translation/fragment shaping
and FP operand conversion, and ends at the shared SRT divider's `qacc` clock
enable. All 30 reported worst endpoints are in that accumulator bank.
Its 40.796 ns data path contains 9.238 ns logic and 31.558 ns estimated routing.
The dominant reported endpoint is no longer the L1 LRU update.

The first timing receipt hashed its own redirected stdout before printing its
final result. A subsequent hash check detects that one mismatch; it is not
silently ignored. `clock/audit_closed_r2.py` preserves the first receipt,
verifies that the formerly empty log contains exactly the first audit's
summary, confirms the queue is terminal, then rechecks all 52,437 source/input
pins and native reports. Its stable `clock/audit-r2.json` also passes a separate
complete hash check. SHA:
`ce48dec23f8e832239dc4dd9b1923eadc7e1aaa1cb357402a1aec02ab1d3821e`.
Synthesis audit SHA:
`e85bff87fc80afa13a97c710caa40cbf78577713b0c5bca42aa7e934eff22fa5`.
The PS-IP missing-clock-pin warning remains recorded; the opened-project
audit verifies the real clock objects. No timing exception was added.

No bitstream, physical Win95/Quake pass or candidate gameplay result is claimed.

After both simulation builds close, 468 generated compiler intermediates
are losslessly archived and compared before unlinking their loose copies,
recovering **417,886,168 bytes**. The core and SoC archives and recovery
commands are recorded in their `generated-model-archive-closed.json` receipts.
All pinned inputs, RTL, private harness objects/headers, executable models,
traces and reports remain intact, including the then-live timing audit's pins.

## Next critical-path candidate: balanced remainder CLZ

The new SRT setup path includes `rem_clz64`, originally a 64-entry first-match
chain. [The one-function recipe](../verif/srt/prepare_rem_clz_tree.py) replaces
it with six binary half-word selections and an explicit all-zero result of 64.
No sequential, rounding, request, ownership or cycle equation changes. This
is a timing proposal, not a claimed frequency gain.

Three [recipe/proof tests](../verif/srt/test_rem_clz_tree.py) pass, including a
Z3 proof over every two-state 64-bit input. Wrong-zero and reversed-half
mutants produce counterexamples. The [native extracted-function test](../verif/srt/run_rem_clz_tree.py)
passes **393,410 samples**, including every 16-bit pattern in each quarter,
all leading-bit positions, zero and randomized sparse words. Both compiled
mutants fail with native exit 1. Native leaf time is 9.71 seconds.

Evidence: `/home/yukidama/external/tmp/ventium-srt-clz.kKzgmNE3`.
[The private full-core builder](../verif/srt/build_rem_clz_core.py) changes
only `rtl/fpu/fpu_srt_div.sv` from the write-direction parent; native build
closes in 12.25 seconds, model
`95f6dbb8699839d8e4af879b07c37d3143311acbe910178e8ee009ac36d984ca`.
Original defines and the separately compiled model-local harness are retained.
The cold memory/FP/AGI matrices pass all **156 cases** at AXI delays 0/7.
An independent audit rereads 75,192 complete architectural records, the
original QEMU comparisons and exact A/B cycle streams; it checks 1,500 targeted
V-memory retirements and all 350 AGI-prime accepts. Audit SHA:
`9d2590ebae4fd960b10388c34ff63a7e9e8abb80fbdbfb1c508075053b1619de`.

[The full-SRT sequential miter](../verif/srt/run_rem_clz_miter.py) instantiates
both actual engines, not the extracted function. It passes **4,160 operations
and 149,946 cycle checks**, including 1,366 divides, 1,365 square roots and
1,429 remainders; all rounding/precision controls, denormal operands, ignored
starts while busy, and 24 reset interruptions are exercised. Results, flags,
busy/done and phase must match. This is parent/candidate equivalence, **not an
independent numeric oracle**. Build/run takes 2.68 seconds; all artifact pins
are independently rechecked. Receipt SHA:
`e30a07f9e12340c8955c6a3f1714bc57ec1238d774896ca19bc4bb25f5bc25a0`.

Canonical `make verify` still closes **FAIL**, native make exit 2 after 184.49
seconds. All 20 same-input A/B cycle streams agree. The unchanged failure
inventory examines all 108 functional streams / 80,800 candidate records and
finds the same 7 passes, 91 length-only failures and 10 first-field C1 failures
with length mismatches. Independent canonical inputs are not identical: only
one complete functional A/B stream matches. No mask, golden, terminal record
or band changes. These failures remain acceptance debt, not passed tests.

### Balanced-CLZ full-PC/export checks and synthesis launch

The [private full-PC builder](build_srt_clz_soc.py) closes natively in **15.18 s**,
model `1aac192a8cb8610b26d1a71c2bfd576c94002dd31b809c4a9fdd331cb9bafb9e`.
All 102 shared directed RTL sources agree, with only `fpu_srt_div.sv` changed
from the write-direction parent. The 154 simulator defines, posted-16 transport,
private model-local harness header and 98 inherited SoC structural warnings
are retained. This is not a full-SoC lint pass.

Both unchanged short CoreMark disks finish with native exit 0 and reference
CRCs matching QEMU:

| Seed (10 iterations) | Parent cycles | CLZ candidate cycles | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

This is **0% cycle-throughput change**, not a valid-duration score or the
standard suite's long correctness seeds. The independent audit checks 63,475
input pins, actual native CPU-11 affinity, original media/ROM, real board-profile
AXI transport, clean native exits and no OOM. Audit SHA:
`cdf29862897d233350b415867ab67f12560dda277b89a406a8438853d1baec9a`.

The [source exporter](freeze_srt_clz_rk_candidate.py) retains 190 payloads,
156 hardware defines, full P5 L1s and the 117-unit/49-include closure. Four
exporter tests pass. Its first invocation rejects the known external-symlink
spelling of `audit_core.py` before copying; adding only that explicit alias
allows export without admitting arbitrary aliases. The independent source
audit checks 63,636 input pins and the exact one-function source delta.
Strict CPU-hierarchy lint passes with all six structural warning classes
treated as errors. Manifest SHA:
`9f33b2549df1c10ce4cb60351a834bdbd9c2b8087e0282f5349454a862ef6b4a`.

Generated compiler intermediates from explicitly checked inactive runs are
losslessly archived, tar-compared and hash-checked before their loose copies
are removed. Recovery commands are retained in each archive receipt. RTL,
executables, private harness objects/headers, media, logs, traces and pinned
inputs remain intact. This restores the disk reserve without lowering the
4 GiB runtime stop floor or the admission rule of twice the matched parent's
actual growth above that floor.

Matched diagnostic synthesis launches **02:37:50 UTC on October 11**:
`ventium-srt-clz-full-synth-oct11.service`, invocation
`08b78fe2aac54b60b1373d15d29d0cb8`; the observed exclusive Vivado scope is
`9b3880c4daab4ea48bf27336f8c17204`. It keeps original 40/100 MHz clocks,
the same logic-only mapper, 8 GiB RAM / 6 GiB swap limits and 30-minute cap.
The live controller enforces host-memory, swap and disk reserves.
`ventium-srt-clz-audit-queue-oct11.service`, invocation
`0d5a28143c0847da9e66dc56d0bec8fe`, will independently audit native closure
and compare timing against the **24.33504 MHz write-direction parent**.
The new timing auditor excludes its own redirected stdout from its input pins,
avoiding the prior receipt's self-hash defect. No retry, route or deployment
is authorized by this queue.

**At this checkpoint synthesis is running; no new Fmax is available.** The
previously prepared address-payload candidate remains separate; it is not
stacked into this SRT build. A separate
[quotient-initialization proposal](SRT_QACC_INIT_PAYLOAD.md) is queued for
unit verification after this timing run. Canonical verification remains FAIL;
there is no new bitstream, board qualification or candidate gameplay result.

Gameplay baseline: **0.51030715 total U+V retirement-event IPC**, model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**, predating this candidate.
