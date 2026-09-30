# CoreMark cycle survey (2026-09-29)

## Latest implementation checkpoint

The latest **measured** raw-byte frontend candidate completes both standard
seed datasets with the correct five CRC fields. Its 10-iteration performance
diagnostic is **2.100583 CM/MHz inside the two clock-query boundaries**, or
2.071844 when including the whole program. Its whole-program CoreMark IPC is
**0.758462**. Neither normalized ratio is a valid-duration
CoreMark score: the short invocation fails the minimum-duration requirement.
The preceding combined experiment exposed `66` ESP-only WAW and prefix-owner
corner defects. Its corrected FIXED32 successor reproduces the same exact
CoreMark counts after the narrow repairs and passes the first 15 focused
prefix/AGI cases. The final fast gate passes 107 functional programs and all
20 M4/M5 kernel metric bands. The expanded prefix matrix has 382 actual passes
and two QEMU connection failures, not 384 verified cases; complete focused/
full-system qualification is pending. **The 2.1 CM/MHz
goal remains unachieved**; neither a short ratio nor a known-fidelity-defective
candidate establishes acceptance. This section supersedes the earlier
prototype measurements below; those measurements remain historical evidence.

| Frozen profile | Seed | Retired | Whole-program clocks | Timed-window clocks | Timed diagnostic CM/MHz |
| --- | --- | ---: | ---: | ---: | ---: |
| Raw control | Performance | 3,660,809 | 9,224,125 | Not instrumented | Not available |
| Raw candidate | Performance | 3,660,809 | 5,527,385 | 5,454,222 | 1.833442 |
| Raw candidate | Validation | 3,655,953 | 5,520,602 | 5,446,551 | 1.836024 |
| SHORT + width-correct alignment + CL | Performance | 3,660,809 | 5,151,285 | 5,081,505 | 1.967921 |
| SHORT + width-correct alignment + CL | Validation | 3,655,953 | 5,144,783 | 5,074,134 | 1.970780 |
| Above + exact slow-dispatch address mask | Performance | 3,660,809 | 5,126,964 | 5,057,830 | 1.977132 |
| Above + exact slow-dispatch address mask | Validation | 3,655,953 | 5,120,360 | 5,050,371 | 1.980053 |
| Above + prefix/AGI D1 overlap | Performance | 3,660,809 | 5,087,263 | 5,018,195 | 1.992748 |
| Above + prefix/AGI D1 overlap | Validation | 3,655,953 | 5,079,879 | 5,009,956 | 1.996026 |
| COMMON: above + authoritative prior-clock GPR writer mask | Performance | 3,660,809 | 4,936,433 | 4,869,034 | 2.053795 |
| COMMON: above + authoritative prior-clock GPR writer mask | Validation | 3,655,953 | 4,930,937 | 4,862,709 | 2.056467 |
| Experimental combined `66`/MOV ACK/control-target bytes | Performance | 3,660,809 | 4,826,619 | 4,760,583 | 2.100583 |
| Experimental combined `66`/MOV ACK/control-target bytes | Validation | 3,655,953 | 4,819,793 | 4,752,962 | 2.103951 |
| FIXED32: narrow `66` WAW/owner repairs, same work | Performance | 3,660,809 | 4,826,619 | 4,760,583 | 2.100583 |
| FIXED32: narrow `66` WAW/owner repairs, same work | Validation | 3,655,953 | 4,819,793 | 4,752,962 | 2.103951 |

The matched performance input loses **47.67% of whole-program clocks** with
unchanged retirements and CRCs. This is a bundled comparison, not an isolated
gain attribution. The candidate uses registered instruction bytes, direct
reference-decoder handoff, byte ALU/shift support and real pre-writeback
integer execution occupancy. It does **not** compile `VEN_UOPCACHE` or
same-pair load-use forwarding. Execution remains in order. It still bypasses
the SoC L1/AXI data service; every recorded request-wait counter is zero.

Latest performance clock queries are at cycles **24,951 and 4,785,534**;
validation queries are at **25,549 and 4,778,511**. The opt-in
`TB_CLOCK_CYCLE_PROBE` records the service boundary without changing guest
timer values. Printed guest elapsed time is not used as the cycle denominator.

### Round wrap-up: techniques and measured gains

Work is stopped at the user's request. No further simulation, build or host
profiling is queued. Both fixed seed-10 datasets have matching reference CRCs;
the current performance diagnostic is **2.100583 CM/MHz, IPC 0.758462** and
validation is **2.103951 CM/MHz, IPC 0.758529**. These are not valid-duration
scores; the complete standard suite and remaining qualification are not
claimed passed. CoreMark CPI also remains above one.

All rows below use the same pinned performance input, dataset and 3,660,809
retirements. Step gains are measured net cycle changes, not additive estimates
of independent features. The control is a historical macro-off profile, not
a fully period-accurate P54 timing oracle.

| Successive measured profile | Whole clocks | Clocks removed in step | Step reduction |
| --- | ---: | ---: | ---: |
| Raw control | 9,224,125 | — | — |
| Registered-byte raw candidate + real EX occupancy | 5,527,385 | 3,696,740 | 40.08% |
| Width-correct alignment + SHORT + CL timing | 5,151,285 | 376,100 | 6.80% |
| Exact slow-dispatch EA read mask | 5,126,964 | 24,321 | 0.47% |
| Paid prefix D1 overlapping AGI | 5,087,263 | 39,701 | 0.77% |
| Authoritative preceding-clock GPR writers | 4,936,433 | 150,830 | 2.96% |
| Fixed `66` pairing + MOV ACK + control-target bytes | 4,826,619 | 109,814 | 2.22% |

The bundled control-to-fixed reduction is **47.67% of whole clocks**, or
**91.11% more modeled throughput** for that identical short workload. Against
the first raw candidate with real execution occupancy, timed clocks drop
from 5,454,222 to 4,760,583: **12.72% fewer timed clocks / 14.57% higher
diagnostic CM/MHz**. Neither comparison is a completed full-duration score.

The fixing approach was evidence-first: reconcile exclusive per-clock owners,
preserve actual instruction occupancy, replace width-blind transfer penalties
with real source widths, use bounded resident-byte decode instead of redundant
fetches, track real prior-clock writer dependencies, retain paid prefix decode,
and admit only reviewed in-order pairing/ACK/target-byte paths. Real-include
leaves and focused pinned-QEMU witnesses check corner cases; discovered WAW,
owner and decoder-extent errors are repaired rather than hidden by looser
timing bands. Guest code, standard seeds and synthetic timer values were not
changed to create a gain.

