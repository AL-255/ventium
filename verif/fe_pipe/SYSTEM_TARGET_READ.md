# Checked system control-target read — October 9

Private, default-off `VEN_P54_CTRL_TARGET_SYSTEM`. Not selected for FPGA or
full-suite acceptance. Latest verified gameplay is **0.39555990 total
U+V IPC**, model `05611d6c`, clocks **1.2–1.3B**, predating this candidate.
Its gameplay is unmeasured. The REP parent's full direct-memory CoreMark
scores are **2.107861982 / 2.110913372 CM/MHz**, not this candidate's scores.

## Cause and implementation

The existing resolved-target selector primes the two synchronous I-cache
read addresses during a slow control instruction's final EXEC/STORE state,
but only for flat, non-system clients. Protected/relocated CALL and RET
clients wait for EIP's registered update before reading the target bank.

`prepare-system-target-read.py` extends only this read-address selector to
checked 32-bit protected clients: the system fast context, non-real/non-V86,
CS.D, no active debug block, and the original cycle/width/SMM gates. The
resolved target offset is added to CS base, including 16-bit RET truncation
before addition and ordinary 32-bit wraparound.

There is **no new request, translation, allocation, hit, LRU update, decode
or retirement**. The existing returned set/way/collision identity, current
line presence, CS extent and instruction permissions still govern use. A
speculatively addressed absent/unpermitted line cannot supply authorization.
Default-off source remains equivalent to the original selector. Full-core
FPGA resource/timing cost, including the relocated address addition, is open.

## Interaction with permission caching

The first experiment on the REP parent, `ventium-system-target-read.94xJtPa9`,
showed actual target-read activity but **zero warm-loop gain**. Its gain gate
remains FAIL. One-entry instruction permission thrashing masked this bubble.

The new experiment applies the same selector recipe to the separately
qualified [multi-page permission shadow](IFETCH_AUTH_MULTI.md), without
altering the earlier results. Root:
`/home/yukidama/external/tmp/ventium-auth-target-read.rHuwKah2`.
Board-profile model SHA256:
`5081f17d754789345f13d46fb9b3801a8aa889eb479d27f7dd1c804c49eb23b9`.
Generic full-address model:
`da2c7b9dd5af09f0df141e4ea48c6458d9969100148a2489593e7e81ad4de1e1`.

`matrix-r1` passes **288 complete QEMU comparisons** and cycle counterparts,
with real paired-V witnesses and no regression in the 144 matched warm-loop
comparisons. Representative relocated offset17, AXI0:

| Loop | Permission-shadow parent | With target read |
| --- | ---: | ---: |
| Direct CALL/RET | 31 clocks | 30 clocks |
| Register CALL/RET | 32 | 31 |
| Memory CALL/RET | 34 | 33 |
| RET immediate | 34 | 33 |
| Cross-line callee | 31 | 30 |

Register/memory JMP, store-modified targets and same-set conflicts remain
unchanged. These are **local microloop savings**, not gameplay gains.

## Correctness evidence and remaining gates

- `leaf-r1`: original, candidate-disabled and candidate-enabled actual include,
  **115,712 checks each**. Every owner/control/width/line offset, relocated
  arithmetic/wraparound and all 8,192 context-gate combinations are covered.
  Original and disabled variants produce identical native executables.
- `system-matrix`: **76** full existing system QEMU comparisons and functional
  parent parity across nineteen fixtures and AXI latency0/7.
- `fault-r1`: **16** full warm-code privilege/remapping comparisons, plus cycle
  counterparts, actual PF counts and U/V witnesses. Uses the unchanged guest
  permission fixture and comparator; only the matched define delta differs.
- `boundary-r2-l0` / `boundary-r2-l7`: **44** full existing demanded-byte,
  restart-PC, overlength and privilege/FP fault-priority cases pass. The first
  wrapper omitted fixture assembly and failed before any DUT run; receipts
  remain. R2 assembles the original twenty-two fixtures into fresh scratch.
- Both whole-core builds close with native exit0, stable source pins and
  private harness/header identity. No canonical binary is overwritten.
- Mandatory generic UV-fast/AXI gate remains **FAIL**, native exit2: unchanged
  101 terminal-record mismatches and four hard cycle bands. No masks, trace
  trimming, widened bands or alternative-mode PASS are introduced.

Additional `warm-boundary-r2` coverage passes sixteen full comparisons and
cycle counterparts. The guest traverses both code pages twice at CPL0, then
enters a warmed crossing MOV at CPL3: supervisor-page PF5, not-present PF4,
exact CR2/restart frame, unchanged destination before fault, and INVLPG/CR3
retry are checked. A separate INT ending at byte4095 must not check unused
successor bytes. Real V retirements remain present. The first single-warm-up
fixture/results are archived separately; the second traversal repopulates
permission proofs after both parent I-TLB fills.

A deliberately broken private model removes only the page-boundary handoff
veto. `ventium-warm-boundary-negative.MlicDTHs/negative-r1` rejects it at both
AXI latencies: the supervisor cases execute MOV without PF, and the unused-byte
case raises a spurious PF. The not-present case still passes because INVLPG
independently clears authorization. This negative control is **not a fix or
deployable candidate**. The unchanged actual implementations pass.

## Cold full-PC qualification started

`external/tmp/ventium-auth-target-soc.yS3YGL3V` builds model
`59650fe299f7ae07f0227c9d0eae696642000affadf35adf640fdad5e3d58059`.
Only `core_ctrl_target_read.svh` differs from permission-shadow PC parent
`1f2583cb`; the only added define is `VEN_P54_CTRL_TARGET_SYSTEM`. All core/FP
sources match the qualified micro model. The host has a unique basename with
identical contents and verified local generated-header ownership. Native build
exit0, stable pins, actual registered/read-first XPM fields and unchanged 98
structural-warning debt items are recorded. This is not whole-SoC lint-clean.

Fresh unchanged-media UV-fast Quake runs on CPU28, invocation
`a3d5ee6b60564859b3fb154c27e6bb54`; Win95 on CPU16, invocation
`162d83e5acce457e9e128ff83f2f39e2`. Each has one CPU, 2GiB RAM, no swap and
strict native/source/closure guards. P5 L1s, 32KiB platform L2, posted16 and
40/40/80MHz clocks are unchanged. No snapshots, guest edits, STEP or pairing
suppression. These runs are **not** gameplay/desktop/timedemo acceptance.
The earlier permission-only guests remain independent controls. The latest
verified gameplay remains 0.39555990 IPC on `05611d6c`, cycles1.2–1.3B,
predating both candidates. Full differential closure, standard suite and FPGA
qualification remain necessary.

Reproduce the leaf with explicit frozen source trees and fresh external output:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/fe_pipe/run-system-target-leaf.py \
  --control-source PARENT --candidate-source CANDIDATE --out FRESH_OUTPUT
```

The full control matrix is `run-system-target-read.py --feature
VEN_P54_CTRL_TARGET_SYSTEM` with matched `--control`, `--candidate`, `--out`.
