# Next-read readiness cofactor — October 16, 2026

Private timing experiment, **not promoted or deployed**. This removes one
request-dependent hit-selection dependency from L1 next-read readiness. It
adds no register, cache port or cycle. Timing and gameplay gain are unmeasured.
The parent is the [36.968577 MHz unplaced boundary-stage
experiment](../fe_pipe/SFETCH_BOUNDARY_STAGE.md), still below the required
40 MHz; neither number is routed sign-off.

## Exact change and invariant

[Recipe](prepare_next_ready_cofactor.py) accepts only L1 source SHA-256
`62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3`.
Candidate SHA-256:
`0429ad9d8f4f16f8534dc3d24321ae7d0cd4420680b74170de786a78703ac337`.
Only `rtl/mem/ven_l1d.sv` changes in the 195-source directed-core closure.

Let R be `c_next_req`, O/P the old-response/prime slot predicates with R
factored out, C current cacheability, H the next-address tag hit, and G the
unchanged next-cacheability, flush/snoop exclusion and access-shape checks.
The original readiness is:

```text
lookup = R && (O || P)
ready  = lookup && ((R && P) || C) && G && (lookup ? H : current_hit)
```

The replacement is exactly:

```text
ready = R && (P || (O && C)) && G && H
```

The identity holds for arbitrary binary O/P predicates, not just reachable
cache states. Existing parallel tag reads supply H. Lookup address/strobe
selection, request/capture signals, cache storage, response ownership and all
sequential behavior remain unchanged. A non-synthesis assertion compares old
and new readiness after reset. No program/PC checks, snapshots, guest patches,
pairing suppression or global slow-mode fallback are introduced.

## Closed evidence

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
|---|---|
| Source-extracted equations, five profiles | 983,040 comparisons; three broken variants rejected |
| Boolean proof | Z3: equivalence UNSAT; ready witness and all three mutant counterexamples SAT |
| Actual full P5 cache, LUTRAM and register tags | 590,084 sampled edges; public outputs, capture controls and cache arrays match |
| Actual next-read priming under held data fills | 640 cases; all eight held beats, byte/dword positions, unchanged backing owner |
| Original 22 fetch/fault guests | 176 RTL executions, 88 QEMU comparisons, 21,832 candidate records, 4,968 V retirements |
| Paged/relocated load/store matrix | 288 measurements, 32,112 candidate records, 456 actual paired memory retirements |
| Integer/store matrix | 1,024 measurements, 169,472 candidate records, 512 V retirements; all 512 cycle deltas zero |
| Fresh qualified private-reference functional corpus | 108 passes under existing masks; 80,800 records, 30,132 V retirements |
| Same corpus without optional masks | 105 passes; existing `tx_regform`, `tx_regform2`, `tx_stack` failures remain |
| Canonical `make verify` | **FAIL: 7 functional PASS / 101 FAIL**, native make exit2 |
| Complete canonical cycle streams versus parent | All 20 identical; this is not a cycle-band pass |

The [independent local audit](audit_next_ready_cofactor.py) regenerates the
source-extracted equations and full-cache fixtures, replays Z3, checks complete
boundary traces against QEMU and the parent, verifies all 195 sources and the
private harness dependency, and rechecks 860 input pins. It distinguishes the
outer service IDs from the guarded inner scopes: exact scope lifecycle journal
events must fall inside their specific successful outer invocations.

The [independent functional audit](audit_next_ready_func.py) regrades all
80,800 records, checks actual child affinities/native exits and 12,418 input
pins, and verifies the executable images against the canonical run. Only GCC's
non-loadable randomized file-symbol strings may differ. Private oracle
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`
is **not** promoted over canonical QEMU. No golden, mask or cycle band changes.

Directed model:
`274f36c65682611be280de39a536cb3fbdb39c22b1d5143ceadfe06f1f457ed5`;
parent `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
Both retain all 153 build definitions, assertions, full caches, relocated
UV-fast execution and real AXI (`--cycle-func --l1-axi` and
`--cycle --l1-axi`, latency0/7). Private model-specific C++ object and generated
header dependency are checked. Build: 19.90 seconds, 32 guarded compiler jobs.
Canonical run: 392.80 seconds; private functional run: 107.79 seconds.
Load/store and integer matrices: 18.30 and 42.08 seconds.

