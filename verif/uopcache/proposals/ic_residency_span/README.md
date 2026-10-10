# IC residency span proposal — not production wiring

This directory proposes replacing repeated sequential-span tag queries with
the existing `ic_front_a/b` probes. It does not change `rtl/core/core.sv`, the
previous performance candidate, byte selection, cache geometry, fill sequencing,
or read-port ownership. Private integration and isolated area measurement are
now closed below; production rollout, whole-chip area, routing, timing and
gameplay benefits remain unverified/unmeasured.

**October 10 update:** the three presence-call assignments and 15 buffered
presence call sites now have a private, default-off integration, exact
extracted-caller four-state checks, full-core directed checks, identical short
CoreMark cycles and an isolated native area comparison (66.0% local LUT
reduction). The exact derivative is exported for a 40 MHz FPGA diagnostic. See
[`docs/FPGA_FETCH_CONGESTION_2026-10-10.md`](../../../../docs/FPGA_FETCH_CONGESTION_2026-10-10.md)
for results and limitations. The generic gate remains red. This is not a
production/whole-chip/standard-suite acceptance claim. Buffered substitutions
below are wired only in the private derivative, not checkout RTL. The historical
October 4 result and command below
are retained as provenance, not the current temporary-directory recipe.

For new work use `run_integrated_miter.py --core <frozen-core.sv> --out <new-dir>`
inside a bounded retained user service, with `TMPDIR=/home/yukidama/external/tmp`
and the output under that directory. The runner refuses an existing output,
requires a supervisor invocation, extracts the actual newly prepared caller
bodies and pins all source inputs. The closed October 10 service used 512 MiB
RAM, zero swap, 16 tasks, 200% CPU quota and a 150-second wall cap. It does not
modify the supplied core. `test_prepare_integration.py` checks transformation
guards without building a processor.

For the expanded private derivative apply `prepare_integration.transform`
first, then `prepare_buffered_integration.transform`. Run
`run_buffered_miter.py --parent <closed-first-stage-miter> --out <new-dir>`
under a retained 512 MiB/no-swap/240-second service. It extracts all 15 guarded old/new
call sites and covers all five distinct buffered expressions; it does not
substitute a detached helper for the real caller test. Both bypass variants
close 9,962,240 comparisons each. Run both preparation test modules together:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B -m unittest discover \
  -s verif/uopcache/proposals/ic_residency_span -p 'test_prepare*py'
