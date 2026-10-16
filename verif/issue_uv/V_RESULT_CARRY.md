# V-pipe arithmetic carry cut — 2026-10-15

**Private timing candidate, not accepted or deployed.** The hardware change is
one expression in `v_pipe.sv`: call `alu_result(..., 1'b0)` instead of forwarding
U's CF into the arithmetic result. `flags_next` still receives the real
forwarded EFLAGS, so V INC/DEC preserve U's new CF. Decoder, issue eligibility,
memory ownership, commit gates, registers and cycle timing are unchanged.

The preceding wait-cofactor candidate synthesized to **37.9507 MHz** at the
unchanged 40 MHz constraint, with a worst path through U CF → V result → GPR.
This cut targets that path. **This candidate has no synthesis/routing result
yet**, and the parent's frequency must not be assigned to it. Equal cycles
are expected: this is an Fmax experiment, not a claimed IPC improvement.

## Safety argument and scope

Actual decode/issue requires `pairs_second`; ADC/SBB are U-only. No other
`alu_result` operation consumes carry. Removing that unused result dependency
does not remove the architecturally necessary CF forwarding for INC/DEC flags.
A simulation-only assertion checks every accepted V descriptor, including held
memory pairs, and rejects ADC/SBB or a missing `pairs_second`. Optional
`+ven_v_result_carry_witness` prints those accepted descriptors.

`prepare_v_result_carry.py` accepts only two exact predecessor hashes and
rejects drift/reapplication. The second changed file, `core.sv`, contains only
the nonsynthesized assertion/witness. The dirty checkout's production RTL is
untouched; the change lives in the reproducible private candidate.
`VEN_P54_REGMEM_PRIME` remains **disabled**, matching the parent. It was not
enabled to improve coverage or performance.

## Closed verification

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Directed parent: `c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a`.
Directed candidate: `a8e5d55b7704f2449002c71af8db1c5c2fe7ae908669fc5dbf2e663d3a59ff73`.

| Evidence directory | Result |
|---|---|
| `v-result-carry-leaf-r3` | Both profiles pass: 13,058,058 decoder and 18,724,320 arithmetic cases total; four deliberate mutants rejected; 26.81 s |
| `v-result-carry-core-r1` | Native build closes 0 in 19.65 s; all 195 source files audited, original 153 defines, private host object/header verified |
| `v-result-carry-system-r1` | 144 cold paged fixtures × AXI latency 0/7; 69,312 candidate records, 3,840 subject V retirements; 14.22 s |
| `v-result-carry-held-r1` | 24 fixtures × latency 0/7; 9,200 records, 1,360 V retirements; actual held-read witnesses retained |
| `v-result-carry-mixed-r1` | 36 U-load/V-store fixtures × latency 0/7; 240 V stores, immediate value readback, 1,140 held and 312 paired-read witnesses; 9.95 s |
| `v-result-carry-integer-r1` | 256 fixtures × latency 0/7; all 1,024 A/B measurements pass; no cycle changes; 32.05 s |
| `v-result-carry-fp-r1` | 384 fixtures × latency 0/7; 208,128 candidate records; all 1,536 A/B measurements pass; 50.16 s |
| `v-result-carry-boundary-r1` | Original 22 fetch-boundary fixtures × latency 0/7; 21,832 records, 4,968 V retirements; 29.45 s |
| `v-result-carry-matched-r1` | All 108 functional programs replayed on identical images/initial ESP: 80,800 complete architectural records equal; 25.57 s; not canonical acceptance |
| `v-result-carry-func-r1` | Fresh qualified-private-QEMU replay: 108/108 under unchanged manifest policy, 80,800 complete records and 30,132 actual V retirements; 109.04 s; not canonical acceptance |
| `v-result-carry-soc-r1` | Native full-PC build closes 0 in 25.77 s; private host/header verified; 98 inherited structural warnings unchanged, not full-SoC lint clean |
| `v-result-carry-lint-r1` | Strict CPU-hierarchy lint passes on the sealed 159-define hardware export; six structural classes remain fatal; 3.73 s; not full-wrapper lint |

The directed whole-core corpus compares complete architectural state against QEMU and
requires exact parent/candidate state and cycle records. The tests use UV + fast
pipeline, `cycle_mode=1`, actual `--l1-axi`, relocated clients and fast
load/store definitions. No STEP, intended-V breakpoint, saved state or guest
patch is added. Pairable subjects must actually retire in V; RAW-dependent and
ADC controls must remain unpaired. Every native owner closed successfully;
none of these results counts as the standard suite or physical FPGA acceptance.

