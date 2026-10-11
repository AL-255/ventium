# Branch-fallthrough ownership sharing — October 11, 2026

**Isolated candidate, not a full-core or timing pass.** This targets the
remaining late I-cache ownership lookups seen in the retained MC-address
V-capture path. The currently running combined synthesis is unchanged.

## Change

`mc_descriptor` checks a small MOV after a paired branch. Although its outer
guard proves `pc == eip + off` with `off <= 13`, it performs two arbitrary
I-cache ownership lookups at `lin` and `lin + len - 1`. These follow late PC
selection and decode. The frontend already computes the current/next line's
tag, winning way, returned-buffer identity and collision checks.

[The recipe](../verif/l1/prepare_mc_branch_residency.py) replaces only those two
calls with the existing `ic_res_buffered_offset/end` helpers, under the already
enabled `VEN_IC_RESIDENCY_SPAN`. The original calls remain when it is disabled.
All PC/page/segment/line bounds, byte selection, decoder logic, priority,
request/commit predicates and address equations stay unchanged. No extra port,
cache-size change, clock exception, pipeline stage or serialization is added.

The transformation starts from the combined candidate's exact header
`5d2044b0…`; the generated header is
`e044fcd954b5c2a0f0151e5e83198833faeffa875a776f17bb388fb2e21614cc`.
It does not modify the source pinned by the active synthesis.

## Closed isolated checks

Four [recipe tests](../verif/l1/test_mc_branch_residency.py) pass. Z3 proves the
32-bit modular address identities for arbitrary CS bases/EIPs and decoded
lengths, including wraparound; the existing guard bounds the helper count to
28 and its six-bit position sum to 59. Wrong-offset and wrong-line alternatives
have counterexamples. This is an arithmetic proof, not whole-core formal proof.

[The native miter](../verif/l1/run_mc_branch_residency.py) extracts both complete
descriptor functions, the real raw-MOV decoder, real I-cache functions, current
frontend span and existing residency helpers. It reuses the existing fixture's
18 cache/returned-port scenarios, every start offset and U/V length, set/tag
carry, full-address wrap, duplicate tags, bypass priority, swapped/missing/
way-stale/collided buffers, and directed four-state inputs. It does not replace
ownership with a mocked per-byte table.

| Configuration | Full descriptor comparisons | Additional helper checks | Accepted first queries | Native exit |
| --- | ---: | ---: | ---: | ---: |
| Fetch bypass enabled | 1,771,072 | 221,344 | 64,024 | 0 |
| Fetch bypass disabled | 1,771,072 | 221,344 | 63,552 | 0 |

Each configuration includes 885,536 wrong-PC queries that must remain rejected.
Both compiled negative controls fail with descriptor mismatches: substituting
mere tag presence loses returned-buffer ownership; using the current line for
both endpoints loses next-line identity. All input hashes remain unchanged.
The test covers settled four-state behavior, not fixed-address event sensitivity
or sequential processor execution. The existing fixture refreshes the address
after cache-metadata changes to accommodate Icarus's function sensitivity limit.

Evidence: `/home/yukidama/external/tmp/ventium-mc-branch-residency.HG9bs2vj/leaf-r1/`.
Service `ventium-mc-branch-residency-oct11.service`, invocation
`ab76f485492d4ae0b7dfbbc6e7164678`, closes in 42.33 seconds; the journal reports
25.1 MiB peak memory. It launches only small Icarus jobs, not another Vivado or
full-core build. Sources, positive/negative logs and receipts are retained.

## Remaining acceptance

Measure the active [combined synthesis](TIMING_COMBO.md) first, then inspect its
actual worst paths before choosing the next integrated experiment. This new
header still needs whole-core differential/regression checks, source-matched
synthesis and timing measurement. No frequency gain is claimed for it.
The canonical gate remains red; the full standard suite and physical Win95/
Quake acceptance remain open. The best completed unplaced post-synthesis
estimate is **26.01118 MHz**, below the **40 MHz** requirement.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48…`, cycles
**1,200,065,237–1,300,065,237**. Both newer timing candidates are unmeasured in
gameplay; isolated equivalence does not supply a gameplay result.
