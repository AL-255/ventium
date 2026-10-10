# Saved-window FP upper-word hardware backport — October 10

**UNQUALIFIED; not deployed.** Full-PC model
`f59d75adada3162d710f0ccf54fe0ba35a3bcb34bfcd19cd0f0b12f4666ffc83`
contains the [leaf/core-tested high-word selector](../verif/l1/HIGH_WINDOW_PAYLOAD.md).
UV, system/relocated fast paths, full P5 L1s, 256 KiB platform L2, posted-16
transport and the **40 MHz core / 100 MHz PL** constraints are unchanged.

The immediate parent synthesized at 195,679 LUTs with a **21.130 MHz unplaced
estimate**. Its 163-level EIP-to-SRT-enable path crosses the younger tag/lookup
decision through `shadow_reuse` and current FP upper-word data. The new mux
uses saved physical shadow ownership; the valid/ACK/permission/coherence
contract is unchanged. It retains shadow priority for partial primary-bank
captures. No new stage, stall, queue or arithmetic unit is introduced.
This is a timing hypothesis, **not a measured frequency or area improvement**.

## Exact source closure

Scratch prefix: `/home/yukidama/external/tmp/`.

- Native root: `ventium-high-window-soc.IIiVZf7B`; build closes native 0 at
  **17:39:14 UTC**, 19.20 seconds, unchanged source pins and matching private
  host/generated-header ownership. The 98 inherited platform structural
  warnings remain; this is not clean whole-platform lint.
- Hardware root: `ventium-high-window-fpga40.U9Ot5NLe`; manifest SHA256
  `705bde4e59bc5dd5b5342ddb240a03c9cc24734abf33742736d05cf819249e81`.
  Parent manifest is `3ab7194b6004cea114ad709014d7d171587bfe8bc303fbc58469d3d8801fa5de`.
- The only parent RTL delta is `rtl/mem/ven_l1d.sv`, SHA256
  `d78345f1fc81235d5c4881d2ad645eda89ee5da808f2a4131d5bbdda3e178436`.
  `VEN_L1D_HIGH_PAYLOAD_SELECT` is the only additional feature define.
  The numeric SRT-floor fix is retained; separate C1/FST repairs are not included.
- [The freezer](freeze_high_window_payload_rk_candidate.py) checks 190 payloads,
  153 native / 155 hardware defines, 117 filelist units and 49 include edges.
  All 170 non-wrapper compiled source payloads match the actual native model.
  The original hardware wrapper and its simulation projection are unchanged.
- Six host freezer tests and **57 actual Tcl profile checks** pass, including
  rejected missing, replaced, reordered, duplicate and forbidden feature cases.
  No simulation, lint, timing or suite pass is inferred from source closure.
- Strict **CPU-hierarchy** hardware lint closes native 0 in 2.48 seconds with
  all six structural warning classes fatal: `ventium-high-window-hw-lint.WkicKq3Y`,
  invocation `30875b3f69a545f3aef4ea216f78559a`. Whole-platform lint remains open.

The source core passes 2,656 full QEMU architectural comparisons and 1,328
identical complete cycle-record pairs, including unaligned/cross-page FP loads.
Its canonical gate remains FAIL; all 20 canonical cycle streams equal its
parent. No mask, golden state or cycle band was weakened.

## Short diagnostics closed; bounded synthesis running

`ventium-high-window-full-synth.5fvbD0Fa`, service
`ventium-high-window-full-synth-oct10.service`, invocation
`4442785ccf4e42ec9cfd7ba8f5512c8f`, starts synthesis at **17:42:34 UTC** only
after both new short CoreMark diagnostics and their independent audit pass.
Actual Vivado scope invocation is `7bf77673bcec48b5baaf36b39f0598d3`.

Both seeds retain exactly **4,767,218 / 4,753,406 ticks** and every original
CRC, with native 0, real wait/EOF/reaping, actual V retirement, 5,615 rechecked
pins and no OOM. Evidence: the native root's `coremark/audit.json`, retained
owner `bf91f7045825480d95afee01182c2875`. These ten-iteration tests are
**duration-invalid**, not 2.1 CM/MHz score qualification; zero cycle regression
is measured, not an additional throughput gain.

Only one Vivado family may start: the unchanged shared heavy-build lock,
8 GiB resident / 6 GiB swap / 48-task envelope, one synthesis job, 30-minute
native cap, 12 GiB initial disk reserve and live host/disk/OOM guards apply.
The same `logic_only` mapper is used for comparison. This controller cannot
place, route or program the board. No new synthesis result is claimed yet.

Preflight recovers **2,192,451,730 bytes** by losslessly archiving 60 closed
compiler intermediates and 12,672 traces from four closed
FP/integer trace matrices, checking each archive against the originals before
unlinking loose generated files. Sources, native executables, logs, failed
attempts, active runs and guest media remain. Per-root archive receipts record
member hashes and restore commands. The disk-admission floor is not lowered.

## Performance boundary

Latest verified gameplay is **0.50510994 U+V retirement-event IPC** on older
`bfb867f7`, clocks **3,800,065,237–3,900,065,237**. All 27 consecutive windows
from 1,200,065,237 average **0.4943896**, including every dip. That same older
model's qualified CoreMark scores are **2.101890118 / 2.107616105 CM/MHz**.
Neither measurement transfers to this gameplay-unmeasured export. Full
timedemo, green differential gates, standard suite and physical FPGA remain
open; REP retirement events are not P54 macroinstructions.
