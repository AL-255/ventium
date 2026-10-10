# Compact round-direction sideband proposal — October 10

## Current-source backport, 16:53 UTC

The [strict backport recipe](prepare_current_round_c1.py) now applies the
already-tested arithmetic C1 hunks to the latest response-payload core
`3c3ab215`, preserving the intervening operand sharing, registered forwarding,
SRT payload selection and numeric floor-exponent repair. Nine host tests pass,
including missing/duplicate context, partial/repeated application, patch drift
and exact reversal of every reviewed hunk. This is **source preparation**, not
a new RTL correctness pass.

Prepared root: `external/tmp/ventium-current-round-c1-core-r2.281an9Xt`.
`prepared.json` pins 4,751 inputs and retains exactly the parent's define set.
The resulting SRT engine, package and shared ALU are byte-identical to those
in the previously checked `6f71bad6` model. The newer top is modified only by
the C1 hunks, never replaced wholesale. A fifth file, `core.sv`, explicitly
connects the new SRT output in the inactive legacy branch; that connection
does **not** implement legacy architectural C1 handling or qualify that mode.

Controller `ventium-current-round-c1-core-r2-oct10`, invocation
`b5c238b5775c4ec08aa77e9ebac684dc`, waits for the active response-payload
synthesis to close successfully before compiling. It then has a 600-second
build bound, a unique private host object/header, the unchanged AXI7 UV-fast
912-case SRT and 1,152-case arithmetic observers, and the original `make verify`
with a 600-second bound. The compiler uses the shared heavy-build guard and
32-job profile; it does not overlap Vivado. The gate must still report its
actual failure if the pre-existing oracle/C1/cycle-band debts remain. No
golden, comparator, output state or cycle band is replaced.

The initial queue failed before copying/building because it expected a
`passed` key in the SRT diagnostic's result schema. The failed root
`ventium-current-round-c1-core.1BrYlH6e` is retained. R2 explicitly checks the
912 cases, zero value/C1 mismatches, native/exact agreement, actual V events
and all native exits; it does not infer a full-core pass from that observer.

Latest verified gameplay is **0.49940993 U+V retirement-event IPC** on older
`bfb867f7`, clocks **3,200,065,237–3,300,065,237**; all 21 windows average
**0.4895819671**. This C1 derivative is gameplay-unmeasured, unbuilt as of this
entry, and not in the active hardware export. Full standard-suite and hardware
qualification remain open. Earlier measurement/queue entries below are history.

## Earlier proposal and qualification trail

**Private, unpromoted RTL candidate.** The subsequent
[FST/FSTP repair](FST_REGISTER.md) fixes the stale-C1 register-pop example below
and a false empty-destination underflow; its 1,920-case test passes, but its
canonical gate remains red. Neither repair has gameplay/FPGA acceptance.
Latest verified gameplay is **0.49929384 total U+V IPC**, `86731249`, cycles
3.2B–3.3B; all 21 windows from 1.2B–3.3B average **0.47844824**, below the
sustained target. The measurements below retain their historical scope.

Leaf, connected-top and directed full-core
checks now pass (see the closed results below); production C1 sources and live
full-PC models remain unchanged. Latest verified gameplay is **0.48007471 total
U+V IPC**, `86731249`, clocks 2.4B–2.5B; this candidate has no gameplay measurement.
The full observed 1.2B–2.5B aggregate is **0.47084103**, below the sustained target.

The [912-case observation](SRT_ROUND_FLOOR.md) proves that simply preserving
C1 is wrong for both FDIV and FSQRT. The proposed
[`round_pack_c1.patch`](round_pack_c1.patch) exposes the actual round direction
without recomputing arithmetic:

- Capture the retained significand LSB before the existing rounding add.
- XOR it with that bit **after** the existing tie-even mask and normalization.
  A real increment toggles it; a tentative tie increment cancelled back to an
  even result does not. At PC24/53 the retained bit is40/11; at PC64 it is0.
- The existing overflow decision explicitly distinguishes infinity (magnitude
  rounded upward) from finite saturation (downward). The underflow branch
  captures the bit after its existing shift/jam, not before it.
- Return `{rounded_up, OE, UE, PE, value80}` from `fx_round_pack_c1`. Preserve
  every original `fx_round_pack_f` caller's83-bit value/exception ABI with a
  wrapper. There is no second add, multiplier, divider, recurrence or pipeline
  stage in the proposal. Hardware cost/timing still require measurement.

`git apply --check` passes against package SHA256
`e7f1e126809559a80e29e6122433d2af27a63d75208056b62ff98ced729ba884`.

