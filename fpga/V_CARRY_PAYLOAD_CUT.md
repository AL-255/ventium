# V carry payload timing candidate — 2026-10-11 UTC

**Unqualified timing experiment: 23.5855 MHz unplaced synthesized estimate.
At least 40 MHz synthesized Fmax remains required and is not achieved.** UV dual issue,
system/relocated fast pipeline, fast memory, full P5 L1s and posted-16 transport
are retained. No timing exception, cycle stage or issue restriction is added.

## Actual critical path and change

The preceding [FP-only ACK cut](FP_EXEC_NOMEM_CUT.md) synthesized at an estimated
22.1361 MHz in the unchanged diagnostic logic-only profile. Its worst path runs
through frontend decode, AGU/TLB, L1 lookup, memory acceptance, V carry-input
selection, the V ALU and GPR writeback. Late `pipe_pair_eff` was selecting CF
inside the V **data** path as well as authorizing its architectural consumption.

[prepare_v_carry_payload.py](../verif/issue_uv/prepare_v_carry_payload.py) removes
only `pipe_pair_eff &&` from that payload selector. The accepted pair's value
is identical; an unaccepted V may compute a different unused value. U flag
forwarding, incoming CF for a zero-count shift, and all write/retirement,
ownership, memory, debug and fault enables are unchanged.

Consumer review: `v_alu` architectural writeback is guarded by `pipe_pair_eff`
in `core_gpr_wb.svh`; `v_flags` architectural use is under `do_v`, assigned
`pipe_pair_eff`, in `core_fastpath.svh`. V branch evaluation uses `uv_common`,
not `v_input_flags`. This is **conditional payload equivalence**, not a claim
that unused combinational outputs are always identical.

Exact parent `core.sv`: `93865328ee935db1f1bf0677fce39f6071af14f9ea4f98be44569c6d91a95f83`.
Candidate `core.sv`: `b1e4686a9b28bbdae3586d9e7007c15429a343a3b72865186020931316abfcf7`.
Directed model: `8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6`.
Evidence root: `/home/yukidama/external/tmp/ventium-v-carry-cut.4KrQvvEw`.
These are private frozen candidates, not the unrelated dirty checkout.

## Closed evidence

- Four recipe tests reject unexpected source changes and reapplication.
- Source-extracted old/new payload blocks driving the real `v_pipe` pass
  **688,128 samples**, including 344,064 paired cases, all 14 ALU operations,
  three widths and all 32 shift counts. The 36,288 unpaired output differences
  are intentionally unobserved. Both deliberate defects—missing U carry
  forwarding and incorrect zero-count shift forwarding—fail visibly.
- The whole-core model builds natively with the parent's unchanged simulation
  profile. Only `rtl/core/core.sv` changes. The private harness object and
  generated-header ownership are checked.
- **144 cold paged cases** cover 12 carry/dependency forms, flat/relocated
  code and six offsets. Both models run at AXI latencies 0/7 in cycle and
  cycle-functional observation modes. Complete QEMU architectural checks and
  complete A/B state/cycle comparisons pass; **3,840 targeted V retirements**
  are observed. RAW-dependent and ADC V forms must remain unpaired.
- The first matrix (`system-r1`) failed a harness assertion: the observer
  marks the V record `paired=true`, while its preceding same-cycle U record
  has `paired=false`. The original failed script/run remain intact. Revision 2
  requires the actual consecutive U/V records, correct U PC, identical clocks
  and V's pair marker. Two unit tests include six invalid witness cases. No
  state comparison or issue requirement was removed.
- The independent audit rereads native exits, all traces and **16,994 pins**:
  **69,312 identical architectural records**, targeted pair witnesses and
  terminal native owners are verified. Audit SHA-256:
  `3feec31e9e2816da2d93f115bab18a518d75a5c4e61605da6e4e0f08321b6768`.

The unchanged canonical `make verify` still exits **2 / FAIL**. All 20 complete
candidate/control cycle streams are identical; this does not qualify the
existing QEMU/gate failures. No golden, mask or cycle band was changed.

## Full-PC and hardware source closure

The posted-16 full-PC build closed native 0 in 15.27 seconds:
`32beddd8035cb335123411e450ee645ed4ff03dddc6a4794685140cc24549b16`.
All 102 shared RTL inputs match the directed model, with only the reviewed
`core.sv` change from parent `74f16acf`. The 154 simulation defines are
unchanged. The 98 inherited platform structural warnings are not a lint pass.

