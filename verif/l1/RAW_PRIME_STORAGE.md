# Unreachable retained storage in cache-only priming — October 16, 2026

**Private candidate; smaller netlist, but unplaced timing regresses. Not
promoted, routed or deployed.** The extracted
state tests, guarded whole-core build and fresh private-reference corpus pass.
Canonical verification remains **FAIL**. All eight directed native corpora pass
and independently match the current parent; their old aggregate assertion fails.
The combined input/storage build saves 805 LUTs and 458 registers, but estimates
35.374438 MHz versus the parent's 36.968577 MHz. There is no frequency or
gameplay gain. A matching cold Win95 simulation is now live, not accepted.

## Evidence for the structural problem

The faster [boundary-stage parent](../fe_pipe/SFETCH_BOUNDARY_STAGE.md) has a
**36.968577 MHz unplaced estimate**, below 40 MHz. Its 92-level worst setup
path ends at `pipe_mem_active_q`, through `mc_next_ready`, `mc_any_accept`,
`mc_chain_accept` and the pairing/owner mux. The native primitive inventory
still contains **487 FDRE instances** named for the retained successor's ten
state objects, including three `mc_valid_q` instances. These are observed
parent-netlist objects, not measured candidate savings or exclusive cone area.

This build defines `VEN_RAW_V_READ_PRIME`. In that existing mode, cache hints
warm an L1 window but never become retained architectural successor packets:

```text
RAW preparation implies mc_prime_base
retained capture requires mc_prepare_ok && !mc_prime_base
therefore retained capture is always false
reset initializes all retained state to zero
all other assignments clear valid or hold the existing state
```

The original source already asserts that RAW execution never retains an owner,
yet leaves the complete sequential implementation for the mapper to simplify.
The critical path and register inventory show that simplification did not
fully happen in the matched synthesis.

## Exact specialization

[`prepare_raw_prime_storage.py`](prepare_raw_prime_storage.py) changes only
`rtl/core/core_mem_chain.svh`. Under the **existing** RAW define it assigns the
ten unreachable state objects their reset zeros. Non-RAW builds retain the
entire original sequential block byte-for-byte. Simulation additionally runs
that original block with private witness registers and asserts their complete
state remains zero after reset. A future change that makes retained capture
reachable therefore fails visibly instead of silently losing a request.

The live AGI, reference, ordinary V, held V, branch-successor and FP hint
equations are untouched, as are request/commit/ready, decoder, exception,
fragment, paired-store and ordinary U/V admission equations. No hint or safe
pair is disabled; no bubble, new stage, new build flag, timing exception,
snapshot dependency or workload-specific condition is added.

