# Fetch/operand congestion: native evidence and narrow sharing experiment

Latest verified gameplay baseline is `958f7ec4`, **0.50588294** U+V event IPC
at 3,300,048,811–3,400,048,811 clocks. All 22 consecutive 100M windows from
1,200,048,811 average **0.4817253664**; no low window is excluded. Audit:
`ventium-sfetch16-latest-r10.8YGncnX4/audit.json`. Full timedemo remains unfinished.
Newer combined benchmark model `bfb867f7` and this area experiment are
gameplay-unmeasured. REP events are not exact P54 macroinstructions.

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
arbitrary-target lookup, LRU policy or permission rule is changed. The proposed
buffered-lookup substitutions are **not yet integrated**. Disabled mode keeps
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