## Independent leaf test, queued

[`round_c1_vectors.py`](round_c1_vectors.py) uses exact integer division and
remainders to round the input to the requested precision/exponent grid.
No RTL function, host floating-point arithmetic or existing rounder computes
the expected value/C1. The sticky input is below the **normalized**128-bit
window, matching the function's interface. The first emitted vector file used
the unnormalized LSB for this tail; this was caught before any RTL run and
corrected. Both files remain in the scratch directory; only`vectors-r2.txt`
is admitted to the queued test.

Six host tests pass: exact values, both nearest-even tie directions, sticky
above a tie, negative directed rounding, zero/gradual underflow, exponent
carry/overflow and normalization. There are15,600 deterministic vectors over
all three defined precisions/four rounding modes/both signs, fifteen boundary
exponents, both sticky values and3,000 additional varied alignments.

[`tb_round_pack_c1.sv`](tb_round_pack_c1.sv) checks actual84-bit RTL results
against these expected80-bit values and C1. Separately, it compares all83
legacy value/exception bits and the compatibility wrapper against a literal
copy of the original round-pack function. This proves exception-bit
**preservation**, not independent correctness of every old exception rule.
No full-core comparator mask or golden is changed.

Private package, original reference, vectors and bounded `run_leaf.py`:
`external/tmp/ventium-round-c1-leaf.s1KdMbTu`.
The test-only package adds the untouched original function renamed to
`fx_round_pack_reference`; that reference is not proposed for hardware.
Test package SHA256
`6974c9fb3b181e0f34c5b28787fa2e2cf0b97735aae8838d2208ad6c42bff7f3`;
vector SHA256
`f48c9f9bf393e4c401b4c43c2792d0bf2d6755f57dcd1738fea284bfa6145ed2`.

Queued service`ventium-round-c1-queued-oct10-r2.service`, invocation
`c9e6c7fb885e4b8ea9735dcbe84d2fde`, waits on the same shared build lock as
Vivado and the exponent-repair leaf. Compilation/run has a600-second bound
after acquiring the normal4GiB/one-job scope. Check actual`closed.json`, native
output and supervisor closure; queue admission and host tests are not an RTL
pass. No concurrent Vivado or Verilator build is launched.

## Integration still required

After the leaf passes, carry the bit in the existing `ven_fp_alu` result
register and `fpu_srt_div` completion register. The SRT inline PC64 path must
account for its signed residual: a retained over-estimate can round upward
without executing its `up` increment. Its intended expression is
`up || (resid_neg && !down)`; do not substitute PE or only`up`.

At `ven_fp_top`, commit C1 only with that operation's existing arithmetic or
SRT owner. Keep FPREM/FPREM1 quotient C1 separate and do not leak borrowed
transcendental micro-operation flags into architectural state. Ordinary
non-rounding special results clear C1; the existing stack-fault override must
retain its distinct overflow/underflow C1 semantics.

Qualify value/flag/latency preservation, both seeded C1 values, alternating
arithmetic/SRT/FXCH owners, reset/cancellation and masked/unmasked faults.
Update every active instantiation explicitly and preserve strict pin/latch
lint. The reference SRT copy, legacy core path and old/new tests need deliberate
interface handling, not missing-port waivers. Combine with the independently
verified exponent repair before full-core differential/standard-suite runs.
Neither leaf alone closes C1, the generic gate or FPGA acceptance.

## Connected private top and independent arithmetic witness

The candidate is now connected in a private four-file integration, including
the independent SRT exponent repair. The self-contained
[`round_c1_integration.patch`](round_c1_integration.patch) applies cleanly to
the current production sources; it is **not applied to production**.
`ven_fp_alu` carries C1 beside its existing registered result; SRT registers it
at its existing DFIN/QFIN completion. `ven_fp_top` consumes it only for the
matching ALU/SRT architectural owner. Immediate divide/sqrt special cases
clear C1 before the existing stack-fault override. Remainder quotient bits and
the later FPTAN status override remain separate. No stage, recurrence, queue
or wide arithmetic unit is added. Actual leaf/top tests and hardware cost are
still pending, so these are source-level properties, not timing sign-off.

[`arith_c1_vectors.py`](arith_c1_vectors.py) adds1,152 finite FADD/FMUL/FSUB/
FSUBR cases across all three PC modes, four RC modes and both initial C1
values. Native x87 and pinned QEMU agree on **every value**. Independent exact
rational arithmetic also matches every native C1 and precision flag. Three
host tests pass. Explicit register opcodes avoid SUBR assembler ambiguity.
Native host x87 is not P54 silicon; no cycle claim comes from this oracle.