```

All **19 preparation tests** pass, including the two-consumer regression below.
The 145-define full-PC derivative `89b68b62` independently completed both
duration-valid CoreMark seeds at **2.101890118 / 2.107616105 CM/MHz**, identical
ticks to `bfb867f7`; these are its own audited runs, not inherited passes.
The 146-define `343f0ccd` also independently passes both duration-valid seeds
at those same ticks/scores. Current verified gameplay is parent `bfb867f7`:
**0.50705320**, clocks **1,300,065,237–1,400,065,237**; both consecutive windows
from 1,200,065,237 average **0.508680175**. Area derivatives remain unmeasured.

The separate `prepare_prefix_integration.py` / `ic_prefix_span.svh` extension
shares the successor's 16-byte gather under `VEN_IC_PREFIX_SPAN`, with no extra
cycles or ports. `run_prefix_miter.py` tests the extracted old/new consumer,
including fixed-address metadata changes without pulsing the address. It does
not broaden the earlier presence-helper proof to arbitrary addresses. See the
fetch audit for 427,296 four-state comparisons, three required failing mutants,
384 paged whole-core fixtures, identical short CoreMark cycles and 83.40%
isolated LUT reduction. Whole-design synthesis instead grew **220,699 → 221,918
LUTs**. Review found a missed second gather in `core_int_retire.svh`; the first
integration changed only the decoder, leaving the sequential copy untouched.

For the complete private integration, additionally apply
`prepare_prefix_capture.transform` to that include and call `audit_consumers`
on both resulting files. Only the nonblocking copy's RHS changes to the same
shared bytes; its retiring-owner guard and all effects remain. The old incomplete
integration is now a required failing preparation test. The actual enabled
whole-core/include preprocessor output has **zero remaining generic prefix-byte
calls**; default-off output remains token-identical to the parent. Directed
model `7791051b` passes 1,536 full QEMU comparisons and 768 identical matched
whole cycle streams. Its full-PC model `751139e1` preserves both short CoreMark
tick counts. Independently audited whole synthesis now reduces **221,918 →
197,375 LUTs (11.06%)**, with unchanged BRAM/DSP counts. This measured reduction
belongs to the complete two-consumer integration. Its own full standard suite
is running; no gameplay, route or hardware acceptance is inherited from a leaf.

## Intended substitutions

Only under `VEN_IC_BRAM`, insert `ic_front_residency.svh` at module scope after
the existing IC FRONT SPAN. Keep all generic functions for arbitrary addresses.

| Current call | Proposed replacement | Contract |
|---|---|---|
| `ic_present(flin)` | `ic_front_a[IC_WAYW]` | Direct address, including partial X/Z |
| `ic_present(flin + {26'd0,fp_pipe_decode_win_last})` | `ic_res_present_offset(fp_pipe_decode_win_last)` | Window last is 5 or 6, or X from optional raw-byte form detection |
| `ic_present(flin + {28'd0,u_d.len} - 32'd1)` | `ic_res_present_end({2'b0,u_d.len})` | Length 0..15, including speculative zero and X/Z |
| `ic_present(flin + {28'd0,u_d.len})` | `ic_res_present_offset({2'b0,u_d.len})` | Length 0..15, including X/Z |
| `ic_present(flin + {28'd0,u_d.len} + {28'd0,v_d.len} - 32'd1)` | `ic_res_present_end({2'b0,u_d.len}+{2'b0,v_d.len})` | Sum 0..30; zero and aligned uses the backwards probe |
| `ic_buffered(flin)` | `ic_res_a_buffered` | Direct, not `flin+0` in four-state simulation |
| `ic_buffered(flin + 32'(IWORDS*4 - 1))` | `ic_res_buffered_offset(6'(IWORDS*4 - 1))` | Current `IWORDS=4`, offset 15; valid only while window is at most 32 bytes |
| `ic_buffered(flin + 32'd1)` | `ic_res_buffered_offset(6'd1)` | Known forward endpoint |
| `ic_buffered(flin + {28'd0,d_len} - 32'd1)` | `ic_res_buffered_end({2'b0,d_len})` | Four-bit reference length, including zero/X/Z |
| `ic_buffered(flin + {28'd0,sfetch_short_len_q} - 32'd1)` | `ic_res_buffered_end({2'b0,sfetch_short_len_q})` | Four-bit hint; existing permission guards stay unchanged |

The first five substitutions target `pipe_bytes_ok`, `pf_miss_fa`, and
`v_bytes_ok`. Retain the original arithmetic comparison/OR guards verbatim.
In particular, replacing a guard with `(!carry || present_b)` is not four-state
equivalent: unknown length makes the original arithmetic lookup default to 0,
and the OR guard can remain X even when B is resident. Preserve the exact full
32-bit address expressions and priority in `pf_miss_fa`; only its presence
predicates change. The miter source extracts those old caller expressions.

`ic_res_present_offset` accepts known offsets 0..31. `ic_res_present_end` accepts
known counts 0..30. Wider windows/counts require a new proof or the generic
functions; a six-bit sum must not silently truncate a third-line crossing.

Do not use these presence helpers for any arbitrary branch-target,
redirected-port or `p54_prefix_ex_flin` lookup. The separate prefix-span extension
has its own probes and proof. Keep non-BRAM paths unchanged. The optional raw
six-/seven-byte U window and 12-/14-byte pairing-buffer policy are unchanged.
The seven-byte form detector need not become a constant6 window.

## Identity, priority, and dependency rules

The A/B probes retain last matching cache way, then last matching bypass slot,
with bypass removed only by `VEN_IC_NO_FETCH_BYPASS`. The single static
`flin-1` probe preserves speculative zero-length backwards wrap. The existing
full `flin_nl` address carries tag identity through set 127->0 and full 32-bit wrap.

Buffered results check both returned `(set,way)` identities and both collision
flags. Returned ports may be swapped, unrelated, way-stale, or equal. Do not
infer buffered permission from equal byte contents or from a stale-A fallback.
This proposal never changes existing A-before-B byte selection or stale bytes.

In a future wiring patch, existing `ic_fa_avail/ic_fb_avail` can share the same
pure identity comparisons, and their way operands can use the A/B probe ways.
Do not add residency gating to availability or `ic_fetch_ready` itself: those
signals intentionally differ from `ic_buffered`. Keep shared queries and
buffer-identity comparisons as separate frontend cones, independent of decoded
lengths, FPU outputs, miss/fill producer outputs, and issue eligibility.
Lengths select helper results downstream only.

## Focused check

After inspection, explicitly run:

```sh
bash verif/uopcache/proposals/ic_residency_span/run-miter.sh
```

The runner mechanically extracts the actual core's `ic_present`, `ic_hit_way`,
`ic_byte`, `ic_buffered`, marked current span, and original caller assignments.
It records the core SHA-256 and fails closed on source-contract drift. It invokes
only Icarus/vvp on this tiny fixture, under one 120-second timeout and a 512 MiB
address-space limit; scratch artifacts are retained in `/var/tmp`.

After changing fixture metadata, the test pulses only `flin` to X for one tick,
then restores its desired value and settles. This refreshes both continuous
function-call arguments without changing the extracted expressions. The
installed Icarus otherwise leaves B stale when function-global arrays change
at a fixed address; `-gstrict-ca-eval` alone did not resolve it. This is the
behavior described in [Icarus issue #983](https://github.com/steveicarus/iverilog/issues/983).
An attempted test-only `always_comb` adapter instead delta-looped in this tool
and was removed. No probe/expected outputs are forced, no assertions are removed,
and production source is not modified. The gate proves the settled factored
truth table/caller expressions, not fixed-address event sensitivity.

Both bypass configurations cover every known start offset 0..31 and U/V lengths
0..15, window lasts 5 and 6, forward/backwards full 32-bit wrap, set/tag carry,
duplicate tags, bypass precedence, missing/redirected/way-stale/collided ports,
and directed X/Z lengths, window detection, addresses, metadata, and guards.
Comparisons use case equality (`===`), preserving X versus 0 versus 1 outcomes.

A passing helper/caller miter is not proof of a future production wiring patch,
the differential gates, the standard suite, or FPGA closure. Those require
their own checks after a separate production wiring change. No
performance value should be inferred from this proposal.

## Root-observed qualification

At **2026-10-04 00:28:12 UTC**, root observed native handle **93713** close
with **exit 0**. Both bypass configurations passed **5,534,560 comparisons
each (11,069,120 total)** under the runner's overall 120-second limit and an
additional **512 MiB RAM / zero swap / 16 tasks** user scope. The scope was
inactive after closure. No whole-core simulator or Vivado was launched by it.

The exact extracted core was SHA-256
`630663db2b2bbcb6521a768de86d0a8f020837f3c29ecee99904895c6b520053`;
it remained unchanged after the check. Final artifacts are retained at
`/var/tmp/ventium-ic-residency-miter.9Hu916/`:

- `bypass.log`: `71589a9b67c5689c55bfd2947730a7f0259fbd0a8c2527a83e483fefdc8e60b1`.
- `no_bypass.log`: `8a5e778f587ba79c5067e519ad8acbf98924008ceca11288a87f6a59e90fdfb0`.

Earlier failures are retained too: the packed-struct variable-bit lvalue was
unsupported by Icarus, then unchanged-address metadata exposed its continuous
function scheduling limitation. The attempted `always_comb` scheduling adapter
timed out; a five-second diagnostic showed **2 time steps / 2,019,093 thread
events**, confirming a delta-cycle loop rather than slow exhaustive coverage.
That adapter is absent from the final source. The final fixture input pulse
and plain-vector X/Z stimulus preserve all assertions and source expressions.

This is a combinational helper/caller proof only. Production wiring, structural
lint, default/shared-FP differential gates, the standard suite and an isolated
FPGA resource comparison remain required before declaring a deployed fix.