Host acceleration is separate: qualified unchanged-input same-clock settle
skipping improves host throughput about **25–28%**, while profiling removal
adds only **2.9%**. Two model threads, serial LTO, and frontend-O3/larger-function
experiments are measured regressions, not adopted speedups. The fastest tested
host configuration still projects a valid-duration run beyond the authorized
30-minute cap; no checkpoint splicing or shortened guest work was substituted.

### Every observed performance clock

The latest exclusive FSM partition sums to **4,826,619**; the preceding raw
candidate is shown alongside it. The separate `S_PIPE` partition below sums
to the latest candidate's **3,158,271** clocks, not additional
clocks. Source width, paired instructions and reject reasons are diagnostic
attributes, not independent quantities to add to these totals.

| FSM owner | Raw candidate | SHORT/alignment/CL | Exact address mask | Prefix/AGI overlap | COMMON | Experimental combined |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Reset | 1 | 1 | 1 | 1 | 1 | 1 |
| `S_FETCH` | 8,712 | 8,208 | 7,912 | 7,888 | 7,896 | 7,896 |
| `S_DECODE` | 116,358 | 116,300 | 92,275 | 52,598 | 52,609 | 52,609 |
| `S_EXEC` | 1,448,026 | 1,448,322 | 1,448,322 | 1,448,322 | 1,448,322 | 1,340,498 |
| `S_LOAD` | 222,591 | 222,591 | 222,591 | 222,591 | 222,591 | 222,591 |
| `S_STORE` | 38,089 | 38,089 | 38,089 | 38,089 | 38,089 | 38,089 |
| FP states 12/13/14 | 217 | 217 | 217 | 217 | 217 | 217 |
| `S_PF` | 6,447 | 6,447 | 6,447 | 6,447 | 6,447 | 6,447 |
| `S_PIPE` | 3,686,944 | 3,311,110 | 3,311,110 | 3,311,110 | 3,160,261 | 3,158,271 |
| **Total** | **5,527,385** | **5,151,285** | **5,126,964** | **5,087,263** | **4,936,433** | **4,826,619** |

| First-selected `S_PIPE` owner | Raw candidate | SHORT/alignment/CL | COMMON | Experimental combined |
| --- | ---: | ---: | ---: | ---: |
| U or U/V issue | 2,275,886 | 2,275,812 | 2,275,812 | 2,280,584 |
| Reference-FSM handoff | 457,936 | 458,010 | 458,010 | 369,225 |
| Paid operand-prefix D1 | 0 | 0 | 0 | 88,785 |
| Address-generation interlock | 275,395 | 275,395 | 124,546 | 155,163 |
| `stall_cnt` drain | 251,631 | 1,019 | 1,019 | 1,019 |
| Branch misprediction | 169,570 | 169,570 | 169,570 | 169,882 |
| Registered I-cache buffer wait | 130,152 | 130,152 | 130,152 | 92,461 |
| Pending modeled memory penalty | 125,399 | 177 | 177 | 177 |
| Missing instruction bytes | 921 | 921 | 921 | 921 |
| FP issue/occupancy | 54 | 54 | 54 | 54 |
| **`S_PIPE` total** | **3,686,944** | **3,311,110** | **3,160,261** | **3,158,271** |

`S_EXEC` includes legitimate P54 multiply/extend occupancy; it is not all
waste. Nor are RAW/WAW, nonpairable instructions or real AGIs freely
recoverable. Timed-window 2.1 CM/MHz at ten iterations would require
4,761,905 clocks. The preceding COMMON diagnostic needed **107,129 fewer**
clocks; the experimental combined run is only 1,322 clocks below that ceiling,
before correctness/fidelity corrections. This tiny margin does not establish
a valid score or authorize weakening a P54 rule.
That arithmetic identifies the remaining gap, not a guarantee that any
particular proposed patch can close it.

### Confirmed defects and current qualification limits

- **Transfer-width timing:** old narrow-load paths applied a dword
  misalignment penalty to byte/word source reads, including MOVSX/MOVZX whose
  destination is wider than the memory source. Word reads at offset 1 were
  also charged despite not crossing a four-byte transfer boundary. The new
  shared predicate uses actual source width; 32,768 independent boundary
  checks pass. Architectural alignment-check exceptions are unchanged.
  The exact producer histogram records **117,932 falsely charged slow reads
  plus 7,346 falsely charged slow stores**. At three clocks per event this is
  **375,834 clocks**, exactly the observed `S_PIPE` reduction. Remaining
  modeled data-memory debt is only **1,196 clocks**: 133 real read misses
  times eight, plus 44 genuine transfer-boundary crossings times three.
  This is a direct-memory/cache-timing-model measurement, not an AXI result.
  The histogram's generic `old_dword_bad` attributes on fast reads/writes
  must not be added as historical charged penalties; those old fast paths
  already used their own width-sensitive checks.
- **Overfetched slow encodings:** a DIV at cache-line offset 17 required a
  complete 16-byte decoder window despite its encoding fitting the current
  returned line. This produced extra fetch clocks and three failed DIV timing
  bands in the measured candidate. The optional short-dispatch correction
  checks the actual encoding extent and returned-buffer ownership; its leaf
  passed 92,364 admitted encodings and 184,728 suffix-independence checks.
  Do not loosen the timing tolerances or replace goldens to hide the defect.
- **CL shifts:** the old fast CL path committed before the specified four EX
  clocks. The corrected candidate's already-started full-core witness passes
  140 cases against pinned QEMU, including memory and high-byte operands,
  8/16/32-bit widths and counts 0/1/3/32. Warm register gaps are six clocks,
  memory gaps seven; those include conservative frontend/store overhead and
  must not be claimed as an optimal four-clock pipeline.
- **IMUL immediate extent:** opcode `69` with a 16-bit operand incorrectly
  consumed four immediate bytes, skipping the next two instruction bytes.
  The source correction consumes/sign-extends imm16 for register and memory
  forms, preserving the dword form. It is present in the latest address-mask
  candidate, but the timed benchmark has no word-69 instructions. The new
  word-69 full-core pinned-QEMU regression now passes in the final FIXED32
  107-program functional gate; its timing gain is not attributed to CoreMark.
