# Fetch/operand congestion: native evidence and narrow sharing experiment

Latest verified gameplay baseline is `958f7ec4`, **0.49630560** U+V event IPC
at 3,600,048,811–3,700,048,811 clocks. All 25 consecutive 100M windows from
1,200,048,811 average **0.4848174992**; no low window is excluded. Audit:
`ventium-sfetch16-latest-r11.S0xEqGEw/audit.json`. Full timedemo remains unfinished.
Newer combined benchmark model `bfb867f7` and area model `89b68b62` are
gameplay-unmeasured. REP events are not exact P54 macroinstructions.

The expanded sharing stage below removes **66.0% of the measured local LUT
cone**, with identical directed and short CoreMark cycles. This is not a
whole-chip area or speedup claim. Full synthesis of its exact 40 MHz hardware
export is now a separately bounded diagnostic; generic verification and
full-suite/hardware acceptance remain open.

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

Full synthesis only is running in `ventium-ic-buffered-full-synth.6cLKnbGf`,
controller `5c441fa813414299b1d46271ef45c11d`. Same `logic_only` mapping as the
old whole design, unchanged clock constraints, one Vivado family, **8 GiB RAM /
6 GiB swap**, 30-minute native cap, 12 GiB starting disk reserve and monitored
2 GiB disk/host reserve. The measured local savings motivate checking the
mapped whole design before another route. Launch is not synthesis, timing,
bitstream or deployment acceptance.

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
