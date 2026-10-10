# Complete shared prefix gather: exact source export

**UNQUALIFIED**, not a deployed image. This corrects the incomplete integration
in [IC_PREFIX_EXPORT.md](IC_PREFIX_EXPORT.md): the retiring instruction's
sixteen-byte `ibuf` copy now uses the same shared bytes as the live decoder.
All ownership guards, nonblocking writes, q_* effects, state transitions and
latencies remain unchanged. UV/system/relocated fast pipeline and fast
loads/stores stay enabled; no slow-mode workaround or guest-specific change.

Verified gameplay baseline is **0.50705320** U+V event IPC, performance parent
`bfb867f7`, clocks 1,300,065,237–1,400,065,237. Both consecutive windows from
1,200,065,237 average **0.508680175**; neither is dropped.
New model **`751139e1` is gameplay-unmeasured**.
REP events are not exact P54 macroinstructions. The predecessor's qualified
2.101890118 / 2.107616105 CM/MHz scores are not inherited by this model.

## Identity and checks

Export `/home/yukidama/external/tmp/ventium-ic-prefix-capture-fpga40.8gXfDVA5`:
manifest `f32d424aa7ad29e5738ac15d759a52297d774b7818ca9e7262cb32a4c9ed0d14`.
Native full-PC model `751139e12510f2ae1cbfae0957f138c248a716c6f9c30606596d2fff81876638`,
root `ventium-ic-prefix-capture-soc.Vkt5yyAz`. Actual native build closes 0,
19.63 compiler seconds; controller's 350.46 seconds include waiting on the
shared heavy-build lock. Private C++/generated-header ownership is verified.
The 98 inherited platform structural warnings are unchanged, not waived away.

Exactly **one payload changes** from the 221,918-LUT immediate parent:
`rtl/core/core_int_retire.svh`, SHA
`76da2937ce317ae31da831d4376c82b0c33fe3b0ffd9d4fbfbf68d05458dfe7f`.
All 189 payloads, 148 ordered hardware defines, 117 filelist units and 48
include edges are checked. All 169 non-wrapper native processor/platform
payloads match the actual compilation; the unchanged hardware top's transport
projection is verified. Original constraints: **40 MHz core / 100 MHz PL**;
full P5 L1s, 256 KiB L2 and 16 posted DDR slots.

The freezer suite passes **91 tests**. Independent actual-compiler-command,
source/profile and **35 real-Tcl checks** pass. The initial independent audit
refused the inherited alias count; its failure receipt remains. Inspection
established 17 exact historical script aliases, with both new build drivers
canonical. No RTL alias, unreviewed source or profile is admitted.

Strict hardware CPU lint closes native 0 in 2.486 seconds, stable inputs and
all six structural classes fatal. Root `ventium-ic-prefix-capture-hw-lint.SS5l1Pa0`,
controller `ef6f9452325c4b7d8294642453802a88`. This is not whole-platform lint.

The directed core `7791051b` passes 384 fixtures, 1,536 complete QEMU comparisons
and 768 identical matched full cycle-record lists; actual U/V and overlap
witnesses are required. Active whole-core preprocessing confirms **zero generic
prefix-byte lookups remain**, with both shared consumers present. Default-off
preprocessing reproduces the predecessor exactly, whitespace ignored only.
[Detailed evidence](../docs/FPGA_FETCH_CONGESTION_2026-10-10.md#second-consumer-correction).

## Remaining acceptance

Own short CoreMark diagnostics both close native 0 with all original CRCs and
unchanged parent ticks: **4,767,218 / 4,753,406**. Independent `coremark/audit.json`
checks 3,362 stable pins, actual V retirement, EOF/reaping, retained supervisor
`dbefff9c355344978315bfc1d3bedf97` and zero OOM. These are duration-invalid
diagnostics, not qualified scores.

Whole-design synthesis **closed native 0 at 11:48:18 UTC**, 1,294.82 seconds:
`ventium-ic-prefix-capture-full-synth.tEFDx2fS`, controller
`ae6a6e8fcb3846c19ad99b66c6685e4c`. One guarded Vivado family, 8 GiB RAM,
6 GiB swap and 30-minute cap; no other synthesis/implementation family.
Independent `audit_closed.py` rechecks 3,722 input pins, actual 148 defines and
147 native read-Verilog files, same mapper/device/clocks, exact one-file delta,
native completion markers, DCP integrity and retained supervisors. No OOM;
peak RAM 8 GiB, swap 234,041,344 bytes. One inherited critical warning remains.

| Whole-design resource | Immediate parent | Complete sharing |
| --- | ---: | ---: |
| CLB LUTs | 221,918 | **197,375** |
| Registers | 54,631 | 54,663 |
| BRAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |

This **24,543-LUT / 11.06% reduction** is a matched whole-design result,
not extrapolation from the isolated 83.40% experiment. Register merging changes
by 32 cells despite unchanged architectural registers/latency. No placement,
route, clock change or bitstream was produced. Read-only original-project-clock
inspection closed in `ventium-ic-prefix-capture-clock-audit.ecnKY6B4`, controller
`4c351f4795724019a64433161b220e4d`: native 0, 183.44 seconds, 3,726 stable
pins, 3,880,636,416-byte peak RAM and zero swap/OOM. Original clocks are
40 MHz core / 100 MHz PL; zero black boxes and MDRV-1/LUTLP-1 errors.
The worst **unplaced core estimate is 18.87 MHz** (previous 18.09 MHz),
not routed Fmax or a 40 MHz sign-off. All 30 worst paths now start at `q_pc`,
ending in SRT result enables, with 185 logic levels (previous 194).
Raw `ibuf`-named LUT attribution falls 26,049 → 5,559; reconstructed names are
not isolated-module area. Both DCPs remain unchanged.

Its own cold standard suite started **11:50:53 UTC**, under the unchanged
duration/completion rules. Actual model/PID/starttime/argv/affinity/cgroup and
3,398 source/input pins are checked in `standard-suite-admission.json`:

| Service suffix after `ventium-ic-prefix-capture-` | CPU | Invocation |
| --- | ---: | --- |
| `cm900-perf-oct10` | 3 | `68ef1a196b0f48a5b9a3f9f886b2bae1` |
| `cm900-valid-oct10` | 5 | `b5d64faf55774c5cb2e2b51daf755e04` |
| `quake-oct10` | 13 | `9be97467da414f8189493baf726793ed` |
| `win95-oct10` | 15 | `5d365235bd6741b48c554903d844490f` |

Every native has one actual CPU and 2 GiB/no swap. CoreMark retains its
60-minute per-seed bound. Quake/Win95 use the original cold media, no guest
patches, snapshots or scripted input. Admission is not acceptance.

The unmodified generic gate remains **FAIL**, native 2: 7/108 functional passes,
101 terminal-record discrepancies and 12/19 graded cycle-band failures.
All 20 complete cycle-kernel **record lists** match the immediate parent;
whole trace files differ in provenance headers. No records/masks/bands changed.
Known x87 C1 repairs are still not in this source. Own duration-valid CoreMark,
Win95 desktop, all 969 original DOS demo1 frames, routed frequency and silicon
acceptance remain required; this export grants none of them.