- Parent header: `3615d9ea4bf93e8c3e08958a1459b111f2bff692822d988d24ec9045f05787ca`.
- Candidate header: `89cad588b5e5e27674399591b8c150610533c1eed1495689b057f3ec5e8147af`.
- Parent directed model: `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
- Candidate directed model: `41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b`.

## Closed local evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

[`run_raw_prime_storage.py`](run_raw_prime_storage.py) extracts the original
storage block and actual `fpd_t` declaration. Each positive profile compares
all **556 state bits for 16,385 edges**, enumerating every 13-bit control
combination twice with changing nonzero descriptor payloads. RAW sees 3,072
preparation samples and zero retained owners. The non-RAW control sees 6,144
preparations and 18 valid-owner observations. Both see 8,193 reset edges.
This is a bounded extracted-state test, not whole-core formal proof.

All four negative cases fail: omitted RAW preparation guard, inverted capture
guard, wrong specialized constant, and accidentally disabled non-RAW capture.
The first two are contract-negative controls; the latter two mutate the
candidate specialization. The source guard is hash-pinned and rejects drift.
Z3 proves the zero-state induction under that source-checked prepare implication
(`unsat`) and finds positive preparation and both broken-guard witnesses
(`sat`). Other eligibility conjuncts are abstracted; no full-core formal claim.

Leaf owner `ventium-raw-prime-storage-leaf-oct16-r1.service`, invocation
`4c0b8bfc54b1490c9f1f1fb7aa19fb92`, closes exit0 / MainPID0 in **10.58 s**,
peak memory **30,089,216 bytes**, no OOM. All six native children close and are
reaped on CPUs18–21. Evidence: `raw-prime-storage-leaf-r1`.

[`build_raw_prime_storage_core.py`](build_raw_prime_storage_core.py) independently
regenerates the leaf fixtures, replays the solver and checks its exact closed
owner before compiling. All **195 source files / 153 definitions** are checked;
only the header above changes. The exclusive 32-job build retains assertions,
fatal structural warnings, full caches, UV/relocated fast paths and the original
10 GiB RAM / 2 GiB swap cap. Its fresh private harness object uses this model's
generated header. Native build closes exit0 / MainPID0 in **19.87 seconds**
with unchanged pins, owner `ventium-raw-prime-storage-core-oct16-r1.service`,
invocation `84b43587f7744888b1ae9d4011a4da0e`. Evidence:
`raw-prime-storage-core-r1`. Seven recipe/build/driver host tests pass.

The fresh private-reference corpus closes exit0 / MainPID0 in **107.68 s**,
owner `ventium-raw-prime-storage-func-oct16-r1.service`, invocation
`214d8095cce7497c8cd458593cc6a4fc`. The independent audit checks **12,370
input pins**, complete **80,800 records**, **30,132 actual V retirements**,
native CPUs4–7 and unchanged executable images. All 108 pass under existing
manifest policy; 105 pass with optional masks removed. The same three historic
x87 stack-fault cases (`tx_regform`, `tx_regform2`, `tx_stack`) remain masked
failures, not newly repaired instructions. Peak memory is 153,571,328 bytes,
no OOM. Evidence: `raw-prime-storage-func-r1/audit.json`. Private oracle
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85` is not
promoted over canonical QEMU. The first audit attempt ran before canonical
ELFs existed and stopped without a verdict; after that job closed, the same
audit passed without a native rerun or policy change.

## Closed whole-core checks and remaining acceptance

The unchanged canonical `make verify` uses actual AXI 7/7,
`--cycle-func --l1-axi` and `--l1-axi` cycle jobs. Its parent has known canonical
failures; they are not waived by local or private-reference tests. It closes
native make exit2 / controller exit1 / MainPID0 in **387.12 seconds**, retaining
**7 functional PASS / 101 FAIL** and nine failed cycle bands. All **20 complete
cycle streams / 66,807 records** match the selected boundary parent exactly;
that is not a cycle-band pass. Inputs remain unchanged; no masks, goldens,
instruction caps or bands were changed. Owner
`ventium-raw-prime-storage-verify-oct16-r1.service`, invocation
`a3705f2c1e504774915472f3fb9a2d83`. Evidence: `raw-prime-storage-core-r1/verify-closed.json`.

The eight original QEMU/full-architectural/cycle corpora ran through
the same exclusive guard: load/store, held V, branch, integer, FP, AGI,
reference and AGI/store. All eight native children exit0 in **259.81 s**,
but the original historical aggregate assertion closes controller exit1,
MainPID0. Owner
`ventium-raw-prime-storage-core-checks-oct16-r1.service`, invocation
`febd335ce935488f8ae109377d4f86c7`; native scope invocation
`1bb8eb4df8ed4070b282ad380fe6c64b`. Their original historical aggregate count
assertion is retained; it already differs from the selected parent's counts.

[`audit_raw_prime_storage_core.py`](audit_raw_prime_storage_core.py) independently
checks **43,224 input pins**, exact closed owner/invocations, original commands,
**4,240 complete stream pairs**, **641,832 architectural records and 641,832
cycle records**, and **163,956 actual V retirements**. Every current-parent /
candidate stream and all nine probe totals match. No records are truncated and
no masks or acceptance bands change. Evidence:
`raw-prime-storage-core-checks-r1/parent-equivalence-audit.json`.

The three historical aggregate differences are clocks 21,190,336 versus
16,951,320; reference hints 24,352 versus 22,872; and primes 282,808 versus
132,736. The second value in each pair is identical for the selected parent and
candidate, not a gain from this specialization. Both observe zero retained
owners. The remaining six aggregate fields are unchanged. The audit explicitly
retains `legacy_aggregate_gate_passed=false` and `canonical_gate_passed=false`;
same-input equivalence is not a standard-suite pass.

