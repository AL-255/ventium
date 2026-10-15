# Buffered fetch metadata ownership — October 15, 2026

**Rejected as a timing improvement; not promoted or deployed.** The completed
matched synthesis audit estimates **36.025650263 MHz unplaced**, versus
**36.591166892 MHz** for the retained prefix-payload parent. Neither is routed
sign-off. The target remains at least **40 MHz synthesized and routed**; no
gameplay gain or standard-suite pass is claimed.

## Structural change

The retained parent timing report has a 93-level path from `q_pc` through live
instruction-byte alignment, semantic decoding, `d_fetch_need`, fragment strobes,
L1 response selection and U/V execution. Sharing the slow decoder with live
S_PIPE/S_EXEC dispatch connects these cones even though fetch demand and
S_DECODE fault metadata consume **buffered `ibuf` bytes**.

[The exact-parent recipe](prepare_fetch_metadata_owner.py) retains the existing
semantic decoder and adds a buffered instance of **the same `decode_stages`
module**, connecting only its nine fetch-metadata outputs. Semantic outputs are
explicitly open on that instance. There is no second opcode table, new register,
pipeline bubble, permission bypass, changed fragment rule or workload-specific
condition. Profiles without `VEN_PIPE_SDISPATCH` retain the original instance.
Synthesis discards unconsumed outputs, but the composed candidate still costs
2,343 additional LUTs and has worse estimated whole-core timing (details below).
The simultaneous FPREM transfer prevents attributing that entire change to
metadata separation alone.

All metadata consumers were inspected: demand and header capture are S_FETCH
qualified; overlength probing, #NM/#GP priority and CS decoded-extent checks
are S_DECODE qualified. In those states, the original decoder also selects
`ibuf`. The new simulation assertions compare all nine metadata outputs with
the live decoder on every FETCH/DECODE clock. The live decoder still supplies
all semantic descriptors, including `d_len`, for fast dispatch.

This differs from the [rejected fetch-fragment experiment](FETCH_FRAGMENT_EXTENT.md):
it separates the byte source before decoding rather than rewriting the crossing
calculation. No rejected timing candidate is inherited.

## Closed checks

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

| Check | Result |
|---|---|
| Source and adapter tests | Three pass; exact source scope, drift rejection, reversible identity-only driver changes |
| Extracted actual core wiring | 524,288 vectors; all 113 semantic outputs equal the original, all nine metadata outputs equal an independently buffered decoder |
| Owner-separation coverage | 94,576 inactive-state fetch-demand differences, while consumed metadata remains equal |
| Negative controls | Live-byte reconnection and lost byte-valid bound both fail natively |
| Whole core | 195-source closure, exactly `core.sv` changed; 152 unchanged defines; assertions and `AXI_LINE_REPLAY=0` retained |
| Private-reference functional corpus | 108/108 pass, 113.74 seconds; existing comparison policy unchanged |
| Same-input complete replay | 216 native executions; 80,800 records, 30,132 candidate V retirements, identical architectural state and cycles; 189.33 seconds |
| Cold system/fault corpus | Five fixtures × delays 0/7/31 × two models; 30,141 candidate records, 5,487 V retirements; 23.70 seconds |
| Finite-CS boundaries | Eight original images × delays 0/7/31 × functional/cycle traces × two models; 96 executions, 6,096 candidate records and 264 V retirements; 5.11 seconds |
| Unchanged canonical gate | **FAIL**, native make exit 2; 7 functional PASS / 101 FAIL; 417.67 seconds |
| Canonical cycle streams | All 20 exactly parent-identical; **not** cycle-band passes |
| Independent evidence audit | Pass; 1,454 input pins, full replay/system/boundary records and native terminal owners rechecked |

The system fixtures cover bounded and relocated fast loads/stores, permission
faults and stack segmentation. Four fixtures include full QEMU comparisons;
the stack fixture retains its explicit architectural/fault checks. Finite-CS
cases are exact A/B plus self-checking RTL diagnostics, **not QEMU differential
passes**: the known reference failure and original failed boundary gate remain.
No instruction trace is trimmed or compared only by PC. No new mask, golden,
cycle band, STEP control or pairing suppression is introduced.

The leaf build and runs close in 100.31 seconds, peak RAM 696,967,168 bytes,
zero OOM. The full-core build closes in 22.38 seconds with 32 jobs under the
10 GiB RAM / 2 GiB swap guarded scope. Its unique host object uses this model's
own generated headers. Functional/system/replay native children have recorded
CPU affinity and actual wait/reaping evidence. New artifacts use external
scratch; no board image or production RTL was overwritten.

