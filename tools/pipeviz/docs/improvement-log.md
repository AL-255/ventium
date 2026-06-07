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
  idle" rail when x87 is idle so the integer stages get the width; faint
  **per-stage column gridlines** anchor each lit cell to its PF/D1/D2/EX/WB
  column, and the stage captions are legend-white); (b) an
  **IPC/stall sparkline strip** (windowed IPC track with a 0/1/2 y-axis + per-cycle
  event pixels with an inline colour key: mispredict/stall/I-fill/walk) that
  doubles as a **clickable navigation overview** — click anywhere to seek the
  Konata playhead to that cycle; (c) the main **gem5/Konata pipeline view**
  (one row per retired instruction, columns = cycles, lifecycle drawn as
  F/D/X/M/W + `=` stall / `!` flush cells cascading diagonally; integer X green,
  x87 X purple; frozen instruction-label gutter showing n / U·V pipe / PC /
  mnemonic + an amber **`Nc` stall badge** = the instruction's cycle span; synced
  cycle axis; **distinct per-stage colours + glyphs** — `F` fetch blue, `L`
  I-cache-fill amber, `D` decode teal, `M` mem orange, `X` exec green (FP
  purple), `W` wb magenta, `=` stall grey, `!` flush red; legend on its own line
  with each swatch tightly paired to its label; walk = pink, wb = slate-blue
  (kept out of the FP/walk purple cluster). Fast-path ops **synthesise their
  P5 F→D→X pipeline depth** (the dual-issue path collapses fetch/decode into one
  clock, so the two preceding cycles are drawn as Fetch+Decode) → consecutive
  instructions cascade diagonally through F→D→X like a real superscalar diagram,
  not a lone X. **Contiguous stall runs collapse into one `=N` block** (N = stall
  cycles) instead of a wall of grey cells; **per-cycle vertical gridlines** every
  10 cycles; the instruction gutter is wide enough for full mnemonics and
  **split-colours each label** (dimmed mnemonic + the operand / branch-target in
  the full class accent, so the target pops). Scrolling **snaps to whole rows /
  cycle-columns** (one row of bottom slack keeps the newest instruction fully
  visible — no clipped half-row at the top edge). The stage board is a COMPACT
  snapshot (the Konata view gets the height — ~29 rows). Two-way selection: click
  a Konata instruction (cell or label) ↔ trace row, which also **pins the register
  panel** to that instruction's post-commit state and drops a **cyan cycle
  playhead** down the Konata view (labelled with a `cyc N` chip at the top);
  stepping unpins. **Shift-click** a second row to
  drop an amber **measurement anchor** — the band between it and the playhead is
  shaded and labelled `Δ<n>cyc` (latency between two instructions; shift-click the
  same row again to clear it). Selecting an instruction also **PC-group highlights**
  every other execution of the same PC (loop iterations) with a tint + a blue
  left-edge marker, so a stalled iteration stands out among its repeats. Auto-follow
  ("stick to the newest row/cycle") is explicit state toggled only by a user scroll,
  so the viewport tracks live
  retirement without stranding on stale rows; the **horizontal** follow anchors to
  the topmost visible row's first cell (not the raw FSM max-cycle), so a long
  non-retiring tail (S_DECODE/S_PF/S_WALK) can't scroll the visible rows' cells
  off-screen into blank space.
- **Memory tables panel** (tabbed): I$/D$ each with a **2D set×way occupancy
  heatmap** (way0/way1 rows, set-axis ticks, legend) above a line table (no LRU
  column; MRU shown as `*` on the way; 32 line bytes wrapped to two rows, not
  truncated); split TLB; prefetch buffer (ibuf + decode); **Hotspots** = a
  per-PC cycle-cost profile (PC | hits | cycles | cyc% | amber cost bar |
  instruction, sorted by total cycles — stalls inflate the cost so the stalled
  load/branch PCs bubble to the top, perf/VTune-style); **Branches** = a
  per-branch-PC BTB profile (PC | type | target | hits | taken | taken% | bias
  bar; taken inferred from whether the next retired PC hit the target); **Instr
  mix** = an instruction-class histogram (branch/fp/mem/alu/sys with %-bars) plus
  the U/V issue-port split as a realised-dual-issue proxy (`50% via the V-port`);
  **Cycles**
  = a perf/VTune-style **cycle-attribution breakdown** — every cycle classified by
  FSM state into retire / issue-stall / mispredict / I-fill / decode / load-store /
  page-walk / x87 / system / halt, drawn as %-bars sorted biggest-first with a live
  IPC readout, so the tallest bar is the bottleneck (answers "why is IPC low?");
  **Memory** = a hex/ASCII
  inspector (type an address or click →EIP/→ESP to follow, ◀/▶ to page; EIP bytes
  cyan, ESP bytes amber).
- **Trace panel**: search/filter box; columns n | cyc | Δ | pipe | PC | bytes |
  instruction | **effect** (Δ shows `+N` only on a stall gap — steady-state 0/1
  suppressed); the **effect column** shows what each retired instruction
  architecturally WROTE — the destination GPR(s) with their committed value plus
  any changed flags (`eax=60000011  ZF0`) plus any **x87 exception** newly raised
  by an FP op (`FP:ZE`); writes are attributed per-instruction via capstone
  register-access analysis, so a dual-issue U/V pair's writes land on the correct
  rows even though the commit snapshot is per-cycle. x86 byte-field
  colouring (prefix gray / opcode blue / ModRM green
  / SIB purple / memory-offset yellow / immediate red / **branch-rel vivid-orange**
  `#ff8c00`, pulled well clear of the offset-yellow), clipped with `…` only past
  ~11 bytes with the **full encoding on hover** (tooltip) so no bytes are lost; the
  **instruction column is split-coloured** (a NEUTRAL-grey mnemonic — the same grey
  for every op — + operand/target in the class accent, matching the Konata gutter;
  so only the operand/target is coloured and a branch's `jne` is grey like any
  other mnemonic while just its target stays orange);
  U=blue V=amber pipe; zebra; Δ
  amber on a stall gap; whole-row scroll snap; capstone disasm (16/32-bit per
  live CS.D). Click a row → highlights its Konata instruction row + pins the
  register panel to its post-commit state (two-way).
- **Register panel**: GPRs/segs/CR/x87; **EFLAGS as a full named-bit grid** (all
  9 flags, set = amber, changed-this-step underlined); GPR/EIP values that
  changed since the last step are amber. Can be **pinned AS-OF a retired
  instruction** (click a trace row / Konata cell): shows that instruction's
  post-commit GPRs/EFLAGS/seg-selectors/x87 with an amber `PINNED n=… cyc=…`
  banner (the pinned x87 header wraps so ctrl/stat/tag never clip); the next step
  unpins back to the live state.
- **Status bar** (grouped, coloured): cyc · state/mode · ret/IPC/pair%/mispred ·
  I$/D$ occupancy/fills/walks · eip.
- **Toolbar** (grouped file | config | transport, accented Run, + **event-jump**
  ◀/▶ that move the Konata playhead to the prev/next pipeline event —
  mispredict/stall/I-fill/page-walk — for fast "jump to the action" navigation).
- Backends: `ventium_top` (user + system) and `ventium_soc` (test386 etc.).

## Iterations
<!-- newest first; appended by the loop -->

### Iteration 24 — per-instruction cycle breakdown, wider bytes, brighter operand split
Verify confirmed 0 picks; ground-truthing (zoomed crops) drove four real fixes.
- **New feature — per-instruction cycle breakdown in the Konata tooltip.** Hovering
  an instruction now shows where its cycles went — `breakdown: 7×Stall  2×Mispredict
  flush  1×Fetch  1×Decode` for an 11-cyc `dec ecx` — so you can read *why* an
  instruction was slow (the stall count is the diagnostic), on top of the existing
  per-cell stage and the row info.
- **Fix (HIGH, recurring) — bytes column truncation.** Widened bytes 140→176px (the
  stretching instruction column still gets ~273px); more of each encoding shows
  before the `…`, with the tooltip covering the longest ones.
- **Fix (med) — operand-accent split too subtle for non-branch ops.** The shared
  mnemonic grey was only marginally dimmer than a neutral operand. Dimmed it
  `#939ba6`→`#828c99` (trace + Konata gutter) so the operand reads as the brighter,
  accented token even when its class colour is the neutral off-white.
- **Fix — Δ-measure label crowded the playhead `cyc N` badge.** Dropped the
  `Δ<n>cyc` label one row below the cyan badge strip so the two never abut.

### Iteration 23 — 'stuck' livelock banner, wider gutter, crisp stage gridlines
Verify confirmed 1 pick (the stuck banner). Ground-truthing the rest: the
stage-board EX|WB "no break" was mostly perception (the fast-path correctly lights
EX+WB and a gridline IS between them), but the gutter-mnemonic and gridline-crispness
findings were real.
- **New feature — 'stuck' livelock diagnostic.** When the sparkline's trailing run
  of zero-retire cycles exceeds 64 AND the core is wedged in a front-end / halt state
  (`S_DECODE` / `S_FETCH` / `S_HALT` / `S_F00F_HANG`), it overlays a red
  `⚠ stuck in S_DECODE — 86c, 0 retired` banner over the IPC band, so a genuine hang
  reads as "the core is wedged", not a dead-looking flat strip. Correctly stays OFF
  for a normal slow decode (test386's 7c loop never trips the 64c threshold) — it's
  a hang detector, not a slow-IPC indicator.
- **Fix (HIGH, recurring) — gutter mnemonic truncation.** `mov eax, dword ptr [esi]`
  was clipped to `… […`. Widened the Konata instruction gutter 300→340px (borrowed
  from the often-under-filled timeline) so full mnemonics show; the per-row tooltip
  still covers anything longer.
- **Fix — crisp stage-board column gridlines.** A fast-path uop lights EX+WB as two
  same-colour green cells; the boundary gridline (drawn behind the cells) read as
  faint. Re-drew the internal PF|D1|D2|EX|WB gridlines ON TOP of the lane cells in a
  brighter `#5a6573`, so the column a stage occupies is unmistakable.

### Iteration 22 — reclaim Konata height, stall contrast, narrower bytes, drill-down
Verify confirmed 0 picks; ground-truthing (MEASURING the panel) drove the layout
fixes that several HIGH findings kept circling.
- **Fix (HIGH ×2) — Konata was starved of height.** Measured: the StageBoard ate
  122px and the sparkline 58px, leaving the headline Konata view only an 188px
  viewport (11 rows). Tightened the (sparse) stage board to 100px (18px lanes) —
  the Konata viewport is now 210px / 13 rows, with no clipping.
- **Fix (HIGH, recurring) — stall bars near-invisible.** The collapsed `=N` stall
  bar's border was a near-black `#1b1f26` that vanished on the dark/amber-Δ-band
  row backgrounds. Gave it a light `#aab4c0` border so the stall span — the most
  diagnostically important event — stands out on any background.
- **Fix (HIGH, recurring) — wasted bytes↔instruction gap.** The bytes column was
  hard-sized to 200px for the worst case while almost every row is 1–3 bytes,
  leaving a huge whitespace band. Narrowed it to 140px (still ~6 bytes, tooltip for
  the rest); the freed width goes to the stretching instruction column (249→309px),
  cutting both the gap and the instruction truncations.
- **New feature — analysis→trace drill-down.** Clicking a PC row in the Hotspots or
  Branches tab now jumps the trace to that PC's first occurrence, so you can go from
  "this PC is 72% of cycles" straight to seeing it in the instruction stream.

### Iteration 21 — x87 hex split, FP-lane cleanup, keyboard shortcuts
Verify confirmed 1 pick. I also **pixel-sampled the trace** to finally close the
perennial "rel byte is yellow" finding: the f8 byte renders red-orange
(`166,52,34`, R/G=3.2, B=34 — vs the salmon immediate at B≈107), 271 red-orange
pixels in the bytes column. It is a CONCLUSIVE perception error; the colour stands.
- **Fix (CONFIRMED) — split the x87 80-bit hex + dim empty slots.** The 20-hex
  blob is now `4005 ae00000000000000` (sign/exp word ␣ 64-bit mantissa) so the
  floatx80 fields are readable, and an empty stack slot's all-zero hex is dimmed to
  `#4b535d` (live and pinned) so it reads as empty, not as data.
- **Fix (HIGH, recurring) — stage-board FP lane.** The FP lane label was a
  near-invisible grey, the "FP idle" status was orphaned in the top-right corner,
  and idle FP showed 4 unexplained ghost stage cells. Now: the FP label is as bright
  as U/V (FP-purple when busy), and an idle FP pipe draws a single flat `x87 FP idle`
  strip in its own lane instead of the orphaned label + ghost cells. (Ground-truthed
  + dropped the sibling "stage board has no gridlines" finding — they're clearly at
  `#454f5d`, spanning the lanes.)
- **New feature — keyboard-driven stepping/navigation.** `.` steps one clock, `i`
  steps one instruction, and `]` / `[` jump the playhead to the next / previous
  pipeline event (mispredict / stall / I-fill / page-walk) — so the whole debug loop
  is drivable from the keyboard.

### Iteration 20 — playhead-behind-cells, stall-bar inset, amber Δ-band, off-screen chevron
Verify confirmed 0 picks; ground-truthing (2x-zoomed Konata crops) caught two HIGH
regressions from my own recent features.
- **Fix (HIGH, self-inflicted) — playhead washed out the cells it crossed.** Iter
  18's playhead cycle-column tint was alpha-blended OVER the cell layer, so a green
  `X` or teal `D` under the current-cycle marker desaturated to a faint white glyph.
  Moved the column tint (and the Δ-band fill) to draw BEHIND the cells: opaque cells
  paint on top, so the tint shows only through the inter-cell gaps and never washes
  a glyph. Confirmed at 2x zoom the playhead `X` cells are now fully opaque.
- **Fix (HIGH) — stall bar overran the preceding `D` cell.** The collapsed `=N`
  stall bar (+ its 1px border) started flush at the next column, abutting the `D`
  glyph (`D[ =8`). Inset the bar 3px on the left so there's a clear gap; the `D`
  reads cleanly.
- **Fix (recurring) — Δ-measure band made visible + amber.** It was a faint cyan
  wash (same family as the playhead) with a floating label. Now a translucent
  AMBER band between the anchor and playhead, with an amber endpoint line and the
  `Δ<n>cyc` label boxed + centred on the span — distinct from the cyan playhead.
- **New feature — off-screen continuation chevron.** When an instruction's
  lifecycle runs past the right viewport edge, a `›` chevron now marks that row, so
  a clipped `… X = F` reads as "scroll right for more" instead of "truncated".

### Iteration 19 — compact register rows, redder branch-orange, per-cell Konata tooltip
Verify confirmed 0 picks (all perception / already-shipped); the value came from
ground-truthing the unpicked HIGH findings by *measuring* the layout.
- **Fix (HIGH) — register rows wasted ~half their height on gaps.** Measured: the
  GPR rows had a 32px pitch for ~14px text because the group boxes stretched to
  fill the tall panel. Added a trailing stretch to each register column so the
  boxes size to their CONTENT (compact rows) and the spare height collects below;
  rebalanced the right splitter to `[600, 300]` so the (now-compact) register panel
  isn't over-tall and the cache table gets the height. (Also confirmed the
  "GPR name↔value gap" finding is stale — it's ~4px, fixed back in iter 15.)
- **Fix (recurring perception) — branch-orange pushed redder.** The rel8/rel32 byte
  is correctly classified `rel` (verified `75 f8 → f8 rel`), but at 9px AA the old
  `#ff8c00` blended toward the offset-yellow and critics kept reading it as yellow.
  Pushed `rel` + `CC_BRANCH` to a red-orange `#ff6a00` (RGB dist from disp-yellow
  81→102, still clear of the salmon immediate-red) so it can't be read as yellow.
- **New feature — per-cell Konata hover tooltip.** Hovering a cell now reports the
  exact cycle and full stage name (`cycle 82: Fetch`, `Stall / bubble`, `Execute`…)
  on top of the per-row instruction info, so a dense F/D/X/= run is decodable
  cell-by-cell without counting glyphs against the legend.

### Iteration 18 — neutral mnemonics, wider Konata cells, x87 exceptions, playhead column
Verify confirmed 1 pick; ground-truthing the HIGH findings caught a colour
regression from my own iter-15 change and two recurring legibility issues.
- **Fix (HIGH, self-inflicted) — branch "orange blob".** Iter 15 unified
  `CC_BRANCH` to the rel-orange, which (with the split-colour delegate dimming the
  mnemonic by *hue*) made a branch's `jne` mnemonic dim-orange — inconsistent with
  the grey mnemonics of every other op. The mnemonic is now a single **neutral grey
  `#939ba6` for ALL instructions** (trace InsnDelegate + Konata gutter); only the
  operand/target carries the class accent, so `jne` is grey and just `0x8048010` is
  orange. This is the cleaner "the target is the only coloured token" contract.
- **Fix (recurring) — wider Konata cells.** Bumped `CELL_W` 16→20 so the F/D/X
  glyphs are legible (was "tiny specks") AND the steep dual-issue diagonal fills
  more of the panel width (fewer cycles per viewport ⇒ less empty-left strip).
- **Fix (CONFIRMED) — x87 exception flags in the effect column.** FP ops now surface
  any newly-raised FSW exception (`FP:IE/DE/ZE/OE/UE/PE`), diffed (the FSW bits are
  sticky) and gated so only the raising op shows it. Verified it ignores the TOP
  field churn (mb_fpindep moves TOP 6→7 but raises no exceptions ⇒ shows none,
  correctly).
- **New feature — playhead cycle-column highlight.** The cyan playhead now tints
  its whole cycle column (translucent cyan) across all rows, so the current cycle's
  cells stand out, not just a hairline.
- **Review-harness — demonstrate the playhead/Δ-band in captures.** They only render
  after a click, so static shots kept drawing "no playhead" HIGH findings. The
  render now drops a playhead + Δ-anchor a few rows back, so both features appear in
  the pipeline crop and critics review the real thing.

### Iteration 17 — Instr-mix tab + Konata gridlines + x87 value-column separation
Verify confirmed 3 of 7 picks; all three were real and clean to land.
- **New feature — "Instr mix" tab.** A retired-instruction-class histogram
  (branch/fp/mem/alu/sys) with %-bars, plus the **U/V issue-port split** as a
  realised-dual-issue proxy. brloop reads `50% via the V-port` (perfect pairing of
  its dec/jne loop); fp shows the `fp` class; dmiss shows alu+branch+mem. Answers
  "what is this workload made of, and how well does it dual-issue?".
- **Fix (CONFIRMED, HIGH) — Konata cycle gridlines legible.** The per-cycle
  gridlines were `#171c24` (near-black, effectively invisible against the dark
  plot), so you couldn't tie an F/D/X cell or a `=8` stall to a cycle number.
  Raised to `#2b3340` (~2x contrast) — kept below the stage board's `#454f5d` so
  they read without fighting the dense 16px cells. The cascade now sits on a
  readable grid.
- **Fix (CONFIRMED, HIGH) — x87 value column separation.** The decoded ST(i)
  value sat 2px from the 20-hex-digit 80-bit mantissa and fused with it. Added a
  fixed spacer column + right-aligned the value, so `ST0  000…000   1.5` has a
  clear gutter.
- (Ground-truthed and dropped: "GPR names↔values gap" and "instruction↔effect
  dead gap" — both addressed in iters 15/16; the screenshots show the integer grid
  packed and the instruction column stretched. The "FP lane idle / playhead absent"
  findings are screenshot-timing artifacts — the FP lane DOES light on `ud_is_fp`
  and the playhead only renders once a cell/row is clicked, which the static render
  never does.)

### Iteration 16 — sparkline fills width, playhead cycle callout, palette/layout polish
Verify confirmed 3 of 7 picks; ground-truthing the unpicked HIGH findings caught
two self-inflicted issues (a recolour collision and a column-stretch regression).
- **New feature — playhead cycle callout.** The cyan Konata playhead now carries a
  `cyc N` label in a teal chip pinned to the top of the visible region, so the
  marked cycle is readable without cross-referencing the ruler.
- **Fix (CONFIRMED) — sparkline fills the panel width.** Bars were drawn 1px/cycle
  from the left, so a ~160-cycle run filled only the left ~20%. Now each cycle's
  bar/event pixel is scaled to `plotw/shown` px (contiguous, gap-free) so the strip
  uses the whole width; `_cyc_at`/hover updated to the same scale so click-to-seek
  still lands right (verified: a mid-strip click maps to the middle cycle).
- **Fix (recurring root cause) — system-op colour, ended.** Iter 13 moved sys ops
  off branch-orange to red `#f4766e`; that red then collided with the immediate-byte
  red (lgdt "looked like an error"). Every warm accent collides with a legend
  colour, so sys is now **neutral** (same as ALU) — the mnemonic itself signals it.
- **Fix (iter-15 regression) — trace column stretch.** Iter 15 made the short
  `effect` column the stretch column, so `instruction` was fixed-width and truncated
  while `effect` sat on a wide empty stretch. Swapped: `instruction` stretches (full
  operands), `effect` is fixed/narrow.
- **Fix (CONFIRMED) — register-panel gaps + pinned placeholders.** Applied iter-15's
  pack-left trick to the Segments and Control/mode grids (trailing stretch column),
  so `CR0 00000000` packs instead of `CR0 ⟨gap⟩ 00000000`. Pinned seg-base/limit +
  CRs now show dim-italic `n/a` (not in the retire record) instead of a bright dot
  run that read as real data; the style resets to live values on the next step.

### Iteration 15 — trace effect column + register-gap + branch-colour consistency
Verify confirmed 0 of 6 picks again; the value came from ground-truthing the
unpicked HIGH findings and a recurring feature request.
- **New feature — trace "effect (writes)" column.** A retired-instruction trace
  now shows what each instruction architecturally WROTE: the destination GPR(s)
  with their committed value plus any changed flags (`eax=60000011  ZF0`,
  `xor ax,ax → eax=00000000  PF1 ZF1`). Critical subtlety found by inspecting the
  raw records: the commit GPR snapshot is **per-cycle**, so naively diffing
  consecutive retirements smears a dual-issue U/V pair's writes onto the U row
  (`mov eax,[esi]` wrongly showed `esi=…`). Fixed by attributing writes
  per-instruction via **capstone register-access analysis** (`written_regs`) and
  showing those registers' committed values — so `mov`→eax and the paired `add`→esi
  land on the right rows. Flags are diffed vs the previous retirement, gated on the
  op actually writing flags.
- **Fix — branch-colour consistency.** A branch *target* was orange in the bytes
  column (`rel` `#ff8c00`) but gold in the disassembly (`CC_BRANCH #e3b341`),
  conflating it with the yellow memory-displacement. Unified `CC_BRANCH` to the
  same `#ff8c00`, so a branch target reads one hue across both columns.
- **Fix — register name↔value gap (retry that stuck this time).** Iter 13's
  `setColumnStretch` was a no-op because the spanning EFLAGS row pinned the column
  widths. Fixed by spanning the flag row across a 3rd column and giving THAT column
  the stretch, so the name+value pack tightly on the left. Verified visually
  (unlike iter 13, where I reverted a no-op).
- (Ground-truthed and dropped: "stage board has no gridlines" — they're clearly
  drawn at `#454f5d`; perception error.)

### Iteration 14 — event-jump nav + review-harness wrong-panel fix
A trace critic caught a real harness bug (one I'd have dismissed as a perception
error): `dmiss_trace.png` showed the PIPELINE panel, not the trace. Ground-truthing
the on-disk crops confirmed it — `dmiss_trace (2000x400)`, `dmiss_regs (1280x1190)`,
`fp_pipeline (2000x410)` were impossible sizes (bigger than the 1640x980 window).
- **Review-harness fix — settle layout before cropping.** The geometry-accurate
  crops (iter 12) read `widget.rect()`, but a `QSplitter` can take an extra
  event-loop pass to constrain a panel after a content change; cropping while a
  panel still held its unconstrained size-hint framed the WRONG region
  (intermittently, ~2 of 5 workloads). Added a `_settle()` that spins the event
  loop until every panel reports an in-window geometry, plus a window-clamp in
  `_box()` as a final guard. Verified: 3 consecutive full renders, 0 bad crops.
- **New feature — event-jump navigation.** Toolbar ◀/▶ "event" buttons move the
  Konata playhead to the previous/next pipeline event (mispredict / stall / I-fill
  / page-walk) by scanning the sparkline's per-cycle event array outward from the
  current playhead. Lands directly on the next stall/miss instead of hunting by eye.
  (Fixed an index-math edge case: the Konata `base_cyc` can be negative — the
  synthesised front-end extends 2 cycles before cycle 1 — so the scan start index
  is now clamped into the strip's range.)
- **Fix (CONFIRMED) — sparkline stall colour.** The evt-strip stall pixel was amber
  `C_STALL`, indistinguishable from the amber I-fill pixel. Recoloured to the grey
  `C_STG_STALL` that the Konata `=` stall band already uses, so a stall reads the
  same grey in both views and is distinct from I-fill.
- **Fix — trace header alignment.** The `bytes`/`instruction` (and n/cyc/PC) column
  headers were centred over their geometric middle while the data is left-aligned,
  so captions floated far right of their columns. Left-aligned those headers so each
  sits over its column's first glyph.

### Iteration 13 — PC-group highlight + sparkline headroom + system-op colour
The Verify phase confirmed two of seven picks; ground-truthing the unpicked HIGH
findings settled the rest (the "lgdt looks like a branch" recurrence was real-ish —
a colour-proximity problem, not a classification bug).
- **New feature — PC-group highlight.** Clicking an instruction (Konata cell or
  gutter label) now tints every other row with the SAME PC — i.e. every loop
  iteration of that instruction — with a subtle fill + a blue left-edge marker. On
  `mb_brloop` clicking `dec ecx` lights all 105 of its iterations, so the one
  iteration that stalled 7c instead of 3c is instantly findable among its repeats.
- **Fix (CONFIRMED) — IPC sparkline top headroom.** A sustained IPC=2.0 bar filled
  the band to the absolute top edge and painted over its own 2.0 reference rule.
  Capped the drawable bar height at `ipc_h-2` (2px headroom) and moved the 1.0/2.0
  rule lines to draw AFTER the bars, so the ceiling is always visible.
- **Fix (CONFIRMED) — cache MRU glyph legend.** The `way` column shows `1*` for the
  MRU way, but `*` was only documented in a code comment. Renamed the header to
  `way *=MRU` (both I$ and D$) so the glyph decodes itself in-place.
- **Fix (recurring root cause) — system-op instruction colour.** `lgdt`/`lidt`/
  `hlt`/CR-moves were painted in a warm orange (`CC_SYS #ff9e64`) that several
  rounds of critics read as the gold branch accent. Moved system ops to a distinct
  red `#f4766e` — unambiguously not a control transfer, and "privileged" reads as
  red anyway. (The instruction was always correctly *classified* as `sys`; the bug
  was purely colour proximity to branch-gold.)
- (Ground-truthed and dropped: the GPR label↔value "dead gap" — a `setColumnStretch`
  attempt was a no-op because the EFLAGS bit-row spans both columns and fixes their
  width; not worth invasive layout surgery for a low-value cosmetic.)

### Iteration 12 — cycle-attribution tab + crop-accuracy fix + readable stage grid
The Verify phase confirmed ZERO of 6 synthesis picks (all perception/low-value);
ground-truthing the unpicked HIGH findings myself separated the real from the noise
(the "fp cache shows 16 not 32 bytes" was a perception error — the rows ARE 28px /
two 16-byte sub-rows, verified by row height; "cells don't align to headers" was the
decode legitimately spanning D1+D2). Two real root causes surfaced:
- **Review-harness root-cause fix — crop accuracy.** The screenshot crop boxes were
  hardcoded (right column at x=1010), but the outer splitter is 3:2 so the right
  column actually starts at **x=922** — the crops had been slicing ~88px off the
  left of the tables/regs panels EVERY round. *That* is why critics kept "seeing"
  clipped register names (a perception error driven by a real harness bug). Crops
  are now computed from live `widget.mapTo(win, …)` geometry, so they always frame
  the real panel regardless of splitter sizes. The regs/x87 names now show in full.
- **New feature — Cycles (cycle-attribution) tab.** A perf/VTune-style breakdown:
  every cycle is classified by FSM state into retire / issue-stall / mispredict /
  I-fill / decode / load-store / page-walk / x87 / system / halt, tallied
  incrementally (auto-resets when the backend restarts), and drawn as %-bars sorted
  biggest-first with a live IPC readout. On `mb_dmiss` it correctly attributes the
  IPC-0.356 to **71.9% issue-stall** (the D-cache-miss bottleneck) — answers "why is
  IPC low?" at a glance.
- **Stage-board gridlines made readable.** Three review rounds reported the column
  separators as "absent"; they were drawn at near-black `#222c37`. Bumped to
  `#454f5d` so the PF/D1/D2/EX/WB columns read and each lit cell is unambiguously
  anchored to its stage even when the rest of the board is empty.
- **Register panel given real vertical room.** The right splitter was 3:1
  (tables:regs), cramming the registers into a 25% bottom strip while a sparse cache
  left a huge void above. Rebalanced to 3:2 + initial sizes so the GPR/EFLAGS/seg/
  CR/x87 panel breathes and the dead void shrinks.

### Iteration 11 — fix Konata horizontal framing + sparkline navigation overview
The Verify phase refuted 5 of 6 synthesis picks (perception errors / low-value),
confirming one; ground-truthing the unpicked HIGH findings myself surfaced two more
real ones the synthesis under-rated.
- **Fix (CONFIRMED, HIGH) — Konata horizontal framing:** the horizontal follow
  pinned to the raw FSM `max_cyc` while vertical follow tracked the bottom rows.
  For a workload with a long non-retiring tail (test386 ends in S_DECODE, max_cyc
  runs ~50 cycles past the last retirement) this scrolled the visible rows' cells
  clean off the left edge — rows listed, timeline **blank**. It's the horizontal
  twin of iteration-10's vertical regression. Fix: the horizontal stick now anchors
  the left edge to the topmost visible row's first cell (clamped to max so a
  fast-path cascade still follows the newest cycle). test386 now renders the full
  `F F F D X = F` slow-path cascade as a clean diagonal.
- **New feature — sparkline as a clickable navigation overview:** the IPC/stall
  strip now seeks the Konata playhead to any cycle on click (with a hover marker),
  gained an **inline event-colour key** (mispred/stall/I-fill/walk) and a 0/1/2 IPC
  y-axis, and is a touch taller — addressing the recurring "sparkline scale is
  cryptic / events have no key" findings while adding real navigation.
- **Fix (recurring root cause) — branch-rel byte colour:** every iteration a critic
  reports the rel8/rel32 branch-displacement byte as "yellow not orange". The code
  was always correct (tagged `rel`), but the rel-orange `#f0883e` sat only RGB-dist
  45 from the offset-yellow `#e3b341` — genuinely too close at 9px. Bumped rel to a
  vivid `#ff8c00` (dist 81), so the perception error should finally stop recurring.
- **Fix (recurring) — trace bytes truncation:** long encodings (ppage's 9–10-byte
  movs) were `…`-clipped with data lost. Widened the bytes column (196→236px, fits
  ~11 bytes) and added a **full-bytes hover tooltip** so the complete encoding is
  always recoverable.

### Iteration 10 — fix Konata auto-follow regression + cycle-Δ measurement cursor
This iteration's review collapsed 43 raw findings to ONE confirmed code change after
the new adversarial Verify phase refuted the rest (3 perception errors, 1 already-
shipped = iter-9's gridlines, 1 low-value). But ground-truthing the unpicked HIGH
findings myself caught a **regression I shipped in iteration 9**:
- **Konata auto-follow regression (HIGH, self-inflicted):** iter-9's row-aligned
  bottom-snap (`setValue((max//ROW_H)*ROW_H)`) left the at-rest scroll value *below*
  max, so the next tick's `value >= max-4` follow check read "not at bottom" and
  auto-follow died. For any workload that overflows the viewport (fp, brloop) the
  vertical view stranded on early rows while cycles ran ahead — the Konata grid
  rendered **completely blank** (instructions listed, zero cells). dmiss/test386
  fit without scrolling so they masked it. Fix: auto-follow is now **explicit stick
  state** toggled only by a user scroll (guarded against our own programmatic
  scrolls), so following never breaks; the row-snap is kept for whole-row top/bottom
  alignment. Verified fp + brloop now render the full F→D→X cascade again.
- **New feature — cycle-range Δ measurement cursor:** shift-click a Konata row to
  drop an amber anchor; the band between it and the cyan playhead is shaded and
  labelled `Δ<n>cyc` (measure latency between any two instructions — e.g. across a
  D-cache-miss stall). Shift-click the same row to clear. Builds on iter-9's playhead.
- **Pinned x87 header clip (CONFIRMED by Verify):** the pinned regs x87 header was 5
  chars wider than the live one (`(pinned)` prefix + 4-digit tag) and clipped the
  `tag=` value off the panel's right edge. Shortened to a tight `pin ctrl=… stat=…
  tag=…` + `setWordWrap(True)` guard, so all three fields stay in-panel.
- **Review-harness — watermark moved to a dedicated band:** the build-stamp used to
  paint over the top-left, obscuring the toolbar in full-window shots (a recurring
  layout-critic complaint). It now lives in a 15px band *above* the screenshot
  (crops taken from the raw grab first, so crop boxes are unaffected) — overlaps no
  UI, still top-left + findable for the anti-staleness check. Also added pinned-regs
  screenshots (dmiss/fp) so the review can actually see the register-pinning feature.

### Iteration 9 — register pinning + playhead, split-colour labels, stage gridlines
- **New feature — pin the register panel AS-OF a retired instruction + cycle
  playhead:** clicking a trace row or a Konata cell/label now pins the register
  panel to *that instruction's* post-commit architectural state (GPRs / EFLAGS /
  segment selectors / x87 stack, from the retire record), banners it
  `PINNED n=… cyc=…` in amber, and drops a cyan vertical **playhead** down the
  Konata view at the commit cycle. The next step/run unpins back to live. Lets
  you inspect the machine state at any point in the trace without re-running.
- **Split-colour instruction labels** (synthesis: "colour only the target
  operand, not the whole mnemonic"): both the Konata gutter and the trace
  instruction column now draw the mnemonic in a *dimmed* class hue and the
  operand(s) — a branch's target, a load's address — in the full class accent, so
  the target pops instead of the whole instruction being one flat slab.
- **Stage-board column gridlines + legend-white captions** (synthesis: "boxes
  float with no stage anchoring" + "raise stage-header contrast"): faint vertical
  gridlines now anchor each lit cell to its PF/D1/D2/EX/WB (and FP X1/X2/WF/ER)
  column, and the stage captions were brightened to match the colour legend.
- **Whole-row scroll snap** (recurring "clipped half-row at the top" finding):
  the Konata view snaps wheel/keyboard scrolling to whole rows + cycle-columns
  and adds one row of bottom slack so a bottom-follow scroll lands row-aligned
  (newest instruction stays fully visible); the trace table scrolls per-item.
- **Review-harness bug fix:** the screenshot watermark's `+dirty` marker never
  fired — `_ROOT` pointed at `tools/` (two `dirname`s) instead of the repo root,
  so `git status --porcelain tools/pipeviz` ran from the wrong cwd and always
  came back empty. Fixed to the repo root; uncommitted working-tree renders now
  correctly stamp `<sha>+dirty`, restoring the anti-staleness guarantee.
- (Re-verified, again, that the branch byte colours are correct: `loop e2 fc` →
  `e2` opcode-blue, `fc` rel-orange — a repeat critic mis-sample, source-dropped.)

### Iteration 8 — Branches/BTB panel + synthesised F→D→X pipeline cascade
- **New feature — Branches/BTB inspector tab:** per-branch-PC profile (type,
  target, hits, taken, taken%, bias bar; taken inferred from the next retired PC
  vs the parsed target). 103 sites on `mb_brrandom`.
- **Konata fast-path pipeline depth** (the recurring "all single X" finding):
  fast-path ops now synthesise their P5 Fetch+Decode stages in the two cycles
  before commit, so instructions cascade diagonally `F→D→X` like a real
  superscalar diagram instead of a lone X cell.
- **Colour fix:** wb/FP/walk were all in the purple-pink family; wb moved to
  slate-blue so the three are separable at the 12px cell size.
- **Stage board:** the instruction label now sits in ONE stage cell (no longer
  straddling the EX/WB column divider); fixed the clipped "FP idle" corner label.
- **Trace:** narrowed the bytes column back toward the common case, and the Δ
  column now shows `+N` only on a stall gap (steady-state 0/1 is suppressed).

### Iteration 7 — Memory inspector + stall-run collapse + cycle gridlines
- **New feature — Memory hex/ASCII inspector tab:** type an address or click
  →EIP / →ESP to follow them, ◀/▶ to page; EIP bytes highlighted cyan, ESP amber.
- **Konata stall runs now collapse** into one `=N` block (N = stall cycles) — a
  D-cache miss reads as `=7` instead of seven indistinct grey cells.
- **Per-cycle vertical gridlines** every 10 cycles on the Konata view so a cell's
  exact cycle is readable.
- **Widened the instruction gutter** so full mnemonics show
  (`mov eax, dword ptr [esi]` no longer `…`-truncated).
- **Real bug fix:** page-walk colour was identical to flush (`C_WALK ==
  C_MISPRED == #f85149`); walk is now pink, distinct from the flush red.
- **Trace:** widened the bytes column so common 9–10-byte encodings show in full
  before the `…` clip kicks in (balancing iter5's anti-collision clip).

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