Full-PC transfer must use the now-qualified boundary/input composition, not
revive rejected prime-width/interior/readiness experiments or drop the input
repair. Matched synthesis/routing to at least 40 MHz, canonical repair,
duration-valid CoreMark, the complete standard suite and matching physical
FPGA Win95 cold desktop/UI and full Quake timedemo remain required.

## Closed full-PC transfer and integration controls

[`build_raw_prime_storage_soc.py`](../../fpga/build_raw_prime_storage_soc.py)
starts from boundary/input model
`afb30954ff40f52727d680e12bcc2dd229f427dcf932f329685d0e109a4c2710`,
not a rejected timing experiment. It checks all **102 common processor/FP
sources**, changes only the exact header, and preserves **157 definitions**,
the retained 8042 controller, keyboard host and `kb_fifo_rdreq` binding. The
new private harness basename prevents cross-model object reuse. All 20
canonical cycle streams must remain parent-identical; the ancestor boundary
cost and canonical failure remain explicitly recorded.

The 32-job, guarded 10 GiB RAM / 2 GiB swap build closes exit0 / MainPID0 in
**24.87 s**. Unit `ventium-raw-prime-storage-soc-build-oct16-r1.service`,
invocation `e83d1a3c1a374e2a905ab7d91711cb14`; evidence
`raw-prime-storage-soc-r1`. Model:
`e9159acb28b80a9511a87cfca1872ab907f43eb3e6f2956dc1a3d3150bcd0fd7`.
All 98 inherited SoC structural warnings are unchanged: this is not a clean
full-SoC lint result. Six transfer/control host tests pass.

[`raw_prime_storage_controls.py`](../../fpga/raw_prime_storage_controls.py)
retains the previous guests, grading, time limits, CPU affinities and resource
caps. Only lineage, input pins and exact parent comparison paths change.

- Cold translated/raw keyboard tests both close exit0, in **115.61 / 106.39 s**,
  with **29,326 / 29,006 actual V retirements**. Each delivers the same nine
  wire bytes; translated/raw guest reads are exactly six/nine bytes, without
  pending-byte duplication. Host-timed input is not a cycle-equivalence test.
  Independent audit checks **66,981 source pins**, exact native ownership and
  logs. Peak memory 106,983,424 bytes, no OOM. Evidence
  `raw-prime-storage-input-r1/audit.json`; unit
  `ventium-raw-prime-storage-input-oct16-r1.service`, invocation
  `ea2bc4c36a084f2eb6a37d9b1e4ff6bf`. This is not Win95 UI acceptance.
- Both unchanged ten-iteration CoreMark disks close exit0 in **221.22 / 223.07 s**.
  All five CRCs per seed match. Performance **4,771,298 clocks** and validation
  **4,755,366 clocks** exactly match the boundary/input parent: **0% measured
  throughput change**, not an optimization gain. Actual V counts are
  **1,055,307 / 1,054,254**. Independent audit checks **67,018 pins**, native
  arguments/affinity/ownership and terminal logs. Peak memory 106,844,160 bytes,
  no OOM, all children reaped. Evidence
  `raw-prime-storage-soc-r1/coremark-ui-disabled-r1/audit.json`; unit
  `ventium-raw-prime-storage-cm10-oct16-r1.service`, invocation
  `d1bc16efcde7451eaaa6d7768c303132`. The original too-short-duration error is
  retained; **neither a valid score nor full-seed correctness acceptance**.

The FPGA exporter now composes the exact CPU header, retained controller and
independently tested [keyboard-injector retry](../../fpga/KBD_INHIBIT.md).
All other payloads, including the corrected posted-memory/mouse wrapper,
must remain unchanged. Three export tests cover all 192 payloads and reject
missing repairs, unrelated edits, wrong geometry and promoted failures. The
initial test invocation used the wrong Python exception class for its negative
cases; correcting it to the existing `FreezeError` changes no export guard.
The bounded export closes exit0 / MainPID0, unit
`ventium-raw-prime-storage-freeze-oct16-r1.service`, invocation
`fc284af9f88e474894b4632c4c3a55c1`, peak memory **568,655,872 bytes**.
It checks all **170 common compiled HDL sources / 192 payloads / 159 hardware
defines**, with exactly those three payload changes. Manifest
`bf079f99538676ae1f43728b78ee52cc7d5b84ae0db49853ee545fcab0b72b66`
under `raw-prime-storage-fpga-r1`. Posted/nonposted wrapper preprocessing keeps
both input devices, but **full-wrapper elaboration, timing, placement/routing
and physical acceptance remain unqualified**. The independent
[`raw_prime_storage_evidence.py`](../../fpga/raw_prime_storage_evidence.py)
audit rechecks **68,320 pins**, every payload and exact three-delta recipes;
`raw-prime-storage-fpga-r1/source-audit.json` passes. Its unit
`ventium-raw-prime-storage-seal-audit-oct16-r1.service` closes exit0 / MainPID0,
invocation `4dd55d8bfdd6429e8924ef1d89e5b938`, peak memory 112,570,368 bytes.
The subsequent matched Vivado run is now live, as recorded below; no board
programming or new physical acceptance has occurred.