Full-cache retained controls also cover 150 chained accesses, 448 fresh pairs,
64 same-bank rejections, 1,536 held-pair checks, 640 data-under-instruction-fill
completions per tag configuration, and code-word reuse. Prime-under-I-fill
completions remain zero because the target intentionally does not enable that
option; do not report them as exercised. These sampled tests and the abstract
Boolean proof are not whole-cache arbitrary-state formal verification.

Failed attempts remain distinct: leaf R1 did not kill the missing-cacheability
mutant; R2 adds exhaustive readiness-decision enumeration. Cache R1 failed
compilation because its inherited fixture named an absent old parameter.
Cache R2 caught the mutant at the earlier public-ready miter, but the runner
incorrectly required the later stimulus assertion. R3 accepts only either of
those specific readiness failures. The final positive RTL is unchanged by
these test-harness corrections. No failed attempt is counted as a pass.

Four recipe/fixture/builder unit tests and three full-PC transfer guard tests
pass. The [full-PC transfer builder](../../fpga/build_next_ready_soc.py)
preserves all 102 shared processor/FP sources and the 157-definition posted-16
PC profile; only the L1 cofactor may differ.

## Full-PC and FPGA transfer

Full-PC model
`5945191c453e113cab7e1c4e009ba768f45c39563b840064008608c94e82e72e`
built in **23.31 seconds**, native exit0, inputs unchanged, with a private
harness basename/local object/matching generated header. Parent model is
`b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2`.
The 98 inherited full-PC structural warnings remain explicit debt, not lint
acceptance. Owner `ventium-next-ready-soc-oct16-r1.service`, invocation
`136e2e9cd1b44defbf13800436029456`.

Both [short cold CoreMark seeds](../../fpga/run_next_ready_coremark.py) and their
[independent audit](../../fpga/audit_next_ready_coremark.py) pass:

| Ten-iteration seed | Parent / candidate ticks | Added clocks | Actual final V |
|---|---:|---:|---:|
| Performance | 4,771,298 / 4,771,298 | 0 | 1,055,307 |
| Validation | 4,755,366 / 4,755,366 | 0 | 1,054,254 |

All five data CRCs per seed match the independent reference. Native times:
215.71 / 212.40 seconds, both exit0; actual CPU12 affinity, cold reset,
`cycle_mode=1`, unchanged posted-16 transport/latencies and fast paired
execution checked. No OOM; both native children reaped. Audit rechecks 24,135
input pins. Owner `ventium-next-ready-cm10-oct16-r1.service`, invocation
`67c5a2d66a6948a9aac759264fd25000`. Final U counts 3,409,917 / 3,405,870 include
startup and are not gameplay measurements. Ratios 2.09587 / 2.10289 are
**duration-invalid diagnostics**, not accepted CM/MHz scores or full-seed
standard-suite passes. Incremental measured cycle gain/regression is **0%**.

[Sealed export](../../fpga/freeze_next_ready_rk_candidate.py):
`next-ready-fpga-r1/input-manifest.json`, SHA-256
`2a7343b2d3f022ab891712c3cad0fb6b6f7f9460f05f60c1080a26e3c77c4982`.
All 192 payloads / 170 common HDL files / 159 hardware definitions are checked
against the measured boundary-stage parent. Only L1 readiness differs; the
posted-DDR mouse wrapper and AUX fixes are retained. Later keyboard proposals
are not silently mixed in. [Independent export checks](../../fpga/next_ready_evidence.py)
recheck 25,340 input pins. Strict CPU-hierarchy lint passes in **3.83 seconds**
with all six original structural warning classes treated as errors. Neither
preprocessing nor this CPU-only lint qualifies the complete FPGA wrapper.

The [matched timing preparation](../../fpga/prepare_next_ready_timing.py)
generates controllers but launches nothing. Comparison DCP is the actual
36.968577 MHz boundary-stage parent, SHA-256
`cdfd1aebe93772078decc21741296b136908179f316b23393419e2971db5119c`.
It retains the original 40/100 MHz constraints, mapper, one-Vivado-family
launcher, 8 GiB RAM / 6 GiB swap limits, 13 GiB combined early stop and 4 GiB
disk stop floor. Admission retains the earlier measured-growth reserve, not
an unsupported prediction of this candidate's disk consumption. The
[sequencer](../../fpga/run_next_ready_timing_sequence.py) can observe only one
exact synthesis invocation and then run its read-only clock report; it cannot
retry synthesis or start implementation/deployment. Resource-stop mutants and
identity-only sequencer tests pass. The closed timing result is recorded below.

