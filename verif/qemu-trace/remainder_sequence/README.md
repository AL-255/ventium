# FPREM sequence and precision audit — 2026-10-15

Status: **two RTL arithmetic defects and one private-reference precision
defect repaired in private candidates; exception handling remains open**.
These are tested private derivatives, not canonical promotion or FPGA
acceptance. No production RTL, workload, golden, comparison mask or clock
constraint was changed. The unrelated backing-payload mux experiment was
[rejected after matched synthesis](../../l1/BACKING_PAYLOAD_MUX.md).

## Actual failures

1. **Reference precision control leaks into remainder calculation.** In
   private QEMU `da49b810…`, PC24/PC53 round both the scaled divisor and the
   remainder, sometimes raising PE. FPREM/FPREM1 are exact operations. Example:
   `A=3ffd:ffffffffffffffff`, `B=3fff:b123456789abcdef`, CW `007f`.
   The truncating quotient is zero and the result must remain A. QEMU returns
   `3ffe:8000000000000000` and sets PE. This is not an RTL mismatch to waive.
2. **RTL FPREM1 assumes every |A|<|B| quotient is zero.** A cold, self-checking
   UV-fast program evaluates `FPREM1(1.5,2)`. Native x87 and the private QEMU
   exit 0 with `-0.5`, Q=1. RTL returns `+1.5` and the guest exits 1. The full,
   unmasked trace first diverges at record 6, PC `0x0804801a`. RTL records
   three actual V retirements, uses `--cycle-func --l1-axi` and AXI latency 7;
   no debugger stepping, snapshots or disabled pairing are involved.
3. **RTL adjusts subnormal exponents without normalizing their mantissas.**
   The shared SRT recurrence requires matching normalized significands. The
   direct-engine control for `A=1`, `B=0000:0000000000000003` fails to terminate
   after 1,026 partial reductions (case 7516). Its final records alternate
   incorrect normal results with C2 still set. The failed native log is retained.

The cold model is
`7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5`.
The unchanged canonical gate remains **7 functional PASS / 101 FAIL**, with
cycle-band failures also open. Neither these diagnostics nor the successful
private 108-program corpus converts that into a canonical pass.

## Tests and proposed fixes

The PDF skill guided reading and visual inspection of the local Pentium
Volume 3 FPREM/FPREM1 pages (printed 25-122 through 25-125; PDF 739–742).
The [Intel manual](../../../ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf)
is unchanged. This established the exact-result, quotient-rounding and partial
reduction rules; native x87 supplies an additional defined-result comparator,
not P54 timing evidence.

`probe.c` executes actual i386 FPREM/FPREM1 instructions. It saves all eight
x87 payloads and restores architectural state between partial reductions.
This is an instruction context-switch test, not a workload save-state fix.
`oracle.py` uses integer arithmetic and admits partial N values 32–63 without
demanding identical native/QEMU step counts or undefined partial quotient bits.
It checks every recorded step, final remainder, quotient, signed zero, TOP,
CW, tags, unrelated payloads and unexpected exceptions. These selected
implementations reduce by multiples of 32 exponent bits, so the extra check
that the last quotient bits equal the original quotient is valid for them;
it is not an assertion that every otherwise legal partial-N policy preserves
the original quotient bits. DE delivery and unmasked exceptions are outside
this finite, masked fixture's qualification.

The first 7,488-case instruction run observed:

| Implementation | Step records | Failing step observations | Result |
| --- | ---: | ---: | --- |
| Native x87 | 216,768 | 0 | Pass |
| Old observer reference `52a9ca27…` | 171,044 | 97,796 | Fail |
| FRNDINT-repaired reference `da49b810…` | 171,044 | 96,868 | Fail |

The current reference fails 3,840 distinct cases: 1,920 each in PC24 and PC53,
and 1,920 each for FPREM and FPREM1. All have numeric failures and spurious PE.
PC64 has none. The earlier 34,200-case arithmetic/C1 test included only 620
small PC64 remainder cases; it did not qualify this precision/sequence space.

The private QEMU transform saves the internal precision setting, selects
extended precision for **only** `helper_fprem_common`, then restores precision
before exception merging. It does not clear PE to hide bad numbers, change RC,
alter global SoftFloat policy or replace canonical QEMU. A following-FADD
probe has no intervening FLDCW/FRSTOR, so it detects internal precision leaking
into the next instruction. Its 96 cases first passed native x87 and the
unmodified reference. Host tests deliberately reject a precision-leak record.