- **Unrelated-write slow-dispatch interlock:** the optional exact mask avoids
  a fallback decoder clock when the preceding fast writer does not update a
  real base/index register. It removes **24,321 whole-program clocks**:
  24,025 `S_DECODE` and 296 `S_FETCH`. Timed-window savings are 23,675.
  It does not remove any measured fast-path AGI clock: `S_PIPE`, its 275,395
  AGI clocks, the execution partition and the 926,946 paired-V retirements
  remain unchanged. Unknown/implicit address forms retain conservative
  fallback. This address-mask-only checkpoint did not fix writer history.
- **Paid prefix D1 hiding an AGI:** AP-500 section 5.5 permits the existing
  prefix clock to overlap the preceding address interlock. The optional
  admission still spends its capture clock and retains all execution clocks.
  Compared with exact-address-mask admission it saves **39,701 whole-program
  clocks** (39,677 decoder and 24 fetch clocks), **39,635 timed clocks**.
  Execution, data-memory debt, paired retirements and the fast AGI count do
  not change. Both seed CRC sets pass; directed qualification remains pending.
- **Authoritative preceding-clock writers (COMMON):** use actual gated GPR
  writeback enables, not stale fast-path destination tokens, with separate
  implicit PUSH/POP ESP treatment. Compared with prefix/AGI overlap, measured
  performance clocks fall by **150,830 whole-program / 149,161 timed**.
  The exclusive change is **150,849 fewer `S_PIPE` AGI clocks**, offset by
  11 additional decode and eight fetch clocks. Validation saves 148,942 whole
  clocks and 147,247 timed clocks. Both configurations still retire 926,946
  paired V instructions and have identical memory-producer histograms.
  This is the gain of the complete writer-history patch; it is **not** an
  isolated implicit-ESP gain. No writer-class cross-tab separates those causes.
  The real-include writer-mask leaf passes. Full-core directed qualification
  remains pending; measured COMMON binaries predate a later zero-count-shift
  checker-classification correction, not a datapath change.
- **Combined `66`/MOV/control-target experiment:** the bundled changes remove
  **109,814 whole-program / 108,451 timed performance clocks** from COMMON.
  Exclusive ownership changes are 107,824 fewer `S_EXEC` clocks and 1,990
  fewer `S_PIPE` clocks; every other FSM count is unchanged. Within `S_PIPE`,
  88,785 former reference handoffs become **88,785 paid prefix D1 clocks**,
  not eliminated clocks; registered fetch waits fall 37,691, while AGI grows
  30,617, issue grows 4,772 and misprediction grows 312. Paired V retirements
  rise from 926,946 to 1,010,959. This is not isolated per-feature attribution.
  The first 25 prefix/AGI, 152 MOV and 11 target-byte focused cases pass, but
  independent review found the new `66` register-only admission must reject
  explicit ESP-only WAW rather than reuse the legacy generic ESP exemption.
  Further prefix-owner corners are also pending. CRCs and initial directed
  passes do not overrule that finding; final qualification requires the fix.
  The corrected FIXED32 binary now passes its first 15 focused cases and
  repeats **every modeled CoreMark count** and CRC on both seeds. Its immediate
  host wall times overlapped that 2.1-second microtest batch and are not used
  as host acceleration evidence. The expanded prefix matrix subsequently
  verifies **382 of 384 cases**; two fail to connect to the QEMU golden and
  therefore are not correctness passes. No RTL mismatch was reported in that
  matrix, but missing goldens cannot establish either remaining case. Complete
  prefix/full-system/suite qualification is not inferred from partial results.

The preceding raw candidate passed **106 functional differential programs**, but
failed the three DIV timing bands just described. It is not fully gated.
The later SHORT/alignment/CL binary has built, passed the CL witness and
completed both CoreMark seed diagnostics. Its address-mask successor also
passes both seed CRC datasets and all exclusive-counter reconciliations.
Earlier approval rejection was
resolved by explicit user authorization for any CoreMark run up to 30 minutes;
the same bounded launch then succeeded. The measured diagnostic above 2.0 now
permits focused leaf and whole-core differential tests, each under ten minutes.
No full-suite, Windows, Quake or FPGA runs are active or claimed complete.

**Final fast-gate qualification:** `/tmp/cm_p54_fixed_verify.log` records a
terminal PASS on FIXED32 binary
`75e3d944c98c7d498d00457b9828894cbf136d11356ee2c0e705abbbd8592736`:
**107 functional differential programs pass**, including the new word-69
regression, and **all 20 M4/M5 kernel metric bands pass**. This closes the
earlier three DIV metric-band failures without loosening tolerances. The same
canonical log separately records **20 nongating per-instruction cycle-trace
comparator divergences**; its cycle authority is the metric bands, not exact
per-retirement cycle records. Do not describe this as cycle-exact equivalence,
`verify-sys`, `verify-all`, or a completed standard suite. The valid-duration
CoreMark score and Win95/Quake acceptance remain unverified this round.

### Next period-correct performance work

1. **Done:** measure the width-corrected candidate with the exact producer
   histogram; its 375,834-clock gain is independently reconciled above.
2. **Implemented and measured, not fully qualified:** exact address-register
   dependencies and actual preceding-clock gated writers now replace the old
   overly broad reader mask and stale fast-path tokens in COMMON. Qualify true
   base/index hazards, byte-parent writes, explicit ESP, implicit PUSH/POP,
   slow `S_EXEC`/divider writers, and address-size/SIB special cases against
   the unchanged Intel rules. Directed leaves are not a full-core replacement.
3. Overlap transient prefix decode / already-resident next-instruction fetch
   with older multicycle EX, without issuing younger effects or caching
   execution descriptors. Registered I-cache and ordinary/0F decode overhead
   are measured separately and must not be double-counted.
4. Enable P54-legal dual memory issue only against a correctly mapped L1
   benchmark configuration, with real `[4:2]` bank conflict, fault ordering,
   permissions and snoop checks. The current direct-memory measurement cannot
   establish its effectiveness or FPGA area/timing.
5. Register-only `66` pairing is useful but insufficient alone: there are
   about 53k such timed instructions per ten iterations. Current direct
   dispatch already pays prefix-D1 plus EX; the possible gain is the following
   legal V slot, not a zero-clock prefix. Separate operand width from code-IP
   width; applying operand `w16` to CS32 fallthrough would truncate EIP.