The leaf checks all opcode/ModRM/applicable-SIB combinations in both code
sizes/cycle modes, exhaustive byte arithmetic and wide operand corners, both
incoming carry values, immediate/register forms, and enabled pairing classes.
It includes **624,144 INC/DEC-with-CF=1 cases** across two profiles. Mutants
clear the required flag carry or admit ADC to V; both are caught per profile.
R3 actually admits 1,676,236 V cases in the current profile and 1,290,089 in the
baseline profile. Leaf proof alone is not whole-core or formal equivalence.

Keep failed/superseded history: R1 stopped before compilation because the
driver incorrectly required disabled REGMEM. R2 passed arithmetic but its
broad sweep did not exercise pairing (only four final directed pairs).
R3 explicitly settles/checks a decoded U NOP and requires >1,000 broad-sweep
paired cases. **R2 is not qualifying evidence.**

Five recipe/leaf host tests, four full-PC transfer tests and four FPGA export
tests pass. The transfer/export tests
reject wrong/extra source changes, altered posted transport or definitions,
missing subject pairs and missing held/mixed witnesses.

## Full-PC transfer and remaining work

`fpga/build_v_result_carry_soc.py` transfers only the two tested deltas onto
the current AUX-corrected full-PC parent
`70c8de9eb55fda79b9fe359553ebd0b73de1e865c61414773000354edaff7b57`.
All 102 shared core/FP sources and the 157-definition profile are checked.
The PS/2 AUX ownership repair is retained byte-for-byte; an older peripheral
source is not substituted. The resulting native PC model is
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`.

The closed `v-result-carry-fpga-r1` export retains all mouse-wrapper changes:
192 payloads, all 170 shared platform HDL sources checked, and exactly two
changed payloads relative to the prior AUX/mouse export. Its manifest SHA-256
is `716dab7ee8801e5f865699f2b8619ae881b9d442feb4d59b42399abea758c77e`.
All 159 hardware defines and the 40 MHz requested core clock are unchanged.
The source-contract checker passes, but the complete FPGA wrapper is **not**
instantiated by the PC simulator. Full-wrapper lint/elaboration, synthesis,
route and deployment are still open. No timing result is inherited.

Canonical `make verify` closed **FAIL**, native make exit 2, in 411.30 s:
7 functional passes / 101 failures, including 90 length-only first failures
and 11 x87 status first differences. The inventory matches the parent;
all 20 cycle streams equal the parent, but this is not a cycle-band pass.
Independent canonical invocations have different initial stack addresses;
the identical-input replay above establishes equality without masking ESP or
normalizing records. No oracle, comparator mask, golden or band was changed.
The directed passes do not waive the red gate. Full canonical/system
qualification, both error-free standard
CoreMark seeds, completed Quake timedemo, and Win95 desktop remain open.
Matching physical FPGA Win95 cold boot plus keyboard/mouse interaction and a
complete Quake timedemo remain required before completion.

### Short CoreMark controls and live synthesis

Both ten-iteration cold CoreMark controls closed successfully on the new PC
model, with exact parent ticks and reference CRCs. Native owner
`ventium-branch-address-cm10-v-result-oct15-r1.service`, invocation
`575b548cdbf74aec918b414f12b08c13`, exited 0; all children reaped, inputs
unchanged and no OOM. Evidence: `v-result-carry-soc-r1/coremark-r1/{closed,audit}.json`.

| Seed | CRCs | Core ticks | Actual V retirements | Host time |
|---|---|---:|---:|---:|
| Performance | `e9f5 e714 1fd7 8e3a fcaf` | 4,767,218 | 1,055,307 | 213.21 s |
| Validation | `18f2 e3c1 0747 8d84 c64e` | 4,753,406 | 1,054,254 | 211.80 s |

These are **short regression controls, not duration-valid scores or standard
suite acceptance**. Their cycle-throughput gain is **0%**, as expected for a
combinational timing cut. They retain UV + fast pipe, cold reset, 40 MHz core/
RTC, 80 MHz VGA and posted16/B20/Rfirst21/gap1 transport. Native affinity was
CPU 12; the separate older Quake run remains on CPU 11.

One synthesis is now running in `v-result-carry-synthesis-r3`, started
2026-10-15 23:52:14 UTC. Owner `ventium-v-result-carry-synth-oct15-r3.service`,
invocation `a5b21d4ee38a4193989de23ecfd21c61`; exclusive native scope invocation
`7c318f143afb4695b1d09a981a8a0f21`. This is the same Default logic-only mapper
and 40/100 MHz constraints as the last synthesized parent. Relative to that
parent, **six payloads change and two mouse HDL files are added**: AUX ownership
and mouse-wrapper integration are also new. A future timing/area difference
therefore **cannot be attributed solely to the V-result cut**.

The native family is capped at 8 GiB RAM / 6 GiB swap and one synthesis job,
with actual CPU affinity 24–27 checked. Stop guards remain 4 GiB free disk,
2 GiB available host RAM/swap, 13 GiB combined scope memory and 45 minutes.
At 161 s: 5.57 GiB scope memory, zero swap/OOM; no result yet. No route or
deployment has started. The prior estimate **37.9507 MHz is not this build's
frequency**.

History is preserved: R1 was an unlaunched preparation; R2's owner
`9bf8913acd2b437f88ac57ba92d7ec5e` failed disk admission before any native CAD
launch. The bound is the larger of 6 GiB and 4 GiB plus twice the measured
parent growth (1,456,762,880 bytes): **7,208,493,056 bytes required**, not merely
6 GiB. More closed traces were archived; no guard was reduced. R3 is a distinct
owner/output directory, not an overwritten failure.

`run_v_result_carry_timing_sequence.py` observes only that exact R3 invocation.
Sequence owner `ventium-v-result-carry-timing-chain-oct15-r1.service`, invocation
`8e7a1f734d454d769bf928c2c7660cc7`, will first require successful native closure
and the independent synthesis audit. Only then may it launch the prepared
read-only clock report under the same exclusive scope. It never retries
synthesis or launches routing/programming. The report Tcl and process/resource
lifetime are unchanged; its report uses frequency in MHz and explicitly
distinguishes unplaced estimates from routed/measured hardware. Three synthesis,
four clock-controller and three sequencer host tests pass, including deliberate
resource-limit weakening, malformed invocation and altered-template rejection.

The older decode-bus Quake run remains separate and running (about 1.028 billion
startup cycles at this update). It cannot qualify this PC/FPGA source or provide
its gameplay IPC. Chrome was absent; no browser or unrelated application was killed.

Current candidate gameplay IPC is **unmeasured**. Older verified baseline:
**0.50520554 total U+V**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`,
cycles **5,600,065,237–5,700,065,237**. It predates this candidate.

