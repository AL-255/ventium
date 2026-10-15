# DECODE bus-address timing experiment — October 15, 2026

**Directed checks pass; canonical verification remains red. No new timing,
standard-suite or physical FPGA acceptance is claimed.**

The last verified gameplay measurement is **0.50520554 total U+V IPC**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
5,600,065,237–5,700,065,237. It predates this candidate. Candidate gameplay IPC
and FPS are unmeasured.

## Measured reason for the change

The [preceding combined experiment](../l1/BRANCH_ADDRESS_SHAPE.md) synthesized
at **35.814053435 MHz unplaced**, below the 40 MHz objective; it was not routed
or deployed. Its worst path starts at `q_pc[0]`, crosses prefix/overlength
decoding and fetch-probe qualification, then reaches shared memory/cache
payload logic and an integer GPR. The previous parent reached 36.591166892 MHz;
the combined change regressed frequency by 2.124%. Required FPREM correctness
repairs are retained rather than removed to recover that timing.

The bus driver's final payload mux reintroduced late `fe_translatable` into
`bd_addr`, even in `S_DECODE`. That state already prepares its next-page
`cur_lin_nat` independently and has an existing clocked assertion proving
`!bd_req && !cur_seg_rel && !cur_is_d`.

The exact-parent recipe changes one selector:

```systemverilog
// Before
if (fe_translatable) bd_addr = cur_lin;
// Candidate
if (fe_translatable || state == S_DECODE) bd_addr = cur_lin;
```

No request, translation/probe authority, fault priority, A20 handling, cache
ownership or commit condition changes. Only an inactive DECODE payload may
differ. There is no new register, bubble, global serialization, guest-specific
test, save-state dependency or dropped V path. The strict waiting-x87 policy
from [the underflow investigation](../qemu-trace/remainder_sequence/UNDERFLOW_STATUS.md)
is retained in the directed parent and added when transferring to the older
full-PC/FPGA profile. A future timing comparison therefore measures **one RTL
change plus one policy define**, not the isolated address selector alone.

## Closed directed verification

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
The runners retain native exit/wait receipts, source pins and trace artifacts.
All runs below are closed; input hashes remained unchanged.

| Evidence directory | Result | Scope / limitation |
|---|---|---|
| `decode-bus-leaf-r1` | 65,536 selector vectors; all-address Z3 proof; four negative controls rejected | Local proof assumes the existing no-request DECODE invariant; not a whole-core/MMU proof |
| `decode-bus-core-r1` | Fresh 32-job build, 20.41 s | 195-source closure; exactly one changed include; all 153 defines retained |
| `decode-bus-boundary-r1` | All 22 original boundary cases pass, 25.40 s | Complete QEMU state, exact parent/candidate traces and clocks; AXI delays 0/7 and cycle/cycle-func modes |
| `decode-bus-system-r1` | Five cold fixtures × delays 0/7/31 pass, 23.03 s | Bounded/relocated access, store fault/retry and invalid SS; QEMU or original architectural witnesses, unchanged policy |
| `decode-bus-delivery-r1` | 72 cases on each model, all 144 executions pass, 75.96 s | FPREM/FPREM1 underflow, FWAIT/FNOP/FLD1, #NM/#MF precedence and recovery; exact parent trace/cycle equality |
| `decode-bus-func-r1` | 108/108 private-reference programs pass, 108.63 s | Existing private reference and comparison policy; **not** the canonical gate |
| `decode-bus-core-r1/verify-closed.json` | Canonical `make verify` fails, native exit 2, 392.38 s | 7 functional PASS / 101 FAIL; all 20 cycle RTL streams identical to parent; cycle bands not waived |
| `decode-bus-soc-r1` | Fresh full-PC build passes, 23.35 s | All 102 shared RTL files exactly match the directed model; 98 inherited structural warnings unchanged, not a full-SoC lint pass |
| `decode-bus-lint-r1` | Strict CPU-hierarchy lint passes, 3.88 s | All six structural warning classes remain errors; not full-SoC lint |

Boundary evidence includes **21,832 candidate architectural records**, **4,968
paired V retirements**, and **44 actual probe witnesses**. System controls add
30,141 records / 5,487 V retirements. Delayed-exception controls add 141,648
records / 40,248 V retirements. These are test coverage, **not gameplay IPC**.
`cycle_mode=1`, the AXI backend, relocated fast paths and dual issue remain
enabled; no debugger STEP or intended-V breakpoint is used. Full P5 L1s,
single-fill and posted-16 transport are preserved in the PC/hardware profile.

