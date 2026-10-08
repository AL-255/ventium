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

## Prepared mapping and primitive-model check

`physical/run.py` freezes the actual eight-entry and banked sources, scoreboard,
Tcl flow and Xilinx functional library files. It compares the two standalone
leaves on `xczu15eg-ffvb1156-2-i`, records actual RAM primitive types and area,
and reports query-to-valid/hit/dirty/physical/permission paths. The banked
post-synthesis and post-route functional netlists then run the **same** independent
scoreboard against the vendor primitive models, not replacement RAM stubs.

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/fe_pipe/banked/physical/run.py --prepare-only
# Only after the current Vivado family AND queued full-model work have closed:
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/fe_pipe/banked/physical/run.py --prepared /absolute/prepared/directory
```

One exclusive Vivado family, 8 GiB/no-swap cap, 7 GiB early stop and 600-second
native limit cover both routed leaves. Post-netlist checks use the separate
bounded build scope, after Vivado has closed. A live Vivado scope is refused
before invoking its replacement-capable launcher. A fresh output is required;
failed or changed inputs are not silently resumed. The explicit 25 ns/zero-IO
leaf constraints do **not** model CPU arrival times, fanout or congestion;
neither a leaf delay nor its clock-budget equivalent is CPU Fmax.

**Preparation, not a physical result:**
`/home/yukidama/external/tmp/ventium-fe-banked-physical.0ug5nm6a`.
At 11:11 UTC Oct 8, its live-synthesis refusal was tested: native exit 1 with
`do not preempt live Vivado`, no run marker/output created, and the same
synthesis invocation/PID continued computing. Do not launch this leaf while
the separately queued banked/no-cut model matrix is active.

The scoreboard now has explicit settle/start-delay parameters, defaulting to
the original RTL schedule. The netlist wrapper allows the Xilinx global reset
pulse to finish before applying the same explicit reset and stimuli; it does
not force DUT state. Fresh Verilator leaf/parent checks and both negative
controls close as before (`ventium-fe-banked-leaf.EnoMSO`). A separate Icarus
**RTL** run using the delayed wrapper also passes all **1,300,925** scoreboard
checks, including 7,105 cross-set captures and the reset/invalidation collisions.
That simulator portability check is **not** a mapped-netlist pass: Vivado
mapping, area, timing and both netlist simulations still await execution.

After these four leaf builds closed, eight enumerated generated GCC precompiled
headers were removed, recovering **660,761,599 bytes**. Per-file hashes and
preserved executable/log hashes are in `pch-reclaim-closed.json`; source,
binaries and test results remain unchanged. Only the compiler caches need
rebuilding if those leaf object directories are reused.
