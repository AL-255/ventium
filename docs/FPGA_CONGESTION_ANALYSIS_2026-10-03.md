# FPGA congestion: measured causes and targeted optimizations

Analysis date: 2026-10-03 (Detroit), 2026-10-04 UTC. Target:
`xczu15eg-ffvb1156-2-i`, 40 MHz core / 100 MHz AXI. This is an optimization
analysis, not routed timing sign-off or a hardware timedemo result.

Gameplay IPC: verified pre-candidate baseline **0.42633263**, build
`5c2491f3`, cycles **7,099,999,637–7,199,999,637**. The live `srtctrl`
candidate has no verified gameplay IPC. Its standard-suite acceptance remains
pending.

## What the previous rounds actually establish

Three source/checkpoint states must not be mixed:

1. Oct 2 pre-front-span synthesis/failed-route diagnostics:
   `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/synth-inspection-oct03.2MjGyf5U/`
   and `route-failure-inspect-oct03.ScF3bypa/` under the same parent. The latter
   opened the preserved `fpga40-task48-retry.5ZayIg/.../rk_ao486_bd_wrapper_routed_error.dcp`.
   Despite a report header saying `Routed`, its route-status report has only
   **4 fully routed / 242,219 unrouted nets**. It is not a completed route.
2. Oct 3 front-span candidate:
   `/var/tmp/ventium-fpga40-icfrontspan-nothrottle.3ZFR9t/`, synthesis hierarchy
   inspected in `/var/tmp/ventium-icfrontspan-synth-inspection.I1YvlZ/`.
   The `impl_nobram_power` retry timed out after four hours. No deployable
   bitstream resulted.
3. Current independent-SRT-rounding-control candidate:
   `/var/tmp/ventium-fpga40-srtctrl-native.eMTOMg/`. Synthesis closed with exit
   zero; implementation handle **46772** was confirmed live and routing at
   **2026-10-04 00:16:31 UTC**. The frozen input
   bundle is `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-srtctrl.3M3DsT/`.
   It must remain immutable; any next RTL optimization is a separate candidate.

Between the two synthesis reports, **34,478 of 38,186 fewer LUTs (90.3%)**
are attributed to the I-cache-associated reconstructed hierarchy. This is
consistent with the front-span transformation, not an isolated causal proof.
The reconstructed
`u_icache` hierarchy dropped **88,737 -> 54,259 LUTs**, with **10,783 FFs
and 8 RAMB36s unchanged**. This supports sharing the fetch/tag selection
network, not reducing cache capacity. Full P5 cache geometry stays mandatory.

Previous front-span synthesis, including children:

| Reconstructed hierarchy | LUTs | Interpretation |
| --- | ---: | --- |
| Shared FP | 72,926 | Includes all FP children below; do not double count |
| I-cache-associated cluster | 54,259 | Includes moved/rebuilt core combinational logic |
| FP transcendentals | 30,874 | Child of shared FP |
| Regfile-associated cluster | 20,570 | Not 20k LUTs of GPR storage |
| FP state | 19,133 | Child of shared FP; wide map/read/write muxes |
| L1D | 10,552 | Includes 4,560-LUT pair-return child |
| BTB | 7,788 | Secondary memory-mapping candidate |

Vivado rebuilt hierarchy. Net paths below `u_icache` include core decode,
fragment translation and L1 acknowledgement logic; `regfile.sv` itself has
only eight 32-bit GPRs. Hierarchy labels locate physical clusters but do not
prove RTL ownership. Confirm source/cell origins before a broad rewrite.

Old failed-checkpoint congestion windows repeatedly attribute **99–100%**
of global level-5 cells to the `u_icache` cluster. The immediately previous
route's `iter_120_CongestedCLBsAndNets.txt` names instruction-tag outputs
and segment-base nets. This independently supports the front-end selection
and fanout diagnosis; it does not establish the current candidate's congestion
attribution.

## Why fewer LUTs alone did not solve routing

| Placed metric | Previous no-BRAM-power retry | Current SRT-control candidate |
| --- | ---: | ---: |
| LUTs | 186,324 | 184,716 |
| Occupied CLBs | 33,693 (78.98%) | 34,457 (80.77%) |
| F7 / F8 muxes | 18,912 / 7,471 | 19,417 / 7,515 |
| Total control sets | 5,246 | 5,706 |
| Minimum control sets | 2,185 | 2,223 |
| Physical-replication additions | 3,050 | 3,482 |