After both short seeds and their audit closed, one synthesis was launched:
`ventium-next-ready-synth-oct16-r1.service`, invocation
`881fba3884214158a222ab511a4d4e13`. It closed native exit0 / MainPID0 at
**06:12:54 UTC**, in **1,916.44 seconds**. The independent synthesis audit
passes: all **25,436 input pins**, **159 actual definitions** and **150 native
read-Verilog files** are checked; only the intended L1 payload differs.
Peak RAM is **8,589,930,496 bytes**, peak swap **503,562,240 bytes**, no OOM
or resource-stop event. The previous family was reaped before the read-only
clock job `ventium-next-ready-clock-oct16-r1.service`, invocation
`9dd8c2692ecf4a948767faa282048d37`, started. It subsequently closed native exit0
and MainPID0 in **472.99 seconds**, with **4,666,085,376 bytes** peak RAM,
zero swap and no OOM. Its independent audit checked **25,411 input pins**;
the exact sequencer also closed successfully. Audit success establishes report
provenance and native closure, **not timing acceptance**.

Mapped LUT use is **187,309 versus 187,990** for the matched parent: **681
fewer LUTs (0.36%)**. Registers are **55,217 versus 55,218**; **277.5 BRAM
tiles and 47 DSPs** are unchanged. This is mapped-area evidence, not a measured
frequency or gameplay gain. No placement,
routing, bitstream generation or board programming is authorized by this
diagnostic controller. Fourteen transfer/CRC/export/CAD/sequencer tests pass;
the earlier failed preparation attempt was a Python path-type error before
controller generation or any Vivado launch, not a synthesis failure or pass.

### Matched timing result: regression, not a 40 MHz candidate

| Same 25 ns core constraint / synthesized netlist | Boundary-stage parent | Next-ready cofactor |
| --- | ---: | ---: |
| Worst core setup slack | -2.050 ns | -3.614 ns |
| Unplaced fmax estimate, `1000 / (25 - WNS)` | 36.968577 MHz | 34.947928 MHz |
| Mapped LUTs | 187,990 | 187,309 |

The **1.564 ns worse slack / 5.47% lower frequency estimate** outweighs any
claim that this small LUT reduction solved timing. Neither column is routed
sign-off or measured board frequency. Do not promote this cofactor as a timing
win or start implementation on that basis. The underlying functional/cycle
equivalence results remain valid but establish a different property.

The candidate's worst path is `q_pc_reg[0]` to
`u_regfile/gpr_reg[4][16]/D`, **96 logic levels**, **28.403 ns** data delay:
6.058 ns logic and 22.345 ns estimated interconnect. The native report crosses
fetch alignment/prefix decode, `d_len` / `d_fetch_need`, `sfetch_want_size`,
fragment/route qualification, backing-address selection, quadword pair credit,
`b_pair_ready`, `c_pair_intent_ready`, `l1_store_pair_ready`, `c_pair_req0`,
`m_pair_ack`, and `l1_c_ack` before register-file writeback. These are observed
mapped-net names; hierarchy/name reuse after synthesis is not a source-level
proof that every stage can be sensitized together.

Next investigation: explicitly factor the interior-fetch size selector, which
still traverses `sfetch_want_size` even though that selected arm first overrides
the decoder count with four. Keep its exact page clip. The earlier separate
[backing-payload mux experiment](BACKING_PAYLOAD_MUX.md) already failed to
improve timing; merely repeating that rewrite is not evidence of progress.
Preserve the two P5 write-buffer slots, fused-pair credit,
extent/fault checks, shutdown/reset behavior and all same-cycle acknowledgments.
Do not disable pairing, add blanket wait states, waive paths, or infer an RTL
fix from the unplaced route estimate alone. Reports and independent audit are
retained in `next-ready-clock-r1` beneath the evidence root above.

## Still open

The [combined input-model builder](../../fpga/build_next_ready_ui_soc.py)
prepares `next-ready-ui-soc-r1` from this exact full-PC parent. All 102 shared
processor/FP sources and all 157 definitions remain identical. Its sole RTL
delta is the [retained-AUX keyboard controller](../../fpga/KBD_INHIBIT.md),
`9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405`.
The host is byte-identical to the tested `retained-ui-soc-r3` input host, with
its exact three headers and corrected named FIFO-read binding. A new private
harness basename prevents external object reuse. Source preparation checks
both full parent closures and the closed cold-input, actual-controller and
full-FIFO evidence; no CPU experiment or new build definition is mixed in.

