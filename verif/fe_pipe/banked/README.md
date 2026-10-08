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

Next: qualify the distinct full-core derivative replacing **only** this child
with the capacity/QEMU/pair matrix and permission/fault/cache gates, then measure
area/timing. Keep the eight-entry synthesis inputs
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
restarts or preempts synthesis. **Both models subsequently compiled; see closure
below.** After synthesis closure and fresh RAM/disk admission, it builds the two models
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

## Matched full-core results, 12:42 UTC Oct 8

Both native builds and the bounded matrix have now closed. The first queue
stopped **after successful banked compilation, before tests**, because its
definition-count audit forgot the Makefile's unconditional leading
`+define+VEN_FPREM` (the explicit profile already contains FPREM). Its original
`closed.json` remains failed. No RTL, build definition, model or test was
changed to get past this check.

`resume_exact_defines.py` admits **only the exact leading FPREM token followed
by the entire ordered pinned profile**: 111 tokens/110 unique definitions for
banked, 108/107 for no-cut. Six added/missing/reordered/duplicate-token negative
controls per profile are rejected. The existing banked binary was hash-checked
and reused, not rebuilt; the unique no-cut model was then built normally.
`r2-closed.json` records native success, stable inputs and the original failure.

- Banked model SHA-256:
  `b4c6311b386dff92ec73fd23c6774846a053b606b109c4c8c7e78a6b1c4dbfc1`.
- Matched no-cut model SHA-256:
  `f6b17a879f34932dbe808d892141797d28866fef00a20b437b9d5d506c4d8cb6`.
- Capacity evidence: `ventium-fe-capacity.7pehlw5j` (banked) and
  `ventium-fe-capacity.yxxbfmfj` (no-cut), under external `tmp`.
  Each profile passes all **14** page-count/AXI-latency combinations in both
  cycle and cycle-func modes: full unmodified QEMU `--mode func --all`
  comparisons for cycle-func, matching complete PC sequences in cycle mode,
  natural OUT exit **133**, and **10 actual U-load/V-INC pairs** per case.

| Hot data pages | 4 | 7 | 8 | 9 | 16 | 32 | 64 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Banked warm round cycles | 13 | 22 | 25 | 28 | 49 | 98 | 194 |
| Matched no-cut U/V-fast cycles | 13 | 22 | 25 | 28 | 49 | 98 | 194 |

All seven measured warm rounds match at both AXI latencies (0 and 7). Thus the
banked proposal removes the measured eight-entry **capacity penalty** on these
working sets without disabling pairing. This is not a general speedup or
gameplay IPC claim. The capacity driver's old result profile string still says
`eight-entry-UV-fast-cut`; the pinned model/source hashes above, not that stale
label, identify the actual banked implementation.

Additional banked checks pass: **4** permission/stack combinations (both trace
modes, complete QEMU comparison), **48** paired retirement-state cases, and
**32** shift/branch cases. Evidence directories are respectively
`ventium-fe-permission-core.q49yy47b`, `ventium-uv-retire-pairs.n8ei19dk`, and
`ventium-uv-shift-branch.uyqtyszk`. These directed user-mode checks account for
the golden's unobservable terminal syscall explicitly; they do not close the
separate generic gate's terminal-record contract failures.

After both models and all microchecks closed, the prepared physical/netlist
check was launched at about **12:43 UTC** with the documented 8 GiB/no-swap,
single-family guard. Full CPU timing, the standard suite and original cold
FPGA Quake timedemo/movie remain open.

## Physical result and primitive-simulator initialization, Oct 8

The standalone synth/place/route flow closed natively with **exit 0**, unchanged
inputs and no resource stop; peak cgroup usage **4,653,154,304 bytes**. The
overall physical verification remains **failed/pending**, because its first
post-synthesis scoreboard failed. The original `closed.json` stays failed.

| Routed leaf | LUTs | Registers | LUTs used as memory | Query-to-physical delay |
| --- | ---: | ---: | ---: | ---: |
| Eight-entry control | 258 | 371 | 0 | 2.190 ns |
| Banked 64-entry proposal | 782 | 1,696 | 64 | 2.758 ns |

The tag banks map into actual dual-read distributed RAM. **The payload does
not:** all 1,600 payload bits remain flip-flops; the RAM inference hints are
not sufficient. This is an area-improvement opportunity, not evidence of an
incorrect architectural result. The standalone zero-IO, 25 ns constraints do
not establish a CPU frequency or full-system timing closure.

The first mapped scoreboard stopped at check 4: tag valid, but physical page
zero instead of `0x20000`. A passive observer found the payload write-enable
unknown because a vendor LUT4 address decoder never evaluated its initially
zero inputs under Icarus. A separate unmodified-vendor-library reproducer
(`postsim/tb_unisim_lut_init.sv`) confirms this event-initialization distinction:
constant initialized-zero inputs yield X, while an input transition returning
to the identical zero value yields the correct one. The archived netlist and
vendor models have not been changed.

The scoreboard now has an opt-in **address-port transition while reset remains
held and before any clock/reference update**. Only the netlist wrapper opts
in; ordinary RTL stimuli are unchanged. This is testbench initialization, not
a forced DUT register/RAM value, changed transaction, or relaxed expectation.
The initialized post-synth replay passed the first-capture point but hit its
**180-second wall limit** without completing; exit 124 is not a pass.

`postsim/replay_initialized.py` now runs both unchanged mapped netlists with
passive progress counters and a **600-second cap per scoreboard**. It pins
the two intentional testbench changes, all other original inputs and both
netlist hashes. The full 1,300,925-check assertion corpus remains required;
completion is still pending. No new synthesis or bitstream was launched.
