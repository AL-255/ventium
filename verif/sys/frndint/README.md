# FRNDINT: general rounding and precise exception repair

October 13, 2026. **Implemented in an isolated frozen-source derivative**, not
promoted into the dirty root RTL or deployed. Full private-reference functional
corpus: **108/108 PASS**. Canonical `make verify`: **7 PASS / 101 FAIL**, still
red. Standard-suite and physical FPGA acceptance remain open.

## Defects and implementation

The [composed reference](../../qemu-trace/c1_reference/README.md) exposed the
original `tx_regform` FRNDINT C1 failure. New native/exact tests confirm several
additional defects in that same operation:

| Defect | General repair |
| --- | --- |
| Rounding increment discarded; exact results retain stale C1 | Carry the existing quantizer's rounding decision through the registered misc response; commit C1 for the completing FRNDINT owner, even without PE |
| PC24/PC53 rounds an already integral result again | Reconstruct the integer at full extended precision; FRNDINT obeys RC, not PC |
| Positive input just below 2^63 rounds to a negative result | Retain unsigned magnitude and restore the original sign after conversion, including signed zero |
| Denormal operand omits DE; unmasked DE overwrites ST0 | Classify the stable pending operand, set DE, and suppress the result/PE/C1 increment when DE is unmasked |
| SNaN/unsupported encodings are passed through without proper invalid handling | Quiet masked SNaNs, use indefinite for unsupported encodings, set IE, and preserve ST0 on unmasked IE |

`prepare.py` changes exactly three SHA-pinned files:

- `rtl/fpu/fpu_x87_pkg.sv`: extracts the existing finite integer quantizer into
  `fx_round_int_mag`, returning `{increment, inexact, unsigned_magnitude}`.
  FIST/FSCALE retain their existing signed conversion/range policy around it.
- `fp_shared/ven_fp_misc.sv`: FRNDINT uses that quantizer, full-precision
  reconstruction and original sign; handles SNaN/unsupported operands.
- `fp_shared/ven_fp_top.sv`: owner-specific C1/DE/status commit and invalid/
  denormal write suppression. ST0 and CW are stable during TOP_MISC; no live
  command bus participates in the decision. Unmasked PE still delivers the
  rounded result and sets the exception status.

No new state, port, extra wait cycle, second wide result comparator, global
serialization, U-only fallback, application address check or guest patch.
The current early-done profile's measured response latency is unchanged for
every tested case: two sampled wait edges for ordinary misc operations, zero
for the four issue-time stack faults. This is a latency regression check, not
a synthesis-area or gameplay-performance result. FIST range bugs, if any,
are not repaired by this change; its signed policy is deliberately unchanged.

The Pentium Volume 3 FRNDINT instruction page (printed 25-128 / PDF 745) was
visually inspected with the PDF skill; C1 follows chapter 6, and P/D/I/IS are
listed numeric exceptions. Exact integer arithmetic independently checks the
normal finite results. Native x87 supplies a second defined-result oracle and
the exception witnesses; it is not a P54 timing or undefined-flag oracle.

## Verification evidence

Frozen parent model:
`369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150`.

Repaired whole-core model:
`2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63`.

The transfer preserves all **195 source files**, except the three deliberate
deltas, and all **152 definitions**. U/V, system/relocated fast paths and AXI
remain enabled. A fresh uniquely named C++ harness is compiled against its
own generated header; its object and dependency file are checked.

1. **Full FP-shell test:** 28,612 FRNDINT cases plus 72 adjacent FIST64/FST32/
   FST64 controls. All RC modes, PC24/53/64, both signs and old C1 values,
   exact values, ties, tiny/subnormal values, integer precision boundaries,
   +/-2^63, large already-integral values, signed zeros, infinities, QNaNs,
   SNaNs, unsupported encodings, and masked/unmasked IE/DE/PE. Four empty-stack
   cases exercise masked and unmasked underflow. Nonaccepted command inputs
   are poisoned, other stack slots/controls/pointers are checked, duplicate
   responses rejected, and reset cancels both registered execution stages.
   Parent: **15,952 failing cases**. Candidate: **zero**. Of these, 27,072
   normal/zero cases also match a separate integer-only oracle. Parent failure
   categories overlap: 2,768 numeric, 14,304 C1, 1,152 exception mismatches.
   All 72 adjacent controls are bit-for-bit unchanged; this does not claim
   exhaustive FIST correctness or qualification of the non-early-done profile.
