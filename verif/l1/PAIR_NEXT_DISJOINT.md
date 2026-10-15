# Pair/next-read timing cofactor — 2026-10-15

Status: **standalone timing experiment rejected; not accepted or deployed**.
The closed synthesized/unplaced estimate is **35.835871708 MHz**, versus the
retained parent's **36.591166892 MHz**: **2.064% slower**. This replaces the
rejected [current-U-only experiment](CURRENT_U_PAIR.md), not production RTL.
It preserves its parent's cycles and pairing in the completed checks, but
that does not justify promoting the slower mapping. There is no routed result.

Verified gameplay baseline remains **0.50520554 total U+V IPC**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
5,600,065,237–5,700,065,237. Candidate gameplay is unmeasured. The retained
parent's unplaced synthesis estimate is 36.591166892 MHz, not routed closure.

## Change and ownership argument

`prepare_pair_next_disjoint.py` changes exactly three hash-checked files from
the retained `prefix-payload-core-r1` parent: `ven_l1d.sv`,
`ventium_l1_axi.sv`, and `ventium_top.sv`.

The new default-off parameter, `PAIR_NEXT_DISJOINT`, allows the selected core
client to omit the late `!mc_lookup_next` veto in pair-bank admission. The
ordinary cache interface retains the original arbitration. Selection requires
dual-load pairing and RAW next-read priming, and excludes predecessor paired
load priming and store/load pairing. Unsupported explicit selection fails at
elaboration. No latency, cache size, SRAM layout, feature define, clock
constraint, or memory transport changes.

Crucially, **idle-port V admission is retained**. A logical U load may be
waiting for translation while its physical `c_req` is low; a separately
translated V load can already capture a response and pair after U's page walk.
Requiring a physical U request incorrectly removed that overlap.

For the selected core producer, `pipe_v_pair_request` requires a new integer
U load, `pipe_pair_mem_ok`, no held memory packet, and no AGI. Every source of
`mem_next_req` excludes that packet:

| Next-read producer | Exclusion from this V pair request |
|---|---|
| Registered successor / held-read prime | Requires a held U packet |
| Fresh-read prime | Explicitly requires `!pipe_pair_mem_ok` |
| AGI prime | Requires AGI, forbidden by new-load admission |
| Reference operand prime | Requires a nonsimple or FP U; read pairing requires simple integer operands |
| FP self-prime | Requires an FP U |
| Register / branch successor prime | Requires no new memory request and a nonmemory U |

The assertion checking the original and new admission predicates remains
**unconditional** on every simulated clock. A second assertion rejects a pair
request whenever the next lookup is active, even when another veto would hide
the output difference. These checks are excluded from synthesis. This is a
source argument plus simulation coverage, **not exhaustive whole-core formal
verification**; future producer changes must maintain this contract.

## Completed checks

All processor runs use UV + fast pipe and the real AXI backend. No snapshots,
debugger stepping, breakpoint suppression, pairing disable, or U-only control
is substituted for acceptance. Full P5 caches, single-fill/posted16 integration
and the parent's definitions are retained.

| Check | Result |
|---|---|
| Actual full-L1 generic client | 538 scenarios; original arbitration preserved |
| Actual full-L1 selected client | 536 legal scenarios; identical unfiltered pins and outputs; idle V accepted |
| Conflicting next/pair negative control | Fails visibly in the unfiltered output miter, as required |
| Cold U translation / resident U data / warm V | 36 cases × AXI latency 0/7; all 72 A/B state **and cycle** comparisons identical |
| Independent cold-alias regrade | 144 complete QEMU comparisons; 15,840 candidate records; first V paired in all 72 comparisons |
| Warm load system corpus | 72 cases × latency 0/7; unchanged states/cycles; 1,500 memory V retirements |
| Store system corpus | 72 cases × latency 0/7; unchanged states/cycles; 456 memory V retirements |
| Held-address corpus | 48 A/B comparisons pass |
| Selected FP memory corpus | 8 A/B comparisons pass |
| Authenticated same-input replay | 108 programs; 80,800 records; 30,132 V retirements per model; exact states and clock counts |
| Unmodified canonical `make verify` | **FAIL**, native exit 2: 7 functional passes / 101 failures; 20 cycle traces exactly parent-identical |
| Full-PC source transfer/build | PASS; all 102 shared sources checked, exactly three deltas; 156 unchanged definitions |
| Hardware source export/Tcl contract | PASS; 170 common HDL inputs, 190 payloads, 158 unchanged definitions; 40 MHz target |
| Strict frozen CPU-hierarchy lint | PASS with all six structural classes fatal; 158 hardware definitions (not full-SoC lint) |
| Short cold full-PC CoreMark controls | Both seeds PASS; 10 iterations each; identical CRCs and 4,767,218 / 4,753,406 ticks; **not duration-valid scores** |

