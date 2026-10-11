# Parallel first-line tag lookup — 2026-10-11 UTC

**Private experiment: native cache miters and five directed full-core matrices
pass. Canonical verification is still FAIL; timing/gameplay/FPGA acceptance
remain open.**
The objective remains >=40 MHz synthesized Fmax with
UV dual issue and the system/relocated fast pipeline and fast memory enabled.

## Measured reason for the change

The balanced SRT normalization candidate's closed matched timing audit reaches
**24.56339 MHz**, versus its write-direction parent's **24.33504 MHz**. Its
worst endpoint is now `dc_lru[8]/D`, not the FPU: **-15.711 ns** setup slack at
25 ns, 139 logic levels, 40.500 ns data delay. The V-memory capture path remains
nearly critical at **-15.392 ns**. These are **unplaced synthesized estimates**,
not routed timing or physical-board frequencies.

The worst path traverses decode, the speculative descriptor/address and
translation checks, cache mapping, `c_next_req`, then `mc_lookup_next`. That
late selector drives the tag RAM's read address before the tag comparison,
store-pair admission, backing ACK, commit and replacement-state update. The
reported arrivals are 32.089 ns at the selector and 33.772 ns at `hit` (including
the source clock arrival). This identifies serialization in the lookup cone;
it is not a prediction that removing it will by itself reach 40 MHz.

## Implementation and contract

[The source-pinned recipe](../verif/l1/prepare_parallel_tag_lookup.py) compares
both current and next physical addresses against the first-line tag/valid
arrays in parallel. The existing selector then chooses the two hit bits.

For either way, the transformation is:

`hit(select ? next_address : current_address)` →
`select ? hit(next_address) : hit(current_address)`.

The selector, selected address/set/tag, second-line lookup, data read ports,
requests, acceptance, update priority, replacement and coherence state are
unchanged. Without `VEN_PIPE_MEM_CHAIN`, the original comparisons remain
verbatim. Both flat LUTRAM and legacy two-dimensional tag layouts are retained.
Unlike an inactive-payload optimization, the selected hit bits must agree even
without a valid request. No new stage, clock exception or extra transaction is
introduced. Additional asynchronous tag reads **may replicate LUTRAM**; area
and mapped timing must be measured, not assumed to improve.

The independent parent is the measured write-direction L1 source:
`279590e09f07f0dfb7b588143678d750371d80356e71517da54c7c7a14139989`.
Candidate source:
`61161ec0f9231f3c6c714f66552828381192cb29191f6984368447bca744143e`.
This is not yet combined with the MC-address or SRT proposals.

## Verification completed

- Two exact-edit/drift recipe tests pass; all surrounding source is preserved.
- [The symbolic array proof](../verif/l1/prove_parallel_tag_lookup.py) finds no
  mismatch for any two-state selector, addresses, valid bits or tag contents,
  for all 26 positive index/tag-width splits of the 32-byte-line address.
  Reversed-selection and wrong-way defects each produce counterexamples in
  all 26 geometries. This is an equation proof, not whole-RTL formal equivalence.
- [Native extracted-RTL tests](../verif/l1/run_parallel_tag_lookup.py) pass
  **262,144 comparisons**: 16 configurations ×16,384, with 2/64/128/256 sets,
  both layouts and memory chaining enabled/disabled. Writable test arrays
  exercise invalid entries, both ways matching, aliases, distinct/same sets,
  boundary addresses and both selectors. Every configuration observes all
  four two-way hit combinations. Four independently compiled defective runs
  fail with the expected hit mismatch. Table writes are test stimulus, **not
  the cache allocation/coherence FSM**.

Evidence: `/home/yukidama/external/tmp/ventium-parallel-tags.EjloHRba`.
Native unit `ventium-parallel-tags-leaf-oct11.service`, invocation
`0a35d9b9e2844acbb565d4218da629d0`, exit 0, 2.54 seconds after obtaining the
shared build lock. Proof receipt SHA:
`ddb7c8e0e70c621dda1fcc5671cbb39ab357b76e699d2a99aa1385ddbcf48d91`.
Native receipt SHA:
`91ce33b7bfe26d15568d255010cabaf989787f5d9df3e514bebfc077d35d029b`.
The independent audit reopens every command and native positive/negative log,
checks coverage counts and service closure, and rehashes all retained pins.
Audit SHA:
`eb17979d81449de4bb7336f51b8026576e789a954af1468f271ca08cc5ccf313`.

## Whole-cache sequential checks

