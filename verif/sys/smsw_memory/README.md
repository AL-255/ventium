# Memory SMSW: Doom startup regression

Status: **isolated repair compiled; 248 full-trace differential case executions pass**
(88 initial + 60 privilege + 25 paging + 75 retry/latency cases). Twenty additional LOCK/segment cases
pass their Intel-spec RTL self-checks but **diverge from QEMU**; these are not
differential passes. Unpromoted; remaining corners and standard-suite
qualification remain open.
The physical-board finding is in
[FPGA_DOOM_2026-10-13.md](../../../docs/FPGA_DOOM_2026-10-13.md).
No guest patch, saved state, replacement DOS extender or U-only mode is used.

## Closed first-stage witnesses

`run_probe.py` cold-boots 80 SMSW cases plus eight ordinary-MOV controls:

- Real mode and protected CPL0; effective 16/32-bit address and operand sizes.
- Zero and nonzero DS bases, 16-bit BX+SI and 32-bit SIB addressing.
- Destination offsets 0, 1, 3, 31 and 4095: aligned, unaligned, dword, line
  and page-boundary spans. **Paging is off**, so this is not a page-fault test.
- Self-checks for the exact two-byte result, adjacent canaries, every GPR,
  preserved defined flags and unchanged register-form SMSW behavior.

Pinned QEMU `-cpu pentium` passes all 88. The unmodified PRIME-CS UV-fast core
rejects all 80 memory forms with exactly one #UD at the tested PC; all eight MOV
controls pass. The native run closed normally in 11.916 seconds. This is a
**missing-opcode regression/control result**, not repaired-RTL acceptance or a
QEMU differential trace pass. `--cycle-func --l1-axi` and delayed AXI responses
are explicit; the failing short probes do not establish actual V retirement.

