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
  purple), `W` wb magenta, `=` stall grey, `!` flush red, **`S` sys/microcode
  bronze** (a DEDICATED `#a87f55`, pulled clear of the L-fill amber it used to
  share so the glyph is decodable + has its own legend swatch); legend on its own
  line with each swatch tightly paired to its label; walk = pink, wb = slate-blue
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
  same row again to clear it). The playhead/Δ **lines + column tint + Δ-band all
  draw BEHIND the cells** (cells paint on top) so a vertical marker never punches a
  stripe through an F/D/X glyph — only the `cyc N` / `Δ<n>cyc` labels sit on top.
  A row whose lifecycle runs past the right edge shows an amber **`›` continuation
  chevron** painted on a small opaque chip in the row's own bg colour, so it reads
  cleanly even when a cell occupies the final column (it no longer muddies
  amber-on-blue INSIDE that edge cell). Selecting an instruction also **PC-group highlights**
  every other execution of the same PC (loop iterations) with a tint + a blue
  left-edge marker, so a stalled iteration stands out among its repeats, AND draws
  **producer→consumer DEPENDENCY EDGES**: a thin line from each source register's
  PRODUCER (the most-recent prior instruction that wrote it — a pure def-use join
  over the read/write reg-sets capstone already exposes) at its commit cell to the
  selected consumer's first cell, labelled with the register (`esi`); the edge is
  amber + thick only when the producer's result arrives right as the consumer's stall
  LIFTS (its commit lands within ±1 cycle of the last `=` stall cell — a true
  RAW/load-use), and dim otherwise. That precision is deliberate: dmiss's `dec ecx`
  stalls BEHIND a cache-miss load, not on its ecx producer (which committed long
  before the stall lifted), so its ecx edge stays dim — the overlay never falsely
  blames a dependency that merely happens to commit somewhere inside a structural
  stall. A loop-carried induction (`add esi` ← `esi` ← prior `add esi`) shows as a
  dim def-use trace. The edges cover **EFLAGS** dependencies too, so a conditional
  branch traces to its flag-setter (`jne` ← `flags` ← `dec ecx`/`cmp`) — the single
  most common dependency in any loop; the register label flips to the LEFT of the
  producer cell when it would otherwise clip past the right viewport edge.
  The per-row tooltip also lists the instruction's `reads`/`writes` (incl. `flags`). Auto-follow
  ("stick to the newest row/cycle") is explicit state toggled only by a user scroll,
  so the viewport tracks live
  retirement without stranding on stale rows; the **horizontal** follow anchors to
  the topmost visible row's first cell (not the raw FSM max-cycle), so a long
  non-retiring tail (S_DECODE/S_PF/S_WALK) can't scroll the visible rows' cells
  off-screen into blank space.
