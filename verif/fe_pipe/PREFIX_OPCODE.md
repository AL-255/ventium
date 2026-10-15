# Parallel prefix endpoint → opcode selection (2026-10-15)

Private timing experiment on the **36.591166892 MHz synthesized/unplaced**
prefix-payload parent. It does not incorporate the rejected response-kind
rewrite. Target remains **40 MHz synthesized and routed**, without disabling
UV, fast paths, or full P5 caches. No production RTL has been overwritten.

## Change and motivation

The parent's measured full-core worst path traverses fetch alignment, decode
length, fetch-demand strobes, response selection and U/V writeback. The slow
decoder already finds contiguous prefixes in parallel, but then encodes their
count and uses that count for two variable opcode-byte muxes. This adds a
serial encode/select dependency before semantic decode.

[`prepare_prefix_opcode.py`](prepare_prefix_opcode.py) derives a one-hot prefix
endpoint directly from the **unchanged** contiguous mask and selects opcode
bytes with parallel masked reductions. Prefix presence/priority, length,
ModR/M, EA, all semantic opcode arms, and all fetch/fault metadata remain
unchanged. It still reads only permission-qualified `ibuf_known` bytes. Endpoint
15 selects byte16, with byte17 zero; it never accepts a sixteenth prefix.
Invalid valid-count values 17–31 retain fail-closed masking.

Exactly one private source changes: `rtl/core/decode_stages.sv`, parent SHA-256
`e961f42125090b880ec06cddd1c9d2414af2f0a458e3fb008d39325b2b085292`.
The recipe rejects drift and reapplication. This adds **no cycle or state** and
is not expected to change IPC at a fixed clock. No measured IPC gain is claimed.

## Closed functional evidence

Scratch root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- An independent two-state bit-vector formula over all 16 arbitrary bytes and
  all 32 valid counts proves old/new opcode-selector inequality **UNSAT**.
  Removing endpoint15 gives **SAT**, detecting the intentional fault. This is
  a selector contract, not sequential whole-core formal verification; no
  four-state equivalence claim is made.
- `prefix-opcode-leaf-r2` compares **all 122 outputs of the actual full decoder**
  for **2,752,512 vectors**, including provisional outputs. It retains the
  parent's 152 definitions and all six hard structural lint classes.
- Coverage includes every prefix extent 0–15, every repeated prefix class,
  every opcode, all valid counts, every one-/two-byte opcode × ModR/M × default
  operand-size combination, mixed prefixes, arbitrary GPRs/flags/modes, and
  1,048,576 deterministic random cases. No output fields are masked.
- Two separately instantiated broken RTL decoders both fail natively: lost
  endpoint15 and wrong second-opcode index. These are not edited expected data.
- Native closure: **74.94 seconds**, CPU14, **647,909,376-byte** memory peak,
  no OOM. Build 57.26 s; positive execution 13.21 s; both negative runs exit1.
  Owner `ventium-prefix-opcode-leaf-oct15-r2.service`, invocation
  `04dd55c18b3a4cdc9bee3be7b9e94fa1`, MainPID0/native exit0 after closure.
- Five host tests pass: exact delta/drift, symbolic positive/negative checks,
  complete output comparison, and rejection of unparsed/duplicate ports.

R1 remains a failed build: the standalone harness omitted `sysop_e`, whose
compilation-unit declaration lives in `core.sv`, not the imported system
package. R2 extracts that exact declaration from the pinned parent. No decoder
logic or expected result was changed to repair the harness.

Closed R2 receipt SHA-256:
`02c30279130b74bcf991a3b4521da074f17887c2d0f4866f2ced0b922f8dfac2`.
Miter model SHA-256:
`435e188ed3e30fb31eaceaf320ed8249fe6d5889aaae19f8ab731ed50fb7ce04`.

## Matched isolated synthesis probe

[`run_prefix_opcode_probe.py`](../../fpga/run_prefix_opcode_probe.py) runs both
full decoders inside the same registered-I/O wrapper, with all outputs retained,
the exact 158 hardware definitions, the same ZU15EG part, 25 ns clock and
`Default -no_timing_driven` synthesis profile. All seven decoder/package inputs
were independently byte-compared with the frozen hardware closure: all match.

This is an isolated mapping probe, **not core Fmax, actual congestion, routed
timing, or a bitstream**. The wrapper registers are measurement infrastructure,
not an RTL pipeline change. It uses one exclusive Vivado family, an 8 GiB RAM
cap, zero swap, 7 GiB proactive stop, 4 GiB disk floor, 2 GiB host reserve and
600-second native timeout. Inputs and logs are pinned; failed runs are retained.

The matched probe is closed, native exit0, **207.84 seconds**, 5,043,658,752-byte
sampled peak, zero swap/OOM, all pins unchanged. The owner is
`ventium-prefix-opcode-probe-oct15-r1.service`, invocation
`20464c574eb14994b5e728a41ab6f028`; its exclusive Vivado scope invocation was
`be0c1555848141e4941c04518449c7e5`. Both owners are terminal; no Vivado remains.

| Isolated whole decoder | Parent | Candidate |
| --- | ---: | ---: |
| LUT primitives | 3,858 | 4,098 |
| Register primitives (including probe wrapper) | 808 | 814 |
| Fetch-demand setup slack at 25 ns | +17.988 ns | +18.643 ns |
| Fetch-demand data delay | 6.994 ns | 6.339 ns |
| Fetch-demand logic levels | 21 | 19 |
| Worst setup slack across all outputs | +16.104 ns | +16.746 ns |