New `66` pairing, MOV ACK-retirement and target-byte frontend changes are
measured only as the separately labelled combined experiment; they are not
included in COMMON and their period-correct qualification is incomplete. Major core/cache
changes remain incomplete until the
standard suite and differential gates pass; this CoreMark-only session does
not establish full-system qualification.

Preceding raw measured binary SHA-256:
`b85a8e9cbafc93db89c34144f368e8a1df3ff40a43836f46575520919adb71b7`.
Compile-record SHA-256:
`e99be165175fc2868873197f9db757c3f81e16492456cad6d442b1176e62d2d3`.
Raw measured evidence is `/tmp/ventium-coremark-matrix.n3d2v1zt/`; the raw control
is `/tmp/ventium-coremark-matrix.d_y6qzap/`. The preceding measured binary is
`/tmp/obj_dir_cm_p54_align_short_sep29/tb_ventium`, SHA-256
`25c144395218655f68a0b2a183d7a372e3c2d393e33d6a84551c3940d7b5c730`;
Its CoreMark evidence is `/tmp/ventium-coremark-matrix.2ihz6t73/`;
compile-record SHA-256 is
`9adaf4cff8224acc03c8db4555d1349444ddeca82183d3c46d46ea4924052230`.
CL evidence is `/tmp/ventium-cl-execution.F50aIB/`.
The preceding address-mask binary is
`/tmp/obj_dir_cm_p54_agi_sep29/tb_ventium`, SHA-256
`e80272eb2a41144103afd6bf3a0fae916723e757f5c316a0eea92f51480193f9`;
its compile-record SHA-256 is
`e656beb9d7196a513cbca49d69cf1669235f466e4eb3e4978504e1ef3bba9dd2`.
Evidence is `/tmp/ventium-coremark-matrix.f381bfud/`.
The preceding prefix/AGI binary is
`/tmp/obj_dir_cm_p54_prefagi_sep29/tb_ventium`, SHA-256
`d003de036a9bfc1810daca8f6988a4795fdb69ab19bf8cc337d41da698587e2f`;
compile-record SHA-256 is
`a579914ca234630653cdae3b33a89a94d54724c1b9206f7ece4e1a911b16cbf1`.
Evidence is `/tmp/ventium-coremark-matrix.cez0y2xy/`; pre-edit provenance is
`/tmp/ventium_coremark_p54_prefagi_source_freeze.json`.

The latest COMMON single-thread binary is
`/tmp/obj_dir_cm_p54_common_t1_sep29/tb_ventium`, SHA-256
`a19f81d2365609dd9a05fb1784c4c1c0be922dacda883bc59718dab86ff4429b`;
compile-record SHA-256 is
`f167c125c5ff855ce7dcca10394671ed5e03e7c192c7072aafbe6c3c54a24a55`.
The matched two-thread binary is
`/tmp/obj_dir_cm_p54_common_t2_sep29/tb_ventium`, SHA-256
`65f337a9d4de19633ef4767fb4fa46a379b20a1034dc3c037716ec668a41ea11`;
compile-record SHA-256 is
`034ed7fcf223153b53eaa40c0407524144b89a347b4789ab53904475d961afb5`.
All four seed/thread runs are retained at
`/tmp/ventium-coremark-matrix.knpvg_rh/`; the 80-input pre-edit source hashes
are in `/tmp/ventium_coremark_p54_common_threads_source_freeze.json`.

Experimental combined NORMAL binary SHA-256 is
`0c1f589262b397b4ce21256e9ae541a075ce4cd272aae2cd79fc13c071fd8d01`,
compile-record SHA-256
`2a21b6d209c1fb65de49c793235181e03efa0a1069c8901af956006727ef1336`.
The serial-LTO counterpart's binary SHA-256 is
`666da6f5b8b73b713395e332cc58b30ad42d733a04e099fc4e6d3f1a37b5c2f3`,
compile-record SHA-256
`9692791b53656d5868117154bef71259a4b8c0a4413069ced63200fdfc7c9039`.
Evidence is `/tmp/ventium-coremark-matrix.mmfx_p6d/`; all 86 compiled input
hashes and both generated headers were frozen before production edits in
`/tmp/ventium_coremark_p54_combo_source_freeze.json`. Defines and production
input hashes match across the host compiler comparison; unresolved prefix
findings are explicit in both case manifests. These are superseded binaries,
not proof of any later source correction.

FIXED32 binary SHA-256 is
`75e3d944c98c7d498d00457b9828894cbf136d11356ee2c0e705abbbd8592736`,
compile-record SHA-256
`a29075460ec7eebdf68939388641198b71e27e4190d140597ecfcc1c74ce2c59`.
Its two-seed evidence is `/tmp/ventium-coremark-matrix.e5ysrwhx/`; 86 compiled
inputs and post-build host tool hashes are frozen in
`/tmp/ventium_coremark_p54_combo_fixed_source_freeze.json`.

Intel AP-500 (241799-002), printed page 17, explicitly describes MOVZX as
one prefix clock plus three execution clocks, four total when unhidden.
Section 5.5 permits overlap with the last preceding multicycle EX clock.
Thus the three-clock EX hold is correct; true transient D1/EX overlap must not
reduce MOVSX/MOVZX occupancy or retire early. Register-only MOVSX/MOVZX fast
execution is a separate pending change, not part of the latest measurement.

That permission is not evidence of universal three-clock MOVSX throughput:
the same manual schedules consecutive memory MOVSX four clocks apart.
The experimental `VEN_P54_PREFIX_EX_CHAIN` therefore vetoes EXT-to-EXT
handoffs. Remaining NP cross-kind D1/microcode-resource cases still need
period-correct qualification; a faster diagnostic with that switch cannot
establish the final P54-equivalent score.

AP-500 section 5.2 explicitly exempts **implicit PUSH/POP ESP updates** from
the following ESP-address AGI, while explicit ESP producers remain hazards.
The existing CoreMark instruction trace contains approximately 192k adjacent
implicit-stack-update/address cases. This is a candidate population, not an
isolated measured gain; COMMON's writer-history change saves 150,849 total
AGI clocks but the measurement does not separate implicit ESP from other
corrected writer-history classes. Do not extend that exemption
to CALL/RET/ENTER/LEAVE solely from the PUSH/POP example.

