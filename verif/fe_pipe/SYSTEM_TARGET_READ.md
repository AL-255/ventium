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

No new full-PC run is launched for this combined selector experiment yet.
The ongoing permission-shadow guests do **not** include it. Full differential
closure, standard suite and FPGA qualification remain necessary.

Reproduce the leaf with explicit frozen source trees and fresh external output:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/fe_pipe/run-system-target-leaf.py \
  --control-source PARENT --candidate-source CANDIDATE --out FRESH_OUTPUT
```

The full control matrix is `run-system-target-read.py --feature
VEN_P54_CTRL_TARGET_SYSTEM` with matched `--control`, `--candidate`, `--out`.
