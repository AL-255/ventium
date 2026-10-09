# Registered instruction-word reuse — October 9

Private, default-off `VEN_L1D_CODE_WORD_REUSE`; **not production, FPGA or
standard-suite acceptance**. Latest verified gameplay remains **0.38064497
total U+V IPC**, model `e44e3176`, cycles **1,200,000,000–1,300,000,000**.
It predates pop-drain, the LRU/XPM candidates, and this experiment. Earlier
full direct-memory CoreMark scores are **2.10736/2.11041 CM/MHz**, not this
candidate's score or an FPGA cache/DDR measurement. The 0.48 target is open.

## Cause and proposed fix

Instruction-fill words already reside in `code_line_q`, a physical-line-tagged
register bank. The existing path copies each requested word through the shared
registered response window before allowing the core to consume it. That extra
capture is necessary for asynchronous data SRAM, but not for these already
registered instruction bytes.

`prepare_code_word_reuse.py` changes only `ven_l1d.sv` in a private source copy.
It selects an aligned dword from the staging registers without a second capture.
Eligibility requires the current physical line, cacheable instruction access,
full-word/legacy-zero strobes and either a valid complete staging line or a
word already received by the current unpoisoned code fill. The first critical
response retains its exclusive owner. Flush, snoop, golden mode, next-request
lookup and the independent hit-stream interface block the new path. Existing
store/invalidation rules remain unchanged.

No asynchronous SRAM-to-core shortcut, new RAM port, storage, speculative fill
validation, cache enlargement or workload-specific address is introduced.
Synthesis/route cost and timing are still **unmeasured**; no MHz claim follows
from a simulator's latency reduction.

## Closed checks

Root: `/home/yukidama/external/tmp/ventium-code-word-reuse.s3T2YiMM`.

- Six source-recipe tests pass, including byte-exact default-off restoration,
  no new clocked state, retained payload reference, rejected drift/duplicates,
  and source-copy isolation.
- `leaf-r4/closed.json`: control, candidate-off and candidate each pass the
  existing **150 accepted memory-chain requests** and **51 new directed
  checks** under the complete frozen full-PC macro inventory. The new checks
  cover every word offset, consecutive retargeting, two accepted strobe forms,
  rejected shapes/policies, arrived versus unarrived fill words, independent
  D-fill overlap, physical poisoning at all eight fill beats, flush and reset.
- Eighteen known-staged reads take **36 → 18 clocks**, with identical backing
  memory results. This is a **directed service-latency result**, not a gameplay
  or CoreMark gain. The default-off candidate preserves 36 clocks.
- Board-profile core model:
  `5178745d389ca66dc534f78cd065a53f77741ab9acfb9549e46f990cd276e21c`.
  Full-address user model:
  `9194e7e36f6db300d434a71ce971fcb050ec26ead0d05b9203e87067940d0401`.
  Both build natively with all six structural hard-error classes, stable source
  pins and unique local host objects bound to their own generated headers.
- `system-matrix/result.json`: **76 model/latency cases** from the retained
  19-program system corpus pass, each in full functional and cycle modes.
  Complete pinned-QEMU architectural comparisons, not prefix trimming.
- `boundaries/result.json`: all **32 instruction placements × two AXI
  latencies** pass complete QEMU comparison and cycle execution. Every loop
  iteration has a real U/V-pair witness. This uses ordinary cold BIOS fixtures,
  not snapshots or debug STEP.
- `coherence-r1/closed.json`: the unchanged code-buffer regression passes all
  **nine control/off/on × hit-under-fill/paired-store/combined profiles**.
  This covers U-store and V-store code mutation, crossing stores, mixed
  load/store pairing, matching and unrelated physical snoops, partial-fill
  poisoning, flush, uncacheable/golden accesses and I/D response ownership.
  Native exits are zero, inputs stayed pinned, and all six structural warning
  classes remain hard errors.

The canonical generic gate closed **FAIL**, native exit 2, with stable inputs:
**7/108 functional passes**, 101 terminal-record length mismatches, and four
hard cycle-band failures. The oracle, comparator, traces and bands are unchanged.
The parent has the same 101 terminal mismatches and five hard timing failures.
These are not waived, and this is **not declared complete**. The private QEMU
pre-exit observer was not used for this candidate's canonical run.

Matched unmodified cycle kernels (UV fast, AXI backend, zero added AXI latency):

| Kernel | Parent clocks | Reuse clocks | Fewer clocks | Current hard band |
| --- | ---: | ---: | ---: | --- |
| Dependent add | 3,826 | 3,686 | 3.66% | FAIL |
| Independent add | 2,228 | 2,088 | 6.28% | FAIL |
| Random branch | 15,471 | 12,923 | 16.47% | PASS |
| Data misses | 41,037 | 41,023 | 0.03% | FAIL |
| Instruction misses | 66,330 | 52,260 | 21.21% | FAIL |

Instruction-miss CPI decreases **16.504 → 13.003**; near-branch CPI decreases
**0.589 → 0.569**, entering its existing band. These are microbenchmarks, not
gameplay speedups. The random-branch hard band tests misprediction behavior;
its separately displayed absolute-cycle comparison still exceeds 10%.
No full-PC guest or FPGA build yet contains instruction-word reuse.

### Failed attempts retained

The first launcher double-acquired the heavy-build lock and was closed before
any compilation. The second preflight rejected an incomplete macro inventory
(`+define` alone omitted Verilator `-D` macros); the runner now consumes the
frozen complete `defines.txt` file.

`leaf-r3` passes control/off but fails the enabled candidate's earlier
payload-selector miter: its reference knew only the old response sources.
The corrected `candidate-r2` retains that assertion and every old reference
case, adding the new registered source through an independent byte-offset
expression. No assertion is suppressed, and the backing-memory data oracle
continues to check the new response. Both private candidates and the failed
native log remain available.

## Reproduction

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/l1/test_code_word_reuse.py
python3 -B verif/l1/prepare_code_word_reuse.py \
  --source /path/to/frozen/pop-drain-source --out /path/to/fresh/private-copy
TMPDIR=/home/yukidama/external/tmp \
VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
tools/build_scope.sh -- python3 -B verif/l1/run_code_word_reuse.py \
  --control-source /path/to/frozen/pop-drain-source \
  --candidate-source /path/to/fresh/private-copy \
  --profile /path/to/frozen/defines.txt --out /path/to/fresh/external-output
```

Remaining: generic-gate repair, full-core event/coherence coverage,
measured end-to-end gain, FPGA timing/resource
qualification, both full CoreMark seeds, Win95 desktop and complete Quake
timedemo on the selected source. UV + relocated fast loads/stores stays mandatory.