### Host execution limit

Removing both diagnostic RTL counter switches produces exactly the same
retirements, whole-program clocks, timed clocks and CRCs on both seed datasets.
The no-profile binary is SHA-256
`6c6e723dac22275ef65923b315b8c7686871c2cc5d8f1f4b266e198450b30091`;
compile record is
`94f34df19b238047ef0124bc0d4631b6543b8a58fba91ef0e97621178af30d3f`.
Evidence is `/tmp/ventium-coremark-matrix.d7b1wp8u/`, with the pre-edit
79-input provenance snapshot in
`/tmp/ventium_coremark_p54_agi_noprof_source_freeze.json`.

Performance/validation wall times are 20.5395/20.6386 seconds, about
249,615/248,096 model clocks per host second: only a 2.9% improvement.
The 1,500-iteration projection remains approximately 51 minutes, exceeding
the authorized 30-minute per-run cap, so that run has not been launched.
Host acceleration must leave all guest work and modeled clocks intact;
checkpoint splicing or changing timer values is not a scoring shortcut.

An exhaustive generated-input snapshot now also permits opt-in skipping of
unchanged **same-clock** reevaluations, never either clock-edge evaluation.
Matched on/off runs on the latest prefix/AGI binary preserve both exact query
boundaries, retirements, five CRCs, exclusive partitions and memory-producer
histograms. Performance wall time falls from 21.0879 to 16.5334 seconds;
validation from 20.5879 to 16.4849. All 10,174,526 performance edge evaluations
remain, 1,982,588 same-clock settles execute and 8,191,938 unchanged settles
are skipped. This raises host throughput about 25–28%, but still projects a
1,500-iteration run beyond 40 minutes; none has been launched.

