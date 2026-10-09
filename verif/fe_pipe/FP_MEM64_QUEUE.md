# Ordered m64 x87 queue — October 9

Private prototype, **not production/standard-suite/FPGA acceptance**.
Verified gameplay remains **0.44513116 total U+V IPC**, model `1f2583cb`,
clocks **1,200,000,000–1,300,000,000**. That measurement predates this change,
target-read and read-retirement priming. CoreMark's full REP direct-memory
scores remain **2.107861982 / 2.110913372 CM/MHz**, not this candidate's scores.

## Two separate changes

`prepare-fp-mem64-queue.py` widens the existing one-entry FXCH/m32 admission
slot, rather than adding an FPU or speculative architectural state. The added
`VEN_FP_MEM_QUEUE64` flag permits completely acquired FLD64/FILD64 and six
non-pop m64 arithmetic forms. It adds 32 payload bits and one width bit; TOP,
tags, ST0, arithmetic and conversion still belong to the existing leaf.

Both core ownership lists are extended: allocation of deferred load responses
and the last-old-response/immediate-load assertion. The wrapper retains its
one-slot capacity, masked-exception admission and ordered response contract.
The core still requires the complete checked operand before issuing a command.
No ACK/ready dependency was added to the raw shape predicate. Translation,
fragment handling, exception/debug drain and actual bus requests are unchanged.

