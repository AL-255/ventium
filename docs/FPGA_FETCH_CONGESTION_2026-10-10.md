# Fetch/operand congestion: native evidence and narrow sharing experiment

Latest verified gameplay is `bfb867f7`, **0.49069743** U+V event IPC at
1,600,065,237–1,700,065,237 clocks. All five consecutive 100M windows from
1,200,065,237 average **0.496524834**, retaining the preceding 0.47318727 dip;
no window is excluded. Audit: `ventium-store-admit-gameplay-r5.DipwsC7P/audit.json`. This same cache-backed
model qualifies both CoreMark seeds at **2.101890118 / 2.107616105 CM/MHz**.
Full timedemo remains unfinished. New area candidate `751139e1` is
gameplay-unmeasured. REP events are not exact P54 macroinstructions.

The final **two-consumer** sharing correction saves **24,543 whole-design
LUTs (11.06%)**. Earlier local successes followed by whole-design regressions
are retained chronologically below; they are not the final area result.
Directed cycle records remain identical. Placement has completed, but its
**18.21 MHz estimate and level-6 congestion** remain poor despite the area gain.
Routed frequency, generic verification and full-suite/hardware acceptance remain open.

## Native checkpoint diagnosis

Read-only Vivado reports used the **old parent** placed/physopt checkpoint,
SHA `d194b0f13e9d78dc2b3cccc637a8910147f4a547c11c0bf12a1fb06ba365332d`.
No placement, route, optimization, clock change or new bitstream was run.
Root: `/home/yukidama/external/tmp/ventium-sfetch16-physical-audit.uhqSfsrm`.
The controller closed native 0 in 124.55 seconds, stable pins, 4,469,288,960-byte
peak cgroup memory, zero swap/OOM and no resource stop. Retained supervisor:
`9fbddd4a2e9b430795bb95f7746f805c`; exclusive Vivado scope:
`eff8972e8e9647f0ae58dc81e75db732`. The closed native DCP is unchanged.

Findings from actual placement, not guesses from module names:

- Requested clocks remain **40 MHz core / 100 MHz PL**. The worst reported
  same-core-clock setup path has 47.202 ns data delay, 166 logic levels and
  slack -22.602 ns against 25 ns. Of its delay, 34.746 ns is estimated routing
  and 12.456 ns logic. The corresponding placed estimate is approximately
  **21.0 MHz**, not measured silicon frequency or routed timing sign-off.
- All 30 reported worst core setup paths start at EIP. Twenty-nine end in
  SRT state/enable logic. The first path traverses address generation, tag
  selection, returned-line/byte selection, decode and downstream FP control.
  Its endpoint alone does not show that an isolated SRT arithmetic path is
  the whole problem. Removing a decode/lookup cone cannot be assumed to fix
  every downstream path.
- The high-fanout report contains computed address bits with **3,024 / 3,007**
  loads, prediction-PC bits with 1,849 / 1,848, I-cache touch indices with
  1,669–1,716, and several other address cones around 1,347–1,351 loads.
- Placement reports level-5 mux-heavy windows. Several have 93–98% cell
  attribution to reconstructed `u_icache`, with 27–31% MUXF utilization.
  Other windows mix reconstructed register-file/core/fetch logic.
- Synthesis reconstructed large neighboring logic cones inside `u_icache`
  (54,033 LUTs) and `u_regfile` (27,836 LUTs). These are **not standalone module
  area measurements**. The register-file RTL itself is eight 32-bit registers
  and write ports; names under it include unrelated computed address logic.
- The two tiles named by the old interrupted route contain SRT result LUT/carry
  logic in this checkpoint. This supplies cell attribution absent from the
  old empty congested-net list, but does not prove those two tiles explain all
  routing congestion or show the state of a completed route.

## Narrow implementation under test

The repository already held a proved, unconnected
[`ic_residency_span` proposal](../verif/uopcache/proposals/ic_residency_span/README.md).
`prepare_integration.py` now makes a **private, default-off**
`VEN_IC_RESIDENCY_SPAN` derivative of the exact combined processor source.
Only three assignment bodies are changed: `pipe_bytes_ok`, `pf_miss_fa` and
`v_bytes_ok`. Seven repeated presence calls share existing A/B probes and one
fixed backward probe. Full miss-address arithmetic, priority and comparison
guards are retained. Speculative zero lengths still query the previous byte;
unknown lengths keep the original four-state behavior.