The current flow uses `AltSpreadLogic_high`: increased occupied CLBs can be
intentional spreading, not an RTL regression. Likewise **432 of the 460**
additional control sets come from physical replication, not new logical reset
domains. Do not claim a causal area/timing win from this non-isolated comparison.

Both runs report initial global/short congestion **level 6**. Initial timing
congestion improves **7 -> 6**. South-long congested tiles improve
**12.70% -> 5.95%**, while west-long grows **3.56% -> 9.60%**: pressure moves,
not uniformly disappears. The current router also reports **349 CLBs with high
pin utilization**. Overlap counts are convergence diagnostics, not completion
percentages.

### Fresh residual-congestion evidence

At **2026-10-04 01:13:24 UTC**, the current native run emitted
`impl_1/iter_140_CongestedCLBsAndNets.txt`: **289 bytes**, with a stable
SHA-256 of `4fefa47a042d76a2572ed5a1f2269fcbf3183972ad6316cacb02dc20d4073775`.
Root read the complete file and checked its hash. It lists six CLB tiles near
**X45–46 / Y187–191** and two nets under the rebuilt `u_icache` hierarchy:
`ic_tag_o[102][0]_831[11]` and `p_0_in23_in[0]`. The latter is an unresolved
synthetic alias; the text report does not identify its exact RTL expression.

The previous `impl_nobram_power/iter_120_CongestedCLBsAndNets.txt` listed
three tiles near X59–60 / Y219–231, five tag-array aliases and two segment-base
aliases. The fresh report corroborates residual tag-query/selection pressure,
supporting the targeted shared-residency proposal below. **Two listed nets
versus seven is not a measured congestion reduction**: placement and iteration
differ, and neither dump describes every congested region or proves RTL ownership.
The live log links the new dump to eight overlaps; root subsequently observed
three at **01:15:15 UTC**, with the same CPU-active worker. Routing was still
incomplete, not a legal-route or timing result.

## Optimization order and exact invariants

### 1. Share remaining sequential-span residency queries

`rtl/core/core.sv` already has shared `ic_front_a/b` probes and factored byte
gathering. The remaining `pipe_bytes_ok`, `pf_miss_fa`, and `v_bytes_ok`
expressions still call generic `ic_present()` on decoder-dependent addresses
around lines 5883, 5934 and 5964. Each query can create another large
variable-index tag-read mux.

Use six-bit **byte positions within the two-line span** to select existing A/B
presence and hit-way results. With two-state inputs,
`fp_pipe_decode_win_last` is always 5 or 6;
U/V lengths are four bits, including speculative zero values. Preserve the
original full 32-bit miss-address expressions; only factor their predicates.
Reuse buffered identity tests for fixed `flin` / `flin+15` slow-fetch endpoints.
Leave arbitrary branch-target, prefix-EX and exceptional-address queries alone.

Mandatory corner cases:

- Both lengths zero at a line-aligned `flin` queries **`flin-1`**, not A/B.
  Preserve that one backwards speculative presence lookup explicitly.
- Preserve 32-bit wrap, set 127 -> 0, and tag carry.
- Preserve last-match cache-way / bypass-slot priority, even duplicate tags.
- Returned data may be on either BRAM port, have stale way identity, collide
  with a fill, or intentionally contain stale speculative bytes.
- Do not gate `ic_fa_avail`, `ic_fb_avail`, or `ic_fetch_ready` with presence:
  those predicates have a different existing contract.
- Preserve four-state behavior. A naive ternary with an unknown offset can
  return a known hit where the procedural original lookup returns no hit.
- Keep lengths downstream of the shared probes: no decode-to-byte-selection
  feedback loop, no added register or pipeline latency.

First qualification is a source-extracted old/new miter over offsets, every
U/V length, bypass priority, collisions, rollover and unknown controls.
Then check actual production caller wiring, lint, differential/system gates,
and the full standard suite. Only an isolated synthesis/placement comparison
can establish resource/routing benefit; the miter cannot.

### 2. Localize validity and tag-memory ports

The I-cache stores **10,240 tag/physical-tag bits**; L1D stores **5,120 tag
bits**. Current placed control-set rows named for L1D tag enables are split
across many replicated `bypass_rst_m1` reset nets. This is a concrete
reset/enable/fanout target.

