# Complete shared prefix gather: exact source export

**UNQUALIFIED**, not a deployed image. This corrects the incomplete integration
in [IC_PREFIX_EXPORT.md](IC_PREFIX_EXPORT.md): the retiring instruction's
sixteen-byte `ibuf` copy now uses the same shared bytes as the live decoder.
All ownership guards, nonblocking writes, q_* effects, state transitions and
latencies remain unchanged. UV/system/relocated fast pipeline and fast
loads/stores stay enabled; no slow-mode workaround or guest-specific change.

Verified gameplay baseline remains **0.50530999** U+V event IPC, parent
`958f7ec4`, clocks 3,900,048,811–4,000,048,811; all 28 consecutive windows
average **0.4862721782**. New model **`751139e1` is gameplay-unmeasured**.
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

Own short CoreMark diagnostics are running. Whole-design synthesis is prepared,
not launched: `ventium-ic-prefix-capture-full-synth.tEFDx2fS`. It must measure
whether removing the missed consumer actually lowers whole-design resources;
the earlier isolated 83.40% saving cannot establish that result. No automatic
placement, routing, clock change or deployment.

The unmodified generic gate remains **FAIL**, native 2: 7/108 functional passes,
101 terminal-record discrepancies and 12/19 graded cycle-band failures.
All 20 complete cycle-kernel **record lists** match the immediate parent;
whole trace files differ in provenance headers. No records/masks/bands changed.
Known x87 C1 repairs are still not in this source. Own duration-valid CoreMark,
Win95 desktop, all 969 original DOS demo1 frames, routed frequency and silicon
acceptance remain required; this export grants none of them.