Evidence: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/smsw-missing-r1`.
Owner: `ventium-smsw-missing-oct13-r1.service`, invocation
`366d1d792974416bbb724cebc5526c7c`; terminal MainPID 0 / exit 0.
Model SHA-256:
`73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca`.
`audit_probe.py` checks the exact emitted instruction bytes, fault vector/PC,
native closure, source/model pins and all 88 outcomes; `audit.json` records
hashes of the complete artifacts. Do not rerun the exclusive auditor in place.

## Proposed implementation

`prepare.py` rejects source drift/reapplication and transforms only three files
from the frozen PRIME-CS source. It does not modify those frozen inputs or the
checkout's dirty RTL in place:

1. Decode every legal `0F 01 /4` memory form as a two-byte write, independent
   of operand size. Preserve register forms and the unprivileged SMSW marker.
2. Dispatch memory SMSW directly to existing `S_STORE`. Do not use `S_EXEC`:
   its `SYS_MOVCR_FROM` arm writes a GPR unconditionally.
3. Supply `CR0[15:0]` to the existing store-data mux. Keep segment checks,
   translation, page-crossing preflight, ACK ownership, flags and retirement
   handling in the ordinary store path.

There is no new state, register, profile switch, ISA shortcut or workload check.
Three source-contract tests pass (`test_prepare.py`); these are **not RTL
simulation or proof of behavioral correctness**. Preparation/build remain
separate from the 40 MHz timing experiment, whose frozen inputs are unchanged.

## Isolated native result

`build_core.py` retains all 195 parent source files / 152 UV-fast definitions,
assertions and a uniquely compiled model-dependent host. Only the three named
RTL files change. Compilation closes native exit 0 / unchanged pins in
19.763 seconds with 32 jobs; the scope journal records a 3 GiB memory peak.
The resource cap was lowered to 10 GiB RAM / 2 GiB swap, below the standard
32-job ceiling. No Vivado family was active during compilation.

Model: `smsw-core-r1/obj/tb_ventium`, SHA-256
`cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e`.
`run_diff.py` uses the unchanged QEMU system producer and comparator: all
**88 cases / 6,556 complete architectural records match**, including CRs,
selectors, GPRs and flags. No record trimming, extra masks or band changes.
Every repaired guest also exits with the independent success marker 0x42;
there are no fault deliveries. Native QEMU/RTL child affinity is observed as
CPUs 0–1, not inferred solely from a unit property.

Goldens: `smsw-golden-r2`; checks: `smsw-diff-r1`, under the same evidence
parent above. Both controllers naturally close exit 0 / MainPID 0.
`audit_diff.py` independently validates closure, the separate build-controller
and native-scope identities, exact three-file transformation and every full
trace comparison. Audit SHA-256:
`b2dcb434a336f655330994bd8f3082185e54d20b3879a0562ecac56d63f6ad52`.

The unchanged canonical `make verify` **closed red** in 405.562 seconds:
7 functional passes / 101 failures, native make exit 2. These include the
existing terminal-record and x87 status divergences; none is waived by the
directed passes. All 20 cycle traces have identical complete records to PRIME-CS.

To detect regressions hidden by that red gate, `run_regression.py` reruns both
models on each of the candidate's exact 108 inputs and initial stack pointers.
All **108 cases / 80,800 records** match the parent and reproduce the candidate's
original traces. The native controller closed exit 0 / MainPID 0 in 77.719
seconds, with unchanged input pins. Evidence: `smsw-regression-r1`; unit
`ventium-smsw-regression-oct13-r1.service`, invocation
`ec126ae3d4524763ab3c7ca1a76b148b`. The wrapper changes only the historical
replay driver's definition count from 150 to 152; exact definition equality
and every full-record comparison remain enforced. This is **regression
equivalence, not a QEMU correctness pass**.

There is still **no synthesis, checkout promotion, physical-board acceptance
or gameplay measurement for the SMSW derivative**.

## Privilege and precise-store corner results

`run_privilege.py` closes 60/60 full comparisons, **11,250 records**, in
6.004 seconds. The 48 SMSW cases cover CPL3 and V86, effective 16/32-bit
address/operand sizes, offsets 1 and 4095, default DS, default SS through
BP/EBP addressing, and explicit FS. DS/SS/FS bases are deliberately distinct
(0x2000/0/0x6000); the two nonselected destinations must remain unchanged.
Twelve ordinary-MOV controls also pass, including on pre-repair RTL; all 48
pre-repair SMSW probes deliver exactly one #UD. The repaired cases preserve
GPRs/defined flags and the exact two-byte footprint. Register r16 preservation
is checked; the r32 upper-half check preserves **existing QEMU compatibility**,
not an Intel architectural requirement (Intel calls that half undefined).

V86 uses IOPL=3 and explicitly allows only byte-wide port 0xF4 in its TSS I/O
bitmap. This is ordinary cold-boot test setup, not a guest snapshot. Failed
fixture revision `smsw-privilege-r1` is retained: its bitmap denied the V86
exit, and the checker counted duplicate fault diagnostics. Revision r2 fixes
those fixture/checker errors and recognizes architectural V86 EIP instead of
treating it as a linear PC. No RTL, comparator or QEMU patch was made.

`run_fault.py` executes 45 cold fixtures with caches enabled, CR0.WP=1, and
seven-cycle AXI read/write latency. The **25 paging cases / 2,960 records**
match QEMU completely: first/second page absent or read-only, plus writable
controls. The word starts at offset 0xFFF and maps across **nonadjacent physical
frames**. The handler checks fault PC, vector/error, CR2, every GPR, saved flags
and both destination bytes/canaries **before any repair or retry**. Physical
readback uses writable aliases. Both caches and paired execution are observed
in native counters; these short fixtures are not gameplay or throughput scores.

The remaining 20 cases (illegal LOCK, null DS, read-only DS and DS-limit
crossing, including ordinary-MOV controls) expose reference limitations:
RTL exits successfully after the expected precise #UD/#GP and unchanged-memory
checks; native QEMU exits with the test's failure marker and its trace proceeds
past the invalid access. The full comparator reports divergence. **The fault
driver therefore remains exit 1, not a 45-case differential pass.**

Specification check, using the PDF skill's rendered-page inspection:
Intel *Pentium Processor Family Developer's Manual*, Volume 3, **241430-004**,
printed pages **25-215** (LOCK) and **25-297** (SMSW), PDF pages 832 and 914.
LOCK must reject instructions outside its listed set; SMSW memory writes must
honor segment write access and limits. The pinned QEMU source's SMSW arm at
`target/i386/tcg/translate.c:6045` lacks a LOCK-prefix rejection; its segment
address helper only adds the selected base. The existing `run-seg-gate.sh`
and `run-pnullseg-gate.sh` already document the segment-oracle limitation.
No goldens, masks, fault behavior or canonical acceptance criteria were changed.

`audit_corners.py` independently repeats all 105 comparisons and checks exact
instruction encodings, fault PC/vector/error, native owners, model/source/input
hashes and terminal markers. It reports **85 differential passes separately
from 20 Intel-spec-only witnesses**, preserving the red full fault gate.
Audit: `smsw-corners-audit-r1.json`, SHA-256
`40789a717d90f1e201945b4b608799e57c23b33ea54ba40da559ad08dafe72f6`.

`run_fault_mutants.py` additionally rejects all **125 negative controls**:
45 removed-store/removed-fault variants and 40 variants for each deliberately
dirty destination byte. The latter alter only microtest initialization, so
each handler must notice the bad byte on its respective side of the boundary.
All exit with failure 0x43, with the expected zero/one fault and exact fault PC;
no RTL forcing or application patching. Runtime 3.345 seconds.

Evidence (same external parent as above):

| Run | Native terminal result | Controller invocation |
| --- | --- | --- |
| `smsw-privilege-r2` | exit 0 / MainPID 0 | `67f44768b30447fd9331644cd46c44c4` |
| `smsw-fault-r1` | exit 1 / MainPID 0, differential disagreements retained | `e9cfc969148f4945b313b9712368dd34` |
| `smsw-mutants-r1` | exit 0 / MainPID 0, all 125 mutants rejected | `edf9ac591744487d994ee5f25cf4b07f` |

These runs use at most 8 concurrent cases, explicit two-CPU native affinity
per child, 4 GiB RAM / zero swap limits, and watchdogs of at most 10 minutes.
All completed in seconds; no full-system benchmark, FPGA rebuild or deploy
was started for this qualification.

## Required next gates

- #SS and real/V86 64 KiB extent failures, CPL3 user/supervisor paging and #AC,
  retry outside the covered CPL0 page-fault cases, priority combinations,
  reset/event/debug boundaries and broader
  store-delay/backpressure coverage. Existing tests do not close these cases.
- Wider register/destination/prefix coverage; independently qualified full
  UV-fast execution and performance, not short-test aggregate counters.
- Update opcode coverage on promotion, keep differential gates green, and run
  the standard suite before declaring completion. Then rerun unmodified Doom
  on a newly qualified FPGA image and obtain an actual completed timedemo.

## Precise page-fault retry — October 13, 10:57 UTC

`prepare_retry.py` preserves the original fault handler's complete state and
no-partial-write checks, then adds ordinary guest page-table repair, two INVLPGs
and IRET to the **same faulting instruction**. The post-retry path verifies the
two-byte footprint/canaries, every GPR, defined flags, stack pointer and exactly
one handler entry. Writable controls require zero handler entries. No debugger
state writes, special RTL support or application patches are involved.

`run_retry.py` uses the unchanged full QEMU comparator and prebuilt isolated
SMSW model. Its 25 cold fixtures cover first/second pages absent or read-only,
writable controls, both address/operand sizes, and ordinary MOV controls.
They run separately at **0, 7 and 31 cycles** of AXI read/write response delay.
All **75 executions / 11,685 records** compare completely. The independent
`audit_retry.py` verifies actual fault vector/error/PC, the two visits to each
retried instruction, preserved completion state, instruction encodings, native
affinity/closure and all artifact/input hashes: **60 fault/retry paths and 15
no-fault controls**. This closes only the stated CPL0 paging retry coverage.

Negative tests in `run_retry_mutants.py` reject all **85 variants**: 25 missing
stores, 20 missing IRETs, and 20 dirty-byte initializations on each side of the
page boundary. Every variant reaches failure marker 0x43 with its expected
zero/one fault; the two page-byte checks and the requirement to return/retry are
therefore exercised. Four source/driver contract tests also pass. A first
mutant launcher failed before running any guest due to a Python local-name
collision; its failed service is retained, and the corrected run uses a new
output and controller identity.

Evidence under the existing external root:

| Run | Controller invocation | Terminal status |
| --- | --- | --- |
| `smsw-retry-l0-r1` | `413f10c1c94b43c79ddd8781208b1056` | 0 |
| `smsw-retry-l7-r1` | `7b55c1be32904dc596168bcb86d90d1b` | 0 |
| `smsw-retry-l31-r1` | `fbdc2c2c2f514e4cba11436392ca34a4` | 0 |
| `smsw-retry-mutants-r2` | `7cba8808a21a486083e33e7629528c83` | 0 |

Each matrix/mutant job uses a separate **1 GiB RAM / zero-swap** service, four concurrent
cases with observed two-CPU affinity per child, and a 600-second watchdog.
The seven-cycle matrix takes 3.77 seconds; the mutants take 2.96 seconds.
They ran beside the sole controlled Vivado build, without a second synthesis
or generated-RTL build. All of these test workers have exited.
Audit: `smsw-retry-audit-r1.json`, SHA-256
`a255b4306164502c097503620f7f6e5be3958e9120e4726b566759ae47d94844`.

The SMSW repair is still **not in the timing candidate or on the FPGA**. These
results do not clear the canonical gate, complete the standard suite, establish
gameplay IPC, or change the failed Doom startup/FPS result.

## Compose the repair with the timing candidate

`compose_prime_reg.py` has prepared `smsw-prime-reg-core-r1` under the same
evidence root. It verifies all **195 sources** against their compiled inputs,
all **152 UV-fast definitions**, the three native model identities, and the
independent parent audits. The SMSW change and register-only branch-flag change
are disjoint; applying them in either order produces exactly the same bytes.
Only four files differ from PRIME-CS: the three SMSW files listed above and
`core_mem_chain.svh`. All other source bytes are unchanged. There are **12,309
pinned inputs** in `prepared.json`; no existing candidate or live synthesis
input was edited.

Six composition/drift tests and four build-admission tests pass, including
rejection of overlap, extra edits, changed job count and inherited acceptance
claims. The first preparation check stopped before creating the candidate
because the corner audit uses `audit_passed`, not `passed`. The corrected
checker explicitly preserves its **85 differential / 20 specification-only**
classification and failed full fault gate; it does not treat an audit as a
correctness pass.

`build_combined_core.py` is ready to compile this composition, but has **not
run**. It retains the source-pinned native builder's command, 32 jobs,
assertions, private host/header check and 660-second native limit, checks that
no Vivado is live, and enforces **10 GiB RAM / 2 GiB swap** inside the shared
build scope. The wrapper admits the exact register-flag parent identity rather
than silently treating it as PRIME-CS. Successful compilation would still need
new combined-model differential, boundary, standard-suite and FPGA checks.
The combined source tree is not a timing result or deployable image.

Current-candidate gameplay IPC is **unmeasured**. The older simulation baseline
is **0.51030715 total U+V**, build `2b4d7a48`, cycles
1,200,065,237–1,300,065,237. This predates the candidate and is not Doom or FPGA IPC.