No cache capacity, memory port, register, latency, prediction, byte-selection,
arbitrary-target lookup, LRU policy or permission rule is changed. At this first
stage, buffered-lookup substitutions were not integrated. Disabled mode keeps
the original three expressions. Non-BRAM mode is not an admitted enabled profile.
This experiment is not included in the model running the long standard tests
or the `bfb867f7` FPGA export.

### Closed checks

- `ventium-ic-residency-integrated-oct10-r1`: actual new caller bodies are
  mechanically extracted from the prepared core into the existing four-state
  fixture. Both bypass configurations pass **5,534,560 comparisons each**,
  native 0, stable pins, within a 512 MiB/no-swap/150-second service. This
  includes all start offsets/U/V lengths, zero lengths, wrap, duplicate tags,
  bypass priority and directed X/Z inputs. The documented Icarus input-refresh
  workaround remains test-only; fixed-address event sensitivity is not proved.
- `ventium-ic-residency-core.YqNk7OKb`: private model **`5ecddf5e`** builds in
  15.08 seconds with 32 bounded compiler jobs, six fatal structural classes,
  matching private harness/generated-header ownership and stable pins.
- Its `matrix/closed.json`: **256 cold paged fixtures**, flat/relocated, every
  code offset and two AXI latencies; **1,024 complete QEMU comparisons plus
  1,024 cycle runs**, actual V-retirement witnesses, native expected exits.
  All **512 matched entire instruction-cycle record lists are identical**,
  not merely equal final clock totals. Closed in 42.50 seconds, stable pins.
- Disabled preprocessing reproduces the parent's entire core token stream
  (whitespace ignored), SHA
  `f3580892ac716281fbd9033a1c7f3619e20ad6d52b97671033d51f6f060c9c5c`.
- Six preparation-tool unit tests pass, including refusal of duplicate,
  missing or unreviewed callers and length/window-bound drift.
- The unmodified generic gate **closed red**, native 2: **7 functional passes,
  101 failures**, plus cycle-band failures. Its complete 20 cycle traces are
  identical to the parent, but this does not waive their failures. Only 21 of
  all 128 record streams match across runs: the independently generated user
  goldens seed different initial ESP values because executable pathname lengths
  differ. The failed full-stream identity audit is retained; no architectural
  values were normalized to turn it into a pass. Each run's own differential
  comparison still reports terminal/bounded-record length discrepancies.

### Isolated native synthesis result

`ventium-ic-residency-area-r2.s7AXo0Zt` synthesizes only the three combinational
presence/miss-address outputs, on `xczu15eg-ffvb1156-2-i`. Both inputs are
mechanically extracted from the actual four-state-tested old/new callers,
with identical ports, original guard logic and the real 5/6-byte decode-window
bound. Same Vivado 2025.2 options, no timing-driven mapping or placement:

| Synthesized resource | Control | Sharing candidate | Reduction |
| --- | ---: | ---: | ---: |
| CLB LUTs (combining-adjusted utilization report) | 7,424 | 4,489 | 39.53% |
| Raw LUT primitives | 7,429 | 4,500 | 39.43% |
| MUXF7 + MUXF8 | 5,239 | 3,144 | 39.99% |
| CARRY8 | 36 | 24 | 33.33% |
| Registers / BRAM / DSP | 0 | 0 | unchanged |

The first attempt failed before synthesis because of an unsupported
`read_verilog -define` invocation; its native failure remains archived at
`ventium-ic-residency-area.rQnRvpbv`. The distinct r2 uses the fileset's
`verilog_define` property. It closed native 0 in 42.23 seconds, peak cgroup
2,684,993,536 bytes, no swap/resource stop, retained successful supervisor
`b2caab554f1b4082beb74031d7dc8568`. All 652 controller pins were rechecked after
closure. The old checkpoint was an identity/ancestry pin, not an OOC input.

This establishes a **local logic-area reduction**, not an additive prediction
of whole-core savings: full synthesis may share or reshape these cones
differently. Full-core area, routed frequency and gameplay benefit remain
unmeasured. No DCP or bitstream was produced. The long CoreMark/Win95/Quake
tests on `bfb867f7` continue unchanged; this separate experiment is not promoted
to their candidate or to production RTL by the local result.