The [private shared-SRT transform](../../srt/prepare_remainder_exact.py) sends
small nearest-quotient cases through the existing exact subtract/normalize
stage, with a registered one-bit distinction for exponent difference -1.
It normalizes subnormal mantissas consistently with their effective exponents
and uses that exponent for complete and partial remainder packing. It retains
the shared divide/sqrt/remainder engine, with no extra normal-operation stage,
software workaround, extra architectural serialization or disabled fast path.
Area/timing and full-core regression qualification remain required; the extra
subnormal input shifts are not assumed free.

The shared-SRT sequence test uses the 7,488 cases plus 960 subnormal/small-quotient
cases, original-control and repaired split/unsplit profiles. Candidate success
requires all 8,448 sequences complete with exact results. The control's bounded
nontermination is a retained failure, not permission for the candidate to
truncate a sequence. This arithmetic-engine test cannot qualify top-level DE,
unmasked IE, NaN/unsupported encodings or empty-stack behavior.

## Evidence and lifecycle

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

- `run-r1`: failed instruction reference diagnosis, owner
  `ventium-fprem-sequence-oct15-r1.service`, exit 1, 177.43 s.
- `precision-r1`: 96 following-FADD checks pass; old reference only, not the
  proposed fix. `original_run_fixed.py` preserves the original driver hash.
  Its old `negative_control_rejected=true` field means the optional check was
  skipped, **not** that a precision mutant ran. The maintained driver reports
  that field as null when the check is not required.
- `small-quotient-r1`: cold UV-fast RTL failure, owner
  `ventium-fprem-small-quotient-oct15-r1.service`, invocation
  `065dc2018877409cb3c9336ec20f2a4b`, exit 1, 1.87 s.
- `srt-r1`: failed original-engine nontermination test; no repaired binary was
  built in that attempt. Original driver/testbench copies are retained.
- `srt-r2`: revised control lifecycle distinguishes the observed bounded
  control failure from candidate completion. Its affinity witness samples the
  actual simulator executable, not taskset's brief pre-exec inherited mask.
  It is now closed successfully: both repaired profiles complete all 8,448
  cases, 266,880 step observations each, zero mismatches. The original control
  completes only 7,516 cases, has 1,226 bad observations and fails its 1,026-step
  limit in the next case. That failure is not relabelled a correctness pass.

### Completed numeric/core checks

| Check | Result |
| --- | --- |
| Repaired private QEMU, both remainder instructions | 7,488 sequences / 216,768 steps, zero mismatches |
| Following FADD, no intervening precision reload | All 96 pass; original PC restored |
| Native/control/candidate negative comparison | Original still fails 96,868 step observations; native and candidate pass |
| Shared SRT, split and unsplit operand wiring | 8,448 complete sequences / 266,880 steps each; zero mismatches |
| Cold UV-fast original FPREM1 reproducer | All 23 records match; guest exit 0; three V retirements |
| Fresh private-reference functional corpus | 108/108; 80,800 complete records; 30,132 V retirements; 109.93 s |
| Adjacent FRNDINT/FIST/FST | 28,684 pass, including 27,072 independent integer-oracle cases |
| FRNDINT stack/priority/precision-state regression | 5,472 pass |
| Earlier arithmetic/C1/remainder regression | 34,200 pass |
| Unchanged canonical gate | **FAIL**, native exit 2; 7 functional PASS / 101 FAIL; 393.74 s |
| All 20 canonical cycle streams | Parent-identical; **not** cycle-band passes |

Private QEMU:
`1418bd574ee8c484987eacb87463fb1defa2629ce0ee7be9959ee37b7cc41f41`.
Its fresh build audited 11,132 source files and changed only
`target/i386/tcg/fpu_helper.c`, taking 29.58 s. `run-r2` takes 189.29 s.

Private core:
`86afc1911cc3c9a066ad5888414af81683226c0a083e9f9d0e2acd4d13582f76`.
It starts from the retained **prefix-payload** parent, not the rejected
backing-payload mux. Exactly `rtl/fpu/fpu_srt_div.sv` changes in the 195-source
closure; all 152 definitions and `AXI_LINE_REPLAY=0` remain. The 20.51 s build
uses a private harness basename/object and checks its generated header dependency.
Repaired SRT source SHA-256:
`f9fd5d2f24be3d43a5aa4d9ee9476058e953504765fca90de6ca5a45b4f8d3b9`.
The complete canonical DIV/IDIV/FADD/independent-FP cycle streams are unchanged;
this is not exhaustive divide/sqrt interleaving or exception qualification.