The local mutation tests reject unconditional address selection, dropping
ordinary translated selection, and a wrong address. Restoring the old selector
fails the separate selector-independence objective, **not** architectural
correctness; the old selector is not falsely labeled an ISA bug.

## Reproducible identities

- Strict directed parent: `08be10a26af0eb36e9393837bebca22b1eed186ad3020179f438143cb4fa8605`.
- Directed candidate: `30274adaf425f55835f21562d845b08bec4552d37f4e29fd35ae7d3a95cb0b25`.
- Full-PC candidate: `7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68`.
- Frozen FPGA manifest: `36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc`.
- Changed bus include: `4bb63e3a106284c1c1e07aa91f35bd72a8ac25475bd402c5eeb2b0f30a7d9426`.

The FPGA export audits all **170 shared HDL inputs / 190 payloads**, with
**157 simulation / 159 hardware defines**. The only additional define is
`VEN_X87_MF_STRICT`; hardware still adds `SYNTHESIS` and `VTM_NO_DPI` relative
to simulation. The source-contract test rejects missing/wrong strict policy
and unreviewed payload changes. This freeze is explicitly **UNQUALIFIED**.

## Pending timing and system acceptance

Two unchanged, ten-iteration cold CoreMark CRC controls closed under
`ventium-branch-address-cm10-decode-bus-oct15-r1.service`, using the existing
runner against `decode-bus-soc-r1`. They are not duration-valid scores or the
standard suite. Both sets of five CRCs match the reference. Performance takes
**4,767,218 ticks** / 1,055,307 paired V retirements; validation takes
**4,753,406 ticks** / 1,054,254 V retirements. Both exactly match the parent:
**0% cycle gain**, as expected for a payload-only timing cut. Native runs take
221.43 / 217.13 seconds. The owner is terminal exit 0 / MainPID 0, invocation
`aa55476109d94b4c9dd3b13101074b85`. Independent audit rechecks 13,868 source pins,
actual CPU12 affinity, child reaping, logs/media/CRCs and zero OOM events.
The short guest console's duration error is not suppressed or counted as a
standard-suite pass; neither diagnostic ratio is a publishable CoreMark score.

`fpga/prepare_decode_bus_synthesis.py` prepared the single-instance synthesis
and independent clock-audit controllers. Synthesis launched at **18:22 UTC**
under `ventium-decode-bus-synth-oct15-r1.service`, controller invocation
`26931169bdb9480fa5bc8264a68a4ed8`, owned Vivado scope invocation
`7a750139557f4ca29f74d4c6fb9aa06a`. **It is running, not a completed result.**
The independent clock audit has not launched. The native
lifetime/ownership, wait/reaping, disk reserve and RAM/swap stop controls are
byte-identical to the closed preceding controllers. Guard-mutation tests
reject relaxed memory/disk limits or replacing the native wait with success.
Clocks remain constrained to **40 MHz core / 100 MHz PL**. Closed CRC controls,
independent audit, unchanged input pins and resource admission passed before
launch: 7,241,719,808 bytes disk free, 15,901,847,552 bytes available RAM.
Vivado retains 8 GiB resident / 6 GiB swap caps, a 13 GiB combined stop and
4 GiB disk / 2 GiB host reserve floors. No new compiler runs overlap it.
Report actual measured synthesized and routed frequencies,
not the requested constraint as achieved Fmax.

Still required: canonical gates green; duration-valid CoreMark performance and
full correctness seeds; candidate gameplay measurement; complete simulated
standard suite; routed timing; physical Win95 cold desktop/UI interaction and
full Quake timedemo on the exact candidate in UV-fast mode. No new bitstream
was programmed in this round.

Disk hygiene: 14 unused precompiled-header caches from closed builds were
removed, totaling **1,273,376,825 bytes**. No source, executable, generated
header/dependency file, trace or log was removed. The caches are regenerable;
receipts `decode-prerequisite-pch-prune-oct15.json` and
`closed-decode-pch-prune-oct15.json` preserve targets, sizes and hashes plus
unchanged executable/receipt hashes. An initial cleanup preflight stopped
without deleting anything when an engine's executable name differed; the
validated rerun used its actual `engine-obj/test` path.