The complete replay is not a new candidate/QEMU run. Its original
authenticated oracle is retained; independent regrading still exposes the
three inherited x87 manifest-mask cases (`tx_regform`, `tx_regform2`,
`tx_stack`). Thus 105 of those 108 programs also pass without those existing
manifest masks. No new masks, goldens, or cycle bands were introduced. The
canonical gate remains failed and the standard suite remains open.

The full-PC build retains 98 pre-existing structural warning lines; no new
ones were introduced. A successful build is not a lint-debt waiver.
The short CoreMark controls ran from reset, with over one million actual V
retirements in each completed 13-million-cycle run. Independent regrading
confirmed native process exits, CPU affinity, source/media identity and no OOM.
Their cycle-throughput gain versus the parent is **0%**. The intended benefit
was a higher FPGA clock; the subsequently closed measurement below rejects
that benefit for this standalone mapping.

## Identity and evidence

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- Parent core model: `e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6`.
- Candidate core: `9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516`.
- Candidate full-PC: `b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2`.
- Hardware manifest: `cc27887f48bb6ff758503f11b79e7ea68c773718fe8357aea95323fb36bc462b`.
- Successful leaf ledger: `pair-next-disjoint-leaf-r6/closed.json`.
- Whole-core closure/canonical result: `pair-next-disjoint-core-r1/`.
- Directed evidence: `pair-next-disjoint-{coldalias,load,store,held,fp}-r1/`.
- Replay: `pair-next-disjoint-replay-r1/`; independent audit:
  `pair-next-disjoint-regression-audit.json`.
- Full-PC build: `pair-next-disjoint-soc-r1/`; export:
  `pair-next-disjoint-fpga-r1/`.
- Short controls and independent regrade: `pair-next-disjoint-soc-r1/coremark-r1/`.
- Frozen CPU-hierarchy lint: `pair-next-disjoint-lint-r1/closed.json`.
- Regression audit SHA-256:
  `4c12fa6a8df888db06173157fc8e03bce0414b311a6c924a743e728d9b85e733`.
- Short CoreMark audit SHA-256:
  `89cd8d61409cf808559edec6966a84803ceb7732dc6827e4a376d9d7f40e2700`.

Failed development attempts remain distinct: leaf r1/r2 encountered a
negative-fixture generator anchor error; r3/r5 were rejected by the disk
reserve before compilation; r4 correctly detected the deliberate conflict,
but the wrapper initially expected a different assertion signature. None is
reported as a passing run. R6 reran both positive models and the negative
control with the corrected checker. Some inherited leaf marker names say
`CURRENT-U`; they do not select the rejected current-U policy.

Only rebuildable, unused precompiled-header caches were removed from closed
attempts and the superseded current-U leaf run. Sources, binaries, dependency
files, logs and evidence paths were preserved. New scratch remains on external
storage. These functional checks preceded the Vivado measurement below;
there was no FPGA reprogramming or production RTL edit.
Additionally, 2,351 closed-run trace paths were hard-linked to byte-identical
copies, recovering approximately 0.79 GiB while retaining every pathname and
SHA-256. The explicit plan and closure are
`pair-next-closed-trace-dedup-{plan,closed}-r2.json`; active/current candidate
traces were excluded. External free space after cleanup was about 6.6 GiB.

## Closed matched synthesis and timing: reject standalone promotion

[Controller preparation](../../fpga/prepare_pair_next_disjoint_synthesis.py)
retains the parent's native lifecycle, mapper, memory limits and disk reserves.
Four controller tests and five timing-parser tests pass. Only one guarded
Vivado build family ran; its synthesis child/helper processes were owned
members, not orphan runs. No Chrome process was killed.

R1 failed preflight before launching Vivado: the evidence checker expected
eight FP measurements, but eight A/B comparisons contain **16 model
measurements**. R2 corrects that count without changing any test or verdict.
The failed R1 and original generator remain separate evidence.

