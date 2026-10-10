# Exact-byte near-RET capture — October 10

**Private, unpromoted candidate; directed comparisons pass, short CoreMark improves.**
Latest verified gameplay is **0.51351913 total U+V IPC**, model `86731249`,
clocks 2.2B–2.3B, predating this and the pending x87 C1 repair. Full direct-memory
CoreMark on `b5453f16` is 2.107843209/2.110905243 CM/MHz, not a cache/FPGA score.

The [complete CoreMark backend cycle comparison](../bench/COREMARK_BACKEND_DIAGNOSTIC.md)
finds 41,630 extra retirement-interval clocks at one ordinary `crc16` RET site.
That one-byte instruction is at line offset 20, where demanding all 16 decode
bytes crosses into an unused successor line. Existing exact-length capture
covers selected integer and x87 shapes, but not control instructions. This is
a structural opportunity, **not proof that all 41,630 clocks can be removed**.

`prepare-ret-short-window.py` adds default-off `VEN_RET_SHORT_WINDOW` only to
a private copy. It admits unprefixed C3/near RET (one byte) and C2/RET imm16
(three bytes), requiring agreement with the existing reference decoder's
kind/subtype/length. Every consumed byte needs its current registered I-cache
owner, permission, same-page span, CS limit and existing snoop/collision checks.
The existing capture blanks the unused suffix; it does not consume unowned
bytes from the next line. Prefixes, far returns and IRET retain their old path.

Only `ibuf` capture is shortened. **S_DECODE, S_LOAD and S_EXEC remain intact**:
no early architectural RET, no ESP/EIP update, no stack read/translation or
target check is performed by the new predicate. SS width, stack and target
faults, TF/RF/events and execution occupancy retain their ordinary owners.
No memory port, cache entry, pipeline stage, guest address match or workload
special case is added. Hardware cost and full-pipeline behavior remain untested.