The unchanged canonical gate and independent evidence audit are closed in
`fetch-metadata-core-r1/verify-closed.json` and `fetch-metadata-audit.json`.
A private-reference pass is not a canonical pass. Independently removing the
optional masks gives **105 passes / three failures**, the same historical
stack-fault cases (`tx_regform`, `tx_regform2`, `tx_stack`); this experiment adds
no waiver. Audit owner `ventium-fetch-metadata-audit-oct15-r1.service` closes
exit 0, MainPID 0, peak RAM 223,518,720 bytes. All test/build owners are terminal;
the canonical owner intentionally retains failure status. No Vivado was launched
for this initial core qualification.
Audit SHA-256: `4bc9170becf3b2aa4cd231955ebccabe24ee34fbec70e6bad296d3a98355a786`.

## Full-PC and hardware transfer

The older timing parent does **not** contain either FPREM repair. The transfer
therefore checks all 102 common RTL sources, and requires exactly three changes:
`rtl/core/core.sv`, `rtl/fpu/fpu_srt_div.sv`, and `fp_shared/ven_fp_top.sv`.
It composes the numeric and operand-exception recipes in order; a negative test
rejects a partial transfer that omits the exception repair. Every other common
source remains identical to the qualified directed core.

- Full-PC model: `e09cd8f84ad449a445c13af01a4c15f47852fc7c26cff63f7792ce8e780ae503`.
- FPGA manifest: `6d57df5328d1c6a2c4b3dc4f1e14a9021378966fa6388ea65af781a94dba3371`.
- Full-PC build: exit 0 in 23.56 seconds; 156 unchanged defines and a unique
  native harness object. All 98 inherited structural diagnostics remain visible
  and unchanged: this is **not** a full-SoC lint pass.
- FPGA freeze: 190 payloads, 170 shared HDL sources, 158 unchanged hardware
  defines, unchanged 40 MHz core target, full P5 caches, UV-fast mode,
  single-fill and posted-16 write configuration. Qualification is `UNQUALIFIED`.
- Strict CPU-hierarchy hardware lint: exit 0 in 4.43 seconds; all six structural
  warning classes remain hard errors. Not full-SoC or board acceptance.
- Eight transfer/adapter/controller tests pass. Timing launch, native ownership,
  watchdog and reaping code are byte-identical to the retained controllers.
  Synthesis admission still requires twice the measured parent disk growth
  above the 4 GiB stop floor, with 8 GiB RAM / 6 GiB swap caps and a 13 GiB
  combined early-stop limit. Only one guarded Vivado family may run.

Evidence directories are `fetch-metadata-soc-r1`, `fetch-metadata-fpga-r1`,
`fetch-metadata-lint-r1`, `fetch-metadata-synthesis-r1`, and
`fetch-metadata-clock-r1` under the evidence root above.

Both short cold-PC CoreMark controls and the independent audit pass:

| Seed | Candidate / parent ticks | Actual V retirements | Native runtime |
|---|---:|---:|---:|
| Performance | 4,767,218 / 4,767,218 | 1,055,307 | 222.99 s |
| Validation | 4,753,406 / 4,753,406 | 1,054,254 | 222.38 s |

Both complete five-CRC sets match QEMU. Actual native CPU affinity is CPU12;
both processes are waited/reaped, input/media hashes remain unchanged, all OOM
counters are zero, and the owner closes exit 0 / MainPID 0. Peak RAM is
202,469,376 bytes. The independent audit rechecks 2,118 source pins and hashes
to `2e1f628d943f11ea282c70051c9ba5d3515f22555ab58f58fdf0ec417f33c14b`.
These ten-iteration runs retain the expected insufficient-duration diagnostic:
**not valid CoreMark scores or error-free standard-suite acceptance**.
Measured cycle-count gain is **0%**, expected for this combinational timing cut.

Synthesis and the subsequent independent clock audit both close successfully,
with source hashes unchanged, terminal owners and no OOM. Their success means
the measurement is valid, **not that the 40 MHz requirement passed**.