Before admission, another 2,511 closed frozen-source paths and 192 now-closed
candidate trace paths were hardlinked to verified byte-identical copies,
recovering about 267 MB without losing paths or hashes. Open-file checks and
pre/post content checks passed. Plans/receipts are
`pair-next-closed-rtl-dedup-{plan,closed}.json` and
`pair-next-current-trace-dedup-{plan,closed}.json`. No active build inputs were
edited during synthesis. Its initial disk reserve was 7,267,680,256 bytes;
the 4 GiB stop floor and measured-growth admission rule were not weakened.

Synthesis closes native exit 0 in **1,922.20 seconds**, with unchanged inputs,
no resource stop and no OOM. Peak scope RAM/swap: **8,384,417,792 /
1,447,436,288 bytes**. Owner `ventium-pair-next-disjoint-synth-oct15-r2.service`,
invocation `cac860fad98f41e1ba15f7a46737879c`, is terminal with MainPID 0.
The independent audit rechecks **18,080 input pins**, all 158 definitions,
148 native `read_verilog` inputs, the exact three-file delta and the readable
checkpoint. The matched mapper remains Default with `-no_timing_driven`.

| Metric | Prefix-payload parent | Pair/next only |
|---|---:|---:|
| LUTs | 186,045 | 185,814 (-231; -0.124%) |
| Registers | 54,985 | 54,981 (-4) |
| BRAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |
| Setup slack at 25 ns | -2.329 ns | -2.905 ns |
| Unplaced Fmax estimate | 36.591166892 MHz | 35.835871708 MHz |

The separate read-only clock audit closes native exit 0 in **463.54 seconds**,
peak RAM **4,779,462,656 bytes**, zero swap/OOM. Owner
`ventium-pair-next-disjoint-clock-oct15-r2.service`, invocation
`25b3861f6b56465bb53406da55dd3734`, is terminal with MainPID 0. Independent
regrading checks **7,680 pins**, actual 40 MHz core / 100 MHz PL clocks,
zero black boxes and the requested multiple-driver/combinational-loop DRCs.
Core hold slack is **-0.101 ns**. This is not placed/routed sign-off.

Synthesis retains the parent's one critical warning and 1,558 warnings,
including the generated PS-IP clock warning; these are not waived. The clock
audit verifies the actual clock objects independently. The inherited
`generic_gate` receipt prose says `FUNC 108/108`; it refers to the private
authenticated-input replay, **not canonical `make verify`**, which remains
7 PASS / 101 FAIL. That historical field is not rewritten as a new verdict.

### Why the single cut did not close timing

All 30 reported worst endpoints are state-register clock enables, including
replicas; they are **not 30 independent bottlenecks**. The worst path is
`q_pc[0]` to `state[0]/CE`, **92 logic levels / 27.608 ns** data delay:
5.489 ns logic and 22.119 ns estimated interconnect (80.118%). Named nets pass
through `d_fetch_need`, `fx_cross`, store-pair readiness and L1 ACK. The
existing [report parser](../../fpga/analyze_setup_paths.py) accounts for the
complete data path, excluding source-clock insertion:

| Through named net | Incremental data delay |
|---|---:|
| `d_fetch_need[0]` | 12.683 ns |
| `fx_cross` | 3.473 ns |
| `l1_store_pair_ready` | 4.402 ns |
| `l1_c_ack` | 3.780 ns |
| State enable endpoint | 3.270 ns |

These are named-net boundaries, not RTL-module ownership. The sampled V-hit
capture path also now traverses fetch need/fragment crossing (91 levels,
-2.305 ns). Its transitive cone shrinks from 69,278 to 69,207 cells, but its
slack worsens from -1.726 ns. A smaller cone alone is not evidence of speedup.
LUTRAM primitive counts remain unchanged: 2,996 RAMD64E and 768 RAMS64E1.

Key SHA-256 identities:

- DCP: `91b94ebdee095c6c7adbd4328ce1ef35cbc5a2ad8b3ceba6dca510b15f13d52d`.
- Synthesis closure: `fa4bae1b5a77fa61a2df36dc686bb50bb11cb027a8b5cb4dc15e62dbb31c43e3`.
- Synthesis audit: `f9544b8a3bad5922403736f0b10706539919077343b5e80ba848c5191f370b7d`.
- Clock closure: `3adfed7c5925b8821be014a3155e9ae6623f7078bdec71071911df9f075e369a`.
- Clock audit: `a0f6ad7b1f2f265115227a6565fe267bbdf977e55c77ae5509b16d4114e94220`.

