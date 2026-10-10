# Exact-byte near-RET capture — October 10

**Private, unpromoted proposal; RTL tests queued, no measured savings yet.**
Verified gameplay remains **0.49083588 total U+V IPC**, model `86731249`,
clocks 1.2B–1.3B, predating this and the pending x87 C1 repair. Full direct-memory
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