The unchanged actual `b5453f16` UV-fast model executes that same ordinary-entry
fixture: all1,152 values and precision flags agree, but **576 C1 values fail**.
Both C1 seeds were checked before execution, so preserving the previous C1
cannot pass. Native guest exit0, actual fault deliveries0, genuine V retirements2,
stable source/model pins and all children reaped are recorded. Diagnostic
exit1 and failed supervisor status are expected evidence of the bug, not a
correctness pass. No architectural comparator or golden changed.

Private tree: `external/tmp/ventium-fp-c1-integration.D3VVvyfg`.
Arithmetic oracle vector SHA256:
`cf413fa07a39c1a7fc62a41867b70143f3d226dfd1f49f03ef8627720591192d`.
Current-model observation: `current-alu-observation-r1/closed.json`, SHA256
`a68531558527224fe275f1b7bfbfbbbbb94d14149ed0284e00d2467945f55392`;
invocation `c32fb3e5567849b9ab250973e2ed8e08`.

[`tb_fp_round_c1.sv`](tb_fp_round_c1.sv) interleaves those cases with all912
native/QEMU SRT cases: **2,064 top-level vectors**. It seeds the actual state
using FLD/FNSTENV/FLDENV commands, not hierarchical deposits. It also checks
consecutive independent arithmetic owners with different C1 results, command
bus mutation after acceptance, no premature C1 commit, masked/unmasked stack
underflow, stack overflow and reset during an actual SRT recurrence.
These additional cases are **prepared, not passed**.

`plan.json` freezes45 source/test/authority pins, SHA256
`a7bdb19c6221c15b6802b4be27ccf30d64a0e6d6c767ece7ae470d434c7779b0`.
Queued service `ventium-fp-c1-integration-queued-oct10-r2.service`, invocation
`194bb4020e65463aaa04bd892ee137a4`, first requires successful closed receipts
from both smaller leaves. It then acquires the common build lock and runs the
top under the normal4GiB/one-job guard, bounded to600seconds. A missing/failed
prerequisite cannot trigger a build. The active FPGA synthesis, full-PC models
and production RTL remain unchanged. Legacy instantiations and alternate
reference interfaces still need deliberate wiring when promoting the patch;
this private top test is not full-core or standard-suite acceptance.

The first top queue failed immediately before any build: its literal TMPDIR
used the `external` symlink while the driver checks the canonical directory.
R2 supplies the resolved external path; the assertion is unchanged. The same
latent mismatch was caught in both smaller waiters. Their exact supervisor
identities and sole `flock 9` children were checked, then only those unstarted
waiters were stopped/requeued with corrected environments. No running compiler,
Vivado process, pinned source, vector or expected result was changed. The old
top's failed invocation and the cancelled original waiters remain in the logs.

## Closed RTL and full-core checks

R2's first actual launch exposed another driver issue: Python subprocesses
closed inherited lock FD 9, so the nested guard waited for its own parent.
The exact waiting tree was stopped, retaining its attempt. R3 preserved FD 9
but failed with compiler-not-found (127) under systemd's PATH. R4 also pins
`VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator`. The real guard
still validates the cgroup and locked descriptor; its policy is unchanged.

All four R4 services closed successfully at
`external/tmp/ventium-guarded-leaf-r4.JYAr22mz`:

- `srt/closed.json`: **912 cases**, parent four value failures reproduced,
  candidate zero, unchanged latency and reset cancellation.
- `round/closed.json`: **15,600 cases**, exact value/C1 oracle and all 83
  original value/exception bits preserved.
- `top/closed.json`: **2,064 arithmetic/SRT cases**, three stack-fault cases,
  consecutive owners and reset cancellation. Model `010c233a`.
- `ret/closed.json`: unrelated **790-case** admission predicate; not FPU evidence.

Every run retained strict structural errors, original vectors, stable pins,
one compiler and bounded execution; no production RTL was changed.

Full-core backport R1 correctly refused a wholesale file copy: the measured
parent has shared ADD/SUB/SUBR input selection and registered arithmetic-memory
forwarding absent from the checkout's unmodified FPU files. Copying over them
would silently lose earlier performance/area work. R2 applies only the C1
hunks and preserves both features. Exactly four files change, and the define
set is identical to `b5453f16`. The rejected R1 attempt is retained.

R2 private root: `external/tmp/ventium-fp-c1-core-r2.rvshYb56`;
model SHA256 `6f71bad660d57b3e4ccf6801739799cde0e8afdf69968cf58d2336831cf8bddf`.
Fresh strict/asserting full-core build passes with its own host object/header.
Using the unchanged native-x87/QEMU/exact-math authorities and ordinary-entry
ISA fixtures in UV-fast mode:

- `srt-observation/result.json`: **912 cases, zero value/C1 mismatches**;
  fixes the original four factor-of-two square-root failures and 456 C1 failures.
- `alu-observation/closed.json`: **1,152 cases, zero value/C1/precision-flag
  mismatches**; fixes the original 576 C1 failures.

Both actual guest exits are zero, actual fault deliveries zero, and actual V
retirement is observed. These checks also pass with `--l1-axi`, read/write
latencies seven, and nonzero backing-ACK counters: 912 SRT and 1,152 ALU cases
again have zero mismatches. Their separate `srt-axi-observation` and
`alu-axi-observation` receipts retain the unchanged oracle, explicit backend
arguments, wrapper transformations, input pins and native logs. These are
directed output-oracle checks, **not complete per-instruction QEMU
equivalence**, standard-suite acceptance, gameplay or FPGA results. Production
promotion still requires alternate/legacy interface handling, further exception
coverage, the generic differential gates and full standard suite.

### Canonical gate still red: C1 must be reconciled, not masked away

`make verify` on `6f71bad6` closed **FAIL**, invocation
`d5ee5c83c35f458fbbfb90635402c61e`, log `generic-r2.log` in the R2 core root.
It retains the 101 terminal-length failures and four hard cycle-band failures
seen on the parent/RET candidate. In addition, eight canonical x87 tests now
show an earlier FSW divergence: `tx_addsub`, `tx_chain`, `tx_fp_denorm`,
`tx_fprem`, `tx_muldiv`, `tx_round`, `tx_sqrt`, and `tx_unifdiv`.
Every reported first difference is **C1 only** (XOR `0x0200`). For example,
`tx_round`'s upward **3/10** reports QEMU `3820`, candidate `3a20`;
`tx_fprem` first reports QEMU `7220`, candidate `7020` at record 288.

The independent 2,064-case witnesses support the repaired round-direction
semantics; they do not automatically qualify every failing canonical record.
Exact first-divergence reproductions and the oracle's C1 behavior still need
to be reconciled. **Do not add a blanket C1 mask, change expected records, or
call this a differential pass.** The canonical gate remains the authority and
the candidate remains unpromoted. Its numerical checks and complete gate
failure are both retained, rather than describing parent parity as acceptance.

### Exact eight-site native reconciliation

[`check_canonical_c1_native.py`](check_canonical_c1_native.py), with the small
[`native_x87_at_pc.c`](native_x87_at_pc.c) observer, now executes the **unchanged
gate ELFs** on native x87. The observer only reads registers/memory and steps
its own diagnostic child: no breakpoint, injected instruction or register write.
After the selected instruction it resumes the original guest to exit zero and
reaps it. This is not a single-stepped RTL acceptance run or a P54 timing oracle.

All **eight exact first-divergence sites** have the same control word, relevant
input operands and output value across native, QEMU and candidate. Native C1
matches the candidate and the independent exact-rational magnitude comparison
at every site, including multiply overflow and square root. QEMU's C1 differs
at all eight. Invalid-ELF and unreached-PC negative controls fail closed.
Receipt: `external/tmp/ventium-c1-canonical-native.5DNHth97/observed-r2/result.json`.
R1 correctly refused the overflow case because the initial witness handled only
finite outputs; R2 explicitly checks finite exact input overflowing to infinity.

The pinned QEMU `target/i386/tcg/fpu_helper.c` (SHA256
`efb0daf00682ed65488b6ee606a409da7d84f1bb6c118d1bdbc8d27ead37c4e6`)
merges IEEE exception flags after these operations but does not update C1 for
their rounding direction. FSQRT only changes condition codes in its negative
operand branch. This explains the observed first differences; it is **not**
permission to ignore C1 or replace the whole golden with native state.

The ELF also corrects a misleading source comment: `tx_round` encodes `DE F1`
(`FDIVRP ST1,ST0`), with old ST0=3 and old ST1=10. Its actual result is **3/10**,
not the documented 10/3. The witness decodes bytes and uses the observed operands;
the original test source, binary, masks and goldens are unchanged.

These eight sites are reconciled, but complete C1 semantics are not closed.
For example, the later exact register-pop at `tx_round` PC `0804802e` leaves
candidate FSW `0220`, whereas native produces `0020`; the current direct
`FX_FST_STI` arm does not write status. Rounded memory stores and other opcode
owners require their own defined-flag checks. Do not infer full canonical or
standard-suite acceptance from this eight-site diagnostic.