| Matched synthesis result | Retained parent | Combined candidate |
|---|---:|---:|
| Unplaced estimated core fmax | 36.591166892 MHz | 36.025650263 MHz |
| Setup slack at 40 MHz | -2.329 ns | -2.758 ns |
| LUTs | 186,045 | 188,388 |
| Registers | 54,985 | 54,939 |
| BRAM tiles / DSPs | 277.5 / 47 | 277.5 / 47 |

Estimated frequency regresses **1.55%**; LUT usage grows **1.26%**. The new
worst path is `eip_reg[0]` to `u_regfile/gpr_reg[4][31]`, with 97 logic levels.
Its netlist traverses instruction alignment, live U/V decode, pairing and
microcache branch selection before GPR writeback. Separating slow buffered
fetch metadata does not remove this live fast-path chain. The report assigns
22.018 ns of its 27.547 ns data delay to **estimated unplaced interconnect**;
that is not measured routed congestion. Candidate unplaced hold slack is
-0.101 ns. Do not spend a placement/routing run or claim timing acceptance for
this result without a justified next change.

Synthesis owner `ventium-fetch-metadata-synth-oct15-r1.service`, invocation
`aae24d20dce8400280df6764cbf20770`, closes in 1,910.56 seconds. Peak resident
memory is 8,589,860,864 bytes and peak swap 1,769,672,704 bytes. The closure audit
checks 2,513 pins, 148 native HDL reads and all 158 hardware defines. There are
zero synthesis errors, one generated PS-clock critical warning and 1,568
warnings; these diagnostics are retained, not waived.

Clock-audit owner `ventium-fetch-metadata-clock-oct15-r1.service`, invocation
`7909cdbd65ec4509be0deb47c74978e3`, closes in 467.99 seconds. Its audit checks
2,519 pins, the original 40/100 MHz clocks, no unresolved black boxes and no
MDRV/LUTLP structural errors. Peak resident memory is 4,849,532,928 bytes with
zero swap. `fetch-metadata-{synthesis,clock}-r1/audit.json` hold the complete
receipts. Only one guarded Vivado family ran at a time. No implementation or
bitstream was launched.

The comparison includes the earlier FPREM numeric and operand-exception fixes,
but **not** the subsequently discovered exact-underflow repair. Preserve those
correctness fixes independently; do not inherit this metadata experiment just
because its functional tests pass. No isolated metadata area/frequency gain
is claimed.

Transfer and timing tools: `fpga/build_fetch_metadata_soc.py`,
`freeze_fetch_metadata_rk_candidate.py`, `run_fetch_metadata_coremark.py`,
`audit_fetch_metadata_coremark.py`, and `prepare_fetch_metadata_synthesis.py`.
No production RTL, board firmware, old evidence, goldens or comparison masks
were overwritten by this transfer.

## Identities and next work

- Parent core: `2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e`.
- Candidate core: `c4d914831fa7a23171e782bf558466ca31b92f42bee34a9c82b58c485e043f6f`.
- Changed `core.sv`: `bcfe5263c7e7ee7357c46e444d7d73babc729d0fc0ead188a0b59fe89947427f`.
- Private QEMU: `b81831c8976043f8d8d6fc7eeb1d1a981337ca274848f2fcc32b2d3fffbf8e48`.
- The parent includes the [qualified private FPREM repairs](../qemu-trace/remainder_sequence/EXCEPTION_STATUS.md), unlike the older timing baseline.

Runners: `run_fetch_metadata_owner.py`, `build_fetch_metadata_core.py`,
`run_fetch_metadata_checks.py`, `run_fetch_metadata_boundaries.py`, and
`audit_fetch_metadata_owner.py`. Direct canonical verification uses the unchanged
`verif/issue_uv/run_fp_nomem_verify.py`. All generated runs use the
`fetch-metadata-` prefix; native owner names are
`ventium-fetch-metadata-{leaf,core,func,system,boundaries,replay,verify}-oct15-r1.service`.

Next: close and audit synthesis, then measure the actual worst paths using the
prepared read-only clock audit. Do not infer frequency from the source-level cut.
Any synthesis gain still requires routed closure, duration-valid CoreMark and
both correctness seeds, full Quake timedemo, and cold Win95 desktop/UI on the
candidate FPGA in UV-fast mode. These remain open.

Verified gameplay baseline: **0.50520554 total U+V IPC**, older simulation model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates this candidate. Candidate gameplay
is unmeasured; the sampled cycle-count gain is **0%**, as intended for a
combinational timing experiment. The board is unchanged; existing-image Doom
still has no valid gameplay FPS.
