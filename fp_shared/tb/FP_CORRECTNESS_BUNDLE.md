# FP repairs on the current performance candidate

Status at October 10, 18:30 UTC: **not qualified for deployment**. UV + system/
relocated fast pipeline and the real AXI backend remain enabled. No U-only,
STEP, global slow-path fallback, comparator mask or golden replacement is used.

The separately measured gameplay baseline is `bfb867f7`, **0.49971398 U+V
retirement-event IPC** at clocks **4,100,065,237–4,200,065,237**. All 30
consecutive windows from 1,200,065,237 average **0.496605827**, including every
dip. That build's duration-valid CoreMark scores are **2.101890118 /
2.107616105 CM/MHz**. These measurements do **not** transfer to the new FP
bundle or range-exception repair; neither has gameplay measurements.

## Current-source bundle

[`prepare_fp_correctness_bundle.py`](prepare_fp_correctness_bundle.py) composes
the reviewed arithmetic C1, register-FST ownership and memory-FST C1 changes
onto the latest saved-high-word timing candidate, preserving its newer cache,
pipeline and numeric SRT-floor fixes. It changes seven specified files, not
the whole older tree. Six host tests cover exact composition, atomic refusal
and preservation of unrelated text; they are not RTL acceptance.

Private core root: `ventium-current-fp-bundle.UDFZQlNE`; model SHA-256
`643bb9e6a94eb4ad0b7b7fc4997c574f6b179ac340970f2d702d0a7f98c2f933`.
The build closes native 0 in 16.68 seconds, with a private C++ harness object
compiled against its own generated header and unchanged source pins/defines.
At AXI read/write latency 7, genuine ISA execution passes:

| Directed observer | Cases | Native / RTL mismatches |
|---|---:|---:|
| SRT values and C1 | 912 | 0 / 0 |
| ALU values and C1 | 1,152 | 0 / 0 |
| Register FST/FSTP, all TOP positions | 1,920 | 0 / 0 |
| Masked finite memory FST narrowing | 2,352 | 0 / 0 |

All 6,336 cases are directed checks, not the canonical differential gate or
the standard suite. Pinned QEMU disagreements remain visible: 1,664 register
FST cases and 1,176 memory-FST C1 cases; no automatic waiver is created.

The original register invocation used port **35199**, outside that observer's
explicit 20000–32767 range, and failed **before RTL execution**. Its output and
controller failure remain. The unchanged observer/model was rerun at **25199**;
unit `ventium-fp-bundle-register-retry-oct10.service`, invocation
`67de33a5004f47679e653a3c6001b7a6`, closes native 0 with all 1,920 cases passing.
The first parent controller must not be described as wholly passing. Its
unmodified canonical `make verify` closes native 2 / FAIL: 7/108 functional
programs pass and 12/19 scored cycle checks fail. The independent `audit.json`
rechecks 4,966 source pins, every directed finding and native exit, actual
AXI/V activity and the retained controller identities. All 20 complete cycle
record streams are identical to the preceding high-word candidate. Neither
the test-port retry nor cycle preservation turns the canonical gate green.

## Newly reproduced unmasked memory-FST defect

The 1995 P54C manual, volume 3, printed pages 7-25–7-28, sections
7.1.12–7.1.15, requires:

- Unmasked overflow/underflow to memory preserves the destination and stack;
  an FSTP must **not** pop.
- Unmasked underflow recognizes a tiny result even if exact. Masked underflow
  requires tiny **and** inexact. A result rounded back to normal is not tiny.
- Unmasked precision still delivers the rounded result, including an FSTP pop.

Primary local source: `ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf`,
SHA-256 `63c27628292de539eb6ea9089404fe7b5d1fca9d292021a4493dce044e9aa988`.
PDF pages 216–219 were rendered and visually inspected using the PDF skill.

[`run_fst_unmasked_observe.py`](run_fst_unmasked_observe.py) adds **1,920**
finite cases: m32/m64, four rounding modes, both signs, FST/FSTP, both seeded
C1 values, five exception-mask combinations and six value classes. It uses
real FLDCW/FNSTENV/FLDENV and no-wait FNSAVE; it never changes executed state.
Its seven host tests include the crucial exact-tiny and unmasked-precision
counterexamples. Native host x87 agrees with every expected case; it is not
claimed to be P54 silicon.

