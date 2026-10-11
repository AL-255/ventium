# Separate FP read acknowledgement — October 11

**Private, unbuilt whole-core proposal. Boolean leaf equivalence passes; no
timing, gameplay, standard-suite or FPGA acceptance is claimed.** The active
[next-query synthesis](NEXT_QUERY_PAYLOAD_CUT.md) is unchanged. The target
remains at least 40 MHz synthesized Fmax with UV and fast pipeline enabled;
the last completed estimate is 23.5855 MHz, unplaced.

## Structural reason

The carry candidate's worst synthesized path reaches FP bank enables through
raw decode, next-request lookup, paired-store/backing admission and
`fp_shared_load_cmd`. The latter is a read-only `S_FLOAD` consumer, but its
`mem_ack` input is shared with writes. The memory subsystem selects a read
response or a backing-write/paired-store acknowledgement into one `c_ack`.

The [recipe](../verif/l1/prepare_fp_read_ack_split.py) adds a read cofactor
under the existing `VEN_FP_LOAD_EARLY_CMD` feature. It changes four pinned
files, reverses every edit to the original whole-file hash, and retains the
original ACK/data response block verbatim. No feature define, clock exception,
pipeline stage, array, request, store acceptance or architectural owner changes.

| Boundary | New signal | Required relation |
| --- | --- | --- |
| `ven_l1d` | `c_read_ack` | Equals `c_ack` when `c_we=0`; contains no backing-write or paired-store admission inputs |
| `ventium_l1_axi` | `core_read_ack` | Same reset, DMA-drain, SMRAM and route-denial handling as `core_ack` |
| `ventium_top` | `core_mem_read_ack` | Same backend selection; legacy/direct modes retain their original ACK |
| `core` | `mem_read_ack` | Same `!fx_hold_e` final-fragment gate as `mem_ack` |

Only the final FP-load command, complete-m64 acceptance and the two associated
high-half-valid gates consume this sideband. Those consumers already require
reads. Assertions compare both ACKs on every read cycle in the cache and core.
Stream response ownership is retained explicitly, including no-new-request
response consumption. When early FP loads are not enabled, the original
interfaces remain unchanged and the internal read ACK aliases ordinary ACK.

This is not a justification for a false-path constraint. Live request, lookup,
tag/owner, cacheability, invalidation and fragment predicates remain; any of
them may become the next critical path. Only a native synthesis can show the
actual timing/area effect. No CPI change has been measured for this proposal.

## Closed leaf evidence

Evidence: `/home/yukidama/external/tmp/ventium-fp-read-ack.kG3e5cW7/leaf-r2`.
Four recipe tests pass. The source-extracted Icarus comparison checks the
actual old ACK block against the proposed read block in four profiles:
registered, registered with code reuse/dual store/stream, combinational with
dual store, and combinational with dual store/stream. Combinational ACK is
only a diagnostic compatibility profile, not permission to deploy it.

Each profile enumerates all 19 symbolic read-control bits, including all four
cache-state encodings, under both extremal backing/store-credit patterns:
**1,048,576 samples per profile**, **4,194,304 total**, with **2,097,152 read
equivalence checks**. These are Boolean control samples, not sequential cache
transactions. A separate structural check rejects write-credit names in the
new read block. All four deliberate `read_ack | m_ack` mutants fail at sample
0/backing 1 with native exit 1; every positive run exits 0.

Unit `ventium-fp-read-ack-leaf-r2-oct11.service`, invocation
`cc1a397cffcf4095a8a28ca0f9aa656d`, closes in **6.93 seconds**. Independent
reading checks all 20 source/binary pins, 13 native exit/log receipts, sample
counts and the retained terminal owner. Closed receipt SHA:
`d6a3e4a5064656bad624a113d3cf665c17ba43c023b043a548f5804b32ffef6e`.

R1 failed preprocessing, not equivalence: removing a data assignment up to
its first semicolon left a conditional payload's alternate branch behind.
Its original files, failed exit and logs remain in `leaf-r1`. The
[R2 extractor](../verif/l1/extract_fp_read_ack_r2.py) removes the complete
data-only span before the next ACK assignment and checks balanced directives.
The four-file RTL transformation is unchanged. Use
[the R2 runner](../verif/l1/run_fp_read_ack_split_r2.py), not the retained R1.

### Backend and fragment boundary check

[The seam checker](../verif/l1/run_fp_read_ack_seam.py) extracts the actual
old/new ACK assignments from the memory subsystem, both top-level backend
configurations and the core's final-fragment gate. It also checks the actual
read-ACK and write-direction port bindings. Given the independently checked
read-equivalence premise, **2,048 control combinations / 12,288 comparisons**
pass, covering reset, DMA drain, SMRAM/route rejection, request/response,
runtime backend selection, legacy/direct responses and fragment hold.

All four deliberate faults—bypassing reset, DMA drain or fragment hold, and
selecting the wrong backend—fail with native exit 1. The positive simulation
and compilation exit 0. Unit `ventium-fp-read-ack-seam-oct11.service`, invocation
`57b8c54dc7ba4204a7a2a46fc1eae8cb`, is terminal with exit 0. Receipt:
`seam-r1/closed.json`, SHA
`f698f11077c0a93470a677194e896e1191ece1effe3d67f961ce1fb44c851cf4`.
This verifies the combinational equations and bindings, not sequential cache
behavior, actual exception delivery or complete module elaboration.

## Next qualification

After the current synthesis/clock audit closes, inspect its actual result
before selecting the next timing candidate. A
[private whole-core builder](../verif/l1/build_fp_read_ack_core.py) is prepared
but **has not run**. It requires the closed leaf, the exact next-query parent
model, unchanged defines and a private native harness/header. Then check the
cold memory, FP/AGI and fault/fragment/reset matrices, canonical gates and both
original CoreMark seeds before measuring this candidate's synthesis. Leaf
equivalence does not prove full wiring, cache ownership or full-system safety.
For the existing `run-fp-memory-fault-gate.sh` fixtures, both same-profile
models must use `FP_MEM_ADMIT=1` and `FP_LOAD_COMMAND=1`; neither is a disabled
handoff control. Check the **complete** cycle-functional trace against QEMU in
addition to the script's selected fault/retry records. Its functional-mode
control is diagnostic, not UV acceptance. The existing fixed QEMU port requires
serialization unless a separately reviewed per-run port adapter is used.

Verified gameplay baseline: **0.51030715 U+V retirement-event IPC**, model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both timing
candidates; neither has a gameplay measurement.
