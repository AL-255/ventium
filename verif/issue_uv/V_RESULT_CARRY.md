# V-pipe arithmetic carry cut — 2026-10-15

**Private timing candidate, not accepted or deployed.** The hardware change is
one expression in `v_pipe.sv`: call `alu_result(..., 1'b0)` instead of forwarding
U's CF into the arithmetic result. `flags_next` still receives the real
forwarded EFLAGS, so V INC/DEC preserve U's new CF. Decoder, issue eligibility,
memory ownership, commit gates, registers and cycle timing are unchanged.

The preceding wait-cofactor candidate synthesized to **37.9507 MHz** at the
unchanged 40 MHz constraint, with a worst path through U CF → V result → GPR.
This cut targets that path. The corrected-wrapper candidate's completed
synthesis audit now estimates **34.6524 MHz unplaced**, below both the parent
and the 40 MHz target; see the latest section below. There is no routed result.
Equal cycles are expected: this is an Fmax experiment, not a claimed IPC improvement.

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

## October 16: synthesis closed; mouse-wrapper integration rejected and repaired

The preceding live status is superseded. Synthesis R3 closed at 00:23:26 UTC:
native exit 0, 1,871.71 seconds, all pinned inputs unchanged, 8 GiB peak resident
memory, zero swap and zero sampled OOM events. It reports 188,612 LUTs, 54,978
registers, 277.5 BRAM tiles and 47 DSPs. These numbers describe an **incomplete
mouse integration**, not an accepted candidate or an isolated V-result gain.

The independent source audit correctly failed at missing native input
`flow/src/ven_ps2_mailbox.sv`. The timing sequencer exited 1 and **did not start
the clock audit**. No route, programming or timing qualification followed.
The failed audit and original DCP/source/controller are retained unchanged.

Root cause: the mouse overlay used the legacy `ven_ddram_axi` instance as its
insertion anchor. That instance is inside the `else` of `VEN_DDR_POSTED`.
The actual 159-define FPGA profile enables posted memory, so both mouse
instances were preprocessed away. Vivado consequently omitted both source
modules and explicitly warned that `mouse_csr_rdata` and `ps2_mouseclk_dev`
had no driver. The earlier source contract checked filenames in expanded Tcl,
not the active Verilog hierarchy; isolated peripheral tests instantiate the
devices directly and cannot catch this wrapper-conditional defect. This is a
real hardware integration bug, **not** a path-normalization audit error.

`fpga/repair_posted_mouse_wrapper.py` moves only the exact mailbox/device block
before the DDR conditional in a **new** export:
`external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-posted-mouse-fpga-r1`.
Manifest SHA-256:
`ab1c791f3f472ec72a0c36628291d3c6d2e78a6a4a1b449a71a06840800ba8e0`.
All 192 payloads, 159 defines, 40/100 MHz clock settings, posted depth 16 and
processor/peripheral RTL are retained except that one block relocation.
No source file in the old export or old native evidence was edited. Three
host tests use the real Verilog preprocessor to check both DDR selections,
reject the old posted source and missing/duplicate-device mutants, and prove
that every other active RTL token is unchanged.

The new actual-wrapper microgate compiles the real wrapper, management AXI-Lite
slave, mailbox and device. CPU/DDR/video and other unrelated modules are
deliberately black-boxed with Icarus `-i`; **this is not complete-wrapper or
processor verification**. It reads capability/reset-status/generation through
ordinary AXI-Lite, checks held read responses and driven device reset levels.
At each of 3.125/40 MHz it requires:

- Corrected posted and non-posted wrappers: pass.
- Original non-posted wrapper: pass.
- Original posted wrapper: fail the actual capability read, not compilation.

All eight cases met those expectations: six positive cases and two required
old-bug controls. Native owner `ventium-posted-mouse-wrapper-oct16-r2`, invocation
`b4eeabc049cd4ccf8ceda03c33f015e7`, exited 0; 0.179 seconds, 17,924,096-byte peak,
zero swap, CPUs 12–13. Independent recheck confirms all 400 input pins and all
native log markers. Evidence: `posted-mouse-wrapper-micro-r2` under the same
scratch root. The first micro attempt is retained as R1: its incorrect expected
initial generation was 1, while the specified fabric-reset generation is 0.
Only that test expectation/timing and evidence snapshotting were corrected;
the repaired wrapper was unchanged.

