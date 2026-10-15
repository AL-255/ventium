# Pair/next-read timing cofactor — 2026-10-15

Status: **private candidate; not accepted or deployed**. This replaces the
rejected [current-U-only experiment](CURRENT_U_PAIR.md), not production RTL.
The new candidate preserves its parent's cycles and pairing in the completed
checks. Its synthesized/routed frequency has **not** been measured.

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
Their cycle-throughput gain versus the parent is **0%**; the intended benefit
is a possible higher FPGA clock, which must be measured separately.

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
storage. No Vivado run, FPGA reprogramming, or production RTL edit was made
for these checks.
Additionally, 2,351 closed-run trace paths were hard-linked to byte-identical
copies, recovering approximately 0.79 GiB while retaining every pathname and
SHA-256. The explicit plan and closure are
`pair-next-closed-trace-dedup-{plan,closed}-r2.json`; active/current candidate
traces were excluded. External free space after cleanup was about 6.6 GiB.

## Remaining promotion work

Both short full-PC controls are complete. Next measure the source-matched
candidate with the guarded, matched synthesis/clock-audit flow. Do not infer a
frequency gain from Boolean simplification. The 40 MHz routed target,
duration-valid CoreMark scoring/correctness seeds, canonical gates, full Quake
timedemo and cold Win95 desktop/UI acceptance on the **candidate FPGA image**
remain required. Do not deploy this source export as though it were a verified
bitstream.
