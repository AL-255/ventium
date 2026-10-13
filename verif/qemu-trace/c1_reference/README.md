# Composed private x87 C1 reference and newly exposed FRNDINT defect

October 13, 2026. **Private functional result: 107 PASS / one FAIL**, with the
unchanged 108-program worker and existing comparison rules. The remaining
failure is a newly confirmed RTL FRNDINT C1 defect, not a waived reference gap.
Canonical `make verify` is still red; no oracle promotion or FPGA programming.

## Reference changes and qualification

`prepare.py` composes the independently tested [round-pack event](../ROUND_INCREMENT.md),
[remainder quotient](../REMAINDER_QUOTIENT.md) and
[environment-pointer codec](../fp_env/README.md), then connects instruction C1:

- Arithmetic, divide, square root and narrowing stores consume the final
  round-pack increment. Internal temporary loads and generic pops do not.
- Successful ordinary FLD/FILD pushes, exact register stores, FCHS/FABS/FXCH
  and comparisons clear C1 at their instruction-specific sites. Push helpers
  leave existing occupied-destination behavior untouched; this does not repair
  QEMU's stack-overflow/underflow implementation.
- FRNDINT compares input/result magnitudes using an isolated SoftFloat status
  copy: its final format pack is exact after the integer rounding step and
  cannot supply the instruction's C1. Comparison exceptions cannot escape.
- FXAM, FPREM/FPREM1, FWAIT, environment restore and observation instructions
  are not subject to a global C1 clear. The explicit quotient repair supplies
  FPREM1's missing C0/C1/C3.

The Intel Pentium Volume 3 Table 6-4, section 7.1.13 and FADD instruction page
(printed 6-12, 7-27, 25-87) were visually inspected using the PDF skill. They
distinguish roundup, zero, sign, quotient and stack-fault uses of C1; undefined
C0/C2/C3 must not be confused with defined rounding C1. The local
[manual](../../../ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf)
is the same SHA-pinned 241430-004 source cited by the preceding diagnoses.

This is a **full private QEMU rebuild**, not a mixed old/new `float_status` ABI
relink. Its 11,132-file parent is the qualified pre-exit observer source.
Exactly four files change: `softfloat.c`, `softfloat-parts.c.inc`,
`softfloat-types.h`, and `target/i386/tcg/fpu_helper.c`. Independent edits are
composed against their exact common ancestor; overlapping edits and source
drift are rejected. The pre-exit observer stays opt-in. Canonical source,
binary, goldens, manifests, comparators, masks, timing bands and root RTL remain
unchanged. The primitive event header's old “no architectural consumer” comment
describes its original standalone proposal, not this composed helper.

`probe.c` is a bare i386 ELF running actual x87 instructions, not direct calls
to replacement C helpers. Architectural FLDENV seeds C1; no debugger register
write or workload save state is used. The same 34,200 inputs run under the
original observer, composed QEMU and native x87:

| Cases | Coverage |
| ---: | --- |
| 33,148 | Previously qualified exact-oracle arithmetic, sqrt, narrowing and pack cases; all RC and PC modes, signs, ties, subnormal/overflow boundaries and specials |
| 192 | FRNDINT at small exact, quarter, halfway and neighbouring values, both signs, RC/PC and C1 seeds |
| 240 | Ordinary loads, exact stores/pops, sign/exchange/compare operations, FXAM and FWAIT preservation controls |
| 620 | FPREM/FPREM1 complete reductions, signed inputs and nearest-even quotient ties |

The old QEMU has **24,254 C1/quotient mismatches**. The composed QEMU and native
x87 have **zero** against independently calculated expectations. Every numeric
result on both agrees with the old control. No candidate status bit outside
the explicitly tested C1/quotient fields changes. Native x87 is not P54 silicon;
this is a defined-result check, not a Pentium timing or undefined-flag oracle.

Full functional rerun: **80,800 complete architectural records**, 107/108 pass
in **112.31 seconds**, on RTL model
`369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150`.
UV/system/relocated fast paths, AXI backend, `--cycle-func`, and AXI read/write
latencies 7 are retained. Logs show **30,134 V retirements** across the corpus;
this is microtest activity, not gameplay IPC. Actual QEMU and RTL process
affinities are observed for all 108 jobs. The wrapper closes exit 1 for the
remaining failed comparison even though all native workers return zero.

The independent audit rehashes **25,314 pins**, checks all source deltas and
raw probe results, and reruns all 108 comparisons. A further fully unmasked
comparison passes 105 programs, **including all of `tx_fprem`**. The three
unmasked failures include pre-existing stack-fault differences; neither their
old masks nor their test programs were changed. No mask is extended to cover
the new FRNDINT mismatch.

## Newly exposed RTL bug and proposed repair

`tx_regform`, record **15**, PC **0x0804801d**, executes **FRNDINT (`D9 FC`)**
with CW **0x037f** and ST0 **`3fffcc4ab916fefc719e`**, strictly between 1.5 and
2.0. RTL, corrected QEMU and native execution produce exactly **2.0**.
Native x87 and the exact rounding rule require C1=1: FSW **0x0220**. RTL
reports **0x0020**. The complete comparison reports exactly this one unmasked
field difference, before the fixture's later intentional stack overflows.

`audit.json` retains an independent passive observation of the **unchanged
gate ELF**, before/after FP state, original instruction bytes and naturally
reaped native exit. Input, CW and numeric result agree with both full traces.
This is independent evidence for an RTL fault, not adjustment to match QEMU.