The corrected export is still unqualified and has **not** been synthesized.
The failed earlier image must not be relabelled a pass or deployed. Next:
complete the corrected wrapper's source/native checks and obtain fresh bounded
synthesis/timing before implementation. The last valid predecessor estimate
remains **37.9507 MHz unplaced**, not routed or measured hardware frequency.
Current-candidate gameplay remains unmeasured; older verified baseline is
**0.50520554 total U+V**, model `c7b95b78…`, cycles
**5,600,065,237–5,700,065,237**. Canonical/standard-suite/physical acceptance
remain open.

## October 16: corrected-wrapper CAD run admitted (still in progress)

The next bounded synthesis started at 00:45:30 UTC from manifest
`ab1c791f…`, in `posted-mouse-synthesis-r1`. Controller
`ventium-posted-mouse-synth-oct16-r1`, invocation
`876ffb6a3e8042d1abdf9028b55df03e`, owns the single Vivado process family;
the native scope invocation is `33cd5b1c38b4419f8a2d67ca0fb5340e`.
Actual Vivado compile-order admission now finds exactly one each of the
wrapper, mouse mailbox and PS/2 device. It printed
`MOUSE_POSTED_PREFLIGHT_OK exact_sources=3 implementation_authorized=false`
before starting `synth_1` at 00:46:27 UTC. This is a **native source check**,
not completed synthesis, timing closure or physical UI acceptance.

`fpga/prepare_posted_mouse_timing.py` preserves the previous resource/lifetime
guards byte-for-byte: one job, 40/100 MHz constraints, 8 GiB RAM / 6 GiB swap,
13 GiB combined early stop, 4 GiB disk floor, 2 GiB host headroom and 45-minute
timeout. CPU-only lint transfers solely because all CPU bytes are unchanged;
the corrected wrapper's `source_contract_passed` and full-wrapper simulation
flags remain false. Eight preparation/Tcl-stub tests and three sequence tests
pass. The stubs do not substitute for the native Vivado source check above.

The exact-owner timing sequence (`ventium-posted-mouse-timing-chain-oct16-r1`,
invocation `037dd942438b41cc973a4dbc2c689cbc`) observes this synthesis only.
It requires successful native closure and the independent source audit before
launching the prepared 15-minute read-only clock report. That audit still
requires both mouse sources in Vivado's emitted synthesis Tcl, now also checks
actual module synthesis and rejects mouse CSR/line undriven warnings. Neither
controller launches implementation or programming; no automatic retry occurs.

Disk admission was met by losslessly archiving 16 bulky cone/primitive reports
from four **closed** older clock runs (early-bus, branch-address, decode-bus,
demand-size R2). Original 900,429,518 bytes became a 19,558,984-byte archive:
`closed-clock-cones-oct16.tar.zst`, SHA-256
`84b13d30b4c693d8dd10db2eefe822276ae58c3ee2e8da5afd14cf1f7b174212`.
Every member's name, size and SHA was checked before removing its uncompressed
copy. The adjacent plan/closed receipts preserve exact targets. Restore into
the evidence root with `zstd -dc ARCHIVE | tar -xf - -C ROOT` before rerunning
those old raw-report audits. Sources, DCPs, binaries, native logs, summary
reports, the pipe-wait comparison parent and live Quake were not pruned.

Current-candidate gameplay IPC is still unmeasured. Older baseline remains
**0.50520554 total U+V**, `c7b95b78…`, cycles
**5,600,065,237–5,700,065,237**. Last valid predecessor estimate remains
**37.9507 MHz unplaced**. Canonical, standard-suite, routed-frequency and
physical-FPGA acceptance remain open; no new performance gain is claimed.

## October 16: newer older-model gameplay observation and input-loss backport

The running decode-bus Quake model now has a verified gameplay window:
**0.48146083 total U+V IPC**, model
`7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68`, cycles
**1,100,065,247–1,200,065,247**. It retires 37,609,117 primary instructions
and 10,536,966 secondary instructions in 100,000,000 actual core clocks.
Primary-only IPC is **0.37609117**, not the architectural total.

`fpga/audit_decode_bus_gameplay_window.py` verifies the live PID/start time,
command, invocation, CPU-11 affinity, no-OOM state and **13,857 source/runtime/
artifact pins**. It checks UV + fast-pipe defines, `cycle_mode=1`, cold reset,
no snapshot/guest patch/STEP/breakpoint options and actual V retirements.
All complete profiler records retain the original counter-consistency checks,
including conservation of every clock through state residency.