Resource housekeeping removed **24 regenerable PCH files / 2,209,299,500 bytes**
from closed builds, preserving and rehashing 6,011 source/log/receipt/binary
files. No source, guest image, executable or test trace was deleted. Receipt:
`closed-pch-prune-oct16-r2.json`. The failed cache R2 was excluded before deletion
when its incomplete row count failed preflight. There was no Chrome browser
process to close; other applications were left alone.

## Matched synthesis and timing closed: area reduction, frequency regression

Strict CPU-hierarchy lint of the exact **159-definition hardware profile**
passes in **3.78 seconds**, with unchanged inputs and the six existing fatal
structural classes. This does not qualify the complete wrapper or erase the
98 inherited full-PC warnings. Evidence: `raw-prime-storage-lint-r1`;
unit `ventium-raw-prime-storage-lint-oct16-r1.service`, invocation
`7a0acc68244f4c728186c318b5f83536`. Five timing-controller host tests also pass.

The matched native synthesis started **2026-10-16 09:53 UTC**, under
`ventium-raw-prime-storage-synth-oct16-r1.service`, invocation
`fb55d51d4ed349029e1555ebd5e6a0dd`, controller PID2398716. Its single guarded
Vivado family has scope invocation `a9873c3909494b4f87c4f6a2ae2a8b5d`;
the synthesis worker is PID2401943. The parent and its native worker are not
independent/orphan runs. Manifest and PC model are the exact sealed identities
above. Mapper settings, 40 MHz core / 100 MHz PL constraints and the faster
boundary-parent comparison are unchanged; the rejected prime-width experiment
is not the timing baseline.

`run_raw_prime_storage_timing_sequence.py` watches that exact invocation,
audits its terminal result, and only then schedules the prepared read-only
checkpoint timing report. It never starts implementation or deployment. Native
limits remain 45 minutes, 8 GiB RAM / 6 GiB swap, a 13 GiB combined early-stop
threshold and 4 GiB free-disk reserve. Synthesis closed native exit0 in
**2,078.94 seconds**, with unchanged inputs, no resource stop and no OOM. The
independent audit passes **68,407 source pins** and the exact three-delta source
closure. Peak guarded memory was 8,589,930,496 bytes with no swap; the cgroup
did reach its memory limit and reclaim pages, but recorded no OOM event.

| Synthesized resource | Boundary parent | RAW storage + input repairs | Difference |
|---|---:|---:|---:|
| LUTs | 187,990 | 187,185 | −805 |
| Registers | 55,218 | 54,760 | −458 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

This is the combined three-delta result, not an isolated RTL gain measurement.
The checkpoint SHA256 is
`2af6ae8a36eb11fd122f9519b4c2400f66603694f21ce08387fce06a30a2db60`.
The native log has zero errors and one critical warning, retained by the audit;
do not describe this as warning-free or standard-suite acceptance.
Evidence: `raw-prime-storage-synthesis-r1/{closed,audit}.json`.

The same sequencer admitted exactly one read-only timing job,
`ventium-raw-prime-storage-clock-oct16-r1.service`, invocation
`2756ba277aca4f219df64270f88fe3c0`, controller PID2408391. It closes native exit0
at **10:37:42 UTC**, in **522.25 seconds**; the sequencer and independent audit
also close successfully. The audit rechecks **68,390 input pins**, unchanged
40 MHz core / 100 MHz PL constraints, owner closure and native reports. Peak
memory is **4,828,667,904 bytes**, no swap or OOM. Audit PASS establishes report
provenance, not timing acceptance.