## Expanded stage: buffered-presence sharing

`prepare_buffered_integration.py` uses the same default-off
`VEN_IC_RESIDENCY_SPAN` flag after the first stage. It replaces **15 actual
call sites / five distinct expressions**: direct `flin` (seven), the 16-byte
window end (three), decoded-length end (three), short-hint end (one) and
`flin+1` (one). Original non-lookup guards, arithmetic, returned `(set,way)`
identity, collision checks and disabled branches are retained. The tool
refuses changed counts, window geometry or length widths. Arbitrary-target
queries, ports/state/latency/byte selection and permissions are unchanged.

Closed evidence, all under `/home/yukidama/external/tmp/`:

- `ventium-ic-buffered-leaf.ovK4JNrt/leaf`: actual old/new callers extracted
  into the four-state miter; **9,962,240 comparisons per bypass configuration**,
  19,924,480 total, native 0, reaped children, observed affinity, stable pins,
  no OOM, 66.01 / 46.58 seconds. The documented test-only Icarus input-refresh
  limitation remains; fixed-address event sensitivity is not proved.
- **13 preparation tests** pass. Initial preflight found that the `flin+1`
  caller starts an OR expression rather than following `&&`. The extractor
  check and test were corrected before preparing the tested candidate; no
  production guard was changed.
- `ventium-ic-buffered-core.lC2f4l2d`: directed core **`90239d23`**, 32 bounded
  compiler jobs, six fatal structural classes, native 0 and stable pins.
  The 256 cold paged fixtures close **1,024 complete QEMU comparisons + 1,024
  cycle runs** in 48.29 seconds. All 512 matched **entire instruction-cycle
  lists** are identical, with actual V-retirement witnesses.
- Default-off full preprocessing matches the parent token-stream SHA
  `f3580892ac716281fbd9033a1c7f3619e20ad6d52b97671033d51f6f060c9c5c`.
  The first whitespace-only check failed on one added leading marker comment;
  its script/output remain. Distinct `disabled-preprocess-r2.json` explicitly
  checks/removes only that exact comment and ignores whitespace. No RTL token
  or architectural trace is masked.
- Generic UV/AXI gate again **red**, native 2: **7 functional passes / 101
  failures**, plus cycle-band failures. Directed passes do not repair or waive
  its terminal/bounded-observation contract.
- `ventium-ic-buffered-soc.gsztNdDc`: full-PC **`89b68b62`**, native build 0
  (15.13 compiler seconds), matching private C++/generated-header ownership,
  145 defines, unchanged 98 inherited platform structural warnings. All
  intersecting processor sources match the directed build.
- Its independently checked `coremark/audit.json`: both **10-iteration
  diagnostics** close native 0, original five CRCs, exact parent ticks
  **4,767,218 / 4,753,406**, no OOM, 2,947 stable pins. Minimum-duration errors
  remain. This is **zero observed cycle cost**, not qualified 900-iteration
  scoring on the new model. Parent scores are not inherited.

### Expanded native area result

`ventium-ic-buffered-area.AvsfLN8k` compares **identical interfaces**: the three
presence/miss-address outputs plus five distinct buffered expressions extracted
from the mitered cores. Same Vivado 2025.2 part/options, actual 16-byte bound,
no timing-driven mapping:

| Resource | Original control | Presence-only | Expanded sharing |
| --- | ---: | ---: | ---: |
| Combining-adjusted CLB LUTs | 13,402 | 10,463 | **4,551** |
| Raw LUTs | 13,417 | 10,483 | 4,571 |
| MUXF7 + MUXF8 | 9,438 | 7,326 | 3,144 |
| CARRY8 | 68 | 56 | 24 |
| FF / BRAM / DSP | 0 | 0 | 0 |

The **66.0% local LUT reduction** is not additive to the earlier 39.53% result;
the earlier cone had fewer outputs. Native 0 in 69.43 seconds, peak memory
2,916,208,640 bytes, zero swap/OOM/resource stop, stable pins. Controller
`5ca17d3aa6504b049fc06becb02361e9`; exclusive Vivado scope
`862e5a1c807c4040a6e416ef9ad495c5`. No placement or timing result.

### Hardware export and full-design measurement