Frames 6 and 7 bracket those counter endpoints in the log and were visually
checked: firing in a stone room with enemy/weapon/HUD, then a different stone
corridor view with weapon/HUD. PNG conversion is pixel-identical to raw PPM;
no color processing was applied. Evidence:
`decode-bus-gameplay-window-oct16-r1.json` under the same scratch root.

This is the **latest observed completed periodic window**, selected post hoc,
not a predeclared A/B comparison or whole-timedemo average. The generic
predeclared-window helper rejected this log's early sample spacing: sample 4
arrives at 400,065,247, not 400,000,000. The pinned host reports in its outer
loop while PS service can advance real DUT clocks, and sets its report origin
to actual `main_time`. The dedicated audit retains that 65,247-clock startup
delay explicitly, validates all actual counter deltas, and does not alter the
generic helper, round timestamps, omit records or interpolate counters.

This supersedes the older 0.50520554 number as the **latest verified gameplay
observation**, but the windows/builds differ: their difference is not a
measured gain or regression. Decode-bus predates the current V-result timing
and peripheral candidates; **current-candidate gameplay remains unmeasured**.
The Quake process is still running; this does not establish timedemo completion.

Separately, the [current-AUX input-loss backport](../ps2_ui/LOSS_AUX_IOBUS.md)
passes 16 actual-iobus cases against 16 required current-parent loss witnesses.
It remains isolated from the live CAD source and needs the documented broader
controller/host/full-PC/FPGA validation. At the last check, corrected-wrapper
synthesis remained active with no OOM or swap; its clock audit had not started.

## October 16: current CPU candidate cold Quake started