[The sequential miter](../verif/l1/run_parallel_tag_cache.py) instantiates the
complete original and modified L1s side by side, driven by the existing
`tb_l1d_mem_chain.sv` and `tb_l1d_window_keep_reset.sv` stimuli. The original
stimulus is retained verbatim; the generator only inserts a shadow instance
and comparisons. Two construction/drift tests pass, including rejection of
ambiguous instances and explicit output connections.

Both tag layouts use full 128-set/two-way geometry and eight actual banked
data arrays. Comparisons run after both clock edges and check all configured
outputs, tag-hit selection, lookahead acceptance, fill state, registered read
owner/data, every tag/valid/LRU entry and all data-bank rows. Existing fixtures
exercise continuous handoff, same-address requests, backpressure, rejected
miss/MMIO/crossing lookahead, byte-at-line-end, store interference, snoop/flush
cancellation, cache-only priming, fill-phase resets and held-response reset.
The reset fixture runs with store-window retention both on and off.

Six positive configurations and two compiled reversed-selector mutants are
included. The mutants must fail the actual cache miter; merely failing to build
does not qualify. Closed generated compiler products are archived with tar
comparison and hashes between cases to bound disk growth; model executables,
headers, sources and native logs remain available.

Unit `ventium-parallel-tags-cache-queue-oct11.service`, invocation
`705075dd978a4bcebc813109aaf10003`, waits for the exact MC-address timing queue
`2af5acc6f3684a2d8d476a01f2a40606`, then launches one guarded native cache run
with 32 compile jobs and a 540-second limit. The shared heavy-build lock is
retained. This first attempt stops at compilation; the retained failure and
corrected native results are described below.

One additional reason to measure the change is visible in the RTL: paired
store admission requires `!mc_lookup_next`, but also consumes `hit`. With the
selected address inside tag RAM, that Boolean exclusion is separated from the
late lookahead dependency by the RAM read. A hit-result mux exposes the exact
identity `!select && (select ? next_hit : current_hit) == !select && current_hit`
to logic optimization. This may remove an irrelevant lookahead dependency from
that admission path, beyond moving the tag comparison earlier. It is a
source-level explanation, **not evidence that the mapped path is removed**.
The eventual matched netlist must confirm the result and its read-port cost.

Remaining: whole-core UV-fast QEMU and A/B traces, canonical verification,
full-PC benchmark/correctness tests,
matched area/timing, and physical Win95/Quake acceptance. Existing canonical
failures are not waived by this leaf result.

## Paired-store coverage and core-build gate

The first cache matrix does not enable the mixed load/store admission path
identified in the timing report. The separate
[paired-cache extension](../verif/l1/run_parallel_tag_pairs.py) therefore keeps
the original `tb_l1d_pair_store.sv` stimulus and expectations, expands its
geometry to full 128 sets, and compares original/modified caches side by side.
It connects lookahead during U stores to a deliberately different tag/set;
that lookahead must never be captured. Existing tests exercise resident and
nonresident U/V stores, independent way ownership, bank conflicts, backing
credit and ACK backpressure, snoop rejection, withdrawn stores, and a saved U
load paired with a V store. Both tag layouts run with the saved read window
disabled/enabled. Two reversed-selector mutants must fail natively.

All configured outputs, acceptance/ownership signals, tags, valid/LRU state
and every bank row are compared after clock settling. The original fixture's
read-data/backing-memory checks remain active; a zero simulator exit without
its success marker and actual pair witnesses is insufficient. Two construction
tests pass. The existing recipe and basic-miter construction tests also pass
when invoked with their required source arguments. Construction checks alone
do not qualify a native cache pass.

`ventium-parallel-tags-pairs-queue-oct11.service`, invocation
`648a3530e0ca4de0b34c3a0e236c67a1`, waits for the exact basic cache queue.
Its native run is bounded to 540 seconds and shares the same guarded 32-job
build profile. No second Vivado run is launched.

[An independent closure audit](../verif/l1/audit_parallel_tag_caches.py) will
reopen both matrices' native commands, logs, binaries, generated fixtures,
service closures and compressed compiler members. Only after it passes may
[the core builder](../verif/l1/build_parallel_tag_core.py) create a derivative
of the measured write-direction core. It preserves the entire 150-define
UV-fast profile and changes only `rtl/mem/ven_l1d.sv`, checks all frozen inputs,
and verifies the private harness was compiled against its own model headers.
Core queue invocation: `f7b67a229835465a8235bc726da2cdaf`, unit
`ventium-parallel-tags-core-queue-oct11.service`. It is build-only; no full-core
functional or timing result is claimed by preparing or queueing it.

