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
  cycle axis; **distinct per-stage colours + glyphs** — `F` fetch blue, `L`
  I-cache-fill amber, `D` decode teal, `M` mem orange, `X` exec green (FP
  purple), `W` wb magenta, `=` stall grey, `!` flush red; legend on its own line
  with each swatch tightly paired to its label. The stage board is a COMPACT
  snapshot (the Konata view gets the height — ~29 rows visible). Two-way
  selection: click a Konata instruction (cell or label) → selects + centres its
  trace row, and vice-versa.
- **Memory tables panel** (tabbed): I$/D$ each with a **2D set×way occupancy
  heatmap** (way0/way1 rows, set-axis ticks, legend) above a line table (no LRU
  column; MRU shown as `*` on the way; 32 line bytes wrapped to two rows, not
  truncated); split TLB; prefetch buffer (ibuf + decode); **Hotspots** = a
  per-PC cycle-cost profile (PC | hits | cycles | cyc% | amber cost bar |
  instruction, sorted by total cycles — stalls inflate the cost so the stalled
  load/branch PCs bubble to the top, perf/VTune-style).
- **Trace panel**: search/filter box; columns n | cyc | Δ | pipe | PC | bytes |
  instruction; x86 byte-field colouring (prefix gray / opcode blue / ModRM green
  / SIB purple / memory-offset yellow / immediate red / **branch-rel orange**),
  clipped with `…` so long encodings never collide with the disasm; U=blue
  V=amber pipe; zebra; Δ amber on a stall gap; capstone disasm (16/32-bit per
  live CS.D). Click a row → highlights its Konata instruction row (two-way).
- **Register panel**: GPRs/segs/CR/x87; **EFLAGS as a full named-bit grid** (all
  9 flags, set = amber, changed-this-step underlined); GPR/EIP values that
  changed since the last step are amber.
- **Status bar** (grouped, coloured): cyc · state/mode · ret/IPC/pair%/mispred ·
  I$/D$ occupancy/fills/walks · eip.
- **Toolbar** (grouped file | config | transport, accented Run).
- Backends: `ventium_top` (user + system) and `ventium_soc` (test386 etc.).

## Iterations
<!-- newest first; appended by the loop -->

### Iteration 6 — Hotspots profile + reclaim Konata height + glyph/legend fixes
- **New feature — per-PC Hotspots tab** (perf/VTune-style): aggregates each PC's
  hit count + total cycles occupied (stalls inflate it), sorted by cost with an
  amber cost bar. Correctly surfaces the stalled `dec ecx` as 72% of cycles on
  `mb_dmiss`.
- **Reclaimed Konata height** (the recurring "only ~6 rows visible" / "stage
  board is dead space" finding): shrank the snapshot stage board (compact 22px
  lanes) and rebalanced the splitter → the Konata view now shows ~29 instruction
  rows.
- **Stage board stall cell** was exec-green; now grey (distinct from exec).
- **Konata glyph fix:** I-cache line-fill now uses `L` (amber), distinct from
  `F` slow-fetch (blue) — they no longer share the `F` glyph.
- **Legend pairing fix** (the recurring "legend colours don't match the bytes"
  perception): each swatch is now tightly coupled to ITS label with a clear gap
  between entries, in both the trace byte legend and the Konata stage legend, so
  the swatch→label mapping can't be misread as rotated. (Verified the byte
  colours themselves are correct: rel=orange, disp=yellow, opcode=blue, etc.)

### Iteration 5 — distinct stage palette, branch-byte colour, two-way selection
- **New feature — two-way Konata↔trace selection:** click a trace row →
  highlights its instruction row in the pipeline view (existing); click a Konata
  cell or gutter label → selects + centre-scrolls its trace row (new).
- **Konata distinct per-stage palette** (was the #1 finding): fetch blue, fill
  amber, decode teal, mem orange, exec green/FP-purple, writeback magenta, stall
  grey — fixes the old "decode==writeback==blue, fill==stall==amber" ambiguity.
- **Konata legend** moved to its own line so it no longer clips off the right;
  widened the gutter stall badge so `11c`/`17c` render fully.
- **Trace:** a dedicated **orange "branch" colour** for rel8/16/32 jump/call/loop
  targets (distinct from yellow memory offsets); the bytes column now **clips
  with `…`** so 9–15-byte encodings can't collide with the disassembly.
- **Registers:** EFLAGS rendered as a **full named-bit grid** (all 9 flags shown,
  set = amber, changed-this-step underlined) instead of only the set bits.
Note: the watermarked review again self-corrected — its source-verification
dropped repeat "branch byte is red" perception errors (already orange).

Outstanding for next iterations (synthesis-flagged): per-PC hotspot/stall-cost
profile, Branches/BTB panel, draggable cycle playhead over the Konata view,
two-row/ragged cache line-byte dump cleanup.

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