Five source-recipe tests pass: byte-exact default-off restoration, unchanged
execution text, preserved existing capture sites/guards, refusal of changed or
duplicate anchors/reapplication, and no source/output overwrite. Reproduce:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/fe_pipe/test_ret_short_window.py
```

`tb_ret_short_window.sv` prepares **790 real-predicate checks**, covering every
opcode, both allowed lengths/subtypes, all 32 line positions, page/CS ends,
missing first/last owners, three snoop inputs, permission, decode/mode/unknown
vetoes and address overflow. The runner extracts the actual candidate equation
and uses the actual decoder enum package. This is an admission-predicate test,
not a decoder, memory system or full processor proof.

Private root: `external/tmp/ventium-ret-short-leaf.2CGHyKA0`.
Its parent is the actual compiled CoreMark source, SHA256
`8fbab03d949cb0b38c7074e708bfb682d1fdeda437bb7b9472d526e4821de34b`;
candidate SHA256
`392062588f25b9dcb643f2a9fd590e4df032408512734cebd53e74ceadf982f5`.
`plan.json` pins the source, recipe, extracted equation, package, testbench and
drivers. Service `ventium-ret-short-queued-oct10`, invocation
`60091c8df204471184ed24dfe96abf59`, waits behind the existing shared build lock.
The actual leaf has a 180-second bound, one compiler and the standard 4 GiB
scope; all six structural warning classes are errors. **Queue admission is
not an RTL pass.** The running synthesis and full-PC models are unchanged.

Before promotion: full-core control/off/on comparisons for C3 and C2 at all
32 positions; complete QEMU traces without trimming/masks; real paired-path
evidence; ordinary and relocated protected-mode stacks, SS16, CS/page ends,
unmapped/protected return stacks and targets, immediate stack adjustment,
pending interrupts/debug/RF/TF, and self-modifying code that changes instruction
length. Then repeat cache-backed CoreMark and the entire standard suite while
keeping the generic gate and existing timing bands unchanged. Keep this small
capture change independently attributable to its parent; do not infer its
performance from the unrelated pending x87 correctness repair.

## Closed directed and CoreMark checks

The original queue was cancelled before compilation: Python closed inherited
FD 9 and the nested build guard waited on its own parent. R3 preserved the FD
but exited 127 because systemd's PATH lacked Verilator. Both failed attempts
are retained. R4 explicitly selects Verilator 5.046 and passes the real locked
descriptor; no cgroup/lock check was removed. At
`external/tmp/ventium-guarded-leaf-r4.JYAr22mz/ret/closed.json`, the actual RTL
passes all **790** predicate cases. The other three R4 leaves independently
qualify the C1 proposal, not this optimization.

The independently built RET-only model is `56707c8a`, from
`external/tmp/ventium-ret-short-core.OEIt81zd`. All parent source inputs are
stable and only `rtl/core/core.sv` changes. Its defines add only
`VEN_RET_SHORT_WINDOW`; its uniquely named host source is byte-identical to
the `b5453f16` parent and compiles against its own generated headers.
Strict structural lint and assertions remain enabled.

[`ret-short-window.S`](ret-short-window.S) and
[`run-ret-short-window.py`](run-ret-short-window.py) test C3/C2 at **all 32
line offsets**, flat/relocated protected clients, SS32/SS16 (including nonzero
high ESP), and AXI read/write latencies 0/7. Each resets normally, enables
paging, executes eight actual CALL/RET pairs, checks stack adjustment and
executes a real U/V pair. Native QEMU completion and complete CR/GPR/segment/
flags traces agree; no new mask or trimmed record is used. Cycle and
cycle-functional observers must produce the same PC sequence and clock total.

Both control and candidate pass **256 fixtures × 2 latencies = 512 comparisons**
each, with zero actual fault deliveries. Candidate logs contain 1,280 actual
short captures. Of the 512 matched clock totals, **160 improve, 352 are equal,
none regress**. The independent no-candidate control pass and first smoke
passes remain under `external/tmp/ventium-ret-corpus.pKu6ArHq`; complete A/B
is `ab-all/closed.json`, invocation `f3bef256a1be4432aafdc1b7d50efdb9`.
This does **not** yet cover intentionally faulting stacks/targets, TF/RF/event
interleavings, SMC length changes, or a full standard-suite run.

The unchanged 10-iteration ordinary-entry CoreMark diagnostic passes both CRC
sets, direct and AXI backends, with exactly the original retirement counts:

| Backend / seed | Parent clocks | RET candidate clocks | Clocks removed |
|---|---:|---:|---:|
| Direct / performance | 4,821,818 | 4,815,654 | 6,164 |
| Direct / validation | 4,815,105 | 4,808,873 | 6,232 |
| AXI / performance | 5,241,779 | 5,187,956 | 53,823 |
| AXI / validation | 5,235,258 | 5,180,840 | 54,418 |

AXI whole-program clocks fall **1.027%/1.039%**; corresponding throughput gains
are **1.037%/1.050%**. No equivalence is claimed between those savings and the
earlier per-instruction interval attribution. Exact service-to-service AXI
diagnostic ratios are **1.97703/1.98018 CM/MHz**: still below 2.1, and these
short runs explicitly fail the benchmark's minimum scoring duration. They are
not valid CoreMark scores or FPGA measurements. Receipt: candidate root
`backend-diag/closed.json`, invocation `45625e8a6d5b476bba55d319d3b895f3`.

The actual `make verify` rerun remains **FAIL**. With the canonical unchanged
QEMU producer, it still reports the terminal-record length problem and the
existing hard cycle failures (`mb_depadd`, `mb_indepadd`, `mb_dmiss`,
`mb_imiss`). Directed PASS is not an override. The complete canonical log is
candidate `generic-r2.log`, invocation `7a1c4d527e494207ba778c8e5a507c40`.
The earlier launcher failed before the gate because systemd lacked the compiler
path; R2 pins it explicitly. Neither attempt rebuilt the canonical core model.