Control root: `ventium-fst-unmasked.6iHX3pKm/old-fst-control`, model
`12086691a653025f57ed05f0efbd7a1a5963a7f6f2878098a0888e5e8c9cbcec`:
**448 RTL mismatches**, 0 native mismatches, 1,184 pinned-QEMU mismatches.
The UV-fast model executes the real AXI backend and 66 V retirements; native
execution exits normally, while the checker correctly exits 1. Existing
masked-FST C1 fixes alone do not address this defect.

[`prepare_fst_unmasked.py`](prepare_fst_unmasked.py) implements a compact
two-file repair on the combined candidate:

- Register one `tiny_nonzero` bit from the **existing** conversion result's
  exponent and captured source; no second conversion or rounding datapath.
- Gate memory response-valid and stack pop with the same range-exception
  predicate owned by the pending FST; keep precision-only stores enabled.
- Report unmasked exact-tiny UE and avoid a spurious PE/round-up from a
  suppressed store. Existing sticky exception bits remain sticky.

There is no new execution state, RAM port or latency stage. Five recipe tests
pass after tightening an initially ambiguous reset-line anchor.
The first prepared controller was stopped before compilation after detecting
the same invalid register-port choice. Corrected controller root
`ventium-fst-range-core-r2.drV0OWQH` preserves that attempt and required actual
parent closure plus the separately successful register retry.

The corrected model is
`e8253e84b5859a97aa74f007b715c71485296c0eb7f30b3df3fb520158927b24`.
It builds natively in 14.75 seconds with 32 compiler jobs and its own generated
C++ header/object. All **1,920 unmasked cases now pass**: the 448 control-model
errors are gone. All **2,352 masked-store** and **1,920 register/all-TOP** cases
remain passing. Each observer has native exit 0, normal guest exit, genuine
AXI backing acknowledgements and 66 V retirements. Pinned QEMU's respective
1,184 / 1,176 / 1,664 disagreements remain recorded, not waived.

The independent closure audit rechecks **5,171 source pins**, the exact two-file
delta, unchanged defines, all 6,192 case findings, native closure and full
trace lengths. The canonical gate still closes native 2 / FAIL, with the same
7/108 functional passes and 12/19 scored cycle failures. All 20 complete cycle
streams match the preceding bundle. The masked-store and register observers
also retain exactly **2,929,482 / 3,029,001 clocks**, respectively.

An exact seven-file full-PC backport now builds at
`ventium-fp-range-soc.KicmQEph`, retaining all 153 parent defines and all newer
cache/performance work. Its **102 intersecting core/FP source files** match the
directed model exactly. Model SHA-256:
`3082ac8377cdc364655dc47854ce9049420d0826b7da4b6a6f213bba0d98f3e8`.
Native build exit is 0, with the matching private generated-header/harness
object. The 98 inherited platform structural warnings remain; this is not a
clean whole-platform lint result.

Both **own ten-iteration CoreMark** seeds close native 0 with the unchanged
reference CRCs and exactly **4,767,218 / 4,753,406 ticks**, respectively. The
independent `coremark/audit.json` verifies 6,294 source/input pins, actual CPU
affinity, V retirement, native wait/EOF/reaping, retained supervisor invocation
`6215de9ba01f41038c7dd7df82ca2070` and zero OOM. This establishes no clock
regression in these matched diagnostics. They are duration-invalid runs, not
new qualified scores or a standard-suite pass. The full-PC candidate remains
gameplay-unmeasured; no FPGA rebuild or board programming occurred.

NaNs/unsupported encodings, all unmasked arithmetic exception responses,
legacy-memory FST, delayed #MF delivery and memory-fault transactional ordering
are **not qualified by these finite-store checks**. Full Quake timedemo,
Win95 desktop, CoreMark correctness, green differential gates and physical
FPGA acceptance remain required.
