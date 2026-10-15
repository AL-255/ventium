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
25-122–25-125, 7-16–7-17, 7-23 and 7-28. Its operand-preservation and exception-priority
rules determined these assertions; native host results are additional evidence,
not Pentium cycle timing.

## Private shared-FPU repair

The exact-parent transform in `verif/srt/prepare_remainder_exceptions.py` changes
only `rtl/fpu/fpu_srt_div.sv` and `fp_shared/ven_fp_top.sv`:

- Reject unsupported x80 encodings before entering the remainder recurrence.
- Raise IE for signaling NaNs and apply the documented quiet/signaling NaN
  selection order and payload comparison. The equal-payload sign choice is
  cross-checked against native x87 and private QEMU; Table 7-10 does not specify
  that tie explicitly.
- Set DE only after higher-priority operands have been handled. Classify the
  pending owner's fixed ST1, not a live command's changeable ST(i) read port.
- Suppress ST0 writeback on unmasked IE/DE. Do not commit the discarded numeric
  quotient flags either: retain prior C0/C2/C3 and clear C1 on operand abort,
  matching native x87 without a full-trace waiver.
- Canonicalize pseudo-denormal A on both zero-quotient bypasses; otherwise its
  exponent and saved tag incorrectly remain denormal.
- Clear C2 on masked empty-stack remainder, while preserving IE/SF and the
  existing masked/unmasked destination/tag behavior.

The shared divide/sqrt/remainder engine is retained. No sequencing stage,
ordinary-operation latency, readiness policy, pairing or fast-pipe mode is
changed. Divide/sqrt/remainder iteration bodies are byte-identical. The new
classification and NaN selection logic still need area/timing measurement;
they are not assumed free.

`srt-exceptions-r1` retains the original **6,860/9,552** failing observations
and the first repair's remaining **108** failures (72 pseudo-denormal
result/tag cases and 36 masked empty-stack C2 cases). `srt-exceptions-r2` fixes
those, but `cold-exception-abort-r1` exposes the discarded-quotient C2 issue:
both guests exit 0 yet the full trace diverges (`b082` versus `b482`). It stays
a failed run. The final `srt-exceptions-r3` and `core-exceptions-r2` include the
status-abort correction. Original recipe and builder copies are archived for
the older receipts; none of those frozen sources or failed results is rewritten.

The final shared-FPU test passes all **9,552** cases, all eight payloads/tags,
command poisoning and three in-flight reset phases. Across the same cases,
9,264 latencies are unchanged; 288 unsupported-encoding paths become 33–64
cycles shorter. No tested latency increases. This is microtest latency, not
gameplay IPC or a promise about every workload.

Final private whole-core model SHA-256:
`2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e`.
The fresh 19.96 s build audits all 195 sources, changing only the two named
files from numeric-repaired parent `86afc191…`. Its 152 definitions,
`AXI_LINE_REPLAY=0`, private harness object/header layout and assertion settings
are preserved.

| Final whole-core test | Complete records | Actual V retirements | Result |
| --- | ---: | ---: | --- |
| Cold masked DE | 23 | 3 | Pass |
| Cold unmasked IE/DE, both operands retained | 49 | 4 | Pass |
| Cold FPREM1 small quotient | 23 | 3 | Pass |

These use `--cycle-func --l1-axi`, AXI read/write latency 7, `cycle_mode=1`,
system/relocated fast-pipe definitions and no debugger STEP, breakpoint,
snapshot or trace mask. All native, QEMU and RTL self-checks exit 0. The final
fresh private-reference functional corpus also passes **108/108** in 108.40 s.
It contains 80,800 complete records and 30,132 actual V retirements. Without
the existing optional manifest masks, 105 programs pass and the same three
deliberate stack-fault programs fail. No mask was added or broadened here.
Three new RTL recipe/locality tests pass; together with the reference checks,
16 host tests pass. This is not full system-mode or standard-suite acceptance.

Reproduce with fresh external output leaves: build the private reference using
`build_exception.py`, run `run_exception_state.py` and
`run_exception_regressions.py`, then use `verif/srt/run_remainder_exceptions.py`
and `build_remainder_exceptions_core.py`. Cold fixtures use
`run_exception_core.py --program {masked_denormal,unmasked_operands,small_quotient}.S`
with explicit `--core`, `--build` and `--out`. Each command is a separate bounded
owner; the braces above describe alternatives, not concurrent use of one port.
The core/leaf builders use the existing serialized 32-job guard, actual child
CPU affinity and a 10 GiB RAM / 2 GiB swap limit. Native tests use distinct
bounded CPU sets. No Vivado run was launched in this stage.

Fourteen explicitly enumerated PCH compiler caches from **closed** private
builds were losslessly gzip-archived, with hashes and decompression verified
before removing the raw cache copies. Sources, binaries, logs, traces and
receipts remain; the caches are recoverable from their `.gz` archives. The
plan and completion ledger are `exception-pch-archive-{plan,closed}.json` in
the evidence root. This recovers **1,001,453,640 bytes**; approximately 9.2 GiB
remains available on the external filesystem.

The independent `audit_exceptions.py` closes successfully, rechecking **23,220
input pins**, all reference sequences, native exception-state comparisons,
shared-FPU cases, cold whole-core traces and the 105/3 unmasked functional
split. The 108 masked functional verdicts remain the unchanged worker receipts;
the audit's separate no-mask regrade does not relabel those three as passes.
It verifies all 20 full cycle streams against the parent, exact two-file RTL
and one-helper reference deltas, archived older recipes, native exit codes
and terminal ownership. Audit SHA-256:
`875d55ff1026d407e3597a1c66d5a794d1c68f2f367d06db821f8102bbbe2521`.
It takes about 195 s, peak RAM 847,187,968 bytes. Its cap was raised from 1 GiB
to 2 GiB during regrading to retain headroom; no OOM occurred. The reference
and final core build peaks are 3,386,122,240 and 3,270,742,016 bytes, with zero
recorded swap peak. All native owners are now terminal; no Vivado is running.

The final unchanged canonical gate **fails**, native make exit 2: **7 functional
PASS / 101 FAIL**. It takes 391.30 s; all 20 complete cycle streams are identical
to the numeric parent. These are not cycle-band passes. The original reference,
goldens, comparison masks and timing bands were left untouched. The private
108-program success is not substituted for this failed canonical gate.

Canonical gates and physical FPGA acceptance remain open. The retained faster
timing parent is still only **36.5912 MHz unplaced**, not ≥40 MHz routed closure.

Verified gameplay baseline: **0.50520554 total U+V IPC**, older simulation model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates these candidates; candidate gameplay
is unmeasured. No gameplay gain is attributed to these correctness repairs.