2. **Cold whole-core test:** an ordinary i386 ELF executes FRSTOR/FRNDINT/
   FNSAVE and checks every result for **412 selected cases**. These are
   directed instruction fixtures, not workload snapshots. Native CPU exits 0;
   parent RTL exits the guest with error 4 on the first status check; candidate
   completes all 412. Full trace: **11,129 records**, including 412 independently
   audited FRNDINT before/after states and **2,474 actual V retirements**.
   Both RTL hosts close normally; guest failure remains distinct from host
   exit. Runtime 11.26 s, no STEP or breakpoint, AXI latencies 7.
3. **Private-reference full functional corpus:** unchanged 108 programs,
   **80,800 complete records**, **108 PASS**, 113.56 s. Original `tx_regform`
   now gives FSW `0x0220` and value 2.0 at record 15. Existing masks remain
   unchanged. An additional entirely unmasked comparison passes 105; the
   three intentional stack-test differences (`tx_regform`, `tx_regform2`,
   `tx_stack`) remain unmasked failures, not new passes. **30,134 V retirements**
   prove corpus pairing, not gameplay IPC.
4. **Unchanged canonical `make verify`:** native make exit 2, controller exit
   1, 400.36 s. Still **7 functional PASS / 101 FAIL** with the old canonical
   oracle. All **20 complete cycle traces match the parent exactly**; existing
   failing cycle bands are not widened or waived.
5. Two recipe/oracle unit tests pass. Independent audits recheck all leaf
   source deltas/native records; the full-core audit rehashes **14,403 pins**,
   repeats all 108 comparisons and all 20 cycle-stream comparisons. Actual
   native/QEMU/RTL affinities are recorded, not inferred from systemd settings.

### New reference gap: do not promote the oracle yet

The 412-case ELF **fails under the composed private QEMU**, exit 4 before one
case completes. Its full, untrimmed 27-record trace localizes the first failure:
FRNDINT at `0x0804800b`, CW `0x037f`, input
`00000000000000000001` (smallest subnormal). Native/RTL result is zero with
FSW **0x4522**; QEMU returns zero with **0x4520**, omitting **DE**. No C1 or
undefined-condition-code mask can justify dropping that defined exception bit.
The QEMU trace producer exits 0 because it captured the failed guest normally;
that is not a differential pass. `audit_integrated.py` preserves this result.

Next reference work: qualify instruction-level denormal handling in FRNDINT,
including masked/unmasked result suppression and exception priority, against
the exact/native fixtures. Do not globally alter SoftFloat denormal handling
or promote the reference merely because its existing 108-program corpus passes.
The new RTL repair is supported by native/exact evidence, not by changing a
golden to hide the discrepancy.

Follow-up: the [instruction-local private-reference repair](../../qemu-trace/frndint/README.md)
now passes all 28,612 FRNDINT fixtures, additional exception/precision-retention
checks, the complete unmasked 11,129-record cold-core trace and all 108 functional
programs. The old failed reference evidence above is retained. Canonical oracle
promotion, cycle gates and FPGA/standard-suite acceptance are still open.

## Reproduction and closed runs

Evidence root: `/home/yukidama/external/tmp/ventium-frndint.tM8XCg6d`.

| Artifact | SHA-256 |
| --- | --- |
| `leaf-r3/audit.json` | `01330e01521138456c0513a8464c96286985d0d5aad7f3f728138c63066f3075` |
| `core-r1/build-closed.json` | `e08838c441c029130dcf4ba67607c002265edf0346b004628570e1289a8eb955` |
| `func-r1/closed.json` | `5bcff38ecdf00cb842f2e456007a3548f2ac1ed5d5ecdfa5518ead54cc0847e2` |
| `audit-core.json` | `355ad4c281a0b7cbd2e579a6833c1062d3105ff886b3178ea44c9a10057742ce` |
| `integrated-r2/closed.json` | `10a09757a9fdeebaeb7fe2998c94b70354bdaba6dd97ac6e3a9fa947861c7a97` |

