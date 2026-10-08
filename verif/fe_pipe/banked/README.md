# Banked translation-cut proposal

**Experimental, outside production and the running frozen synthesis.**
The [capacity probe](../CAPACITY.md) exposes a 32–33% warm-loop cycle penalty
above eight hot data pages despite genuine U/V fast execution. This proposal
addresses that specific structural limit; it is not a Quake repair claim.

`ven_fe_dtlb.sv` keeps the existing capture/query interface but organizes the
registered raw translation results as **16 sets × 4 ways**. This matches the
ordinary parent DTLB's page index and capacity. Query reads only four tags,
not a 64-entry associative tree. Each constant-way payload/tag bank has
independent query/capture addresses and no bulk data reset, with a distributed
RAM inference hint. Actual LUTRAM inference, LUT/FF cost and timing must still
be measured; the attribute does not prove mapping.

Safety rules stay unchanged: exact page owner, one matching way, in-place
updates, invalid-before-replacement allocation, per-set round-robin eviction,
and reset/context flush/**every parent fill** invalidating all children before
capture. Raw U/S, R/W, presence and dirty information travel with the physical
page. Live CPL, access intent and CR0.WP are not cached. No extra pipeline
stage, fast-path disable, changed architectural TLB capacity, guest-specific
addresses or permission bypass.

Remaining limitations are explicit: parent fills still invalidate unrelated
children; the parent's eight large-page entries can cover more than 64 small
page queries, so this exact-4-KiB child can still suffer extra misses in a
large-page workload. Its associativity differs from the old fully associative
eight-entry child. Do not generalize the ordinary 64-page retention result to
all address distributions or large-page working sets.

## Closed leaf checks, Oct 8

```sh
TMPDIR=/home/yukidama/external/tmp bash verif/fe_pipe/banked/run-leaf.sh
```

Evidence: `/home/yukidama/external/tmp/ventium-fe-banked-leaf.iPL6eJ`.
Four native builds close; input hashes unchanged. Assertions and the six hard
structural-warning classes remain enabled. Tiny leaf builds run sequentially,
two compiler workers in a separate **2 GiB / no-swap** scope; this does not
launch or interrupt the sole Vivado process family.

- Independent banked scoreboard: **1,300,925 checks**, including all 64 resident
  pages, same-owner updates, same-set eviction, full-tag aliases, negative
  lookup results, cross-set simultaneous query/capture, reset and invalidation
  collisions. 3,496 updates, 3,304 evictions and 7,105 cross-set captures.
- Actual P54-large parent integration: **60,166 checks**, 34,163 positive and
  8,481 negative owner observations; **273,304** live access-policy checks.
  Includes permission changes, dirty changes, unrelated replacement,
  small/large overlays and context flushes.
- Negative control suppressing parent-fill invalidation fails at the expected
  stale-hit assertion. It is a detected failure, not a correctness pass.
- Old eight-entry child fails the new **64-page retention** assertion. This
  is a performance-capacity discriminator, not a claim that the old leaf's
  architecture is incorrect.

Next: freeze a distinct full-core derivative replacing **only** this child,
rerun the exact capacity/QEMU/pair matrix and existing permission/fault/cache
gates, then measure area/timing. Keep the current eight-entry synthesis inputs
immutable. Do not launch a second Vivado family or overlap another large model
build with the current memory-heavy synthesis. Both CoreMark seeds, Win95
desktop and original cold Quake timedemo/movie remain mandatory before declaring
a major core/cache repair complete.

## Matched native build preparation

`/home/yukidama/external/tmp/ventium-fe-banked-core.iuIaEE` contains a frozen
**165-file** native source tree copied from the tested payload candidate.
`source-manifest.json` proves that **only** `rtl/core/ven_fe_dtlb.sv` differs;
the repaired L1 is identical. Parent source and binary receipts were checked
before copying. The banked profile keeps the exact 110 simulation definitions;
the matched no-cut control removes only the three FE-experiment definitions,
keeping UV/system-fast/AXI enabled. Each model has a unique local harness
basename; no old generated object is reused.

At **2026-10-08 10:26:14 UTC**, `after_synthesis.py` was queued against the live
Vivado invocation `32d0aec64c6949d88779db0f89a7cead`. Its watcher checks the
actual process cgroup and waits for that run's native closed receipt; it never
restarts or preempts synthesis. **Neither full model has begun compiling.**
After closure and fresh RAM/disk admission, it will build the two models
sequentially, **32 compiler jobs**, 16 GiB guarded scope, 600 seconds per native
build. It then runs the capacity/QEMU matrix and bounded permission/stack,
retirement-state and shift/branch checks. Inputs are pinned across the queue;
drift or failure stops it. `queued.json` is a plan/ownership record, not a pass.

This proposal has **no gameplay IPC measurement**. Historical `53f129e9`:
**0.1659957781052303 primary/U-counter IPC**, not total U+V, over qualified
intervals within cycles 8,721,490,845–19,169,282,165; it predates the proposal.