## Evidence storage

Eight unpinned precompiled headers from the two closed leaf builds were removed
(659,150,526 bytes; regenerable). Closed integer/FP traces were compressed only
after every archived member's SHA-256 and size matched its original; binaries,
sources, commands, native logs, comparisons and receipts remain in place.
Archive: `v-result-carry-integer-fp-traces.tar.zst`, SHA-256
`51dc42ee9d88bafd005eef49691edb5d81362a32e47cc501fee42056eea84cf1`;
610,306,448 raw bytes → 1,722,077 archive bytes. Restoration instructions and
per-file hashes are in `v-result-carry-trace-storage.json`. No live run,
accepted image or source was deleted.

Additional storage recovery on October 15:

- `closed-generated-objects-removed.json`: 2,367 individually validated generated
  object/archive/PCH files removed, 904,030,996 bytes. All source, native binaries,
  private harness objects, dependencies, headers and evidence remain. Rebuilding
  regenerates the removed compiler products; the live Quake build was excluded.
- `v-result-closed-trace-reserve.tar.zst`: 2,682 closed traces, 303,059,035 raw
  bytes → 3,155,553 archive bytes; SHA-256
  `a093d52c3b65459761dfd892163b57419b19f1ef7fb6b8de676db820153594a3`.
- `closed-parent-trace-reserve.tar.zst`: 3,738 closed parent traces,
  752,904,401 raw bytes → 8,353,679 archive bytes; SHA-256
  `55f2064dbe0e2b909c9e684540a2bee1cc6c2d22ee88bc0e9e4fd02f4b8a8427`.

Both trace archives were read back and checked member-by-member before unlinking
originals. Their matching JSON receipts record individual hashes, terminal
owners and restoration commands. All frozen/current inputs were rehashed and
preserved; restore the relevant archive before rerunning a historical raw-trace
audit. External free space reached about 6.9 GiB before R3 admission.