All named owners are terminal with MainPID 0. Leaf R3 service invocation
`5deac088306344d4a5fcb2aec8aa61d2`, scope `b26cc41e2d7a4eab8500a423b93a8f1b`,
closed in 12.19 s (warm compiler cache), peak 2,800,197,632 bytes / zero swap.
Core owner `f104097c93b74f8d8ca81ff876db9e07`, scope
`9e7df164df284cffa1e7706a59f1746a`, native build 20.31 s,
peak 3,403,010,048 bytes / zero swap. Functional owner
`8712798668a447f3846b184d63c56de2`, peak 157,888,512 bytes, zero OOM events.
Canonical owner `a72040d0191d4718bc675a1e3d12d4f2` is terminal failure as above.
Integrated R2 owner `d3a5da47766b4dc285ccf1754b61c089` exits 0.

Run `test_prepare.py` with `FRNDINT_PARENT` pointing at the parent directory.
`run_leaf.py --parent P --out FRESH` and `build_core.py --parent P --leaf L
--out FRESH` require the named `ipc_parallel32` guarded scope, explicit
Verilator 5.046, CPU8-15 affinity and external TMPDIR. Admit above 5 GiB free;
32 compile jobs stay inside 10 GiB RAM / 2 GiB swap, with no Vivado family.
The actual owner services used an additional 11 GiB/no-swap envelope.
`run_func.py` uses four workers on CPU8-11, 2 GiB/no-swap; `run_integrated.py`
uses CPU13 and 1 GiB/no-swap. Both auditors use CPU12. All output leaves must
be fresh. Core `make verify` retains its normal guarded one-worker limit;
its four-worker environment request is intentionally clamped by that guard.

Failed launcher R1 (wrong scope environment names) ran no compiler. Leaf R2
already passed but revealed two ~80 MiB GCC PCH files per model, exceeding
the driver's size estimate without crossing the 4 GiB reserve. R3 corrects
admission and losslessly archives closed PCH files. Integrated R1 passed native
execution but failed the ELF converter's CLI before starting RTL; its source
and failure are retained. R2 fixes only that CLI/metadata parsing. Neither
failed attempt is relabelled as a pass.

## Disk recovery and remaining acceptance

The old three identical 416,554,196-byte video-stream paths were consolidated
into a byte-verified `raw.vcap.gz`; finished movies and metadata are untouched.
Recovery instructions are alongside the original capture in
`ventium-fpga40-capture.VMIAgs/quake-clock37-r4.xUgDDO/RAW_RECOVERY_OCT13.md`.
Archive SHA-256:
`8e0aaae366ed7ca2c1544da26a300b3ff7e15aa2d5dad58582fc69d48e649ec4`.
Measured net recovery was about **336 MiB**, not three file sizes (the copies
did not occupy three independent allocations).

A second scoped archive preserves **4,100 closed files** (four generated PCH
caches and 4,096 old canonical traces) as byte-verified per-file gzip members.
`archive-plan.json` and `archive-closed.json` list exact paths/hashes and
`gzip -dk` recovery. Original 1,432,970,356 bytes become 104,080,833 bytes;
about **1.23 GiB** recovered. Current input pins, all source/model binaries,
headers, dependency files, media and run logs stay available. Failed gates
stay failed. First archive attempt refused two folders without verification
closure before any deletion; they were excluded from the successful pass.

The completed core's two PCH files were also losslessly compressed after all
workers closed; `core-r1/PCH_RECOVERY.md` records both original and archive
hashes. Input pins were rechecked after cleanup. Free space is about 4.96 GiB:
above the 4 GiB reserve but **still below the >5 GiB heavy-build admission**.
Do not use a rounded `df -h` display as permission for the next heavy build.

Still required: broader exception delivery/system-mode and non-early profile
qualification, remaining private/canonical reference corrections, canonical
cycle-band work, CoreMark's two correctness seeds, full Win95 desktop/UI and
Quake timedemo, and physical UV-fast acceptance. No new FPGA bitstream or
programming is part of this stage. Latest earlier endpoint/SMSW unplaced
estimate remains **35.057 MHz**, below the required 40 MHz; this derivative
has **no Fmax or area measurement**. No CM/MHz or gameplay gain is claimed.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237-1,300,065,237**. It predates this candidate and is not physical
FPGA/Doom IPC. Existing-bitstream Doom still fails before gameplay; no FPS.
