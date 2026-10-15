# Buffered fetch metadata ownership — October 15, 2026

**Private implementation and simulation experiment; not promoted or deployed.**
No candidate frequency, gameplay gain or standard-suite pass is claimed.
The retained older prefix-payload image estimates **36.591166892 MHz unplaced**;
the target remains at least **40 MHz synthesized and routed**.

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
Synthesis is expected to discard unused semantic logic; its actual area cost
and whole-core timing benefit are **not yet measured**.

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
the canonical owner intentionally retains failure status. No Vivado was launched.
Audit SHA-256: `4bc9170becf3b2aa4cd231955ebccabe24ee34fbec70e6bad296d3a98355a786`.

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

Next: transfer the exact corrected source set into the
full-PC/hardware closure, then measure area and the actual worst paths using
one guarded Vivado family. Do not infer frequency from the source-level cut.
Any synthesis gain still requires routed closure, duration-valid CoreMark and
both correctness seeds, full Quake timedemo, and cold Win95 desktop/UI on the
candidate FPGA in UV-fast mode. These remain open.

Verified gameplay baseline: **0.50520554 total U+V IPC**, older simulation model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates this candidate. Candidate gameplay
is unmeasured; the sampled cycle-count gain is **0%**, as intended for a
combinational timing experiment. The board is unchanged; existing-image Doom
still has no valid gameplay FPS.
