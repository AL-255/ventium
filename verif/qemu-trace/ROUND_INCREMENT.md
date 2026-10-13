# Private SoftFloat rounding-event qualification

October 13, 2026. A prerequisite for the independently diagnosed
[QEMU C1 omissions](../../fp_shared/tb/REMAINING_C1.md), **not a replacement
oracle, processor fix, green canonical gate, or FPGA acceptance**. The active
processor target remains at least 40 MHz synthesized Fmax with UV + fast pipe.
Its latest completed predecessor measurement is 32.270556344 MHz; the new
PRIME-COHERENCE synthesis is still running when this evidence is recorded.

## Implementation and contract

`prepare_round_increment.py` derives three exact-hash-checked private QEMU
SoftFloat sources. It observes whether the **last format-rounding operation
increments the retained significand's magnitude relative to truncation**.
The event is a separate, nonsticky `float_status` Boolean. It is neither an
exception flag nor an architectural C1 assignment. No original numerical
result or exception equation is changed; the source-reversal test checks this.

The increment constant alone is insufficient: nearest rounding can add a
nonzero half-ULP constant without changing any retained bit. The event instead
tests the carry from discarded bits:

```c
inc > round_mask - (p->frac_lo & round_mask)
```

The decision is recomputed after subnormal shifting and tie handling. Exact,
zero, infinity and NaN packing reset stale events. Masked overflow to maximum
finite reports no magnitude increment; overflow to infinity reports one.
This mechanism applies to the format-packing paths exercised below. It does
**not** establish integer-conversion rounding, stack-fault precedence, unmasked
x87 exceptions, transcendental internals, remainder quotient flags, rebias
modes, or all non-x86 SoftFloat configurations.

## Native qualification

Evidence root:
`/home/yukidama/external/tmp/ventium-qemu-round-event.D71NCRGd/native-r2`.
Four private builds compile the actual QEMU 8.2.2 `softfloat.c`, headers and
parts includes: unchanged control, proposal, wrong-nonzero-increment mutant,
and missing-reset mutant. They do not execute a guest or replace any QEMU
binary. The proposal seeds its event true before every call, so exact and
special inputs must actively clear stale state.

The same **33,148 cases** run on all four binaries:

| Operation | Cases |
|---|---:|
| x80 to binary32 / binary64 | 2,672 each |
| x80 plus zero at all three precisions | 8,016 |
| x80 addition / subtraction / multiplication / division | 4,656 each |
| x80 square root | 1,164 |

Cases exercise all four x87 rounding controls and all three precision modes,
both signs where applicable, exact results, ties, cancellation, subnormals,
overflow, infinity and NaN packing. Deterministically generated arithmetic
operands supplement explicit boundaries. **9,370 expected events** are one.
The oracle uses exact rational/integer arithmetic, not SoftFloat outputs or
host floating point. Square-root decisions compare the radicand against the
square of the half-ULP boundary.

- Proposal: **zero event mismatches**.
- Wrong-nonzero-increment mutant: **2,950 detected mismatches**.
- Missing-reset mutant: **7,924 detected mismatches**.
- All four: **every numerical result and exception word equals the original
  control**, including both deliberately wrong event implementations.

The runner pins actual transitive compiler headers before compilation and
requires the compiler's subsequent dependency lists to match exactly. Private
status/parts headers must appear in those lists. Tested driver/recipe/oracle
copies, commands, dependency files, logs, cases, binaries and raw output remain
in the run directory. The canonical source and its existing build are read-only.

Service `ventium-round-event-r2-oct13.service`, invocation
`0587c617bffb4deeb4b4f96b5bed0bb6`, is terminal with MainPID 0 / exit 0.
Native work took **12.035810 seconds**, peak **193,171,456 bytes**, on CPU12,
under a 1 GiB RAM / zero-swap / 600-second cap. `audit_round_increment.py`
independently verifies owner closure, all raw records and binaries, case
identity, negative-control detection and **377 unchanged pins**.
Closure SHA-256:
`c3628dfa94d7d1b680a8f377f325f2ed171d39f4880bfed1cd7f1fcfe803de86`.
Proposal probe SHA-256:
`c0b22664036ca70a9289cab1e07202230d218754259fae3758889ff4f3a09912`.

The preceding `native-r1` passed its narrower 13,360-case format suite in
11.899637 seconds. R2 supersedes its five-column probe/runner with the expanded
seven-column arithmetic harness; the original native artifacts remain. An
earlier source-only preparation rejected an ambiguous indentation anchor;
newline-anchored exact replacements fix the recipe without relaxing hashes.

Eight source/oracle host tests and the existing nine narrowing-oracle tests
pass. Reproduce on a mounted external scratch volume:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  taskset -c 12 python3 -B verif/qemu-trace/test_round_increment.py
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  taskset -c 12 python3 -B fp_shared/tb/test_remaining_c1.py
```

`run_round_increment.py --source SOURCE --build BUILD --out FRESH_OUTPUT`
requires a systemd invocation, CPU12 affinity, external `TMPDIR`, at least
4 GiB free, and the exact pinned source plus its matching QEMU compile database.
Use a bounded user unit as above; do not rebuild or write into `BUILD`.
The read-only audit is:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  taskset -c 12 python3 -B verif/qemu-trace/audit_round_increment.py \
  --run /home/yukidama/external/tmp/ventium-qemu-round-event.D71NCRGd/native-r2 \
  --unit ventium-round-event-r2-oct13.service
```

## Remaining work

No architectural helper consumes the new event yet. A subsequent separately
qualified reference change must implement instruction-specific C1 behavior,
including exact results, zero-C1 instructions and exception/stack rules,
without clearing quotient/FXAM/environment flags or weakening comparisons.
Existing terminal-observer/cache-key changes and the remaining undefined-C0
policy must also be qualified deliberately. The canonical gate remains
**7 functional PASS / 101 FAIL**, unwaived; cycle-band failures remain open.

Current candidate gameplay IPC is **unmeasured**. Older verified simulation
baseline: **0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates the candidate and is not FPGA or
full-timedemo IPC. No performance gain is claimed for this verification work.