The new regression exposed a **pre-existing protected-mode FDP bug** in both
parent and prototype: the shared FPU received `dbase + q_ea` as its saved data
pointer. FNSTENV requires the offset paired with the saved selector in protected
mode. This is documented in Intel's manual, sections 8.1.8 and 8.1.10.
([Intel Volume 1](https://www.intel.com/content/dam/support/us/en/documents/processors/pentium4/sb/25366521.pdf))

`prepare-fp-dptr-offset.py` separately changes only the metadata input to
`seg_real ? (dbase + q_ea) : q_ea`. The memory address remains linear and
translated. Existing real/V86 pointer values are preserved; this is **not** a
qualification or repair of their environment-image encoding. The legacy
non-shared `fpu_writeback.sv` path is also outside this fix and still needs
its own pointer-format audit.

## Evidence and retained failures

All roots below are beneath `/home/yukidama/external/tmp/`.

- `ventium-fp-mem64-queue.r1W3rCBu/leaf-r3`: parent and disabled candidate
  each pass the original 12 leaf checks; enabled candidate passes 25. Actual
  older/younger state images, TOP/tags, FIP/FDP/selectors, input poisoning,
  unmasked rejection, capacity and reset are checked. Low fraction and signed
  high-dword operands catch truncation. The unchanged parent with the wide
  test enabled fails at real wide admission, as required.
- The first leaf launch refused missing setup inputs; `leaf-r2` subsequently
  hit the fixed task cap through compiler-cache process overhead, not OOM.
  `leaf-r3` passes with caching disabled, still 32 aggregate compile jobs,
  16-GiB/128-task bounds and six structural hard-error classes.
- Initial wide-only board model `d295b5b7` passes the 64 flat smoke comparisons.
  Its `matrix-r1` **FAIL** is retained: 128 flat cases pass; all 128 relocated
  executions fail the guest's saved-FDP check in both parent and candidate.
  The QEMU guest passes. No expected value or comparator was weakened.
- Initial pointer correction used `real_mode`; its successor uses `seg_real`
  to avoid inadvertently changing V86 values. Earlier models/results remain
  separate, not overwritten or presented as the final candidate.
- Final pointer-only root: `ventium-fp-dptr-r2.dG0pvlBe`, board model
  `88b73822c6276074344e347c9541e29c8950a427da33f5470dd33c9cbb4b8b4e`.
- Final wide-plus-pointer root: `ventium-fp-mem64-r2.LCJyV4S0`, board model
  `d18116278630cb2f8733ce5a0c54aceae37ca677a6cf7d900fa4bf5f937660cf`,
  full-address user model
  `7f555c1b55a36bfc85f05d62aca9726ddb29d5d0ca556163391cb83c24da85e7`.
  Source pins, native build exits and model-local generated headers pass.
- `matrix-r3`: **256 complete QEMU architectural comparisons**, each with a
  cycle execution. Eight operations × drained/overlapped × flat/relocated ×
  aligned/cache-line crossing × two models × AXI latencies 0/7. Every program
  checks results and saved metadata and requires actual V pairing. All 128
  matched complete-program totals and steady windows are nonregressing.
  All forced-FWAIT controls are exactly unchanged. Actual queue acceptance
  and integer retirement with two pending owners occur for all eight forms.
- `fault-r2`: **24 complete QEMU comparisons** plus cycle executions.
  FADD64/FLD64/FILD64 × absent first/second operand page × two models ×
  AXI latency 0/7. The handler checks error/EIP/CR2, older completed divide
  result, old metadata, unmodified stack depth and no younger integer effect.
  Only the PTE is repaired; restart produces the exact result. Warm calls
  prove actual queue use; no partial operand may reach the FPU.
- Five recipe tests cover source drift, repeated application, both load-owner
  anchors, disjoint copies and existing-output preservation.
- `hardware-lint`: original parent, pointer-only and final candidate all pass
  with `SYNTHESIS`/`VTM_NO_DPI` and six hard structural classes. This is **not
  Vivado synthesis, timing, placement or resource evidence**.
- `system-matrix`: 76 complete QEMU comparisons and parent architectural
  parity pass. The unchanged generic `make verify` **still FAILS**: 7/108
  functional passes, 101 terminal-length mismatches, and four cycle bands
  (dependent-add 1.133, independent-add 0.639, D-miss 5.000, I-miss 13.003 CPI).
  A fresh parent execution with identical ELF/loader inputs matches all 108
  complete architectural traces, including terminal states. This establishes
  nonregression on that corpus, **not** a generic-gate pass.

## Directed performance, not gameplay

Aligned flat steady iterations, excluding the first four of sixteen calls.
Complete cold-program timing is also checked. These loops include environment
checks and stack cleanup: the numbers are not bare instruction latencies.

| Younger operation after FDIV | AXI latency | Parent → candidate clocks/iteration | Clocks saved |
| --- | --- | --- | --- |
| FADD/FMUL/FSUB/FSUBR64 | 0 | 170 → 165 | 2.94% |
| FADD/FMUL/FSUB/FSUBR64 | 7 | 400 → 395 | 1.25% |
| FDIV/FDIVR64 | 0 | 201 → 200 | 0.50% |
| FDIV/FDIVR64 | 7 | 431 → 430 | 0.23% |
| FLD/FILD64 | 0 | 171 → 163 | 4.68% |
| FLD/FILD64 | 7 | 401 → 393 | 2.00% |

No percentage of Quake improvement is assigned to this change. It is not yet
present in a measured gameplay build. The dominant last-measured pipeline
memory wait remains 21.12% of clocks; this queue cannot eliminate that category.

## Reproduction and open gates

Create a private source with the pointer recipe, then the wide-queue recipe.
Build matched models with all existing U/V/fast-system/fast-memory flags; add
only `VEN_FP_MEM_QUEUE64` to the second. `run-fp-mem64-queue-leaf.py` accepts
`--parent`, `--candidate` and `--out` source directories. Whole-core
`run-fp-mem64-queue.py` takes `--control`, `--candidate` executables and a new
`--out`; repeat with `--fault` for source-page faults. Use the existing bounded
`tools/build_scope.sh`, explicit external TMPDIR and the `ipc_parallel32`
profile. Neither runner accepts snapshots or trims architectural traces.

Do not promote solely on these directed passes: the mandatory generic
UV-fast/AXI gate has known terminal-observer/cycle-band failures, and complete
standard-suite, post-queue event, full-PC gameplay, hardware resource/timing
and FPGA deployment qualification remain open.
