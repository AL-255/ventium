# FP repairs on the current performance candidate

Status at October 10, 18:05 UTC: **not qualified for deployment**. UV + system/
relocated fast pipeline and the real AXI backend remain enabled. No U-only,
STEP, global slow-path fallback, comparator mask or golden replacement is used.

The separately measured gameplay baseline is `bfb867f7`, **0.52847961 U+V
retirement-event IPC** at clocks **4,000,065,237–4,100,065,237**. All 29
consecutive windows from 1,200,065,237 average **0.496498649**, including every
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
unmodified canonical `make verify` is queued/running separately.

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
pass after tightening an initially ambiguous reset-line anchor. Native RTL
qualification of this repair is **pending**, not inferred from source tests.
The first prepared controller was stopped before compilation after detecting
the same invalid register-port choice. Corrected controller root
`ventium-fst-range-core-r2.drV0OWQH` preserves that attempt and waits for actual
parent closure plus the separately successful register retry. It will build
with 32 compiler jobs, run unmasked and masked FST/register observers, and run
the unchanged canonical gate. No concurrent Vivado family is allowed.

NaNs/unsupported encodings, all unmasked arithmetic exception responses,
legacy-memory FST, delayed #MF delivery and memory-fault transactional ordering
are **not qualified by these finite-store checks**. Full Quake timedemo,
Win95 desktop, CoreMark correctness, green differential gates and physical
FPGA acceptance remain required.