The exported hardware manifest is
`f72fd96df8f9259cf35be66e952c6f01f46bbe5a4d147acb5d3b1c25dc2699c3`.
The independent exporter audit rechecks 20,261 pins, all 190 payloads and the
117-unit/49-include source closure. All 156 hardware defines, 40/100 MHz
constraints, full P5 L1s, platform L2 and posted-16 transport are unchanged.
Strict CPU-hierarchy lint on the exact export closes native 0 in 2.40 seconds;
this is not a full-SoC lint pass.

Both original short cold CoreMark seeds closed native 0 with the original CRCs
and exactly the parent clocks:

| Seed (10 iterations) | Parent clocks | Candidate clocks | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

The independent audit rechecks 20,104 source pins, original media, complete
consoles, native argv/CPU-11 affinity and child reaping; no OOM occurred. Audit
SHA-256: `2f732eb52b68f5bb723576dc8cf991b6bb9865780745b2f43b23230e3feb1ec5`.
This is **0% cycle-throughput change**, not a duration-valid CM/MHz score or a
standard-suite pass.

## Closed synthesis and timing — 00:34 UTC, October 11

The single synthesis controller `ventium-v-carry-full-synth-oct10.service`,
invocation `832f3005a99a4bba9062723d1995f2b8`, closes native 0 in **1,009.73 s**.
The original diagnostic `logic_only` mapping, 156 hardware defines and
40/100 MHz constraints remain unchanged. The independent audit checks all
20,477 source pins and 148 native Verilog inputs; only the intended `core.sv`
payload changes. Peak RAM is 8 GiB and swap 169.64 MiB, with no OOM/resource
stop. The inherited PS clock-pin critical warning and all 1,570 synthesis
warnings remain recorded, not waived.

| Metric | FP-only parent | Carry candidate | Change |
| --- | ---: | ---: | ---: |
| Unplaced synthesized Fmax estimate | 22.1361 MHz | **23.5855 MHz** | **+6.55%** |
| Worst core setup slack at 25 ns | −20.175 ns | −17.399 ns | +2.776 ns |
| CLB LUTs | 195,869 | 197,313 | +1,444 / +0.74% |
| Registers | 54,610 | 54,645 | +35 |
| BRAM tiles / DSPs | 277.5 / 47 | 277.5 / 47 | unchanged |

The native clock audit closes in **245.66 s**, invocation
`afd4730d2da24e42a250dc649c5de937`, retaining both original clock domains and
reopening the parent under its own original constraints. Both native owners
and their audit queue are terminal with exit 0; no implementation was started.
Worst unplaced core hold remains −0.101 ns. These figures are not routed
sign-off, measured board frequency or a 40 MHz pass.

All 30 reported worst setup paths now end in FPU bank clock enables, rather
than the parent's GPR/flags/multiply data inputs. The worst has **146 levels**,
42.102 ns data delay (9.512 ns logic, 32.590 ns estimated routing). It traverses
raw decode, address/permission preparation, next-read selection, L1 lookup,
store-pair/backing ACK and `fp_shared_load_cmd`. The latter is restricted to
`S_FLOAD`, whereas the memory-chain boundary is restricted to `S_PIPE`.
This motivates investigating physically separate read-ACK preparation, not
adding a false-path constraint or disabling early FP commands. Separately,
the [next-query address cofactor](NEXT_QUERY_PAYLOAD_CUT.md) removes a late
permission qualifier from inactive address preparation; its whole-core checks
are the next experiment. Neither investigation has a new timing result yet.

Evidence hashes:

- Synthesis audit: `8c24387d99fbd4ed913df0a218c0e494758179cacc267e576bd28b45223308a0`.
- DCP: `a020c35a4cbbd10ab3fae0c0d83bf7fec0721e83380d6d0a55e17a301febaa7f`.
- Timing audit: `a2ec3b8edc65d191771c86061b032212ce3ae12d3e9a5d6fd6363ce66154483b`.

**40 MHz, canonical correctness, routed timing and physical FPGA acceptance
remain outstanding.** No standard-suite or new gameplay result is claimed.

Latest verified gameplay baseline: **0.51030715 total U+V retirement-event IPC**,
model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates this
candidate, which has no gameplay IPC measurement.