This composition **compiled and passed its short controls; it is not accepted**.
The bounded
[build owner](../../fpga/run_next_ready_ui_build.py), unit
`ventium-next-ready-ui-build-oct16-r1.service`, invocation
`ee6638e17fc548239e426eb1c5e81a01`, waits for exact CAD sequencer invocation
`53b5d32e82414436a25eee699e0d28dd` to exit successfully. It checks its native
synthesis/clock closure, then permits one build through the unchanged exclusive
32-job build scope. Owner replacement, failure, disk reserve loss or the
50-minute observation deadline prevents compilation; none causes a CAD retry.
Six transfer/sequencing/control/audit guard tests pass. No guest or bitstream is launched
by this owner. Public-pin input in this PC model does not qualify the FPGA
debug-MMIO serializer or physical Windows UI.

The composed model's [cold input runner](../../fpga/run_next_ready_ui_input.py)
retains the original raw/translated public-port guest, native wire/guest-read
grader, timing, process bounds and QEMU negative control. Its
[parallel short-seed runner](../../fpga/run_next_ready_ui_coremark.py) retains
both original CoreMark images, all CRC checks, actual affinity/child-lifetime
checks and exact **4,771,298 / 4,755,366** timing-parent kernel clocks.
The [independent auditor](../../fpga/audit_next_ready_ui_coremark.py) regrades
the original console/log data and parent results. These controls cannot award
full-duration scores or standard-suite acceptance.

The queued build completed in **23.52 seconds**, native exit0, inputs unchanged,
private harness object bound to this model's generated header. Model SHA-256:
`e42cd5d8974d5e471995b18b4bbde3b32e723c2a336360cd24731c9312376449`.
Its **98 inherited structural warnings are unchanged**, not waived or counted
as a full-SoC lint pass. The queue's exact CAD-owner/closure checks also passed.

Both cold keyboard guests passed in **108.61 / 108.60 seconds** on actual
CPUs 16 / 17. The normal translated guest consumed `1d/01/81/9d/1c/9c`; the
raw guest consumed all nine original set-2 bytes, with no missing/duplicate
wire or guest read. Both stopped gracefully after the pass, with zero pending
or owned bytes and exit0. Independent audit checked **25,502 source pins**,
native ownership and unchanged media. Peak memory **52,133,888 bytes**, no OOM.
Owner `ventium-next-ready-ui-input-oct16-r1.service`, invocation
`aa635dafaf9841018024644b9645c669`, is terminal/MainPID0. Evidence:
`next-ready-ui-input-r1/{started,closed,audit}.json` and both native logs.
This is public-pin keyboard transport, **not Windows interaction or FPGA MMIO**.

The concurrent 10-iteration CoreMark controls passed all five reference CRCs
for each seed in **218.58 / 217.57 seconds**, actual CPUs 12 / 13, native exit0.
Kernel ticks remain exactly **4,771,298 / 4,755,366**: **0% cycle change** from
the timing parent, while retaining 1,055,307 / 1,054,254 cumulative V retires.
These short runs deliberately have the benchmark's duration-invalid diagnostic;
they do not establish an error-free standard-suite pass or valid CM/MHz score.
Independent audit checked **25,539 source pins**, raw console/CRCs, observed
child argv/affinity, original parent ticks, and reaped processes. Owner
`ventium-next-ready-ui-cm10-oct16-r1.service`, invocation
`40f7160fa90b4281abee06f14fdb3eb0`, closed MainPID0 with no OOM and peak memory
**61,640,704 bytes**. Evidence: `next-ready-ui-soc-r1/coremark-ui-disabled-r1`.

Routed timing meeting 40 MHz, full standard suite, canonical failure repair,
candidate FPGA Win95 cold desktop plus keyboard/mouse interaction, and a full
candidate FPGA Quake timedemo remain required. The boundary-stage parent's
measured boundary-fetch costs are inherited, not repaired by this cofactor.

Candidate gameplay IPC is **unmeasured**. Last verified older baseline:
**0.49046518 total U+V IPC**, model
`7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68`,
cycles **1,600,065,247–1,700,065,247**. That is 37,998,050 U plus 11,048,468 V
retirements in 100 million clocks; U-only IPC is 0.37998050. It predates the
V-result/input/fetch/readiness candidates and is not full timedemo completion
or physical FPGA performance.
