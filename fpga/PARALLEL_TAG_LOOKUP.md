# Parallel first-line tag lookup — 2026-10-11 UTC

**Private, leaf-verified experiment. No full-cache/core, timing, gameplay or
FPGA acceptance yet.** The objective remains >=40 MHz synthesized Fmax with
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

## Whole-cache checks queued

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
planned. The mutants must fail the actual cache miter; merely failing to build
does not qualify. Closed generated compiler products are archived with tar
comparison and hashes between cases to bound disk growth; model executables,
headers, sources and native logs remain available.

Unit `ventium-parallel-tags-cache-queue-oct11.service`, invocation
`705075dd978a4bcebc813109aaf10003`, waits for the exact MC-address timing queue
`2af5acc6f3684a2d8d476a01f2a40606`, then launches one guarded native cache run
with 32 compile jobs and a 540-second limit. The shared heavy-build lock is
retained. **These native cache results are not available yet.**

One additional reason to measure the change is visible in the RTL: paired
store admission requires `!mc_lookup_next`, but also consumes `hit`. With the
selected address inside tag RAM, that Boolean exclusion is separated from the
late lookahead dependency by the RAM read. A hit-result mux exposes the exact
identity `!select && (select ? next_hit : current_hit) == !select && current_hit`
to logic optimization. This may remove an irrelevant lookahead dependency from
that admission path, beyond moving the tag comparison earlier. It is a
source-level explanation, **not evidence that the mapped path is removed**.
The eventual matched netlist must confirm the result and its read-port cost.

Remaining: actual whole-cache/reset/coherence checks, whole-core UV-fast QEMU
and A/B traces, canonical verification, full-PC benchmark/correctness tests,
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
when invoked with their required source arguments. These are construction
checks, **not native cache passes**.

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

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating this gameplay-unmeasured experiment.