[`IC_BUFFERED_EXPORT.md`](../fpga/IC_BUFFERED_EXPORT.md) identifies the exact
**UNQUALIFIED** 188-payload / 147-define export. Strict hardware CPU lint closes
native 0 in 2.30 seconds, six structural classes fatal, unchanged pins. Clocks
remain **40 MHz core / 100 MHz PL**, full P5 caches, posted-16 DDR and
UV/system/relocated fast loads/stores. No slow-mode workaround.

Full synthesis only closed in `ventium-ic-buffered-full-synth.6cLKnbGf`,
controller `5c441fa813414299b1d46271ef45c11d`. Same `logic_only` mapping as the
old whole design, unchanged clock constraints, one Vivado family, **8 GiB RAM /
6 GiB swap**, 30-minute native cap, 12 GiB starting disk reserve and monitored
2 GiB disk/host reserve. Native 0 at 10:19:43 UTC, 1,104.90 seconds, stable
3,301 input pins, no OOM/resource stop. Peak memory 8 GiB plus 623,144,960 bytes
swap. Independent closure audit verifies the actual ordered defines, source
read commands, DCP integrity and retained successful supervisor.

The full result is **220,699 CLB LUTs**, versus the older parent's **190,864**:
**29,835 more**, with registers 54,571 → 54,647 and unchanged 277.5 BRAM / 47
DSP. This comparison includes the ten performance backports as well as fetch
sharing; neither isolated causation nor a whole-design sharing win is proved.
The isolated 66.0% result does **not** establish compactness of the combined
processor. Investigate the native mapped cones before another placement/route.

There is one critical synthesis warning in both runs: generated PS XDC's
`create_clock` cannot resolve `PS8_i/PLCLK[0]`. It is not waived; checkpoint
clock inspection is part of the read-only comparison. New synthesis DCP SHA
`2efbd305640c98e626b2dd31861f34922b689c6451718c30d1d7cca5058ec36c`.
Read-only comparison: `ventium-ic-buffered-netlist-audit.o1OrEevL`, controller
`455c1db5ea1d4f829a4aa31cef7f0fe5`; immutable old/new synthesized DCPs, 10-minute
cap, 8 GiB RAM / 4 GiB swap. No optimization, placement, routing, clock changes
or bitstream output. No new routed frequency or hardware acceptance.

## Successor-byte lookup: the newly enabled duplication

The closed native netlist comparison (`ventium-ic-buffered-netlist-audit.o1OrEevL`)
took 87.57 seconds, native 0, stable DCPs, 3,263,479,808 bytes peak RAM, no
swap/OOM. Reconstructed `u_icache` attribution rises **54,033 → 83,353 LUTs**;
L1D rises only 6,960 → 7,164 and AXI master 431 → 578. Reconstructed boundaries
absorb neighboring core logic and are not independent module costs.

The prefix/EX performance extension activates **16 generic `ic_byte` calls**
at `p54_prefix_ex_flin+i`. Each independently indexes the full tag metadata
and selects a returned line. Native isolated RTL statistics show 32 separate
256-bit muxes and 15 full-width address adders for this gather. This is a
concrete duplication to remove, not evidence to disable prefix overlap.

`prepare_prefix_integration.py` now produces a private, default-off
`VEN_IC_PREFIX_SPAN` derivative. Two line probes share the successor's 16-byte
gather, retaining ordered cache-way/bypass priority, returned set/way identity,
A priority, collision rejection, stale-A fallback and ternary X-merging.
No new ports, cache state, latency or admission/retirement permission. The
existing system/relocated prefix overlap and UV-fast mode remain enabled.
Full-width `base+0` deliberately preserves the original arithmetic's unknown
address behavior. The default-off full preprocessed core token stream is
identical to its parent (only whitespace ignored; no comments/RTL discarded).

Closed evidence under external scratch:

- `ventium-ic-prefix-leaf.wxaN00ze/leaf`: **213,664 + 213,632 = 427,296** native
  four-state byte comparisons, bypass on/off, 11.97 seconds. All sets/offsets,
  full address wrap, duplicate tags/bypass, returned identities/collisions,
  stale bytes and directed X/Z inputs. **18 fixed-address update checks per
  mode**, with no address pulse or manual DUT recomputation. Native 0, actual
  affinity, children reaped, immutable inputs, retained supervisor
  `6a00a58472834ea397f0eaeaf74ebc13`.
