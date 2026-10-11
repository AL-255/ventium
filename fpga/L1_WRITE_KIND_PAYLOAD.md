# Backing write-direction payload experiment — 2026-10-11 UTC

**Private candidate, not qualified. No frequency improvement measured yet.**
The objective remains **at least 40 MHz synthesized Fmax with UV dual issue,
system/relocated fast pipeline and fast memory enabled**. The best retained
unplaced estimate is 23.58546 MHz; the immediate read-ACK parent is 23.50176 MHz.

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
No synthesis result, bitstream, physical Win95/Quake pass or candidate gameplay
result is claimed at this stage.

Gameplay baseline: **0.51030715 total U+V retirement-event IPC**, model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**, predating this candidate.