## Next experiment: compose the two independently tested cuts

The rejected [fetch-fragment-only mapping](../fe_pipe/FETCH_FRAGMENT_EXTENT.md)
was limited by next-read/pair arbitration; this pair/next-only mapping is
limited by fetch/fragment crossing. That motivates testing **both**, not
assuming their individual timing results add up. The retained 36.591 MHz
prefix-payload parent remains the timing baseline.

[The composition recipe](prepare_fetch_pair_next.py) applies exactly the
existing four file transformations on their hash-checked common parent.
Both original equivalence assertions stay enabled; idle-port V admission,
architectural request size, fault checks, cycle latency and all feature
definitions remain unchanged. Five host tests check exact source identity,
drift/reapplication rejection, assertions, the guarded build lifecycle and
new-model bindings through the replay/regrade adapters.

[The private core build](build_fetch_pair_next_core.py) closes in **20.81 s**,
native exit 0, source pins unchanged. Its 195-source closure has exactly four
deltas, 152 unchanged definitions, `--assert`, `AXI_LINE_REPLAY=0` and a unique
host object/header binding. Model SHA-256:
`8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1`.
This is a new **unqualified** experiment; no functional, timing or board pass
is inherited. The following fresh runs are now closed:

| Composition check | Result |
|---|---|
| Complete authenticated-input replay | 108/108; 80,800 records and 30,132 V retirements per model; exact states/clocks; 172.27 s |
| Cold U translation / warm V | 36 cases × delays 0/7; 72 A/B comparisons and 144 full QEMU comparisons; first V paired in all 72; 10.43 s |
| Load system corpus | 72 cases × delays 0/7; 288 model measurements; exact states/clocks; 1,500 memory V retirements; 19.05 s |
| Store system corpus | 72 cases × delays 0/7; 288 model measurements; exact states/clocks; 456 memory V retirements; 20.09 s |
| Original fetch-boundary corpus | 22 cases; 176 native executions, 88 full QEMU comparisons; 21,832 candidate records, 4,968 V retirements, 44 probe witnesses; 22.49 s |
| Canonical `make verify` | **FAIL**, native exit 2; 7 functional PASS / 101 FAIL; all 20 cycle streams parent-identical; 403.52 s |

The load/store/cold-alias comparisons use the prefix-payload parent. The fetch
comparison uses the source-pinned pair/next-only model, isolating the added
fetch cut; it does not reclassify that model's timing result as a pass. All
tests use real AXI, UV-fast, unchanged stimuli and complete records. These
counts are not gameplay measurements or additional unique ISA encodings.

[Independent regrading](audit_fetch_pair_next.py) checks **19,256 pins**, the
195-source/four-file composition, all replay records, all 20 cycle streams,
and the complete cold-alias QEMU/pairing comparisons. The same three inherited
stack-fault mask cases remain: 105/108 replay programs pass without optional
manifest masks. Canonical failure remains explicit. Audit SHA-256:
`9441cfb60415fa1dfc3f5d83a40fc1a981fb3a3790627f1653fd7d1c5ddfc73a`.

Evidence uses `fetch-pair-next-{core,replay,coldalias,load,store,fetch}-r1`
under the root above. All seven bounded owners are terminal, MainPID 0;
the canonical owner exits 1 because its native make exits 2, while the others
exit 0. Replay/directed workers use explicit, disjoint CPU affinity sets;
the build uses the guarded 32-job profile. Replay peaks at 766,771,200 bytes,
the 22-worker boundary run at 722,845,696 bytes. Neither Vivado nor another
heavy build overlaps this verification round. No second synthesis, full-PC
transfer, CoreMark run or board programming has yet been performed for the
composition. Its frequency is **unmeasured**.

The 40 MHz target, duration-valid CoreMark scoring/correctness seeds,
canonical gates, full Quake timedemo and cold Win95 desktop/UI acceptance on
the **candidate FPGA image** remain required. Existing-image Doom still fails
before gameplay, with no valid FPS result. Neither experiment has a measured
gameplay IPC; the older 0.50520554 total-U+V baseline and exact window above
remain the latest verified measurement.