- `ventium-ic-prefix-negative.uy08SwlM`: three independent wrong implementations
  (stale-B fallback, reversed way priority, removed full-width X arithmetic)
  each fail natively at the specifically required fixture, not by timeout or
  compile error. Original candidate/positive evidence unchanged.
- Preparation-tool suite: **15 tests pass**, including refused width, consumer
  state/index, marker, duplicate and repeated-application drift.
- `ventium-ic-prefix-core.v5Uu6dx1`: model **`bdfa17b4`**, native build 0 in
  15.25 seconds, six fatal structural classes, 32 bounded compiler jobs,
  private harness/current generated-header ownership and stable source pins.
- Its `prefix-matrix`: **384 cold paged fixtures**, six instruction/veto kinds,
  flat/relocated clients and every line offset. **1,536 full QEMU comparisons
  plus 1,536 cycle runs**, AXI latencies 0/7, actual V-retirement and overlap
  witnesses, unchanged EX floors. All **768 matched entire cycle-record lists
  are identical**, native expected exits, 39.69 seconds, stable pins. This is
  not merely equality of final clock totals. Supervisor
  `88a333995b2d4c75bffc4e9e6a989c26`.

Isolated same-interface native area (`ventium-ic-prefix-area.HxnkxgUE`):

| Resource | Original successor gather | Shared successor gather |
| --- | ---: | ---: |
| Combining-adjusted CLB LUTs | 27,949 | **4,640** |
| Raw LUT primitives | 27,949 | 4,769 |
| MUXF7/8 | 19,855 | 2,463 |
| CARRY8 | 124 | 12 |
| Registers / BRAM / DSP | 0 | 0 |

**83.40% local CLB-LUT reduction**, not an additive or whole-chip projection.
Same Vivado 2025.2, part and logic-only OOC objective; no timing/placement.
Native 0 in 87.37 seconds, peak RAM 4,392,386,560 bytes, zero swap/OOM,
unchanged pins; controller `db02add2c23d4eb5aa0bfa7290f81974`.
Full-PC model **`343f0ccd`** closed native build 0 in
`ventium-ic-prefix-soc.ApbJoeMH`. Both short CoreMark seeds close native 0,
original CRCs and exact 4,767,218 / 4,753,406 parent ticks. Duration-valid
seeds, cold Win95 and cold Quake are now running on this exact model. Its
gameplay and physical FPGA performance remain unmeasured.

The [exact hardware export](../fpga/IC_PREFIX_EXPORT.md) contains 189 payloads
and 148 ordered defines; the entire actual native compiler command, source
closure, permitted deltas and real Tcl admission are independently checked.
Strict hardware CPU lint closes native 0 with all six structural classes fatal.
Whole-design synthesis closed at **11:07:22 UTC**, native 0 in 1,391.73 seconds,
in `ventium-ic-prefix-full-synth.7G1TINWD`. The independently audited result is
**221,918 LUTs**, versus its **220,699-LUT immediate parent**: **+1,219 LUTs
(+0.5523%)**, not an improvement. Registers 54,647 → 54,631; BRAM/DSP unchanged
at 277.5/47. This comparison changes only the sharing cone and its flag, with
identical mapping and 40/100 MHz constraints. It disproves extrapolating the
83.40% isolated saving to the whole design; it also does not support attributing
the earlier entire 29,835-LUT increase solely to this successor gather.
All 3,516 pins remain stable, actual 148 defines / 147 source reads checked;
8 GiB peak RAM plus 229,478,400 bytes swap, no OOM/resource stop. No route began.

Read-only native project-clock and matched primitive-netlist audit closed
in `ventium-ic-prefix-clock-audit.9Mt59oqx`, controller
`b188faacceef4b7c80d854c21280f163`: native 0 in 157.19 seconds, 3,521 stable
input pins, 4,302,340,096-byte peak RAM, zero swap/OOM. Independent `audit.json`
checks retained supervisor, native report markers, both primitive sets and
unchanged DCPs. Loaded original project clocks are **40 MHz core / 100 MHz PL**;
zero black boxes and zero MDRV-1/LUTLP-1 violations. The worst **unplaced** core
estimate is **18.09 MHz**, slack -30.284 ns, 54.987 ns data delay and 194 levels.
Its 43.231 ns routing component is an estimate; this is not physical frequency
or directly comparable to the old placed checkpoint. All 30 worst paths again
start at EIP. No optimization, placement, routing, changed clock or bitstream.