| Synthesized, unplaced estimate | Boundary parent | RAW storage + input repairs |
|---|---:|---:|
| Core Fmax, `1000 / (25 - WNS)` | 36.968577 MHz | **35.374438 MHz** |
| Setup slack at 40 MHz | −2.050 ns | −3.269 ns |
| Worst-path logic levels | 92 | 94 |
| Paired-V capture setup slack | −1.886 ns | −1.811 ns |
| Paired-V capture cone cells | 68,492 | 67,381 |

Frequency regresses **4.31%**, despite the smaller area and slightly improved
paired-V capture path. The native primitive tables contain **487 → 0 FDREs**
named for the ten retained objects, so the intended storage removal occurred;
the net total register reduction is smaller because other mapping changed.
This does not solve the chip's worst path. No isolated input/storage contribution
is claimed, and no route run or deployment is justified by this result.

The new worst path is `q_pc[0]` → `int_err[0]/CE`: 27.972 ns of data delay,
including 5.500 ns logic and **22.472 ns estimated interconnect**. The report
crosses fetch alignment/prefix decode, `d_fetch_need`, `sfetch_want_size`,
fragment strobes, route/cacheability, store-pair credit/request, backing ACK,
`l1_c_ack` and exception-delivery control. Synthesized names are evidence of
the mapped dependency, not proof that every named state can be sensitized
simultaneously. In particular, inspect the remaining read-only system-control
consumers of general `mem_ack`: the core already has an equivalent
final-fragment `mem_read_ack`, but IDT/CS descriptor, IRET and other slow read
owners still use the general write-credit-dependent completion. Any proposed
cut must cover GPR/commit mirrors and retain the mixed walk's A/D writes,
fragment hold, faults and request ownership. No additional ACK repair has been
implemented or qualified here; do not repeat an already rejected size/credit
cofactor and call it a new timing result.

Evidence: `raw-prime-storage-clock-r1/{closed,audit}.json`, its native timing
and primitive reports, and `raw-prime-storage-sequence-closed.json`. All are
unplaced diagnostics; **40 MHz synthesized/routed closure remains unmet**.

A second pre-launch cleanup removed only **10 regenerable PCH files /
904,073,303 bytes**, rehashing **2,171 preserved files**. This included the two
successfully closed positive children of the otherwise failed cache R2 run;
its failed mutant artifacts remain untouched. Sources, guest media, binaries,
receipts and traces were retained. Receipt: `closed-pch-prune-oct16-r3.json`.

Subsequent lossless deduplication replaces **10,600 duplicate trace storage
instances** with hardlinks across only the two closed RAW-storage/prime-width
directed corpora. All 16,960 candidate/control trace paths and hashes, original
native commands and failed aggregate verdicts remain intact. It requires exact
closed service identities, the eight successful native child receipts, the
previous full-stream audit hashes, an empty open-file census and byte-for-byte
comparison before replacement; every affected hash is rechecked afterwards.
Observed free space increased from 7,150,727,168 to 8,022,327,296 bytes (other
jobs were still live). Golden traces, models, sources and guest media were not
touched. Receipt: `closed-core-trace-dedup-oct16-closed.json`; the plan records
original identities. The retained traces must be copied before any future
mutation because identical evidence files now share storage. That operation
alone did not meet the 8 GiB Win95 admission threshold.

Then **16 large capture-cone/primitive reports** from the closed rejected
next-ready, prime-width, interior-cofactor and backing-direction runs were
losslessly archived: **905,972,195 source bytes → 19,604,564 archive bytes**.
Each member was read back and SHA-256 verified before removing its raw copy;
all current candidate pins were rechecked before/after. All DCPs, summaries,
logs, receipts and source remain. Archive `rejected-clock-cones-oct16.tar.zst`,
SHA256 `cb5d163cd33ea7389985479229bcf9c158076cd4cccba5cd38d43cffc93f847e`;
`rejected-clock-cones-oct16-closed.json` records original paths, hashes and the
restoration command. This recovered about **845 MiB** and allowed the unchanged
Win95 admission threshold to be met without deleting unique evidence.

## Complete-trace diagnosis of remaining cycle failures

