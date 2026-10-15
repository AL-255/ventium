# Current-U paired-read interface — October 15, 2026

**Rejected: loses V overlap during a U translation miss.** Warm directed checks
and the complete 108-program replay pass, but the new cold-alias test adds
1–3 cycles in every case. Do not synthesize, route or promote this version.
No Fmax, routed result, new CoreMark score, gameplay measurement or FPGA
acceptance exists for this candidate.

## Why this change

The rejected [fetch-fragment experiment](../fe_pipe/FETCH_FRAGMENT_EXTENT.md)
exposed a 100-level EIP-to-`pipe_mem_v_hit_q` path through next-address/DTLB
qualification, `core_mem_next_req`, pair-bank readiness and V acceptance.
The next-read exclusion is necessary for the cache's **general** paired-read
interface. Simply deleting it would let competing clients use the same banks.

The actual 152-definition core has `VEN_P54_DUAL_LOAD_PAIR`, but neither
`VEN_P54_DUAL_LOAD_PRIME` nor `VEN_P54_STORE_LOAD_PAIR`. Its only sideband
producer is `{pipe_v_pair_request, 1'b0}`: V accompanies a current U load.
There is no standalone two-lane or predecessor-prime pair client in this
configuration. Ordinary next-read priming remains enabled and unchanged.

[The private recipe](prepare_current_u_pair.py) adds a default-off
`PAIR_CURRENT_U_ONLY` integration parameter, passes it through
`ventium_l1_axi`, and enables it in `ventium_top` only for that producer profile.
The specialized bank lookup uses the already-qualified `pair_legacy_capture`
predicate directly. It retains current tag hit, cacheability, saved-window,
code/stream, byte/dword extent, held-response, distinct-bank, flush/snoop and
reset checks. The same-line immediate-response path is unchanged. No register,
extra cycle, cache port, cache-size change or U/V disable is added.

Default cache clients retain their complete original arbitration. Optional
paired-load-prime and U-store/V-load configurations retain the generic mode;
explicitly selecting an incompatible specialization fails elaboration.

**This is not unconditional old/new equivalence.** A sideband with no live U
can previously enter the general idle-pair branch. In the specialized interface
it is deliberately rejected. This matters because `pipe_new_load_req` does
not imply a physical request: a U translation miss, segment/page fault, route
denial or DMA stall may squash it downstream. Do not assume `c_req` is always
true, or claim the existence of this admission alone proves architectural
corruption. **The cold-alias result below demonstrates that this admission
can be useful, retained overlap, not an orphan.** The narrower contract is
therefore unsuitable even though it preserves architectural state.

## Closed checks

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

Three recipe tests pass. The [actual full-cache miter](run_current_u_pair.py)
closes in **14.05 seconds**. Generic mode compares against the unchanged cache.
Specialized mode compares against that same cache behind the explicit client
filter `c_req && !c_we && pair_req_valid == 2'b10`; this changed input contract
is recorded, not hidden as unrestricted equivalence.

- 538 bank/size/hint/held/invalidation cases per successful execution; 448
  fresh independent-bank accepts, 64 same-bank rejections and 1,536 held-slot
  observations, plus the original memory-chain checks (150 acceptances).
- Each execution compares 15,976 sampled interface/control states.
- A separate empty-slot/no-U probe requires acceptance in generic mode and
  rejection in specialized mode. Standalone two-lane requests likewise remain
  supported in generic mode and are rejected by the specialized interface.
- The deliberately broken specialization reintroducing no-U admission fails
  natively. No negative result is counted as a positive test.
- Three positive executions were run, but the third's requested LUTRAM/two-
  window flags were already present in the hardware profile. It is a repeat,
  **not an additional configuration** or evidence for FF/single-window tags.

[Full-core build](build_current_u_pair_core.py) closes in **20.93 seconds**.
The 195-source closure changes exactly `ven_l1d.sv`, `ventium_l1_axi.sv` and
`ventium_top.sv`. It derives from the retained faster prefix-payload parent,
not the rejected fetch-fragment candidate. All 152 definitions, `--assert`,
UV/system/relocated fast paths, full caches and `AXI_LINE_REPLAY=0` are retained.
The private C++ object references its own generated header. Native builds use
the guarded 32-job profile, limited to 10 GiB RAM / 2 GiB swap.

Candidate model SHA-256:
`10864ce701d4c90d5b8b16e3dd470a7eedc7e565450e2eef3b3f18784b5732b9`.

| Cold paged corpus | Cases | Candidate architectural records, AXI 0/7 | V-memory retirements |
|---|---:|---:|---:|
| Paired loads/read-ALU, same-bank and split rejection | 72 | 31,392 | 1,500 |
| Load/store pairs, including post-store readback | 72 | 32,112 | 456 |