The generic gate remains an independent red obligation. Bare synthesized DCPs
have **no clocks loaded** in either profile: project XDCs must be loaded via
`open_run synth_1` for clock admission, as required by the existing implementation
launcher. The read-only bare-DCP comparison made no timing/frequency claim and
did not create or modify a clock to hide the generated-PS-XDC warning.

### Second-consumer correction

The first integration missed a **second sixteen-byte gather in an included
task**, `core_int_retire.svh:retire_reference_integer`. It changed only the
live decoder mux in `core.sv`. The unchanged retirement copy still uses
`ibuf[i] <= ic_byte(p54_prefix_ex_flin + i)` and can keep the original network
alive. In the matched native netlists, `ibuf`-named raw LUTs remain
26,398 → 26,049. Reconstructed names alone are not proof of exact RTL area,
but the source consumer omission is concrete and must be corrected before
concluding that the two-probe implementation failed to compact the gather.

`prepare_prefix_capture.py` changes only that nonblocking assignment's RHS to
the already four-state-tested `ic_prefix_bytes[i]`, under the same default-off
flag. All owner guards, loop bounds, q_* capture, effects, state transitions
and clocks are unchanged. An explicit audit now requires **both** exact
consumer substitutions; the old incomplete integration is a negative test.
The source preparation suite has **19 passing tests**. No additional data port,
register, latency, issue credit or global fallback is introduced.

Private directed model **`7791051b`**, root
`ventium-ic-prefix-capture-core.oPfI27fO`, builds native 0 in 18.72 seconds,
strict six-class lint, stable inputs and private harness/header ownership.
Default-off whole-core preprocessing preserves SHA
`c5c1b22bbda9011aeea9ada6734086f648b096e406a944f93472b6c26d01390c`
(whitespace only ignored, no discarded RTL/comment tokens).
Its closed 384-fixture matrix passes **1,536 full QEMU comparisons + 1,536
cycle runs**, both AXI latencies, actual V retirement and overlap witnesses;
all **768 entire matched cycle-record lists are identical**. Native expected
exits, children reaped, unchanged pins, 53.18 seconds; controller
`0410bc55a67e414ea12c9db218e0504f`. Generic verification closes with the same
101 terminal-record discrepancies and 12 cycle-band failures; all 20 complete
cycle-kernel record lists match the immediate parent. The full-PC build closes
native 0 as `751139e1`; both short CoreMark seeds pass CRCs with identical
4,767,218 / 4,753,406 ticks (duration-invalid). Sole-family whole synthesis
started 11:26:43 UTC with 8 GiB RAM, 6 GiB swap and a 30-minute limit.
Whole synthesis now closes native 0 in 1,294.82 seconds, independently audited:
**221,918 → 197,375 LUTs**, a **24,543-LUT / 11.06% whole-design saving**.
BRAM/DSPs stay 277.5 / 47, registers 54,631 → 54,663. The one-file delta,
148 actual defines, mapper, DCP integrity and all 3,722 pins are checked;
no OOM, no route or bitstream. This confirms the missed consumer materially
retained the old gather, not merely a change in reconstructed hierarchy names.

Read-only native project-clock audit additionally closes in 183.44 seconds,
3,726 stable pins, no black boxes or MDRV-1/LUTLP-1 errors. Original 40/100 MHz
constraints are unchanged. **Unplaced core estimate: 18.87 MHz**, up from
18.09 MHz; this is not routed Fmax or hardware sign-off. Worst paths now begin
at `q_pc` and reach SRT result enables through 185 levels, versus 194 before.
Raw `ibuf`-named LUTs fall 26,049 → 5,559, consistent with the removed gather;
name-based attribution alone is not a module-area measurement.
Evidence and the newly started independent standard suite:
[exact export](../fpga/IC_PREFIX_CAPTURE_EXPORT.md).

At 12:07 UTC, current verified gameplay is performance parent `bfb867f7`'s
**0.50137912** U+V event IPC, clocks **1,400,065,237–1,500,065,237**; all three
consecutive windows from 1,200,065,237 average **0.50624649**.
`751139e1` is still gameplay-unmeasured.

