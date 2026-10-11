# Carry-rotate depth reduction — October 11, 2026

**Private, helper-tested proposal. No new Fmax, whole-core pass or FPGA
acceptance is claimed. The requirement remains at least 40 MHz.**

## Measured reason for this change

The completed branch-residency synthesis has an unplaced core estimate of
**26.14379 MHz**, WNS **-13.250 ns** at 25 ns. Its 30 reported worst endpoints
are L1 replacement bits, not 30 independent bottlenecks. The first path is
`q_pc[0] -> ... -> u_dst_val[17] -> u_shm1[7] -> v_br_taken_eff ->
core_mem_next_commit -> dc_lru[53]/D`: **135 logic levels /38.039 ns**.
The V-response capture path has the same shift/branch section and
**-12.419 ns** slack. These are unplaced estimates, not routed sign-off.

The existing [path parser](analyze_setup_paths.py) accounts for the first
path's entire data delay (excluding source-clock insertion):

| Through named net / endpoint | Increment | Cumulative |
| --- | ---: | ---: |
| `l1_c_rdata[1]` | 25.465 ns | 25.465 ns |
| `u_dst_val[17]` | 0.980 ns | 26.445 ns |
| `u_shm1[7]` | 6.920 ns | 33.365 ns |
| `v_br_taken_eff` | 1.232 ns | 34.597 ns |
| `core_mem_next_commit` | 0.864 ns | 35.461 ns |
| `dc_lru[53]/D` | 2.578 ns | 38.039 ns |

Names in rebuilt hierarchy are not proof of RTL block ownership. The source
nevertheless contains four actual 32-iteration RCL/RCR loops in
`shrot_result`/`shrot_cf`; U's count-minus-one helper feeds the reported
`u_shm1` net. ROL/ROR already use bounded barrel shifts. The new report, not
assumed additive gains from earlier experiments, motivates this proposal.

**This alone cannot establish 40 MHz:** even deleting the entire 6.920 ns
segment leaves a long upstream path. In particular, `u_dst_val` multiplexes
memory ALU data into the generic U datapath, while the current fast decoder
admits only register shifts. Separating those shift operands requires a
separate decoder/owner proof and integration tests; no exception or unsafe
pairing rule has been introduced to hide that path.

## Proposed RTL

[The exact-source recipe](../verif/issue_uv/prepare_carry_rotate_tree.py)
replaces only the RCL/RCR result/carry implementations in ALU package
`3001ae4833b49f9b14d31c6685add9a81c0949443c25681b76fa15afdf9e3058`.
It rotates the operand and carry as a **9-, 17- or 33-bit ring** through six
constant-distance stages. The full six-bit helper count retains its original
`min(count,32)` behavior, not an incorrect `count & 31`. Architectural caller
masking, other shift operations, flags, decoding, admission and clocks are
unchanged. No pipeline stage or extra cycle is added.

The ring widths and stage distances are compile-time constants after unrolling;
there is no variable-divisor arithmetic. Result and carry use the same pure
helper. Actual resource sharing/area and frequency still require synthesis.
The candidate package SHA-256 is
`d99bb02a29042157b87b7cb0451d7aa6c6e3751873fd7674b5a040e01f5d1156`.
The frozen branch-residency FPGA export is untouched.

## Completed microbench

Three source-recipe tests pass, including exact reversible scope and rejection
of parent drift/reapplication. [The native runner](../verif/issue_uv/run_carry_rotate_tree.py)
compiles both complete packages and
[compares their actual helpers](../verif/issue_uv/tb_carry_rotate_tree.sv):

- **352,328 comparisons**, including **137,288 RCL/RCR** cases.
- All eight binary width values and suboperations, all 64 helper counts, both
  carry inputs, zero/all-ones/one-hot operands and deterministic random data.
- Exhaustive byte operand values with nonzero upper GPR bits; **176,128**
  count-32-or-greater checks; **72** X/Z-count checks.
- Three separately compiled defects fail with native mismatches: masking the
  count to five bits, taking carry from bit zero, and using a 16-bit rather
  than 17-bit rotation distance for word operands.