The independent [closed-run audit](audit.py) passed after regrading the raw
remainder sequences, both repaired engine profiles, the cold full trace and
all 108 functional traces. It checked **23,009 input pins** and all 11,132
private-QEMU source files. Removing the corpus's optional manifest masks gives
105 passes; the same three deliberate stack-fault programs remain failures.
No new mask was introduced. Audit SHA-256:
`993d69f391b956b3ad41571c95d8aef34ccfb2d499cad31707e916e482e02c5b`.
The audit took approximately 301 s, peak RAM 551,600,128 B. Its pass covers
these named numeric/core regressions, **not the separate failed DE diagnostic**.

All native owners in this stage have closed (MainPID 0). Reference build,
engine test and core build peaks were 3,601,084,416 / 1,439,879,168 /
3,379,478,528 bytes, each with zero recorded swap peak. Failures remain
failed owners: original reference diagnosis, original small-quotient RTL,
first engine control, canonical verification, and both DE diagnostics.

`small-quotient-r2/original_run_small_quotient.py` preserves the exact successful
runner before adding the generic `--program` diagnostic option. Its digest
matches the recorded cold-run input pin. The audit uses that explicit archive,
not a silently substituted later driver.

### Newly exposed exception gap — still open

`masked_denormal.S` checks that FPREM with a nonzero subnormal dividend raises
masked DE, while retaining the exact numeric value. Native x87 passes. The
older private reference fails its self-check. `denormal-r1` therefore stops
before RTL comparison and remains a failed owner with no completed closure.
The diagnostic runner now continues to collect RTL evidence after a reference
self-check failure, but requires **all** self-checks to pass for a green verdict.
`denormal-r2` is the separate follow-up and **fails**: native exit 0, QEMU
guest exit 1, RTL guest exit 1. The comparator reports all 14 records equivalent
and the RTL has three V retirements, but both omit DE; matching the defective
reference is not success. The 3.92 s owner closes exit 1 with all input pins
unchanged. This test used the earlier `da49b810…` reference; the new precision
transform does not add denormal exception handling and is not qualified for it.

The general follow-up is instruction-specific operand classification and
exception-priority handling in the QEMU remainder helper and shared-FPU commit
path: masked DE must become sticky; unmasked DE must leave the operands intact;
invalid/empty-stack priority and quiet/signaling NaNs need separate tests.
Do not globally clear flags, allow unsupported encodings to enter SRT, overwrite
ST0 on an unmasked abort, or treat numeric agreement as exception correctness.
The precision-only QEMU fix does not claim to repair this broader gap.

Reproduction uses fresh output leaves and explicit external TMPDIR. Run the
reference `build.py` and `../../srt/run_remainder_exact.py` through guarded
`ipc_parallel32` owners (CPU8–15), followed by `run_fixed.py` on CPU12.
`../../srt/build_remainder_exact_core.py` uses CPU0–31 and requires the successful
engine receipt; the cold runner uses CPU13. `run_small_quotient.py --core CORE`
selects the normal reproducer; add `--program masked_denormal.S` for the still
failing DE case. `audit.py --root ROOT` requires terminal owners and CPU13.
All directed owners have explicit 120–720 s caps. The failed R1 inputs are
archived, not edited to make their recorded failures disappear.

All generated output stays on the external ext4 scratch filesystem. The
32-job reference/RTL builders use the real serialized build lock and retain
FD9, cap their owned scope at 10 GiB RAM / 2 GiB swap, and refuse live Vivado.
The new instructions are bounded diagnostics, not standard-suite runs.

Still required: whole-core UV-fast differential tests, unchanged canonical
gates, ≥40 MHz closure, duration-valid CoreMark and both full correctness seeds,
complete Quake timedemo, and cold Win95 desktop/UI on the **candidate FPGA**.

Verified gameplay baseline: **0.50520554 total U+V IPC**, older simulation
model `c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`,
cycles **5,600,065,237–5,700,065,237**. It predates these candidates; candidate
gameplay is unmeasured. No IPC/FPS gain is claimed for oracle or remainder repair.