- **Memory tables panel** (tabbed): I$/D$ each with a **2D set×way occupancy
  heatmap** (way0/way1 rows, set-axis ticks, legend) above a line table (no LRU
  column; MRU shown as `*` on the way; 32 line bytes wrapped to two rows, not
  truncated); the **Data$ header also reports a replayed D-cache MISS-RATE** — the
  resolved access stream run through the real 128-set×2-way×32B LRU geometry, tallied
  hit/cold/conflict (`D$ replay: 100% miss (14/14 · 14 cold, 0 conflict)` for dmiss),
  the hit/miss OUTCOME the resident-line snapshot and the Mem-map geometric stride
  can't give — and it disambiguates the stride (dmiss +0x20 = the line size = all
  miss, vs test386 +0x2 < the line = ~91% hit, which both read as 'stride 100%');
  split TLB; prefetch buffer (ibuf + decode — but when the ibuf is
  all-zero the decode line shows **"ibuf idle — fast-path fetch from the I-cache;
  slow-path decoder not engaged"** instead of decoding the zeros into a bogus
  `00 00`→`add [eax],al` that would falsely claim to be the instruction "@ eip").
  Every cache/TLB/Hotspots/Branches table shows a centered, muted **empty-state
  hint** when it has zero rows (e.g. "D-cache empty — this workload has issued no
  data loads/stores yet", "TLB empty — paging is off or no translations resolved
  yet") so an empty tab reads as 'no activity yet' rather than a broken/blank panel.
  **Hotspots** = a
  per-PC cycle-cost profile (PC | hits | cycles | cyc% | amber cost bar |
  **field-coloured** instruction, sorted by total cycles — stalls inflate the cost
  so the stalled load/branch PCs bubble to the top, perf/VTune-style; the
  instruction column uses the same `operand_segments` field-colouring as the trace
  + Konata gutter; the numeric columns **right-align** (header + data) so digit
  places line up for magnitude scanning); **Branches** = a
  per-branch-PC BTB profile (PC | type | target | hits | taken | taken% | bias
  bar; taken inferred from whether the next retired PC hit the target; numeric
  columns right-aligned like Hotspots); **Instr
  mix** = an instruction-class histogram (branch/fp/mem/alu/sys with %-bars) plus
  the U/V issue-port split as a realised-dual-issue proxy (`50% via the V-port`);
  **Cycles**
  = a perf/VTune-style **cycle-attribution breakdown** — every cycle classified by
  FSM state into retire / issue-stall / mispredict / I-fill / decode / load-store /
  page-walk / x87 / system / halt, drawn as %-bars sorted biggest-first with a live
  IPC readout, so the tallest bar is the bottleneck (answers "why is IPC low?");
  **Memory** = a hex/ASCII
  inspector (type an address or click →EIP/→ESP/**→access** to follow, ◀/▶ to page;
  EIP bytes cyan, ESP bytes amber, and the **most-recent load/store ACCESS** gold —
  →access tracks the address of the newest retired memory op and gold-outlines its
  exact byte span, so you can watch the memory the program is touching and jump
  straight from a trace `@<ea>` to the data there, e.g. follow dmiss's striding load
  frontier `@08049180`→`@080491a0`→…); **Mem map** = an **address-vs-sequence
  SCATTER** of the access stream — one point per retired load/store (X = retire order,
  Y = effective address, low at the bottom), loads blue / stores gold — so the access
  PATTERN reads as a shape the per-row trace list can't show: a strided walk is a
  straight diagonal (dmiss's loads), a hot location a horizontal band, random access
  scatters (header gives count / address span / load·store split + the **dominant
  STRIDE** — the mode of the consecutive-access deltas with its %, e.g. dmiss reads
  `stride +0x20 (100%)` = exactly the 32-byte cache line, so every access misses;
  `irregular stride` when no delta dominates). **Clicking a point** rings it with a
  crosshair, reads out its `n / cyc / @address / load|store` in the header, jumps
  the trace (+ pins regs) to that instruction, AND pins the **Memory** tab to that
  access's bytes (navigates + gold-outlines the exact span, "showing clicked access"
  — no forced tab switch, so switching to Memory shows precisely what that load/store
  hit) — so an outlier or a stripe in the scatter is one click from its source row
  AND its memory.
- **Trace panel**: search/filter box (`mov` / `pc:08048` / `cyc>=133` / `pipe:V` /
  `stall` / **`@`** to isolate memory-accessing rows — the placeholder advertises it);
  columns n | cyc | Δ | pipe | PC | bytes |
  instruction | **effect** (Δ shows `+N` only on a stall gap — steady-state 0/1
  suppressed); the **effect column** shows what each retired instruction
  architecturally WROTE — the destination GPR(s) with their committed value (blue)
  plus any changed flags (`eax=60000011  ZF0`, teal) plus the **x87 ST(0) result**
  of an FP op (`st0=86`, purple — diffed vs the previous retirement so a non-faulting
  `fadd`/`fld`/`fmul` no longer reads as a blank no-op) plus any **x87 exception**
  newly raised (`FP:ZE`, amber) plus the **resolved memory-access address** of a
  load/store (`@08049160`, gold — base+index*scale+disp evaluated on the
  pre-instruction register file, exact for a U-pipe op; so a cache-missing load's
  access stride is visible right in the trace, e.g. dmiss steps `@08049000`,
  `@08049020`, `@08049040`, … by 0x20); writes are attributed per-instruction via
  capstone register-access analysis, so a dual-issue U/V pair's writes land on the
  correct rows even though the commit snapshot is per-cycle. x86 byte-field
  colouring (prefix gray `#aab4c0` / opcode blue `#4ea1ff` / ModRM green `#56d364`
  / SIB purple `#c89bff` / displacement gold `#e3b341` / immediate salmon `#ff7b72`
  / **branch-rel red-orange** `#ff6a00`, pulled well clear of the gold), clipped
  with `…` only past ~11 bytes with the **full encoding on hover** (tooltip) so no
  bytes are lost; the **instruction column is FIELD-coloured** to match the bytes
  legend AND the Konata gutter AND the Hotspots instruction column — a NEUTRAL-grey
  mnemonic (the same grey for every op) then each operand token coloured by its
  field via `disasm.operand_segments`: immediate=salmon, displacement (inside
  `[...]`)=gold, branch-target=red-orange, registers/brackets neutral; so a `mov
  ax, 0x10` shows its `0x10` salmon exactly like its immediate byte, and a branch's
  `jne` stays grey while only its target carries the orange;
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
  unpins back to the live state. The x87 stack's ST-label column has a fixed min
  width so a populated row never butts the exponent against the label (`ST1 3fff`,
  not `ST13fff`) in any mode/state, and the empty-slot `·` marker renders in pinned
  mode too — so the pinned stack matches the live layout exactly.
- **Status bar** (grouped, coloured): cyc · state/mode · ret/IPC/pair%/mispred ·
  I$/D$ occupancy/fills/walks · eip.
- **Toolbar** (grouped file | config | transport, accented Run, + **event-jump**
  ◀/▶ that move the Konata playhead to the prev/next pipeline event —
  mispredict/stall/I-fill/page-walk — for fast "jump to the action" navigation).
- Backends: `ventium_top` (user + system) and `ventium_soc` (test386 etc.).

## Iterations
<!-- newest first; appended by the loop -->

### Iteration 37 — D-cache replay miss-rate + Memory-pin reset-on-load fix
After SIX straight 0-pick rounds the review surfaced a genuinely-new CONFIRMED pick
(MEDIUM): no panel reported a D-cache hit/miss OUTCOME, even though the resolved access
stream and the cache geometry are both already on hand. I GROUND-TRUTHED it first
(replayed the stream through a 2-way-LRU model: dmiss 100% miss, test386 9%, ppage 30%
— all distinct and meaningful) before building.
- **New feature (CONFIRMED) — replayed D-cache miss-rate in the Data$ header.** A new
  `_dcache_replay` runs `trace.accesses` through a client-side `DC_SETS×WAYS×LINE`
  (128×2×32B) LRU model — the same geometry as the hardware `dcache_timing` — tagging
  each access hit / cold-miss / conflict-evict, and appends `D$ replay: X% miss (M/N ·
  K cold, J conflict)` to the Data$ header. This names the cause of the load-stall
  bubbles the pipeline draws and the dmiss stride only implies, and crucially
  DISAMBIGUATES the geometric stride: dmiss `+0x20` = the 32B line ⇒ 100% miss, while
  test386 `+0x2` < the line ⇒ ~91% HIT — yet both read `stride … (100%)`. Pure
  derivation from data already captured; unit-tested (set-conflict eviction + spatial
  locality) and matched against the per-workload probe.
- **Correctness fix — the Memory tab's Mem-map-click pin now clears on image load.**
  iter35's `_click_hl` (set when a Mem-map point pins the Memory tab) was NOT reset by
  `load_image`, so loading a new program left a stale "showing clicked access" gold
  highlight at the OLD program's address. Added `MemoryView.reset()` (called in
  `load_image`); smoke-tested that the pin clears across a load yet still works
  in-session. Found by my own source review, not a critic.

### Iteration 36 — Mem-map selection robustness (track stable retire-n, not a volatile index)
Review confirmed the live watermark (`90f235d`) on all 6 critics and **confirmed 0 of
0** picks — the SIXTH straight 0-pick round ("None remains"). The tool is finished;
this iteration is a genuine small CORRECTNESS fix I found by my own code review (the
loop weights my ground-truthing over critic nitpicks), not a cosmetic tweak. First
verified the cross-panel drill-downs are already consistent: `select_n`/`select_pc`
both call `setCurrentCell` → `currentCellChanged` → `_on_row`, which emits both
`rowSelected` (Konata) and `instSelected` (regs pin), so Hotspots/Branches/Konata/
Mem-map clicks ALL pin regs symmetrically — no bug there.
- **Correctness fix — the Mem-map selection now survives the access-stream rolling
  cap.** The scatter stored its clicked selection as a list INDEX, but the trace caps
  the access stream at 4000 and drops older accesses off the FRONT (in place), which
  shifts every index — so after a long run a stored selection would silently point to
  the WRONG access (crosshair + readout on a different point). The selection is now
  keyed on the clicked access's stable retire-`n` and the current index is resolved
  each paint (`_sel_idx`), so it tracks the same access across front-drops and cleanly
  disappears (no stale crosshair) if that access is itself dropped. Smoke-tested by
  simulating a front-drop: a selection of index 8 correctly follows its access to the
  shifted index 3 (same n/@addr), where the old code would have drifted to a different
  point; a dropped selection resolves to None; a fresh stream clears it.

### Iteration 35 — Mem-map → Memory click link + "@" filter discoverability
Review confirmed the live watermark (`29bca32`) on all 6 critics and **confirmed 0 of
0** picks — the FIFTH straight 0-pick round ("None"). Maintenance mode; two small,
ground-truthed additions. I first GROUND-TRUTHED two dead candidates: a trace `mem`
filter token is redundant (typing `@` already isolates exactly the memory rows, since
the filter substring-matches the effect text's `@<ea>`), and store→load edges stay at
one pair — so I picked the genuinely-new links instead.
- **Refinement — Mem-map point click also pins the Memory tab to that access.** A
  click already ringed the point + jumped the trace; it now ALSO navigates the Memory
  inspector to that access's address and gold-outlines its EXACT byte span (size from
  `mem_operand`, carried in the access tuple), labelled "showing clicked access". It
  does NOT force a tab switch (the crosshair stays visible; switch to Memory to see
  the bytes), and the pin clears the moment you navigate away (Go / a follow button /
  paging). So a scatter point is now one click from BOTH its source instruction (left)
  and its memory contents (right) — completing the scatter→trace→Konata→regs→Memory
  drill. Smoke-tested: click navigates+highlights the right (addr,size), no tab switch,
  navigate-away clears the pin.
- **Polish — surface the `@` memory-access filter.** Verified the trace filter already
  isolates memory rows when you type `@` (it matches the `@<ea>` in the effect text);
  the filter placeholder now advertises `@  (mem)` so the capability is discoverable.

### Iteration 34 — Mem-map dominant-stride annotation
Review confirmed the live watermark (`56efc9f`) on all 6 critics and **confirmed 0 of
0** picks — the FOURTH straight 0-pick round (features critic: "None"). The UI is
saturated; per the converged-loop discipline this iteration is a small, ground-truthed
enhancement to a recent feature, not a forced new surface.
- **Refinement — dominant-stride annotation on the Mem map.** The scatter's slope
  shows a strided walk as a *shape*; the header now also states the **numeric stride**
  — the mode of the consecutive-access address deltas with its share, e.g. dmiss reads
  `stride +0x20 (100%)`. That value is the cache-analysis punchline: 0x20 is exactly
  the 32-byte cache line, so a 0x20 stride means every load lands on a fresh line and
  misses — the whole dmiss story in three tokens. Shows `irregular stride` when no
  delta reaches 40%. GROUND-TRUTHED before building (the iter30+ discipline): probed
  the delta distribution — dmiss +0x20 100%, test386 +0x2 100%, ppage +0x4 56% — all
  meaningful; rounds the % (so 5/9 reads 56%, not a floored 55%). Pure client-side
  from the already-collected access stream. Smoke-tested the stride values across
  three workloads, the click still selects/emits, and the no-access map is inert.

### Iteration 33 — interactive Mem map (click a point → readout + trace jump)
Review confirmed the live watermark (`3689302`) on all 6 critics and **confirmed 0 of
0** picks — the THIRD straight 0-pick round. The features critic explicitly returned
"None remains … No new actionable feature idea survives", listing every surface as
settled. The UI is saturated, so this iteration is the anticipated honest outcome: a
modest REFINEMENT of the just-shipped Mem map rather than a brand-new surface.
- **Refinement — make the Mem map interactive.** The access scatter's points are now
  clickable: a click rings the nearest point with a white crosshair, reads out its
  `n / cyc / @address / load|store` in the header (in the point's own load-blue /
  store-gold), and emits `pointSelected(n)` → the trace jumps to that retire-n row and
  pins the registers (mirroring the Konata/Hotspots drill-downs). So an outlier point
  or a stripe in the pattern is one click from its source instruction — closing the
  scatter→trace→Konata→regs navigation loop. The access stream now carries `cyc` too
  (`(n, cyc, addr, is_store)`). A nearest-point hit-test with an 18px radius guard
  ignores empty-area clicks. Smoke-tested: clicking access idx5's pixel selects it +
  emits its n + jumps the trace; empty-area clicks no-op; an empty (no-mem) map
  doesn't crash on click.

### Iteration 32 — Mem-map access-pattern scatter (address vs sequence)
Review confirmed the live watermark (`f90851b`) on all 6 critics and **confirmed 0 of
0** picks — for the second straight round the adversarial review found nothing
actionable (the UI is saturated). The features critic returned "None worth shipping",
and amusingly its reasoning cited my own in-progress `AccessMapView` source (it read
`tools/pipeviz/pipeviz/` mid-run while I was building this very feature) — independent
confirmation that the access-pattern scatter is exactly the gap that remained.
- **New feature — Mem map (address-vs-sequence access scatter).** A new `AccessMap`
  widget + tab plots the memory-access stream the trace already resolves: one point
  per retired load/store, X = retire order `n`, Y = effective address (low at the
  bottom), loads blue / stores gold, with auto-scaled axes + an empty-state hint. The
  access PATTERN finally reads as a SHAPE — dmiss's strided loads render as a clean
  diagonal (`@8049000`→`@80491a0` by 0x20), a hot location would be a horizontal band,
  random access scatters — none of which the per-row trace `@<ea>` list conveys. The
  trace collects the `(n, addr, is_store)` stream (capped, rolling); `main` plumbs it
  to the tab. GROUND-TRUTHED first: dmiss (14, clean stride), test386 (34, tight
  cluster) and ppage (10, one huge-span outlier auto-scale absorbs) all have usable
  data; brloop/fp (0 accesses) show the empty-state hint. Verified the collected
  addresses match the trace `@<ea>` EXACTLY, retire-order monotonic, all workloads
  paint without crash, reset clears the stream.

### Iteration 31 — Memory '→access' follow mode (watch the program's memory frontier)
Review confirmed the live watermark (`605762e`) on all 6 critics but **confirmed 0 of
4** picks — the UI is genuinely mature: every pick was refuted as already-surfaced
(per-PC latency dispersion = the Konata `lat` column already shows per-occurrence span
colour-graded + one-click drill-down; per-visit latency sparkline = same `lat` column;
register value timeline = the trace effect column already shows the value sequence +
the filter isolates a PC; Hotspots cost-bar min-1 floor = the intentional ASCII-bar
convention, exact value in the adjacent cycles/cyc% columns). So no fixes this round;
I picked a genuinely-new feature that survives scrutiny.
- **New feature — Memory tab '→access' follow + gold access highlight.** Building on
  iter30's resolved `@<ea>`, the Memory inspector gains a fourth follow button
  (→EIP/→ESP/**→access**): →access tracks the address of the most-recent retired
  load/store and gold-outlines its EXACT accessed byte span (the size now comes from
  `disasm.mem_operand`, e.g. 4 bytes for a dword load, 1 for a byte). This closes the
  loop the @addr opened — you can now jump from "this load read @08049160" straight to
  the data there, and watch the program's memory frontier advance as you step (dmiss's
  striding loads walk the highlight by 0x20). Before building it I GROUND-TRUTHED the
  signal (the trace's resolved EA fires on every dmiss load; store→load pairs occur
  only once across all workloads, so a memory-dependency-edge feature was correctly
  rejected as too thin). Smoke-tested: →access navigates to the newest access address,
  highlights the correct span, and a no-memory workload (brloop) leaves it inert.

### Iteration 30 — resolved memory-access address in the trace, singular/plural subtitle
Review confirmed the live watermark (`7563011`) on all 6 critics. Verify **confirmed
1 of 2** and refuted the other. Notably the features-critic's top pick (per-stall
CAUSE attribution on the `=N` bubble) was REFUTED — and my own ground-truth had
already found `pending_mem_pen` reads 0 on every dmiss stall (all are `stall_cnt`
"issue" stalls), so the proposed "D$-miss" tint would never have fired; the verifier
separately noted it would duplicate the StageBoard split + dep-edge gating + lat
grading. So I picked a genuinely-new, reliable feature instead.
- **New feature — resolved memory-access address in the trace.** A new
  `disasm.mem_operand` extracts a load/store's addressing (base/index/scale/disp,
  skipping `lea`/`nop` which carry a non-accessing memory operand), and the trace
  resolves the effective address = base+index*scale+disp on the PRE-instruction
  register file — the prior retirement's committed GPRs, which is the exact input
  state for a U-pipe op (always the senior of its dual-issue pair; V-pipe reg-based
  ops are skipped to stay correct). It surfaces as a gold `@<ea>` in the effect
  column, so a cache-missing load's access STRIDE is finally visible right in the
  trace (dmiss: `@08049000 @08049020 @08049040 …` by 0x20; ppage 16-bit: `@0480`,
  `@0514`). Correctness was cross-checked: every resolved load address+0x20 equals a
  later committed `esi` value, proving it's the true pre-state, not a stale read.
  Widened the effect column 168→192px to fit `reg=val + @addr`.
- **Fix (CONFIRMED, LOW) — singular/plural subtitle.** The Branches subtitle
  hard-concatenated "branch sites", rendering the ungrammatical "1 branch sites" for
  a single-branch loop (brloop). Added a count guard ("1 branch site"); applied the
  same guard to the Hotspots "distinct PC(s)" label.

### Iteration 29 — flag-dependency edges, left-aligned bar-column headers
Review confirmed the live watermark (`5b41520`) on all 6 critics. Verify **confirmed
1 of 6** and refuted 5 with code-cited reasoning (trace top-row sliver = the same
already-refuted scroll-overflow at the top edge from tail-following auto-scroll;
pinned Segments "baselimit" collision = false, a measured 11px gap + no manual
x-positioning, just grid compaction; ppage 'eax' overprint/clipped = the
settled-intentional dependency-edge label, measured to end inside the plot; Data$
'line addr' over-stretch = the uniform last-column-stretch convention already
accepted for the TLB 'D'; effect-column radix collision st0=84-vs-eax-hex =
disambiguated by colour + 8-hex width + register-name + tool-wide convention).
- **New feature — dependency edges now cover EFLAGS.** `disasm.read_regs` now also
  reports flags-read (symmetric with `written_regs`), and the Konata model carries a
  reads-flags/writes-flags pair per instruction. Selecting a conditional branch now
  draws a `flags` edge to its most-recent flag-setter (`jne` ← `flags` ← `dec ecx`) —
  THE most common dependency in any loop, and previously invisible (a `jne` reads no
  GPRs so it showed no edge at all). The register label flips to the LEFT of the
  producer cell when it would clip past the right viewport edge (producers near the
  playhead frontier). The tooltip's reads/writes lists now include `flags`. Smoke-
  tested the producer join (jne→dec ecx flag edge), the no-flags case (mov), and the
  capstone read/write-flags units; the demo shot now selects a branch to surface it.
- **Fix (CONFIRMED, LOW) — bar-column headers left-align over their bars.** The
  `cost`/`bias`/`bar` glyph-bar columns are the stretched last column with left-pinned
  bars, but their headers defaulted to centered, so e.g. Branches' `bias` floated far
  right in the column's empty half while its `TTTT…` bar hugged the left. Generalised
  the iter28 header-align helper and left-aligned the three bar-column headers so each
  caption sits directly over its bar (matching the same header↔data principle that
  already right-aligns the numeric columns).

### Iteration 28 — producer→consumer dependency edges, right-aligned profiler columns, 'S sys' legend
Review confirmed the live watermark (`12fa635`) on all 6 critics. Verify **confirmed
2 of 6** and refuted 4 with code-cited reasoning (filter-placeholder contrast = a
sampling error, ink is *lighter* ~1.5:1 + intentional placeholder dimming; x87 tag
2-vs-4-hex live/pinned = different data sources — live `fptag` is the real 8-bit
empty-mask, pinned `ftag` is a hardcoded `0x0000` placeholder, each format string
matches its field width; Instr-mix uniform-gold bars = the deliberate table
convention, all three glyph-bar tabs put colour in the text and gold in the bar;
TLB bare `D` header = a conventional MMU status bit exactly like the `V` beside it).
Both confirmed picks were independently ground-truthed before the fix.
- **New feature — producer→consumer dependency edges (the carried idea, the features
  critic's top pick two iterations running).** A new `disasm.read_regs()` (the mirror
  of `written_regs`, keeping capstone's read-set) feeds a per-Konata-insn read/write
  reg-set; selecting an instruction now walks `insns[]` backward to the most-recent
  writer of each source register and draws a thin edge from that producer's commit
  cell to the consumer's first cell, labelled with the register. The edge is amber +
  thick when the producer commits DURING the consumer's lifecycle (a live dep that
  plausibly gated it) and dim when satisfied early — a pure def-use trace, so it
  never falsely attributes a stall (verified on dmiss, where `dec ecx` stalls behind
  a load, NOT on its ecx producer, and correctly shows only a dim ecx edge). The
  tooltip also lists each instruction's `reads`/`writes`. Fully client-side, no
  backend change. Smoke-tested the producer join + the no-reads (`jne`) empty case.
- **Fix (CONFIRMED, HIGH) — right-align the numeric columns in Hotspots & Branches.**
  `_fill()` built every cell left-aligned, so `1` sat far left of `105`'s units place
  and magnitude scanning (the whole job of a profiler table) was defeated. Numeric
  columns (hits/cycles/cyc% ; hits/taken/T%) now right-align, header + data, via a
  `right_cols` arg + a `_right_align_headers` helper.
- **Fix (CONFIRMED, MEDIUM) — the Konata `S` (sys/microcode) glyph is now decodable.**
  It had no legend entry and reused the L-fill amber (`C_SYS`), so a gold `S` cell
  (ppage's microcoded `add [eax],al`) looked up to the wrong swatch. Gave it a
  DEDICATED bronze `C_STG_SYS = #a87f55` (colour distance 79 from the L-fill amber)
  and an `S sys` legend swatch, leaving the shared `C_SYS` class colour untouched.

### Iteration 27 — x87 ST(0) writes in the trace, pinned-x87 column fix, prefetch idle guard, empty-table hints
Review confirmed the live watermark (`1829ec6`) on all 6 critics (now including the
new all-9-tab sweep). Verify **confirmed 3 of 6** picks and refuted 3 with code-cited
reasoning (the empty-slot dot drop = redundant + same root cause as the confirmed
pinned-x87 fix; Hotspots "650 cycles" vs Cycles "120 cyc" = intentional profiler
per-PC occupancy vs wall-clock, both labelled inline; Run-button green ≈ exec-cell
green = a sampling error — Run is forest `#238636`, exec is brighter `#3fb950`). All
three confirmed picks were independently ground-truthed (zoom + pixel-sample) before
the fix.
- **Fix (CONFIRMED, HIGH) — Prefetch no longer decodes the idle all-zero ibuf into a
  lie.** On the fast dual-issue path the slow-path ibuf is unused/all-zero, yet the
  tab decoded those zeros into `add byte ptr [eax], al` and labelled it "@ eip" —
  directly contradicting the real EIP byte (`dec ecx`) shown in the Memory tab. Now
  an all-zero ibuf shows a dim "ibuf idle — fast-path fetch from the I-cache;
  slow-path decoder not engaged" instead of a bogus decode.
- **Fix (CONFIRMED, MEDIUM) — x87 FP ops now show their result in the effect column.**
  A non-faulting `fadd`/`fld`/`fmul` was completely blank under the header literally
  reading "effect (writes)", reading as a no-op. `_effect()` now diffs the logical
  ST(0) vs the previous retirement and, for an FP op that changed it, surfaces
  `st0=<value>` (decoded via `floatx80_to_float`) in the x87 purple `#c89bff` — so
  the FP result is visible like a GPR write but distinct from one. Verified the fp
  workload's `fadd` rows show `st0=84/85/86/87` and no integer op gets a spurious one.
- **Fix (CONFIRMED, cosmetic-but-real) — pinned x87 'ST13fff' collision.** The live
  path padded the ST-label grid column only incidentally (via the empty-slot `·`);
  the pinned path dropped the `·`, collapsing column 0 so a populated row rendered
  `ST13fff` with no gap. Gave the label column a fixed min width (pads it in every
  mode, even a full stack) AND restored the `·` in pinned mode — the pinned stack now
  matches the live layout exactly.
- **New feature — empty-state hints on the cache/TLB/Hotspots/Branches tables.** An
  empty table used to render as a large blank void that read as broken/stuck. Each
  now shows a centered, muted explanatory hint when it has zero rows (e.g. "D-cache
  empty — this workload has issued no data loads/stores yet", "TLB empty — paging is
  off or no translations have been resolved yet"), mirroring the Konata view's
  existing "step the core to fill the pipeline view" empty-state. Implemented as a
  click-transparent `_HintTable` overlay that shows/hides on row count, so it never
  interferes with selection once data arrives.

### Iteration 26 — operand field-colouring everywhere, playhead lines behind cells, chip-backed overflow chevron, 9-tab review sweep
Review confirmed the live watermark (`bca2a4e+dirty`) on all 6 critics. Verify
refuted 5 of 6 picks with code-cited reasoning (bytes-truncation = tooltip+resize
preserve full encoding; right-column "dead space" = faithful sparse-cache render +
intrinsic Konata scroll; non-contiguous cache sets = occupancy strip+header+addr
column already signal gaps; sliced last cache row = standard scroll-overflow
clipping; pinned-x87 `pin` = TOP still lives in the status word + `PINNED` badge)
and **confirmed 1** (the overflow chevron). Ground-truthing (zoom + pixel-sample)
verified that one and drove the rest.
- **Fix (CONFIRMED) — overflow `›` chevron no longer muddies the edge cell.** When
  a row's lifecycle ran past the right edge the amber `›` continuation cue rendered
  INSIDE the last cell's right sliver (an unreadable amber-on-blue `F›` collision);
  rows with no cell at the edge placed it cleanly on the dark margin. It now paints
  on a small opaque chip in the row's own bg colour (9px, so it masks only the
  cell's rightmost sliver), so the chevron reads crisply over any cell colour while
  the boundary glyph stays recognisable. Verified by re-zooming ppage's right edge.
- **Fix (carried, ground-truthed) — playhead/Δ lines draw BEHIND the cells.** Iter
  20 moved the playhead column *tint* behind the cells but the cyan playhead LINE
  and amber Δ-anchor LINE were still drawn on top, punching vertical stripes
  through the F/D/X glyphs. Both lines (and the Δ band fill) now draw in the
  behind-cells block; only the `cyc N` / `Δ<n>cyc` labels sit on top. Verified by
  zooming brloop's playhead at cyc 119 — glyphs crisp, no stripe.
- **New feature — operand FIELD-colouring across every disassembly view.** A new
  `disasm.operand_segments` tokeniser colours each operand token by its x86 field —
  immediate=salmon, displacement (inside `[...]`)=gold, branch-target=red-orange,
  registers/brackets neutral — so the decoded operands speak the SAME palette as
  the bytes legend. Wired into the trace instruction column, the Konata gutter, AND
  the Hotspots instruction column (a new reusable `InsnCellDelegate`). A `mov ax,
  0x10` now shows its `0x10` salmon exactly like its immediate byte; `mov dword ptr
  [0x482], 0x500` shows the `[0x482]` gold and the `0x500` salmon. Unit-checked the
  tokeniser + zoom-verified all three views.
- **Review-harness — all-9-tabs sweep.** The review only ever saw the DEFAULT
  (Code$) table tab for 25 iterations; the other 8 (Data$/TLB/Prefetch/Hotspots/
  Branches/Instr-mix/Cycles/Memory) were invisible to every critic. `gen_review_shots`
  now sweeps all 9 tabs for one rich workload (brloop) and writes a watermarked crop
  per tab, closing a long-standing review blind spot (this is exactly how the
  Hotspots colour-inconsistency above surfaced).

### Iteration 25 — colour-coded effect column, latency grading, legible cells
Verify confirmed 1 pick (effect-column colour split). Ground-truthing settled the
recurring stage-board/trace findings and the "U/V is dim grey" claim (they're
already blue/amber).
- **Fix (CONFIRMED) — colour-code the effect column.** `eax=60000011  ZF0  FP:ZE`
  was one flat blue blob. A new `EffectDelegate` now paints register writes
  (`eax=…`) blue, integer flag changes (`ZF1 SF0`) teal, and x87 exception groups
  (`FP:ZE`) amber, so the three write kinds are distinguishable at a glance.
- **New feature — latency badges colour-graded by magnitude.** The Konata gutter's
  per-row `Nc` latency badge is now dim grey for a normal fast op, amber for a
  moderate stall, and red for a heavy one (≥10c) — so the slow instructions pop out
  of the gutter (dmiss's stalled `dec ecx` reads bright-red `11c` against the dim
  `3c` of its loop-mates). Also labelled the column `lat` in the header.
- **Fix (HIGH, recurring) — Konata cell glyphs hard to read.** Bumped the per-cell
  F/D/X/= glyph font 8→9pt (the cells are already CELL_W=20 wide, so 9pt fits with
  padding); the stage letters now read without zooming.

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