Native service `ventium-carry-rotate-leaf-oct11.service`, invocation
`a6b10daf3dcd4b9784abbdf6aa6823da`, closes with exit 0 in **34.96 seconds**;
actual affinity is CPU 8, peak memory **14,323,712 bytes**, no swap.
Evidence: `/home/yukidama/external/tmp/ventium-carry-rotate.XCh2NcqF/leaf-r1/`.
Closed receipt SHA-256:
`df5653a85f3bc5aba2f9cdd8029301ccbdebae67d6e33900b0bdbc8b30d96153`.
This is native helper equivalence, not all-input whole-RTL formal proof or an
independent ISA oracle. X/Z operand/width equivalence is not claimed.

[The whole-core builder](../verif/issue_uv/build_carry_rotate_core.py) now closes
successfully after the timing queue, native exit 0 in **25.40 seconds**. It
replaces only this package in measured parent model `70900101`, retaining all
150 UV-fast defines and a fresh model-local harness/header dependency. All
input pins remain unchanged. Unit `ventium-carry-rotate-core-oct11.service`,
invocation `5ad00b68397e4c8591dbfbb184839578`; model SHA-256:
`1c9cc9ede4e2afe92d9b85333949f8a4ed5927757d6c309edfa0a370e33b7f29`.

[The cold-check controller](../verif/issue_uv/run_carry_rotate_checks.py) closes
with failure under invocation `468d03d51a754c67850b3fb08da253c7`. It differs from the
previous checked controller only in its title, expected ALU-package delta and
unique unit prefix. It retains the five matrices/**820 cold fixtures**, initial
32 test workers, full QEMU architectural/A-B cycle comparisons, focused FP
fault checks, unchanged canonical gate and same-input replay. Its AGI failure
prevents it from reaching those last three steps. The original standard suite,
synthesis, route and physical
Win95/Quake validation remain required. The parent canonical QEMU gate is
**FAIL**; the new candidate's canonical run is pending, not waived by these
microbench results.

### Proven golden-port race and retained rerun

Both `agi-r1/k0-r0-o1/golden.command.json` and `k0-r0-o7` selected TCP port
**51617** after closing their ephemeral reservation socket. The offset-7
QEMU child reports **Address already in use**. Its tracer nevertheless connects
to the offset-1 child: the resulting **entire 199-record golden trace is
identical to the previously checked offset-1 golden**, not the offset-7 image.
The offset-1 tracer reports `ConnectionResetError`. The first wrong PC is
record 78 (`0x000f0201` versus `0x000f0207`), and the control RTL trace is exactly
its previously checked offset-7 trace. This is direct evidence of cross-connected
goldens, not an assumed environmental explanation for an RTL mismatch.

All original failed artifacts remain. The **unchanged** driver reruns all 12
AGI fixtures /48 model-latency measurements with one worker in `agi-r2/` and
passes, native exit 0, invocation `6b6e3d3a120f49048b005bf918b1aaf0`.
The other four matrices also closed successfully. The original 820-fixture
scope is retained; the sequential rerun avoids this race for this batch but
does not repair the shared ephemeral-port allocation algorithm.

[The continuation controller](../verif/issue_uv/resume_carry_rotate_checks.py)
requires the collision proof, identical fixture/model/input hashes, all five
complete matrices, and preserves the failed receipts. Its first admission
rejects a lexical path mismatch (`external/tmp` symlink versus canonical mount)
before starting any checks. The corrected identity check resolves paths and
still compares exact hashes. Invocation `5dd954e6aa0d45d2b15ce6f3599fc99c`
passes all **16 focused fault cases on both models**. The unchanged canonical
gate closes **FAIL**, native exit 2 in **428.98 seconds**, with stable inputs;
all **20 complete cycle streams match** the parent. Complete **108-program /
80,800-record same-input replay also passes**, in **76.60 seconds**. The
continuation controller is terminal with exit 1 solely because the canonical
gate remains red; its error list is empty and inputs are unchanged. Receipt
SHA-256: `bf92162afb71aee785ef28774f6a89520c6c665a0ed3029ed042f77aa304b622`.
No oracle masks, trace truncation, cycle bands or gate verdicts are changed.

Gameplay baseline: **0.51030715 total U+V IPC**, simulated model `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**, predating these timing proposals.
Both newer timing and carry-rotate candidates have no gameplay measurement.