The new read-only [loop-budget analyzer](../fe_pipe/analyze_loop_cycle_budget.py)
accounts for every clock in four existing canonical cycle traces, including
startup and exit. It checks complete equal retirement-PC streams, contiguous
indices, monotonic clocks, explicit loop-entry addresses and independent FSM
clock totals. Seven host tests reject truncation, tail divergence and bad
accounting. No simulator rerun, trace trimming, gate change, new mask or altered
timing tolerance is involved. Evidence:
`raw-prime-storage-cycle-budget-oct16-r1.json`.

| Kernel | RTL / golden total | Excess before first entry | Excess first traversal | Excess subsequent complete traversals | Excess final traversal + exit |
|---|---:|---:|---:|---:|---:|
| `mb_depadd` | 4,626 / 3,400 | 65 | 1,160 | 0 | 1 |
| `mb_indepadd` | 3,028 / 1,802 | 65 | 1,160 | 0 | 1 |
| `mb_faddchain` | 10,306 / 9,201 | 64 | 1,035 | 4 | 2 |
| `mb_rmimm` | 2,295 / 2,027 | 65 | 62 | 0 | 141 |

Thus the integer add failures do **not** establish a steady-state pairing or
ALU throughput defect. After the first traversal, all 14 measured intervals
match the golden: dependent 203 instructions / 202 clocks; independent
204 instructions / 102 clocks. `mb_rmimm` likewise repeats ten instructions
in five clocks. The FP chain has one additional four-clock interval, then
nine equal 757-clock intervals. These are directed loop observations, **not
gameplay IPC, an accepted score, or a substitute for the still-failed totals**.

The independent-add native log records exactly 20 L1 fills, 160 backing beat
acknowledgements and 1,320 fill clocks, of which 1,160 are backing-wait clocks.
The actual frozen testbench applies `AXI_RLAT=7` **before every R beat**, not
only the first beat. The cycle oracle assumes an eight-clock cache miss.
The 1,160-clock first-traversal difference is consistent with this transport
cost; a cycle trace alone does not prove exclusive causation. Preserve this
stress profile and original failures. Before changing execution hardware or
claiming cycle-model fidelity, measure and reconcile the reference's memory
contract with actual AXI request/response timing; do not simply widen bands
or discard startup. The full-PC DDR model's first-beat/gap settings and physical
board latency are separate measurements, not this stress model's parameters.

## Matching cold Win95 simulation; closed desktop review pending

[`prepare_raw_prime_storage_win95.py`](../../fpga/prepare_raw_prime_storage_win95.py)
now prepares the established cold Win95 controller for PC model `e9159acb…`.
All **68,320 source pins** are rechecked. The native command, pristine guest,
ROMs, clocks, memory model, reset, capture and shutdown behavior are unchanged.
Five host tests verify exact command/environment equality, retained resource
guards, template-drift rejection and stale-model rejection. The preparation
unit `ventium-raw-prime-storage-win95-prepare-oct16-r1.service` closes exit0 /
MainPID0 in 31 seconds, invocation `11ead01e99cd45a395a71e0a12d79b9c`.
Receipt: `raw-prime-storage-win95-prepared.json`.

After verified archive recovery, the run launches at **10:39:34 UTC**:
`ventium-raw-prime-storage-win95-oct16-r1.service`, invocation
`b70a11654a5a4aa889dc62c4ec6fb907`, controller PID2413671, native PID2413699.
The native child is observed live with **actual CPU10 affinity**, the exact
`e9159acb…` executable/argv, normal cold reset, the posted-16 RTL backend and
40/40/80 MHz simulated timebases. The 2 GiB RAM / no-swap / 160-task / one-CPU
limits, 8 GiB disk-admission threshold and 4 GiB live stop reserve are unchanged.
Its controller cannot award a desktop PASS. The run is **boot-only**;
interactive keyboard/mouse and physical-board validation remain separate,
unfulfilled requirements. No snapshot, guest patch or UI-input bypass is used.

The closed-result checker now has a separate schema 6 profile,
`board-posted16-40mhz-retained-input160`. It preserves the previous exact native
command, resource limits, cold-reset, process closure, immutable-file and manual
raw-frame review checks. It additionally binds the sealed FPGA manifest,
retained-input audit and `coremark-ui-disabled-r1/audit.json` to this exact PC
model. Complete native `VEN-PERF` records must show actual V retirements and
consistent, monotonic total U+V counters; these are boot-execution evidence,
not a gameplay IPC measurement. All **51 host checker tests pass**, including
stale/rehashed lineage, missing pairing, bad counters, legacy-profile borrowing,
resource changes, incomplete closure, snapshots and invalid visual evidence.