### Placement-only check, started 12:04:44 UTC

The 185-level path is not merely a slow arithmetic recurrence. The native
report traverses prefix decode, paired-return invalidation/issue, lookahead
address/translation, cache/store admission and acknowledgement, then FPU
operand selection and SRT launch. Those are netlist observations, not proof
that the complete path is sensitizable or permission to add false paths.

`fpga/place_completed_40mhz.tcl` opens the completed native project with its
actual XDCs. It verifies part/top, non-stale completed synthesis, fresh
implementation history, exact DCP hash, 40/100 MHz clocks and no black boxes.
It runs only `opt_design -directive RuntimeOptimized` and the frozen project's
`AltSpreadLogic_high` placement policy, saving separate optimized/placed DCPs.
No new synthesis, directive sweep, route, phys-opt, bitstream or board write.
**40 real-tclsh stub tests pass** for admission, native failures and missing
artifacts; these are flow-control tests, not physical acceptance.

Root `ventium-ic-prefix-capture-place.kOshlZlT`, controller
`0a85d2fb04ab4c66a17ff54413759b3b`, sole Vivado scope
`25a061ffc2ce4d90ab8abac2a4cf63a1`. Bound: 60 minutes, 8 GiB RAM / 6 GiB swap,
monitored host/disk reserves. Input DCP SHA
`cd26e7d6ea4c85349d59eb88e3427ad480ff605f803cf30f6db27c64edb3fc48`.
Optimization has completed natively; placement/result audit is still pending.

### Recoverable scratch cleanup

137 inactive September `.snap` files from the old external `ventium_run` tree
were archived, independently SHA/size-verified through decompression, rechecked
unchanged and individually unlinked after repeated native-user/FD checks.
No current source, media, binary, trace or acceptance input was removed.
Net recovered: **16.889 GiB**. Recovery archive and exact-name manifest:
`ventium-closed-snapshot-archive.genxQpF8/september-snapshots.tar.zst`
(SHA `04b5205fab66d72fc6cd6d9279446bff8952b26d03ff4e01b746bcc567ad07e2`),
with `admitted.json`, `verified.json`, `closed.json` alongside. Legacy tools
requiring a loose snapshot must extract that specific member. Current
acceptance runs remain cold boots.

On October 10, three inactive October 4 board diagnostic `run.vhd` copies were
archived and individually removed, recovering **201,277,440 bytes** (192 MiB).
Board free root space rose from 76,668,928 to 277,950,464 bytes. Source paths:
`/tmp/ao486/quake-branch-unpaired.xEnkTc/run.vhd`,
`/tmp/ao486/quake-cold-run.M3iXDE/run.vhd`, and
`/tmp/ao486/quake-paired-boundary.DEDpHO/run.vhd`. Logs, firmware, binaries and
the still-required `/tmp/ao486/quake-cold-oct02.vhd` base remain. No PL control
or DDR write occurred. Root-visible open-FD/mapping/owner checks, full source
SHA/identity/age checks and repeated archive decompression verification precede
the exact unlinks. The 12-member archive also preserves each run's diagnostics:
`ventium-board-archive-oct10.YBhg3Sl6/closed-oct04-runs.tar.gz`, SHA
`77bb363a07a4785debc05dd607dbd3de9bc7b1af3d50fcd1af5da7936eb5dab6`.
`verified.json`, `prune-dry-run.json` and `pruned.json` retain recovery metadata.

### Registered cache-invalidation control proposal

The actual unplaced critical report traverses the generic decoder's
`d_unknown` into `u_pair_return/flush_all0`, then paired lookahead/address and
FPU-command logic. The frontend source selects successor-cache bytes in
`S_EXEC`, live front bytes in `S_PIPE`, and registered `ibuf` in `S_DECODE`.
Yet `cache_inv_go` can assert **only in `S_DECODE`**. That is a structural
opportunity to eliminate an unnecessary cross-state combinational dependency;
it is not a false-path constraint or proof of achieved frequency.

`verif/uopcache/proposals/cacheinv_local/` adds an **unconnected** small
combinational recognizer using only registered `ibuf`, `cosim_en` and `soc_en`.
It recognizes the same 0F 08/09 forms and repeated non-LOCK prefixes, retaining
the old byte16 behavior; the existing fetch engine still owns overlength
exceptions. A future caller must retain the original `S_DECODE` gate. No
cache, pipeline register, stall, permission rule or live candidate was changed.