Both complete fresh-QEMU comparisons and complete parent/candidate state and
cycle comparisons pass, in 17.99 / 17.76 seconds respectively. No masks,
terminal trimming, snapshots, STEP or pairing-disabled controls are used.
Same-bank and split cases still require zero memory-V pairing.

The existing held-read corpus also passes all 24 cold cases at AXI 0/7, with
identical complete states/clocks and preserved pairing. Four selected cold FP
overlap cases (flat/relocated, offsets 0/31) pass at both latencies with zero
cycle delta. This is a selected FP subset, not the full FP corpus.

## Open gates

The unchanged canonical `make verify` closes **FAIL**, native make exit2,
in **388.05 seconds**. Its inherited generic resource guard reduced the
requested four workers to one; the 600-second bound was retained. All 20
complete RTL cycle streams match the parent. No golden, mask or band changed.
A matching parent failure is not a pass.

The [108-program same-input replay](run_current_u_pair_replay.py) closes
**108/108 PASS** in 170.63 seconds, with 80,800 complete functional records,
identical parent/candidate clocks and 30,132 V retirements in each model.
There were no OOM events. This reuses the retained authenticated input states
and reference traces; it is not a fresh-QEMU or canonical-gate pass.

## Regression caught before synthesis

[The new microbenchmark](run_current_u_pair_cold_alias.py) maps linear `0x5000`
to the already-resident U physical page, but does not touch that alias before
the measured pair. V's separate translation and cache line are warm. It boots
from reset, builds real page tables and takes a real U translation miss; no
saved state or forced internal state is used. Wide, byte and read-ALU forms
run with flat/relocated segments at six instruction offsets: **36 cases**.

All 36 fail the unchanged A/B cycle comparison at AXI latency0. The driver
stops each case there, so **latency7 is not completed**. An
[independent audit](audit_current_u_pair_cold_alias.py) checks all 72 complete
QEMU architectural comparisons and 7,920 candidate architectural records:
state is correct and parent-identical in every case. However, every candidate
loses the first V pairing. Eighteen runs take one extra clock, eighteen take
three. For example, `byte-r0-o0` changes from **2,031 to 2,034 clocks**; the
first younger instruction moves from paired V at cycle1,907 to ordinary U at
cycle1,910, and its loop's V count falls from 16 to 15.

`core.sv` retains `pipe_mem_active_q` across `S_WALK`. An accepted V response
can travel with that packet while U's translation finishes. Requiring a
physical `c_req` at V admission removes this useful behavior. The 108-program
replay and warm-cache tests did not exercise this corner strongly enough.
This is a performance regression introduced by the private proposal, **not a
new architectural bug attributed to the retained parent**.

Retain this failing benchmark as a required timing-optimization regression.
The proposed next approach is to preserve the no-physical-U admission and
prove a narrower invariant: when this core's pair sideband can use the banks,
its ordinary next-read lookup cannot also own them. That could remove only
the late next-lookup veto, through an explicit integration contract, without
discarding pending-U/V overlap. Every next-read producer must be checked;
generic cache clients must retain arbitration. This proposal is **not yet
implemented or proven**. Do not merely bypass the veto or replace this failed
case with a warm control. The faster parent's fetch/response/writeback path
also still needs attention.

| Closed evidence | SHA-256 |
|---|---|
| `current-u-pair-leaf-r1/closed.json` | `a3da04226465fb5278d589598892b9f3b075e8ca06e5b91c5586e7fd8214b3cb` |
| `current-u-pair-core-r1/build-closed.json` | `b0bb9f62748419e42416921233207bc89313f68f727283fbcb13c2d53aa40fe4` |
| `current-u-pair-core-r1/verify-closed.json` | `14df913b1ca16bb9c1670b251f5a9e61b783ad605fa72c074ed4b0f4c16b20e1` |
| `current-u-pair-replay-r1/closed.json` | `803cc9a9f3081cf0a4bd088dea8cb6790a93573ed0d0dbaebdcaabe82d4d68e4` |
| `current-u-pair-coldalias-r1/closed.json` | `735f7c5a3db60c8844924001f5adac2c1a76778246927130596426789ebe009a` |
| `current-u-pair-coldalias-r1/audit.json` | `f6860d4517585efcdee4a708956e3b39ed1ebf3aa98464837653c5dca0e5d4a4` |

All production/root RTL and the physical board remain unchanged. Latest
verified gameplay is **0.50520554 total U+V IPC**, older model `c7b95b78`, cycles
**5,600,065,237–5,700,065,237**. That baseline predates this unmeasured candidate.