## Native cache closure and corrected attempts

The initial basic-cache attempt, invocation
`db1eb24eb681420f982805232013bb77`, fails before simulation: the generated
shadow module's opening name is changed but its named `endmodule` is not.
That driver and native failure remain under `cache-r1/`. The corrected generator
renames and validates both boundaries; a new construction test covers the error.
The original downstream queues stop on that failure without launching pair or
core tests. No RTL failure or correctness pass is inferred from it.

The first actual pair attempt, `pairs-r2/`, likewise stops at elaboration:
its monitor references optional `window_valid_q` with window reuse disabled.
The corrected monitor retains that comparison under the existing feature guard,
and a construction test checks the guard. It does not enable the window in the
disabled test or remove any existing stimulus/expected-data assertion. The
failed attempt/driver are preserved. The candidate RTL is unchanged throughout.

| Completed matrix | Native invocation | Positive configurations | Compiled defects | Time |
| --- | --- | ---: | ---: | ---: |
| `cache-r2` | `8c5c622f028b4884a6fce7dd208ba399` | 6 | 2 | 22.89 s |
| `pairs-r3` | `ea061c568eac46bdbbb8cb8336e873af` | 4 | 2 | 17.21 s |

All ten positive configurations exit 0 with their original success markers;
all four defects build successfully and fail with the expected native miter
mismatch, exit 1. The basic matrix compares **5,466 clock-edge samples**, with
408 active lookahead observations. The pair extension compares **1,124 edge
samples**, witnesses paired acceptance at 56 sample points and rejects 132
store-time hints. These are monitor observations, not architectural retirement
or gameplay counters. Every modeled tag/valid/LRU entry and data-bank row is
checked along with ports and ownership state.

The independent audit reopens both actual native service closures, commands,
generated fixtures, all run/build logs, binaries and compressed compiler members.
Its receipt `cache-audit.json` has SHA
`f44b17c19c65b1deb5018ffe494edb6e25679e79ba84f6ab397c10b405c31cd5`.
Basic-cache receipt SHA:
`6233011a748b4c4407c9677143e97da071a287ac9324f5b5b237d5aad7ad47a3`.
Pair receipt SHA:
`a6e38eeeb186b7a6de98392e560515bb60f6f0e17b1c4cd6aac35c6b39fb72eb`.

The actual full-core build closes with native exit 0 in **12.00 seconds**, unit
`ventium-parallel-tags-core-r2-oct11.service`, invocation
`fbfce69b9e2d40f983e8f32ffbc2570e`. Its input pins and private model-header
dependency check pass. Model SHA:
`f7e68723078b950fc04f2270c5548131614001bdc88d57c746e1bc47068aadb5`.
The build uses the
write-direction parent, not a combination with MC-address or SRT changes.
The newly closed independent [MC-address estimate](MC_ADDRESS_PAYLOAD.md) is
**26.01118 MHz**. This tag experiment has no timing result yet, and no combined
frequency gain is assumed.

## Closed full-core regressions

All five original directed matrices pass: 640 branch, 24 held-request,
72 memory, 72 FP and 12 AGI fixtures (**820 cold fixtures**). The
[independent auditor](../verif/l1/audit_parallel_tag_core.py) reopens their
complete QEMU and A/B traces: **438,312 candidate architectural records**,
438,312 cycle records and **117,436 actual paired V retirements**. Both AXI
latencies (0 and 7), paging/relocation and the unchanged 150-define UV-fast
profile are checked. No architectural fields or terminal records are dropped.

The first auditor invocation fails because its journal command match expects
the canonical mount path while systemd records the equivalent external symlink.
The corrected matcher resolves each exact builder argument, checks the script,
rejects extra/repeated arguments, and handles only the manager's sentence
period. Three new tests cover canonical/alias paths and wrong commands. No
RTL, trace, comparison or acceptance condition changes to resolve this error.

Receipt `core-audit.json`, SHA:
`02303e07c2c5315793adf4eac77ad7d4bfd6f417daaff631463c98cf292e2df3`.
The unchanged canonical gate exits 2 after **207.78 seconds**, still **FAIL**;
all 20 complete cycle streams are identical to the parent. This directed pass
does not close the existing canonical failures or the standard suite.

Closed generated compiler products for this model and the separate SRT-IDLE
model are losslessly archived, recovering **402,369,058 bytes**. Native
binaries, headers, private harness objects, sources and all traces remain;
verified archives and extraction commands are retained beside the models.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating this gameplay-unmeasured experiment.