The test shell connects the **actual full `decode_stages`**, all its real
ports and original core enum types. It compares the qualified predicate across
all two-byte patterns, every prefix/header offset and second opcode, LOCK at
each position, every 7-bit state code, independently changing live gather
bytes and 100,000 deterministic randomized cases. Three negative controls
remove LOCK rejection, corrupt WBINVD recognition or remove the state gate.
Ten host tests pass; the separate source-contract audit verifies that the
actual `751139e1` source has exactly the abstracted mux and always-valid
16-byte `S_DECODE` window. This is a two-state proposal, not an exhaustive
formal or four-state proof.

`prepare_integration.py` also prepares a default-off `VEN_CACHEINV_LOCAL`
fragment by mechanically extracting that same leaf's body and renaming only
local identifiers. It changes the single original caller under the flag and
retains its `S_DECODE` qualifier. Tests reverse the rename to recover the exact
leaf body and remove the disabled conditional to recover the exact original
source. This recipe is **not applied to production or any running candidate**;
native miter success and a separate full-core qualification must come first.

Native RTL testing **passed**, under
`ventium-cacheinv-local-oct10.service`, invocation
`4b2af08633cb4ceb99262b7c0f924913`, root
`ventium-cacheinv-local.2vGg1j9C/run`. After acquiring the shared heavy-build
lock, all four builds close native 0; the candidate passes **653,984 cases /
22,248 positive recognitions**, and each required negative fails at its actual
`CACHEINV-MISMATCH`. Total 29.61 seconds, 1,152,376,832-byte peak RAM, no OOM,
stable pins. Its owner was not retained after success; closed/supervised receipts
are available, not a claimed live retained supervisor. This remains a two-state
actual-decoder test, not full-core or four-state acceptance.

The recipe is now applied only to a fresh private full-core derivative,
`ventium-cacheinv-core.1Jju4rvk`, model `5f4e0ca0`. Exactly `core.sv` plus the
generated `core_cacheinv_local.svh` change. Native build 0 in 15.07 seconds,
32 bounded compiler jobs, all six structural classes fatal, verified local
private harness/header ownership and stable pins. A new cold paged full-core
matrix is running against QEMU and the unchanged parent: INVD/WBINVD, mixed
and maximal legal prefixes, all line offsets, flat/relocated clients and AXI
latencies 0/7, checking complete architectural and cycle record lists plus a
real U/V pair. No production or running full-PC candidate was changed.

### Closed placement and control-path diagnosis, 12:46 UTC

`ventium-ic-prefix-capture-place.kOshlZlT`: native Vivado exits 0 after
**2,490.08 seconds**, with a fully placed DCP, 6,304,292,864-byte peak cgroup
RAM, zero swap/OOM, original 40/100 MHz clocks and zero checked structural DRCs.
Placement uses 196,363 LUTs, 54,683 FFs and **35,113 CLBs (82.31%)**;
BRAM/DSP remain 277.5/47. The mux-heavy north/south windows reach congestion
**level 6**, despite lower LUT utilization. No routing or bitstream generation.

The strict controller remains **FAILED**: Vivado rewrote its project XPR.
`project-delta.json` reconstructs the exact old SHA from current bytes and
proves the only changes are removing two strategy description strings and
adding an empty simulation-source GUI filter. All **3,725 other pins** remain
unchanged, including RTL, constraints, scripts and synthesis DCP. No project
or failure receipt was overwritten. The separate
`audit-metadata-requalified.json` admits **native placement only** after these
checks; its first parser attempt expected `Placed` instead of the actual
`Fully Placed` header and is retained separately.

Worst reported core setup slack is -29.911 ns against 25 ns: a **path-local
placed estimate of 18.211 MHz**, not routed Fmax or a physical-clock claim.
Worst reported hold is -0.156 ns. The first path is `q_len` to paired-return
data: 157 logic levels, 54.612 ns total (12.323 logic + 42.289 estimated routing).
**All 30 reported worst paths traverse `d_unknown` and `flush_all0`** before
paired lookahead/address logic. This directly supports testing the registered
invalidation projection above. It does not prove that it repairs all timing
paths; rerouting this unchanged congested design is not the next experiment.
