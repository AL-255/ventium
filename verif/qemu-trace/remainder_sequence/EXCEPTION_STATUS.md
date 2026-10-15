# FPREM operand-exception follow-up — 2026-10-15

Private candidates only; no canonical reference, production RTL, comparison
mask, guest workload or FPGA image has been replaced. This follows the
[numeric remainder repair](README.md). Unmasked underflow-result rescaling and
system exception delivery remain separate, open qualifications.

## Independent instruction check

`state_probe.c` executes actual i386 FPREM/FPREM1 instructions, immediately
followed by nonwaiting FNSAVE. FRSTOR supplies directed instruction operands,
not application save states. The 9,552 cases cover both instructions, 14 operand
classes in both positions, four IE/DE mask combinations, all supported PC/RC
values, three TOP positions, signs, old sticky flags/condition codes, and empty
ST0/ST1/both. The PC/RC/sign/TOP variants are directed combinations, not their
complete Cartesian product. UM is always masked.

The Python oracle separately checks exception priority, all exception flags,
unmasked destination retention, CW/TOP and unrelated stack contents. The
native/reference comparison additionally checks all eight 80-bit payloads and
tags. Undefined condition bits on exceptions and partial reductions are not
treated as architectural results; complete finite quotient bits are checked.
No such exclusions were added to the repository's trace comparator.

Native x87 passes all independent checks. The earlier precision-only private
QEMU (`1418bd57…`) differs in **4,068 cases**. It omits DE, overwrites ST0 on
unmasked operand exceptions, and does not implement the remainder empty-stack
response. Matching it would not constitute correctness.

## Private reference repair

`prepare_exception.py` changes **only `helper_fprem_common`** in the already
precision-repaired source. It applies the operand priority order before numeric
evaluation, sets masked DE, suppresses writeback on unmasked IE/DE, and handles
empty-stack IE/SF. Existing NaN selection and the earlier precision save/restore
remain. No global SoftFloat behavior or flags are overridden.

Private QEMU SHA-256:
`b81831c8976043f8d8d6fc7eeb1d1a981337ca274848f2fcc32b2d3fffbf8e48`.
Its fresh guarded build takes 29.24 s and changes one file in the 11,132-file
source inventory. It passes all 9,552 saved-state cases, the original 7,488
numeric sequences / 216,768 step records, and 96 following-FADD precision-state
checks. The retained older `da49b810…` control still fails 96,868 numeric step
observations. The exception fix did not conceal that negative control.

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

- `exception-state-r1`: failed precision-only reference diagnosis; native
  passes and all 4,068 reference mismatches are retained.
- `build-exceptions-r1`: successful fresh reference build.
- `exception-state-r2`: successful repaired-reference saved-state test.
- `exception-sequence-r1`: successful exact-sequence and PC-restoration
  regression, with the original numeric failure control retained.

Six new host tests reject missing DE, overwritten unmasked destinations, wrong
priority and parent drift. The complete local host set passes 13 tests when
`QEMU_FPREM_PARENT` selects the documented precision-repair parent. A first
all-tests invocation omitted that required variable and failed one setup;
that invocation was not an implementation failure or a pass.

The PDF skill guided read-only visual inspection of Intel 241430-004, printed
25-122–25-125, 7-23 and 7-28. Its operand-preservation and exception-priority
rules determined these assertions; native host results are additional evidence,
not Pentium cycle timing.

## RTL status

The shared-FPU experiment is under whole-core regression. It preserves the
shared iterative engine and fast-pipe configuration; it does not disable
pairing or serialize ordinary arithmetic. A cold unmasked-exception trace
still exposes C2 being committed from a discarded calculation. This remains
an open follow-up despite successful guest self-checks; no trace waiver is
being used to call it a pass.

Canonical gates and physical FPGA acceptance remain open. The retained faster
timing parent is still only **36.5912 MHz unplaced**, not ≥40 MHz routed closure.

Verified gameplay baseline: **0.50520554 total U+V IPC**, older simulation model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates these candidates; candidate gameplay
is unmeasured. No gameplay gain is attributed to these correctness repairs.