The current private RTL has two missing connections:

1. `ven_fp_misc` initializes `rounded_up=0`; its FRNDINT arm computes the
   rounded integer but never records the rounding decision.
2. `ven_fp_top` consumes that registered bit only for FST memory owners.
   Exact FRNDINT also needs a status commit to clear stale C1, even without PE.

Proposed general repair: retain the rounding decision already computed by the
integer quantizer and carry it through the existing registered misc response;
commit C1 for the completing FRNDINT owner only. Do not add a second wide
input/result comparator, clear all FP flags, alter response latency, or affect
an unrelated in-flight instruction. Cover exact/inexact results with both old
C1 values, all RC/PC modes, signs, zero, ties and subnormals; preserve precise
stack/exception/reset behavior and ordinary FIST/store controls.

Also test two source-inspection risks before accepting that repair:
FRNDINT currently routes through `fx_from_int(..., pc_q)`, although integral
results must not lose low integer bits at PC24/PC53; and rounding a positive
value just below 2^63 must not become signed integer-indefinite/negative.
These additional corners are **not yet established by a failing native RTL
test**. The current instruction probe's FRNDINT cases are small magnitudes.
Do not claim them repaired or use the C1-only witness to qualify them.

No FRNDINT RTL repair was included in the reference-stage commit. The subsequent
[isolated RTL repair](../../sys/frndint/README.md) now passes 28,612 directed
FRNDINT cases, a 412-case cold full-core program, and all 108 private-reference
functional programs. Its new denormal test also finds another defined-exception
gap in this private QEMU; canonical promotion and full acceptance remain open.

## Evidence, resources and reproduction

Root: `/home/yukidama/external/tmp/ventium-qemu-c1.Mw2HgVmG`.

| Artifact | SHA-256 |
| --- | --- |
| Composed QEMU | `01510a0f2592ab0f21306596a70160b3f31b6fbc0f8a0952dcf5bc322021c8e4` |
| `build-r1/closed.json` | `fb8f421327f59ca0ce0e04e929238d6f5345658243ae0eb599d598df3a7aeb79` |
| `probe-r1/closed.json` | `99b9eb6c436e840d89fa2214ca5ea9a09ba2df13ee5ea53597706ee1e3128551` |
| `func-r1/closed.json` | `69b04ab3c05f764bd48ccbdba673d12abbadfabba6c00c073a4b6375c18c3081` |

All three services are terminal, MainPID 0. Build owner
`ventium-qemu-c1-build-oct13-r1.service` invocation
`24784d83704841a1ad29b8faf779bac2`; its guarded scope invocation is
`4675e0f661ff46c9bed6f9f765a8a654`. Full native build took 29.44 s with 32
compiler jobs, peak 3,534,209,024 bytes and zero recorded swap peak. Probe owner
`ventium-qemu-c1-probe-oct13-r1.service`, invocation
`fb6d94b938a74479ae605b71f650ca16`, peaked at 64,204,800 bytes; its three
instruction runs took 0.205 s, excluding preparation/compilation. Functional
owner `ventium-qemu-c1-func-oct13-r1.service`, invocation
`d35fba827ef64064b87f91d5009f5753`, peaked at 149,585,920 bytes; no OOM events.

- `test_prepare.py`: set `QEMU_SOURCE` to the pinned source; two tests pass.
- `build.py --out FRESH`: bounded `tools/build_scope.sh`, explicit ipc_parallel32
  profile, CPU8-15 affinity, external TMPDIR; canonical build is read-only.
- `run_probe.py --build CLOSED_BUILD --out FRESH`: bounded service, CPU12,
  1 GiB/no-swap, 300 seconds; exact original control identity required.
- `run_func.py --build CLOSED_BUILD --probe CLOSED_PROBE --core CLOSED_CORE
  --out FRESH`: bounded service, CPU8-11, 2 GiB/no-swap, 600 seconds, four workers.
- `audit.py --root ROOT`: CPU12, writes a new `audit.json` after checking the
  named R1 closures and native witness; refuses overwriting an existing audit.

Three superseded QEMU R3 executables were removed only after a successful
lossless `tar --diff` byte comparison. Approximately **148 MB net freed**;
sources, models used by current runs and all logs were preserved. Recovery
archive: `ventium-qemu-env.oo7IGAh3/build-r3-binaries.tar.gz` under external tmp,
SHA-256 `4bf4958b4565a4ce7c74f5b32f5707daa6d3ebcd939c8aa6d7c63090ba8702b5`.
Extract relative to `ventium-qemu-env.oo7IGAh3` to restore the three R3 paths.
Free disk remains above 4 GiB, but below admission for a new heavy RTL build.

Still open: FRNDINT RTL repair, instruction-level unmasked/stack-fault and
partial-remainder qualification, deliberate canonical observer/cache promotion,
cycle-band failures, 40 MHz timing, full standard suite and physical UV-fast
Win95/Quake acceptance. No FPGA programming, clock change or gameplay run was
performed. Existing-bitstream Doom still fails startup; no Doom FPS exists.
Latest earlier endpoint/SMSW unplaced estimate: **35.057 MHz**, below 40 MHz;
later RTL has no timing result.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, `2b4d7a48`, cycles
**1,200,065,237-1,300,065,237**; predates this candidate, not FPGA/Doom IPC.
