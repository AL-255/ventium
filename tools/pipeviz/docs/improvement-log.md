<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# pipeviz — self-improving visual loop log

Each iteration: render screenshots → adversarial review agents critique the
visuals → synthesize prioritized fixes → implement → verify → commit. This log
records what each iteration changed and the outstanding ideas, so the loop does
not repeat itself.

## Current UI (keep this in sync each iteration — critics read it)
- **Pipeline panel** = (a) a small LIVE *stage board* snapshot on top (3 lanes
  U/V/FP × P5 stages, current clock only; the FP group collapses to a thin "FP
  idle" rail when x87 is idle so the integer stages get the width); (b) an
  **IPC/stall sparkline strip** (windowed IPC track + per-cycle event pixels:
  mispredict/stall/I-fill/walk); (c) the main **gem5/Konata pipeline view**
  (one row per retired instruction, columns = cycles, lifecycle drawn as
  F/D/X/M/W + `=` stall / `!` flush cells cascading diagonally; integer X green,
  x87 X purple; frozen instruction-label gutter showing n / U·V pipe / PC /
  mnemonic + an amber **`Nc` stall badge** = the instruction's cycle span; synced
  cycle axis; click a trace row → highlights its instruction row).
- **Memory tables panel** (tabbed): I$/D$ each with a **2D set×way occupancy
  heatmap** (way0/way1 rows, set-axis ticks, legend) above a line table (no LRU
  column; MRU shown as `*` on the way; 32 line bytes wrapped to two rows, not
  truncated); split TLB; prefetch buffer (ibuf + decode).
- **Trace panel**: search/filter box; columns n | cyc | Δ | pipe | PC | bytes |
  instruction; x86 byte-field colouring (prefix gray / opcode blue / ModRM green
  / SIB purple / disp+rel yellow / imm red); U=blue V=amber pipe; zebra; Δ amber
  on a stall gap; capstone disasm (16/32-bit per live CS.D). Click a row →
  highlights that instruction's row in the Konata view.
- **Register panel**: GPR/flags/seg/CR/x87, changed-since-last-step values amber.
- **Status bar** (grouped, coloured): cyc · state/mode · ret/IPC/pair%/mispred ·
  I$/D$ occupancy/fills/walks · eip.
- **Toolbar** (grouped file | config | transport, accented Run).
- Backends: `ventium_top` (user + system) and `ventium_soc` (test386 etc.).

## Iterations
<!-- newest first; appended by the loop -->

### Iteration 4 — sparkline + Konata polish (anti-staleness review confirmed working)
First review with the new watermarked harness: all critics reported the correct
build sha and described the REAL UI; the synthesis source-verified and **dropped
the two "branch byte is red" findings as critic perception errors** (the trace
already colours rel8/disp yellow — confirmed by screenshot). Shipped:
- **New feature — IPC/stall sparkline strip** between the stage board and the
  Konata view: windowed-IPC track (0..2) + per-cycle event pixels
  (mispredict/stall/I-fill/walk), with a live IPC readout.
- **Stage board:** fixed the clipped top title/headers (top padding); **collapse
  the idle FP group** to a thin rail so the integer U/V stages get the width.
- **Konata view:** bigger cells (more legible stage letters), wider instruction
  gutter, **amber `Nc` stall badge** per instruction (its cycle span — instantly
  shows D-miss/fill stalls), legend enlarged so the FP entry no longer clips.
- **Cache heatmap:** stop the last set-tick (128) + way labels clipping the edge.
- **Trace:** narrowed the bytes column to cut the dead gap before the disasm.

### Iteration 3 — anti-staleness review harness + trace filter + byte-colour fix
The previous review's critics described a pre-iteration-1 UI (old waterfall /
1-row heatmap) because **the workflow's own critic prompts still described the
old layout** and a stale "Baseline" here primed them. Fixed the *review process*
so critics always anchor on the latest:
- **gen_review_shots** now stamps every screenshot with a build watermark
  (`pipeviz build <sha>[+dirty] <time>`); the workflow **regenerates the shots
  itself** (new *Render* phase) so images can't drift from HEAD; critics must
  report the watermark + a "what I actually see" inventory, and the synthesis
  **discards findings whose watermark ≠ the current build**. Removed all stale
  UI descriptions from the prompts; rewrote this doc's UI section to match HEAD.
- **Trace byte colour fix (real bug):** relative-branch rel8/rel16/rel32 targets
  (jmp/jcc/call/loop) were coloured red (immediate); they're displacements →
  now yellow. Real immediates (mov/int/push imm) stay red.
- **New feature — trace search/filter box:** substring + `pc:`, `cyc>=`/`<=`/`=`,
  `pipe:U|V`, and `stall`, with a live match count.

### Iteration 2 — gem5/Konata per-instruction pipeline view
Replaced the per-stage "waterfall" (which only showed the live EX latch repeated
downward) with a true **gem5/Konata superscalar timing diagram**: **Y = instructions**
(one row each), **X = cycles**. Each instruction's lifecycle is reconstructed
from the per-cycle FSM trace and drawn as a run of stage cells (F/D/X/M/W, `=`
stall, `!` flush) so consecutive instructions **cascade diagonally**. Integer
execute = green, x87 FP = purple; a D-cache-miss stall stretches as a long amber
`= = =` run before the `X`. Frozen left gutter (n / U·V pipe / PC / mnemonic) +
synced top cycle axis; click-to-link and hover preserved. (Addresses the review's
#1 high finding "per-instruction lifecycle (Konata-style) waterfall".)

### Iteration 1 — legibility, density & cross-panel linking
Driven by a 5-critic adversarial review (45 findings). Shipped:
- **Pipeline:** fixed the stage-board header/label collision; de-emphasised empty
  stage cells so the active stage pops; dim the FP group when idle. Waterfall:
  added **stall (amber) + mispredict (red)** legend entries and recoloured those
  cells; labelled **every** cycle row; added U|V|FP group tints + 2px separators;
  clearer `[paired]/[single]` status.
- **Trace:** added a **Δcyc** column that turns amber on a stall gap (surfaces the
  D-miss penalty); coloured the pipe column (U=blue, V=amber); zebra striping;
  reclaimed the dead horizontal space; freed green from mnemonics (ALU→neutral)
  and brightened the prefix-gray byte colour.
- **Tables:** rebuilt the cache heatmap as a real **2D set×way grid** with axis
  ticks + a legend; dropped the uninformative LRU column (MRU now a `*` on the
  way); wrapped the 32 line bytes to two rows (no more ellipsis truncation).
- **Registers:** highlight values that **changed** since the last step (amber).
- **Chrome:** grouped the toolbar (file | config | transport) with an accented
  Run button; grouped + coloured the status bar; visible panel separators.
- **Feature:** click a trace row → it highlights/scrolls that cycle in the
  waterfall (cross-panel selection link).

Outstanding high-value ideas (next iterations): per-instruction Konata-style
lifecycle bars (one row per insn spanning its stage cycles); IPC/stall sparkline
strip; trace search/filter box; branch/BTB view; arbitrary-memory hex view;
two-way heatmap↔table hover link.