[`freeze_raw_prime_storage_win95_expectation.py`](../../fpga/freeze_raw_prime_storage_win95_expectation.py)
retains the prior live `/proc`, service-invocation, native argv, affinity,
cgroup, ROM/disk and source checks, with three passing host tests. It requires
the actual new invocation at launch and cannot launch a guest or manufacture a
desktop review. Independent admission closes exit0 in the service
`ventium-raw-prime-storage-win95-admission-oct16-r1`, invocation
`94d3dbee0f8842ba885b162b9ec7c2c3`, after checking **66,976 build pins and 28
runtime pins**, live native identity/affinity and zero OOM events. Expectation
SHA256: `cee5930399a6bf2e35d8896e5211d3efb54c195a8e5624cd8f715517e3dba549`.
Evidence: `raw-prime-storage-win95-{expectation,admission-audit}.json` and
`raw-prime-storage-soc-r1/win95-cold-raw-prime-storage-oct16.1`.
At admission, no closed desktop evidence existed; closure is recorded below.
The short CoreMark/input controls remain preparation evidence, not
standard-suite acceptance. Running this functional input/boot check does not
promote the timing-regressed image.

The gameplay baseline at admission was **0.50229051 total U+V IPC**, model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, cycles
**1,400,065,247–1,500,065,247**. This is 38,787,572 U plus 11,441,479 V
retirements; U-only IPC is 0.38787572. It predates this candidate, which has
**no gameplay measurement**. Evidence is the independently checked
`v-result-carry-gameplay-window-1400-1500M-oct16-r1.json`; it is not timedemo
completion or physical-board acceptance.

### October 16: desktop captured, native run closed normally

The last raw capture, `frame_00005.ppm`, shows the Welcome window, readable
text, desktop icons and taskbar, with no visible error in the agent's review.
The two final published captures are byte-identical. The run was then closed
through its existing **host-only graceful stop request**, not by killing the
simulator or modifying guest state. No new simulation was launched.

At **1,015,115,499 cycles**, the simulator exits 0; the controller waits for it,
confirms the process group is absent, closes its held log, rechecks its source
and immutable input pins, and inventories all six published raw frames. The
same service invocation closes exit 0 / MainPID 0. `result.json` records
`CLOSED_UNQUALIFIED`, no terminal error, no collection errors, unchanged input
pins and no timeout/disk-stop reason. Its SHA-256 is
`f7736437fab8d5356ab8769a350522d4fa5961c2f7166d370012f8772ce2e9a7`.

Final counters: **215,063,707 total architectural retirements**, comprising
184,467,768 U and **30,595,939 V**. These are cold-boot execution counters,
not gameplay IPC or UI-interaction evidence. Repeated `FCB2:2FF7` #UD debug
prints are the previously documented ROM callback trap, not by themselves
proof of a crash; see [the earlier investigation](../../docs/WIN95_BITSTRING_FIX_2026-09-30.md).

Raw desktop witness SHA-256:
`0589d29b72d19308e5eb7eb4d62d0c96348cf6eb949d96c236f5d6a202f5f36c`.
The adjacent `frame_00005-review.png` is a lossless preview: decoded RGB hashes
match (`4403f8b271a2ade70021f8500366baec2dc0858d386c772ed7ce1dd351d626f7`).
The closed raw file, not that preview, is the acceptance witness.

**Human visual confirmation has been requested and is pending.** No manual
review receipt or checker PASS has been fabricated. Keyboard/mouse interaction
was not exercised. This is the RAW/input parent PC model `e9159acb…`, not the
new parallel-write-admission model; no current-candidate or physical FPGA
acceptance follows from this capture. Both existing Quake simulations remain
running separately.

Current verified simulation gameplay baseline is **0.497040387 total U+V IPC**,
model `b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`,
cycles **1,100,065,247–2,100,065,247** (U 384,240,079; V 112,800,308).
It predates RAW/input and parallel-admission; neither has a gameplay
measurement. This broader window is not FPGA IPC or a completed timedemo.