The V-result CPU model now has its own cold FreeDOS Quake run; it is no longer
waiting behind the older decode-bus observation. Owner
`ventium-v-result-carry-quake-oct16-r1`, invocation
`2c4e771b55e141d98f2ed235d37cc5f1`, started at 01:17:04 UTC. Actual native
PID 2100579 is confined to **CPU 14**, with binary SHA
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`.
The older model remains independently active on CPU 11; neither result is
credited to the other. Current-candidate gameplay IPC is still **unmeasured**.

`fpga/prepare_v_result_carry_cold.py` preserves the existing cold flow's guest,
native arguments, output/EOF/completion checks and limits, changing only model,
run identity and CPU assignment. Two host tests check this exact adaptation and
reject partial, tainted or unclosed timedemo results. All **18,586** candidate
build-input pins rehash successfully before launch; the live owner repeats that
check. Its independently observed native admission confirms the binary hash,
PID/start time, parent, cgroup, command and actual CPU affinity.

The run uses a fresh private 64 MiB-class guest disk, cold reset, no snapshots or
guest patches, 16 MiB guest RAM, 40 MHz core/RTC timebases, 80 MHz VGA and the
actual posted AXI transport (16 slots, B delay 20, first R 21, gap 1). It keeps
UV + fast-pipe build settings, no STEP/breakpoint request and normal fallback.
The same model's directed tests already observed actual V retirement; its
new cold-run gameplay/V counter evidence is pending. Startup counters are not
reported as gameplay IPC.

Limits remain one CPU, 2 GiB RAM, no swap, 160 tasks, 4 GiB per-file limit,
three-day native deadline / 73-hour owner lifetime, 6 GiB free-disk admission
and 4 GiB live disk stop. The full **969-frame** timedemo and clean native
closure are still required. Evidence is under
`external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-soc-r1/quake-cold-v-result-carry-oct16.1/`.
This model includes the current AUX-status fix but **not** the isolated PS/2
loss/resync proposal or the FPGA-only mouse wrapper. It cannot qualify either
as physical-board behavior. Win95/UI, canonical gates, both complete CoreMark
seeds, routed timing and physical FPGA acceptance remain open.

The [extended PS/2 checks](../ps2_ui/LOSS_AUX_IOBUS.md) separately pass all 12
new RX-skid/self-test/translation cases. The first transport run remains failed
under its original deadline; an assertion-preserving bounded diagnostic proves
the apparent mouse loss is the newly introduced reset-inhibit latency, not
lost command data. No live controller or hardware input was changed.

Latest verified gameplay baseline remains **0.48146083 total U+V IPC**, older
model `7e877b3b…`, cycles **1,100,065,247–1,200,065,247**. The current candidate
is unmeasured; this new launch is not a standard-suite pass or performance gain.

## October 16: corrected-wrapper synthesis and source audit passed

`posted-mouse-synthesis-r1` closed at **01:19:08 UTC**, native 0, in
2,017.992 seconds. The independent audit then passed under the original
retained owner, checking **19,927 input pins**, 150 native `read_verilog`
inputs and all 159 hardware defines. Both mouse mailbox and device are now
actually synthesized, with no unresolved mouse CSR/line-driver omission.
All sources remained unchanged, peak scope RAM was 8 GiB, swap was zero,
and no sampled OOM or resource-stop event occurred.

The new DCP SHA-256 is
`9354b17d35b1c0cb4a49bf1bcd00cf6e511b8253c5b250b427d10e6764741315`.
Utilization is **188,884 LUTs (55.35%), 55,209 registers, 277.5 BRAM tiles and
47 DSPs**. Against the matched pipe-wait predecessor this is 872 fewer LUTs
and 168 more registers. This comparison includes the V-result carry cut,
AUX repair and mouse-wrapper integration; it is **not** an isolated per-fix
area gain. The incomplete old R3 image remains rejected.

The native synthesis retains one critical warning about a generated PS8 XDC
`create_clock` target, also present in the predecessor; it is not silently
removed or called a warning-free result. The separate timing audit checks the
actual active clocks and unconstrained paths. It has confirmed `clk_pl_0`
at **100 MHz** and `mmcm_clk` at **40 MHz** as constraints; those are not fmax
results or measured board rates.

The read-only timing owner `ventium-posted-mouse-clock-oct16-r1`, invocation
`14a67035bb154378890aa2df53642efc`, started after source-audit success and is
still running. No implementation or programming was launched. New fmax and
routed frequency remain pending; the last audited predecessor estimate is
**37.9507 MHz unplaced**. The current cold Quake candidate is also still live
and gameplay-unmeasured. Latest verified gameplay remains **0.48146083 U+V**
on older model `7e877b3b…`, cycles **1,100,065,247–1,200,065,247**.

## October 16: corrected-wrapper timing audit closed below target

The preceding live timing status is superseded. Owner
`ventium-posted-mouse-clock-oct16-r1`, invocation
`14a67035bb154378890aa2df53642efc`, closed native 0 / MainPID 0. The independent
audit passes **19,508 input pins**, source/DCP identity and actual 40/100 MHz
constraints. Runtime was 462.132 s; native scope peak 4,455,170,048 bytes,
zero swap and no OOM. Evidence: `posted-mouse-clock-r1/{audit.json,
core_setup_unplaced_estimate.rpt}` under the same scratch root.

| Synthesized, unplaced estimate | Pipe-wait predecessor | Corrected-wrapper candidate |
|---|---:|---:|
| Core fmax | 37.9507 MHz | **34.6524 MHz** |
| Setup slack at 40 MHz | −1.350 ns | **−3.858 ns** |

The candidate's worst hold estimate is −0.101 ns. These are synthesized
estimates, **not routed sign-off or measured board frequency**. Audit success
means the report is authentic and structurally checked, not that timing passes.
No implementation, programming or timing waiver followed. The comparison
includes V-result, AUX and mouse integration changes, so it does not isolate
the V-result cut's contribution.

The worst setup path is `q_pc[0]` to GPR 4 bits 16–31: 97 logic levels,
28.647 ns data delay (6.011 logic + 22.636 estimated routing). It traverses
instruction-byte/prefix decode, fetch demand/fragment shaping, address-route
admission, paired-store readiness, backing ACK, paired retirement and register
writeback. The next investigation is this combinational request/readiness/
response coupling. It must preserve precise ownership, store ordering and
UV-fast throughput; a globally delayed ACK or disabled pairing is not a fix.
The aligned paired-write comparison is already adder-free in this frozen
source, so replacing an obsolete address adder would not address this result.

Current candidate `b6b92dbf…` continues its independent cold Quake run and is
still gameplay-unmeasured. Latest verified older baseline remains
**0.48146083 total U+V IPC**, `7e877b3b…`, cycles
**1,100,065,247–1,200,065,247**. Canonical gates, the full standard suite,
40 MHz routed qualification and physical FPGA acceptance remain open.