The measured local fetch-delay reduction is **9.37%**, costing **240 LUTs
(6.22% of this leaf)** and six mapped registers. These include mapping/replication
effects in the registered probe, not added architectural registers. The local
gain is enough to justify whole-core qualification, not a claim that 40 MHz is
achieved. Net delays here are unplaced estimates. Full-core area/timing may differ.

Reports and both checkpoints are in `prefix-opcode-probe-r1/reports/`.
Closure SHA-256:
`985e3af4c0c4fdae1d82ddb1c71c39a3d9963f42df4669a56e78c1b8c800a164`.

The worst isolated fetch path above starts at **valid-count** registers. To
avoid mistaking that for the original byte-data bottleneck,
[`inspect_prefix_opcode_bytes.tcl`](../../fpga/inspect_prefix_opcode_bytes.tcl)
reopens both unchanged DCPs and restricts launch to the **128 byte-data
registers**, explicitly excluding valid-count registers. It performs no new
synthesis or constraint change. Byte-data → fetch demand improves from
**6.884 ns / 21 levels to 6.268 ns / 19 levels: 0.616 ns (8.95%)**.
This supports the targeted cone improvement, but still cannot predict
whole-core mapping or routed Fmax. The OOC clock-location warning remains;
the comparison is unplaced data delay, not clock-network sign-off.

This additional inspection closes native0, MainPID0, owner
`ventium-prefix-opcode-bytepaths-oct15-r1.service`, invocation
`8310d835b884493ba5b49073b76855b9`. Its logs and reports are retained at
`/home/yukidama/external/tmp/ventium-prefix-byte-path.prHwNafJ`.
Both DCP hashes were checked before and after inspection, unchanged:

- Parent: `61d01344eb55469f633a88a0b5dbe28e9ac2ccc24bb5db64aacb17f442da061f`.
- Candidate: `d8f1ded271750f63c8a56932d03ba6e8da1981f5c1cacdb5157409ee74c5f15f`.

## Whole-core transfer

[`build_prefix_opcode_core.py`](build_prefix_opcode_core.py) audits all 195
parent sources and copies the exact closure, changing only the decoder. All 152
defines, assertions, `AXI_LINE_REPLAY=0`, full-cache/UV-fast configuration and
original harness are retained. Its unique C++ source basename is rebuilt into
the new model's object directory; the dependency file resolves to that model's
own generated header. Root RTL and the frozen parent are untouched.

`prefix-opcode-core-r1` closes native0 in **21.77 seconds**, 32 compiler jobs,
actual owner affinity CPU0–31, under the existing 10 GiB RAM / 2 GiB swap build
scope. All pins are unchanged. Model SHA-256:
`14435a4d189ed3d0d441e14d356877cf6492c4c50077f80093b5d92ea8b4aff5`.
Build success alone is not acceptance.

[`run_prefix_opcode_checks.py`](run_prefix_opcode_checks.py) binds the unchanged
canonical/private functional gates, complete same-input replay and existing
cold system/fault fixtures to this model. Three adapter tests verify exact
reversal and unchanged comparison/fixture policy. Canonical failures are
retained as failures, never relabelled by a private-oracle or A/B pass.

All processor runs for this round are closed:

- Private-reference functional corpus: **108/108**, **118.20 s**. Independent
  regrading passes 105 without masks; `tx_regform`, `tx_regform2`, and `tx_stack`
  retain only their existing historical x87 stack masks. No new mask is used.
- Same-input replay: **216 native executions**, **196.29 s**, **80,800 complete
  records and 30,132 candidate V retirements**. Architectural state and cycle
  counters match the parent exactly. This is **0% sampled cycle gain**, as
  intended for a combinational timing change. Native children are reaped and
  their CPU13–16 affinity is observed; no OOM.
- Five unchanged cold system/fault fixtures, AXI delay0/7/31: **30 native
  executions**, **27.30 s**, **30,141 candidate records / 5,487 V retirements**.
  All full parent/candidate comparisons pass; actual child affinity and wait
  are recorded. They include bounded/relocated memory and precise fault cases.
- Canonical `make verify`: **FAIL**, **435.94 s**, native make exit2, wrapper
  exit1; **7 functional PASS / 101 FAIL**. All 20 cycle traces remain
  parent-identical. No golden, mask, band or comparison policy was changed.

[`audit_prefix_opcode_checks.py`](audit_prefix_opcode_checks.py) independently
regrades the complete functional/replay/cycle records, verifies terminal native
owners and **19,847 input pins**, and preserves the canonical failure.
Audit SHA-256:
`1f80a208437fd359c5c8dd078f68f1a632fa8df539043a0c646fb5d88f967c92`.
Audit success is evidence integrity, **not** a canonical gate pass.

## Acceptance remains open

No duration-valid CoreMark, standard-suite, routed or FPGA acceptance
is established by these checks. The parent's canonical functional/cycle gate
failures remain unresolved, not waived. The candidate must undergo full-core
same-input/differential checks before full-system transfer or deployment.

Latest verified gameplay IPC remains **0.50520554 total U+V**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`,
cycles **5,600,065,237–5,700,065,237**. This prefix-opcode candidate has **no
gameplay measurement**. That older simulator completed demo1 at 969 frames /
125.4 guest seconds / reported 7.7 FPS at 40 MHz; neither result qualifies
this candidate or the board. Physical Doom remains blocked by the old image's
memory-SMSW #UD before gameplay, with no valid Doom FPS.