The testbench now exposes opt-in model-thread counts independently of its
32-way C++ build jobs. Multi-threaded models serialize DPI calls, following
[Verilator's threading contract](https://verilator.org/guide/latest/exe_verilator.html).
The launcher reserves the compiled thread count in CPU affinity and task
budgeting. Such models must match the single-threaded CRCs, retirements and
exact clock windows before using their shorter wall times for a long run.

The matched COMMON one-/two-model-thread experiments do preserve every
retirement, clock query, CRC, exclusive counter, and memory-producer cell.
However, two threads are **slower**, not a host acceleration:

| Model threads | Performance host seconds | Validation host seconds | Performance clocks/host second | Projected 1,500-iteration performance minutes |
| --- | ---: | ---: | ---: | ---: |
| 1 | 16.1369 | 16.0839 | 305,910 | 39.79 |
| 2, serialized DPI | 16.9873 | 16.8838 | 290,596 | 41.89 |

These are four contemporaneous CPU-pinned diagnostics without an overlapping
heavy build, not a claim of a completed long run. The single-thread model is
the measured faster baseline. All 9,872,866 mandatory performance edge
evaluations remain; 1,751,658 same-clock settles execute and 8,121,208 are
skipped. Current generated C++ already uses `-O3 -march=native`, so selecting
O3 is not a new optimization. A valid-duration run near 2.1 requires about
397k model clocks/host second to fit the 30-minute cap; neither model meets
that rate. No 1,500-iteration candidate run has been launched.

General LTO remains forbidden by the shared build guard because an independent
linker worker pool could escape compiler-job control. The newly implemented,
default-off **`VL_LTO_SERIAL=1`** permits only three exact generated-make
assignments in the fixed `ipc_parallel32` scope: `USER_CPPFLAGS=-flto=1`,
`USER_LDFLAGS=-flto=1`, and `AR=gcc-ar`. The guard requires the complete bundle
exactly once; other profiles, partial/duplicate bundles and auto/jobserver LTO
are rejected. Make parsing also rejects use outside that profile. The normal
build remains unchanged.

GCC documents that the numeric LTO argument bounds link workers; absent a
link-time `-O`, it inherits the highest object optimization, here O3. Matching
`gcc-ar` supplies archive plugin support. [GCC optimization options](https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html#index-flto)
Six real-shell/Make policy unit tests and 23 matrix/parser unit tests pass.
The tiny real-include AGI smoke at `/tmp/ventium-lto-smoke.lrv98u/` compiles
every model/global/PCH object with numeric `-flto=1`, links with that same
numeric flag, and passes 5,894 checks. Its log explicitly reports **serial**
execution of two LTRANS partitions, not two simultaneous workers. The observed
cgroup limits are exactly 17,179,869,184 bytes and 128 tasks. The IR archive is
readable with the matching GCC symbol tool.

The subsequent frozen combined NORMAL/LTO four-run comparison preserves every
retirement, clock query, five CRC fields, FSM/pipe/pair counter, memory-producer
cell and input-settle counter on both seeds. **Serial LTO does not accelerate
this model:** performance takes 16.4836 versus 16.1844 seconds, validation
16.3851 versus 16.0844, about 1.9% slower. NORMAL achieves approximately 298k
model clocks per host second; its 1,500-iteration projection remains about
39.9 minutes, LTO about 40.6, both outside the 30-minute cap. No long run was
launched. The LTO root object has 46 `.gnu.lto` sections and an empty native
`.text`, unlike NORMAL; its archive contains readable IR, so a missing archive
plugin is not the explanation. Final text sizes are 16,014,749 versus
16,021,279 bytes. This changes the simulator compiler, not guest code, clocks,
seeds, timer values, or the P54 datapath.

Host `perf` sampling is unavailable: the system's `perf_event_paranoid=4`
rejects even a userspace-cycle probe; no security setting was changed. The next
bounded diagnostic is a general `--prof-c` build to identify generated ICO/NBA
hotspots, with gmon files under `/tmp`. A separate proposed host-only variant
uses true **Verilator** `-O3` (not the already-enabled C++ O3) and the existing
four-compiler/10-GiB profile's 20,000-operation function splits. The new
default-off `VL_FRONTEND_OPT=default|3` knob selects only this frontend option;
invalid choices fail Make parsing and the default adds no option. This approved
variant built in 72.999 seconds with the exact same 86 source inputs and define
set, not a new RTL timing policy. The official
documentation distinguishes module inlining from C++ optimization and notes
that finer C-function splitting can reduce simulator speed. [Verilator command options](https://verilator.org/guide/latest/exe_verilator.html)

The clean four-run FIXED32/FE3 comparison at
`/tmp/ventium-coremark-matrix.eifczevm/` preserves all guest retirements, clocks,
query windows, CRCs, FSM/pipe/pair partitions, memory-producer cells and settle
counts on both seeds. **The frontend-O3/larger-function bundle is slower:**

| Host model | Performance seconds | Validation seconds | Performance clocks/host second |
| --- | ---: | ---: | ---: |
| FIXED32, default frontend, 3k splits | 16.5341 | 16.5355 | 291,918 |
| FE3, frontend O3, 20k splits | 16.9885 | 17.1896 | 284,112 |

The variant costs 2.75%/3.96% more wall time; its text grows from 16,019,687 to
16,762,968 bytes. This bundled experiment does not isolate frontend inlining
from split size, but establishes that the selected combination is not an
acceleration. Its 1,500-iteration projection is still approximately 42 minutes;
no long run was launched. FE3 binary SHA-256 is
`5fc937b4c64a143af07bc5e9476e92e639769e0b4d7d331229532d1be9c1e8bf`,
compile-record SHA-256
`e7599be8546121d8526f52fbdf2a9448dea43f36661d82c16117ea827596b5ff`.
Both profiles are retained in the fixed-source freeze. Plain `--prof-c`
sampling remains the unexecuted next diagnostic; no profiler build was started
merely because another optimization failed.

The pending IMUL69 decoder-only runner was found looping before elaboration:
Python's default subprocess descriptor closing hid the inherited build-lock
FD9 from its active-scope check, causing repeated guard re-execution. The
exact process was terminated without compiling. The runner now preserves
only the validated lock descriptor for the scope probe and compiler child;
its rerun now passes all 144 decoder checks. It does not relax
the fixed shared lock, cgroup memory cap or task cap.

Focused leaf evidence from this checkpoint is retained in
`/tmp/ventium-agi-write-mask-leaf.wWvXNu/`,
`/tmp/ventium-imul69-decode-zwusc5ch/`,
`/tmp/ventium-int-exec-occupancy.vwNB6L/`, and
`/tmp/ventium-sdispatch-short-leaf-5fd4edb7/`.
Execution occupancy passes all four reference/native/iterative/experimental
profiles and both 1,280-check CL-decode profiles. The experimental profile is
only a functional leaf witness, never a period-correct score configuration.
Current SHORT extraction passes 92,363 admitted encodings and 184,726 suffix
checks; this source is no longer byte-identical to the earlier 92,364-case
leaf because new frontend work is underway. No frozen COMMON whole-core gate
is inferred from a changing-source leaf.

## Finding

The reported **1.086 CoreMark/MHz is a valid cycle-derived result for a
minimal, direct-memory testbench configuration**, but it is not a measurement
of the dual-issue FPGA feature set. That binary was built with only
`VEN_FPREM` and `VEN_SEG_ENFORCE`, and its 1,500-iteration invocation omitted
`--cycle`. It did not compile the registered I-cache/µop-cache frontend or the
optional fast-memory paths. The benchmark also bypasses the SoC L1/AXI data
path. Treating this result as a routed P54C-equivalent core score is a
configuration error.

On an identical 10-iteration input with identical 3,660,809 retirements and
data CRC `0xfcaf`, a profiled minimal build took **9,092,633** clocks, an
intermediate frontend build **7,225,038**, and the broader P54 fast-path build
**5,622,250**. The counters account for *every clock* in each of these short
runs. **3,138,753 of the 3,470,383 clocks separating minimal and broad builds
(90.44%) are extra `S_FETCH` clocks.** The minimal build sends about 788k
instructions through the slow fallback; each re-fetches a 16-byte window in
four serialized, already-acknowledged 32-bit transfers. This is avoidable
core-local sequencing, not an observed AXI or DRAM stall.

This does **not** prove that 90.44% of the 1,500-iteration deficit has the same
cause. Those full runs were not compiled with `VEN_PERF_PROFILE`; their exact
per-cycle state split cannot be reconstructed after the fact. The short-run
ratios do, however, agree with their corresponding 1,500-iteration ratios to
about 1–2%, and both full runs retired virtually identical instruction counts.

## Reproducible measurements and comparability

The workload is the pinned GCC 13.3 `p5cc` static i586 CoreMark ELF with the
same performance seed and dataset in all comparisons below. `CoreMark/MHz` is
`iterations × 1,000,000 / RTL clocks`; CoreMark's printed `Iterations/Sec` uses
the testbench's synthetic Linux time and is not the CPU-frequency result.
Ten- and 100-iteration runs print CoreMark's minimum-duration error even when
their data CRC is correct, so their normalized ratios are diagnostics, **not
official scores**. The physical P54C comparison of approximately 2.1
CoreMark/MHz uses a different compiler/library/memory environment; it is a
directional target, not an exact cycle oracle.

| Configuration | Iterations | Retirements | RTL clocks | CoreMark/MHz | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| Minimal, `--cycle` absent | 1,500 | 542,165,382 | 1,381,142,683 | 1.086057 | Completed; CRC `0x25b5` |
| Intermediate frontend, cycle mode | 1,500 | 542,165,384 | 1,068,908,947 | 1.403300 | Completed; CRC `0x25b5` |
| Minimal + profiler, `--cycle` absent | 10 | 3,660,809 | 9,319,910 | 1.072972 | Diagnostic; CRC `0xfcaf` |
| Minimal + profiler, cycle mode | 10 | 3,660,809 | 9,092,633 | 1.099792 | Diagnostic; CRC `0xfcaf` |
| Intermediate + profiler, cycle mode | 10 | 3,660,809 | 7,225,038 | 1.384076 | Diagnostic; CRC `0xfcaf` |
| Broad P54 fast path + profiler, cycle mode | 10 | 3,660,809 | 5,622,250 | 1.778647 | Diagnostic; CRC `0xfcaf` |
| Earlier broad P54 fast path + profiler | 100 | 36,188,797 | 55,235,622 | 1.810426 | Diagnostic; CRC `0x988c` |

The two completed runs are archived at
`/home/yukidama/ventium-bg-sep28/coremark_v86iret_sep29/performance.log` and
`/home/yukidama/ventium-bg-sep28/coremark_lar_correctness_sep29/performance.log`.
The complete short-run profiler logs are
`/tmp/coremark_survey_{minfuncprof,minprof,midprof,fullprof}_10.log`; the 100-iteration
profile is
`/home/yukidama/ventium-bg-sep28/coremark_candidate_ff0a803/coremark_100.log`.
The three short profiler binary SHA-256 IDs are respectively
`3a55fa106df4e766929f8aef0e93a0f7c0e423b9ec0343f47537c4f27c95a2a8`,
`d224a0f899d13c77195cf35094913c986e86b98c635318b093f3e48ad9b51a70`,
and `2c2e951d3f855d18f5c0320f00e78b3ddf9a720afd71ec7a060187b20912fcf7`.
The 10-iteration intermediate profiler reproduced the prebuilt intermediate
binary's **7,225,038** clocks exactly; the minimal profiler likewise reproduced
the prebuilt minimal binary's **9,092,633** with `--cycle` and **9,319,910**
without it. Thus the counters did not change those configurations' cycle
counts.

The relevant compile records are the `Vventium_top__verFiles.dat` files in
each Verilator object directory. The minimal build has no `VEN_IC_BRAM`,
`VEN_UOPCACHE`, or `VEN_PIPE_SDECODE`. The intermediate build has
`VEN_IC_BRAM`, `VEN_UOPCACHE`, `VEN_UOP_SFETCH`, `VEN_SFETCH_RESIDENT`, and
cross-line/repair options, but not `VEN_PIPE_SDECODE` or the broad fast-memory
set. The broad build has those plus `VEN_PIPE_SDECODE` and numerous fast-memory,
FP, and pairing switches. These are **bundled** A/B configurations; no
single-macro gain is claimed.

To reproduce the minimal diagnostic without touching the canonical testbench
build, compile with `make -C verif/tb OBJDIR=/tmp/obj_dir_coremark_profile
VL_EXTRA_DEFINES='+define+VEN_SEG_ENFORCE +define+VEN_PERF_PROFILE' VL_J=1
rtl` (one shell command; the line break here is visual). Run that binary on
`coremark_10.image.json` using `--emulate-syscalls --no-trace --cycle
--max-insn 10000000 --max-cycles 30000000 --quiesce 200000`; omit `--cycle`
only for the functional-mode control. Set `--out` and `--user-stdout` to
scratch paths under `/tmp`. For the intermediate/broad profiles, copy the
exact define lists from their recorded Verilator compile records and add only
`VEN_PERF_PROFILE`; never use a wildcard RTL filelist. All commands here use
direct-memory mode (no `--l1-axi`).

The archived intermediate run did not preserve its launch command, but its
473,692,929 bus reads over 1,500 iterations (~315,795/iteration) match the
same binary's explicit `--cycle` 10-iteration run (3,244,897 reads,
~324,490/iteration). Its explicit no-`--cycle` 10-iteration control made
61,783,101 reads (~6.18 million/iteration). The mode identification in the
table is therefore strongly supported by an A/B fingerprint, not by a saved
command line.

The missing `--cycle` is real: `verif/tb/tb_main.cpp` defaults it off and only
sets `ventium_top.cycle_mode` when requested. `core.sv` gates V pairing and
several fast paths on this port. It is **not** the whole explanation: on the
minimal binary, turning `--cycle` on changed the same 10-iteration run only
from 9,319,910 to 9,092,633 clocks (2.44%), because the hardware features
were absent at compile time. Conversely, the intermediate feature binary
without `--cycle` took 27,342,171 clocks: its functional-mode safety fallback
deliberately routes all µop-cache fetches through the slow decoder. Never use
that mode for a hardware performance claim.

The minimal *functional-mode* profiler also reconciles every one of its
9,319,910 clocks: **4,996,399** in non-`S_PIPE` states and **4,323,511** in
`S_PIPE`. Its `S_FETCH` count is **3,152,020**. Thus, including both the
compile-time feature gap and the runtime mode gap, the minimal-to-broad
10-iteration difference is 3,697,660 clocks, of which 3,138,921 (84.89%) are
extra `S_FETCH` clocks. It retired zero V-slot instructions, as expected for
`cycle_mode=0`; the cycle-mode minimal run retired 653,981 through V. That
mode switch saves only 227,277 *net* clocks here because different stall and
issue-arm counts offset most of the gross V-slot benefit.

At 2.1 CoreMark/MHz, 1,500 iterations would take 714,285,714 clocks. The
minimal run exceeds that by **666,856,969** clocks (48.28% of its observed
time). Switching to the measured intermediate cycle-mode build removed
**312,233,736** clocks, or **46.82% of that target gap**. The remaining
**354,623,233** clocks (53.18% of the original target gap) are *not* an
exclusive stall attribution: they include legitimate issue time, differences
from physical-P54 compiler/memory setup, and unmeasured configuration effects.

## Exclusive accounting of the 10-iteration runs

The profiler increments exactly one FSM-state counter per clock. Within
`S_PIPE`, it increments exactly one first-selected arm counter. State sums
equal reported clocks in all three runs; `S_PIPE` arm sums equal `S_PIPE`
clocks. State numeric IDs differ across define sets, so the table uses names.

| Exclusive state | Minimal | Intermediate | Broad fast path | Minimal minus broad |
| --- | ---: | ---: | ---: | ---: |
| `S_FETCH` | 3,151,852 | 897,306 | 13,099 | 3,138,753 |
| `S_DECODE` | 787,963 | 890,385 | 689,101 | 98,862 |
| `S_EXEC` | 787,839 | 890,252 | 655,364 | 132,475 |
| `S_LOAD` | 223,610 | 233,304 | 93,773 | 129,837 |
| `S_STORE` | 38,211 | 38,989 | 39,596 | -1,385 |
| `S_PF` | 6,440 | 6,447 | 15,471 | -9,031 |
| x87 states | 217 | 226 | 440 | -223 |
| `S_PIPE` | 4,096,500 | 4,268,128 | 4,115,405 | -18,905 |
| `S_RESET` | 1 | 1 | 1 | 0 |
| **All clocks** | **9,092,633** | **7,225,038** | **5,622,250** | **3,470,383** |

The `S_FETCH` decrement is the net source of **90.44%** of the minimal-to-broad
cycle reduction; some other states increase, so the causal contribution must
not be estimated by summing positive percentages as if the stages were
independent. Minimal-to-intermediate saves 1,867,595 clocks; intermediate-to-
broad saves 1,602,788. In the minimal run, `fp_sys_bail` is selected 787,936
times and `S_FETCH` lasts 3,151,852 clocks (4.0001 clocks per handoff). In the
intermediate run, `uop miss/!cycle` is selected 891,077 times and `S_FETCH`
lasts 897,306 clocks (about one per handoff). The broad build still has 690,022
µop misses but only 13,099 `S_FETCH` clocks, consistent with the enabled
in-`S_PIPE` slow-window capture. The relevant flow is in
`rtl/core/core_fastpath.svh` (slow handoff and `VEN_PIPE_SDECODE`) and
`rtl/core/core_fetch_decode.svh` (`S_FETCH` four-word fallback or resident-byte
copy); `IWORDS=4` is in `rtl/core/core.sv`.

The minimal `S_PIPE` 4,096,500 clocks split exclusively into:

| First-selected arm | Clocks |
| --- | ---: |
| Successful U issue (possibly paired V) | 2,218,851 |
| Non-simple handoff to slow FSM | 787,936 |
| `stall_cnt` execution/injected penalty | 439,981 |
| Address-generation interlock | 275,393 |
| Pending modeled memory penalty | 219,526 |
| Branch-recovery bubbles | 153,839 |
| Missing instruction bytes | 920 |
| FP issue/occupancy | 54 |
| **`S_PIPE` total** | **4,096,500** |

All per-state `mem_req && !mem_ack` counters were **zero**. This direct-memory
measurement does not exercise the SoC data cache, page-fill latency, or AXI;
it cannot answer whether those dominate Quake/Win95 on FPGA. The large bus
read count is caused by repeated acknowledged request *volume*: 15,815,361
minimal versus 3,300,789 broad reads for the same 10-iteration instruction
stream. It is not 12.5 million additional *wait* cycles.

## What remains after the broad fast path

The existing 100-iteration `VEN_PERF_PROFILE` log gives an independent,
exhaustive cycle partition for the broader build: **55,235,622 clocks =
22,611,391 issue clocks + 18,059,031 non-issue `S_PIPE` clocks + 14,565,200
non-`S_PIPE` FSM clocks**. Its score-equivalent is 1.8104 CoreMark/MHz, 13.8%
below the rounded 2.1 target, but it is too short for an official CoreMark
score. The top exclusive non-issue pipe arms are 6,773,727 µop misses,
4,333,450 `stall_cnt`, 2,774,555 AGI, 1,507,086 modeled memory penalties,
1,437,847 branch bubbles, and 1,230,103 registered I-cache read bubbles.
The slow FSM's largest states are 6,767,766 decode and 6,450,448 execute
clocks. All memory-request wait counters are again zero.

Only 6,803,827 of 36,188,797 retirements came from the V slot (18.8%).
Among the 22,611,391 otherwise successful U-issue clocks, 15,807,500 V
attempts were rejected by P5 pairing rules: 5,529,307 had a non-simple U or V,
6,538,536 an incompatible pairing class, 2,020,381 a U-to-V RAW dependency,
1,715,666 a V memory operand, and 3,610 a non-ESP WAW. These are *not* all
bugs or freely recoverable cycles; permitting illegal pairs would invalidate
P54 fidelity. The µop-map raw-hole survey identifies 6,511,493 non-simple
integer contexts and 1,402,983 simple non-memory contexts; of the latter,
978,000 were otherwise immediately issuable. Its endpoint split (physical
line end 631,424; known cross-line form 344,813; capacity only 800 in that
immediately issuable subset) argues against merely enlarging the descriptor
RAM. Full detail is in the archived 100-iteration log.

## Engineering actions and acceptance

1. **Fix benchmark identity first.** Require a declared feature profile and
   `--cycle` for performance scoring; print binary hash, source commit/dirty
   status, define set, input image hash, cycle/retirement counts and CRC with
   every result. Reject functional-mode or minimal-gate runs as FPGA P54C
   scores. Keep the pinned performance and validation seeds distinct.
2. **Remove serialized resident instruction re-fetch.** Give the slow decoder
   a tagged, 16-byte resident window (or a P5-like fetch/predecode queue) and
   capture it without four repeated bus beats. Preserve same-clock store/DMA
   invalidation, physical snoop identity, cross-line/page and CS-limit checks,
   exact fault priority, and functional fallback. `VEN_PIPE_SDECODE` is a
   measured prototype, not permission to bypass these checks. The master plan
   forbids relying on a persistent decoded-op cache as the final P54C model;
   transfer its safe byte-window lesson to the real frontend.
3. **Then attack the measured residual.** Attribute `stall_cnt` by producer
   (including multiply/divide and FP dependencies), pair rejection by opcode
   and register dependency, and µop/slow decode by line endpoint and opcode.
   Expand only P5-legal issue and memory forms. The intermediate-to-broad
   bundle saved 1.603M/10-iteration clocks, but individual optional defines
   need one-at-a-time correctness and FPGA PPA checks before adoption.
4. **Profile the real hierarchy separately.** This benchmark's zero memory
   waits cannot support a claim about AXI, L1 misses, or Quake. A full SoC
   CoreMark run needs a mapped guest image rather than merely adding
   `--l1-axi` to the Linux-user image (its stack is outside the routed DRAM
   aperture; see the preceding CoreMark note).
5. **Qualify any RTL change.** Run the fast differential gate after every RTL
   edit. A major frontend/cache change is incomplete until both CoreMark seed
   CRCs, Win95 desktop, Quake timedemo, and the differential gates pass; check
   FPGA timing/area as well. Nothing in this survey changes RTL or establishes
   a new gameplay result.

An exact cycle-by-cycle partition of the completed 1,500-iteration low-score
run requires **another full-duration instrumented run** of that identical
binary/configuration. The short profiled A/B runs establish the dominant
mechanism and reconcile every clock they actually observed, but they must not
be misrepresented as a retrospective full-run trace.

Latest independently verified Quake gameplay IPC remains **0.45746656** over
cycles **1,150,151,638–1,400,151,638** on frozen full-PC build
`3237b6523e8ec4c2db59ae0ef59012de45729b4852dcbdf8b3c20b7bc568d66d`;
it predates this working-tree candidate. No newer candidate gameplay IPC has
been verified.