Do **not** simply remove reset or add `ram_style`: I-cache exports the entire
tag array, presenting many constant-index reads at its module boundary.
First narrow metadata reads to explicitly shared addressed lookup ports (or
perform lookup inside the cache). Then investigate reset-free, validity-guarded,
single-fill-write per-way **asynchronous LUTRAM** templates. Validity and LRU
remain resettable. Do not add BRAM latency to same-cycle metadata queries.

Preserve all three physical snoops, alias invalidation, noncacheable bypass,
fill poison across idle bubbles, pre-edge lookup state, and same-edge
fill/snoop/flush priority. Reset/debug observation of invalid tags needs an
explicit contract before changing storage. Require measured inferred memories,
not an attribute-only claim.

### 3. Cut unnecessary FP permission-to-payload dependencies

The previous front-span **synthesis** path is EIP -> frontend/decode ->
permission/translation/L1 acknowledgement -> FP payload/forwarding/admission ->
SRT rounding/result capture: **47.106 ns / 186 logic levels**, with **77.76%**
estimated routing. It is unplaced timing, not a standalone-divider delay or
Fmax. The independent live RC/PC mux already targets one false dependency.

Next inspect fresh critical paths before changing more:

- Accepted divide commands cannot use the fast-arithmetic forwarding path.
  Consider unforwarded SRT operand steering with shared memory conversion,
  proving accepted operands/start cycles under queues and all operation forms.
- Separate command **ownership/context** from same-cycle admission permission
  where valid/ready and queue semantics permit it. Do not blindly change
  payloads when VALID is low: queue READY may inspect them.
- Compact FP state's physical-bank write funnel / wide map muxing only with
  map-permutation and simultaneous-write tests. Keep pointer-based FXCH,
  shared ALU/SRT/transcendental resources and existing commit priorities.

No extra arithmetic units, unconditional pipeline stages, live-CW capture,
guest-specific hacks, or serialized restore without a protocol proof.

## Evidence-driven build policy

No implementation-directive sweep is justified by these reports. Keep one
Vivado family, preserve the current routing evidence, and do not kill Chrome.
For each next structural change: prove the local truth table / protocol first,
then compare an identically constrained frozen candidate's hierarchy, muxes,
control sets, occupied CLBs, high-pin windows, critical cone and congestion.
Only route an evidence-backed candidate. No incomplete-route deployment,
DRC bypass, or inferred Fmax from intermediate WNS.

After a major core/cache change, acceptance still requires differential gates
plus **both CoreMark CRC seed configurations, Windows 95 boot-to-desktop, and
a completed error-free Quake timedemo**. A microtest, snapshot, gameplay entry,
or successful bitstream generation does not replace that suite.

## First targeted proposal: local proof completed

The [isolated fetch-residency proposal](../verif/uopcache/proposals/ic_residency_span/README.md)
implements shared A/B presence/buffered helpers with the backwards-zero-length
query. At **2026-10-04 00:28:12 UTC**, root observed native handle **93713**
close with **exit 0**, passing **11,069,120 comparisons** across bypass-enabled
and bypass-disabled configurations. It uses actual source-extracted old
functions and caller expressions, all lengths/offsets, metadata/port fixtures,
rollover and directed X/Z cases. The test-only Icarus stimulus refresh and
earlier failed scheduling-adapter attempts are documented, not hidden.

This code remains under `verif/uopcache/proposals/`, not connected to production
RTL. The production core and live frozen candidate were not modified. There is
no new claimed LUT reduction, Fmax or gameplay gain: production integration,
lint/differential/standard-suite qualification and measured hardware resource
comparison are still pending. No new implementation-strategy trial was launched.

## Report provenance

Local inspection bundles above are retained, not committed generated artifacts.
Key text report hashes:

- Previous front-span `utilization_hierarchical.rpt`:
  `50109155da5b31a7980e491bdfeded2a6af4ca7af67a8b91baf67a5b28e6b7cb`.
- Previous front-span `timing_summary.rpt`:
  `3dfa35b245b5a6b686c45c1a351ff4502d21fe4b60ef2d00773ca8a92ea11854`.
- Older failed-checkpoint `congestion.rpt`:
  `58edbc781ac05510514abb9a7a410c65c4839d25ec99722ea4ecc0edec07765e`.

AMD's [control-set guidance](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Control-Signals-and-Control-Sets)
explains why control compatibility affects packing/placement; its
[utilization reference](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/report_utilization)
distinguishes hierarchy and implementation-stage reporting. These references
support the methodology, not proof of a Ventium optimization's benefit.