## Fresh functional audit and cycle diagnosis — October 16 UTC

`run_v_result_carry_func.py` reruns the exact 108-program worker against the
current directed model `a8e5d55b…`, with private reference
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`.
The adapter changes only the model identity, repository location and CPU
assignment (12–15, disjoint from Quake and CAD). UV + fast pipe, relocated
clients, `--cycle-func --l1-axi`, AXI latency 7, all original programs,
instruction limits, manifests and comparison rules are retained. Every golden
is freshly produced in an isolated cache; this is not replaying the parent's
successful reference traces.

Owner `ventium-v-result-carry-func-oct16-r1.service`, invocation
`798617b6a0d94ce0965a1334842f22dd`, is exited / MainPID 0 / native 0.
Wall time is **109.04 s**, peak memory **157,786,112 bytes**, with no OOM.
`audit_v_result_carry_func.py` independently rehashes **12,357 input pins**,
checks native closure/actual child affinity, compares all **80,800 complete
records**, and verifies the **30,132 V retirements** from the AXI-backed logs.
All 108 flat images are byte-identical to the canonical run. For 54 ELFs only
GCC's randomized, non-loadable local `STT_FILE` name differs; loadable bytes,
headers, addresses and other metadata remain equal. Nothing is rewritten.

The separate fully unmasked comparison is **105/108**. The same three deliberate
stack-fault fixtures (`tx_regform`, `tx_regform2`, `tx_stack`) retain the existing
reference limitation: QEMU does not implement their stack-fault response.
For example, `tx_stack` first differs at record 20 in the indefinite payload
substituted by RTL. Existing per-record masks are unchanged; this result does
not promote the reference or waive canonical verification. Five adapter/audit
host tests pass. Native log/trace/closure evidence remains in
`v-result-carry-func-r1`.

The existing `verif/analyze_cycle_gate_costs.py` was rerun on this exact model's
20 retained canonical cycle pairs. Its six host tests pass; all 105 input pins
recheck unchanged. `v-result-carry-cycle-costs-r1.json` confirms the previously
documented [parent diagnosis](../l1/PIPE_WAIT_READ_ACK.md): first-occurrence
cost dominates the add/FP-chain deltas, while multiply retains a dispatch
bubble and the miss kernels retain large repeated costs. No new processor
execution or gate relaxation is involved.

The supplemental `audit_cycle_accounting.py` conserves every positive
cumulative cycle-counter tick, counting a simultaneous U/V retirement cycle
only once. All 20 streams pass that accounting; four host tests cover pairing,
idle gaps, cold intervals and invalid ordering. Artifact:
`v-result-carry-cycle-accounting-r1.json`. Selected observed counts:

| Kernel | All clocks | Before first retirement | Retirement-active clocks | Later retirement-empty clocks | Repeated backward-edge interval |
|---|---:|---:|---:|---:|---|
| Dependent add | 4,626 | 73 | 3,234 | 1,319 | 202 clocks / 203 instructions, 14 intervals |
| Independent add | 3,028 | 73 | 1,635 | 1,320 | 102 clocks / 204 instructions, 14 intervals |
| MUL | 5,355 | 73 | 1,203 | 4,079 | 13 clocks / 5 instructions, repeated |
| D-cache miss | 137,367 | 73 | 4,103 | 133,191 | 67 clocks / 4 instructions, repeated |

The hot add intervals sustain approximately **1.0 dependent / 0.5 paired CPI**;
they do not turn the cold full-stream gate into a pass. Both add streams have
19 inter-retirement distances of 70 clocks, accounting for 1,311 empty clocks.
The reference's fixed eight-clock miss penalty is not an AXI beat/service model.
Retirement-empty cycles alone do **not** prove a cache-miss cause or quantify
Quake's IPC gap. The previous matched native profile established that MUL's
ten-clock EX occupancy is correct: the remaining clock is dispatch. Any future
fix must overlap safe handoff rather than subtract a clock from execution.

Read-only board check confirms native AArch64 and SSH reachability, with about
242 MiB free root storage / 294 MiB free tmpfs. No guest process, programming,
reset, MMIO write or deletion was performed. A new Win95 long run has not been
started: ordinary full-PC live input remains unintegrated, and the preserved
cold launcher's 8 GiB host disk admission is not currently met. The isolated
mouse protocol tests and old desktop captures cannot substitute for that work.
Synthesis/clock sequencing and the older Quake remain live, not acceptance.
