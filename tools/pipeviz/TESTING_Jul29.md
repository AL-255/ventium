<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# Pipeviz acceptance review — July 29, 2026

## Purpose

This review exercises Pipeviz as an interactive debugger/performance-analysis
tool, not merely as a Python import or backend ABI smoke test. It drives actual
Qt controls, checks linked views and architectural evidence, and visually
reviews screenshots from complicated workloads.

The repeatable acceptance harnesses are `tools/pipeviz/verify_interactions.py`
and `tools/pipeviz/verify_authoring.py`. They use `PySide6.QtTest.QTest` for
keyboard and mouse interaction; screenshots go to their `--out` directories,
while ignored authoring build products stay in `tools/pipeviz/.generated/`.

## Environment

Review date and timezone: 2026-07-29, America/Detroit.

| component | reviewed version |
|---|---|
| Python | `~/miniconda3/bin/python`, 3.13.14 |
| PySide6 | 6.11.1 |
| Capstone | 5.0.7 |
| Verilator | 5.046 (2026-02-28) |
| continuation baseline | `11a1afb` plus the authoring/timeline changes below |
| Qt platform for repeatability | `offscreen`, Fusion dark style |
| principal window | 1640×980 |
| compact request | 1280×800; honored exactly with responsive register pages |

The offscreen Qt plugin prints `This plugin does not support
propagateSizeHints()` and, when opening Help, `does not support raise()`. These
messages are limitations of the headless platform plugin; widget geometry,
events, rendering, and captures still complete successfully.

## Commands

Run from the repository root:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python -u \
  tools/pipeviz/verify_interactions.py \
  --out /tmp/pipeviz_interactions_jul29
```

Run the documented workload contracts independently:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python -u \
  tools/pipeviz/verify_examples.py
```

Run the complete Assembly/C authoring path:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python -u \
  tools/pipeviz/verify_authoring.py \
  --out /tmp/pipeviz_authoring_jul29
```

Run the broad per-tab visual capture sweep:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python -u \
  tools/pipeviz/gen_review_shots.py /tmp/pipeviz_review_jul29
```

Static checks used at the end of the review:

```sh
~/miniconda3/bin/python -m compileall -q tools/pipeviz
~/miniconda3/bin/python -m pip check
git diff --check -- tools/pipeviz
```

## Interactive scenarios and evidence

### 1. Empty startup, Help, and control honesty

Procedure:

1. Verify explicit-image, explicit-snapshot, and no-argument demo startup
   resolution are mutually distinct (a snapshot never falls through to a demo).
2. Construct and show a fresh `MainWindow`.
3. Inject a backend-construction failure and require the existing live handle
   to survive with an actionable error.
4. Confirm Reset, Clock, Insn, Step N, Run, and event navigation are disabled.
5. Confirm Pipeline, IPC history, Trace, Registers, caches, Prefetch, Cycles, Memory, and Mem map
   explicitly say that no program is loaded; Memory navigation is disabled.
6. Confirm `.`, `R`, `F5`, `Ctrl+O`, `Ctrl+Shift+O`, `Ctrl+Shift+R`,
   `Ctrl+0`, `Alt+V/A/C`, `Alt+1…0`, and the File/View/Help menus exist.
7. Switch analysis tabs with the Alt shortcuts and focus Trace search with `/`
   while another pane owns focus.
8. Press F1 through `QTest`.
9. Select “Reading the Pipeline View” from the Help index.
10. Confirm at least eight indexed topics, dedicated loading and Assembly/C
    help, and the stage-glyph explanation.
11. Load a temporary flat image whose manifest mixes a JSON integer entry with
    a hexadecimal-string load address; verify EIP, bytes, and displayed fields.
12. Require empty files and MZ `.exe` inputs to fail with actionable errors,
    while the Open filter advertises `.rom` and no unsupported generic `.exe`.
13. Feed synthetic streams beyond the per-read/view caps and require Pipeline,
    IPC, Cycles, and Trace to reach the newest sample, label bounded history,
    and preserve predecessor-derived Trace state.
14. Require bounded-history status to use a captured U+V denominator and label
    `pair(win)`/`mispred(win)` while retaining lifetime retirement/IPC.
15. Run a real six-byte loop for 9,000 clocks in one refresh and require backend,
    Pipeline, IPC, Cycles, and newest-6,000 Trace endpoints to agree.

Expected and observed:

- Status says no image is loaded.
- Every data pane distinguishes unloaded state from sampled zero/empty state.
- Disabled Run is visibly gray rather than looking executable.
- F1 opens the indexed user guide.
- The Pipeline page explains axes, U/V pairs, F/L/D/X/M/W/=/!/S glyphs,
  dependencies, playhead/anchor measurement, and four worked examples.

Captures: `00_startup.png`, `00_help_pipeline_guide.png`.

### 2. Branch loop, transport controls, filters, and linked navigation

Fixture: `build/verify/mb_brloop.cycle.flat`.

Procedure:

1. Click Clock and verify exactly one core cycle advances.
2. Click Insn and verify at least one new retirement.
3. Click Reset and verify retirement history clears.
4. Set N=120 and click Step N.
5. Type `pipe:V` into the Trace filter and verify the visible row count.
6. Navigate matches with Enter/F3 and Shift+F3, reject a zero-match query
   visibly, clear with Escape, and focus/select the query with `/`.
7. Enter an invalid reset address and require a visible warning without
   replacing the running backend.
8. Toggle U/V mode and require **Apply + Reset**.
9. Click a trace row and verify Registers becomes pinned and the timing
   playhead follows.
10. Shift-click an earlier timing row and verify the delta anchor.
11. Click previous/next event controls.
12. Select Hotspots, activate its top row with Enter, and verify the trace
    jumps to that PC.
13. Reload from disk and require the custom ESP/reset configuration to survive.
14. Attempt reload with an invalid preserved entry and require the active
    backend, retirements, and Trace to remain unchanged.
15. Attempt a flat placement that crosses 4 GiB and require rejection before
    the active backend is closed.
16. Reset, click Run, wait for timer ticks, click Pause, and verify cycles
    advanced and the timer stopped.

Observed evidence:

- 212 instructions retired in 120 clocks.
- 106 U retirements and 106 V retirements; the filter reports 106 V rows.
- Pairing is effectively 100%; four mispredict event cycles are visible.
- Trace, timing selection, pinned registers, Hotspots, and PC navigation agree.
- Invalid addresses are rejected before model replacement; filter navigation
  wraps deterministically; reload preserves reset configuration.

Capture: `01_branch_transport.png`.

### 3. D-cache pressure and memory drill-down

Fixture: `build/verify/mb_dmiss.cycle.flat`, N=160.

Procedure:

1. Step 160 clocks.
2. Filter by `stall`, then by `@` (resolved memory access).
3. Open Data$ and inspect residency plus replayed miss reporting.
4. Open Memory and click `→access`.
5. Open Mem map and click a midpoint in the plotted stride.
6. Verify the point selects the matching trace retirement, pins Registers, and
   pins the exact accessed bytes in Memory.

Observed evidence:

- 57 retirements, 14 Data$ lines, 14 resolved accesses, 15 stall-tagged trace
  rows.
- Mem map reports a `+0x20` dominant stride at 100%, matching the 32-byte cache
  line walk.
- The clicked map point selected retirement 31 at address `0x080490e0`; the
  Trace, playhead, Registers, and Memory highlight all moved together.

Captures: `02_dcache_memory_follow.png`,
`03_dcache_memmap_drilldown.png`.

### 4. x87 pipeline and post-retirement state

Fixture: `build/verify/mb_fpindep.cycle.flat`, N=420.

Procedure:

1. Step 420 clocks.
2. Locate and click an `fadd` retirement.
3. Verify the timing data contains FP instructions and the register panel shows
   a pinned x87 control/status/tag and logical stack.
4. Open Instr mix and require the FP class.
5. Compare the full default RTL `state_e` order with the C ABI state names.
   Require every state to have nonempty lane/stage/description metadata, every
   non-reset state to produce an occupied live-board cell, and no active state
   to inherit halt styling. Open Cycles, require the full sample count, nonzero
   retire/I-fill cycles, and zero false halt cycles.
6. Click Clock and verify pinning clears back to live state.

Observed evidence:

- 263 retirements, including 88 x87 trace rows.
- 421 classified cycle samples.
- At the 420-clock capture, Cycles now attributes 155 I-fill, 154 retire, and
  111 issue-stall clocks with zero halt clocks; the former stale name table
  incorrectly reported 265 halt clocks.
- Pinned retirement 251 shows `st0=84`, x87 status `0x3000`, and the 80-bit
  stack representation.

Capture: `04_x87_pinned.png`.

### 5. Multi-segment ELF and random branches

Fixture: `build/verify/mb_brrandom.cycle.elf`, N=800.

Procedure:

1. Load the ELF rather than the flat image.
2. Require multiple `PT_LOAD` segments, automatic entry `0x08048000`, and a
   disabled raw load-address field.
3. Step 800 clocks and open Branches.
4. Require many independent branch sites with both taken and not-taken outcomes.

Observed evidence:

- Two ELF load segments were applied.
- 484 instructions retired with 71 real `S_PIPE` mispredict-bubble cycles.
- Branches shows 41 distinct sites and both 0% and 100% outcomes in this
  unrolled randomized stream.

Capture: `05_elf_random_branches.png`.

### 6. System boot, paging, TLB, and workload switching

Fixture: `verif/sys/tests/ppage/ppage.bin`, N=1200.

Procedure:

1. Load the BIOS-style raw image and require automatic system mode.
2. Require entry/load/ESP to be disabled with reset-vector/placement tooltips.
3. Require top-of-1-MiB placement (`load=0x000f0000`).
4. Step 1200 clocks, open TLB, and require actual valid entries.
5. Load the user-mode branch fixture into the same window.
6. Require system/SoC options, trace filter, accesses, and Memory click pin to
   reset; Memory must begin by following the new program's EIP.

Observed evidence:

- 128 instructions retired; CR0 reached `0xe0000011`.
- 12 Code$ and 8 Data$ lines are resident.
- Six valid I/D TLB entries are displayed, including 4 KiB and large-page
  mappings.
- The expected terminal `S_HALT` is shown as a neutral green “halted” state,
  not a red “stuck” error.
- Switching to the branch image yields a clean user-mode session with no stale
  trace filter or memory selection/address.

Capture: `06_system_paging.png`.

### 7. Stale SoC library recovery

Fixture:
`ventium-refs/09-external-cpu-tests/test386.asm/test386.bin`.

The installed `libventium_viz_soc.so` predates the current snapshot/replay ABI.
Before this review, Pipeviz instantiated it before checking compatibility; its
constructor/destructor could abort the entire process.

Procedure:

1. Load test386 and automatically dismiss the modal warning after recording it.
2. Require the warning title `SoC model missing`.
3. Require SoC to turn off, safe core/system fallback to remain loaded, and
   transport controls to stay usable.

Observed evidence: the warning/fallback completes without a native abort.
Compatibility is now checked from the shared-library symbols before
`vv_create`.

Capture: `07_stale_soc_safe_fallback.png`.

### 8. Compact layout and dense trace

Fixture: D-cache miss workload after 160 clocks.

Procedure:

1. Request 1280×800.
2. Verify every major panel remains within window bounds and at usable size.
3. Require at least 690 pixels for the linked Trace/timeline column and at
   least 570 pixels for analysis.
4. Require fixed 22-pixel trace rows, no toolbar/tab overflow, intact status
   metrics, and a responsive trace profile that keeps at least 180 pixels for
   disassembly while compacting bytes/effects to 104/150 pixels.
5. Select compact x87, widen to the three-column register view, narrow again,
   and require x87 to remain selected.

Observed evidence:

- Qt honors exactly 1280×800.
- The left analysis column remains 700 pixels and the right analysis column
  remains 576 pixels.
- All ten analysis tabs and all toolbar controls remain directly visible.
- Registers switch to non-clipping Integer/Segments/x87 pages when the right
  pane cannot fit all columns, then return to three simultaneous columns when widened.
- The compact trace displays substantially more retirements vertically, while
  retaining readable 9-point text and row selection.

Capture: `08_compact_layout.png`.

### 9. Dual-Fibonacci U/V benefit

Source: `tools/pipeviz/examples/fibonacci_uv.c`.

The harness compiles the same freestanding, two-chain Fibonacci C program and
runs it twice: U/V issue off (U only) and U/V issue on. It captures
both at cycle 600, then runs to completion and verifies four 32-bit results in
target memory:

```text
0x198c09a0  0x726acb51  0xfe61a042  0x8a587533
```

Observed comparison:

| mode | clocks | retired | IPC | paired |
|---|---:|---:|---:|---:|
| single issue | 2451 | 1130 | 0.461 | 0.0% |
| U/V issue | 1984 | 1133 | 0.571 | 85.3% |

U/V mode computes the same two recurrences in 467 fewer clocks (19.1% lower)
and raises IPC by 23.9%. At cycle 600, the single-issue trace contains only U
rows, while the U/V capture shows adjacent U/V retirements and a denser timing
diagonal.

Captures: `09_fibonacci_single_issue_active.png`,
`09_fibonacci_uv_active.png`.

### 10. Assembly/C authoring and exact source linkage

Procedure:

1. Require at least 250 unique Ventium/P54C completion mnemonics, map every
   current RTL decoder family to an advertised entry, and check representative
   integer, system, x87, mode-gated, and build-gated families. Require every
   entry to have a signature, description, availability, latency, pairing
   class, and a stage sequence drawable by the popup pipeline preview.
2. Render the Assembly editor and verify mnemonic/register syntax formats,
   including comment markers inside quoted data versus a real trailing comment,
   and require labels/directives named like registers/opcodes to retain their
   structural colors.
   Type every single-key debugger binding as source, require an `Assembly *`
   dirty marker, then require contextual Ctrl+O and Ctrl+S to open/save source.
   Open Ctrl+F, require two highlighted `mov` matches, traverse both, and close
   the bar with Escape. Require Enter after an assembly label and a C opening
   brace to preserve and advance indentation.
   Attempt to open invalid UTF-8 Assembly and C files; require a diagnostic,
   unchanged editor text, and a recoverable neutral state after New.
   Open UTF-8-BOM source without exposing the BOM in the editor, and require an
   empty Assembly build to report an actionable empty-source diagnostic.
   Cancel the file chooser with dirty source and require no discard prompt.
   Drop `.S` and `.c` files and require routing to their source workspaces
   without loading either as executable bytes or replacing the active backend.
   Point the artifact directory at a regular file and require a normal
   `BuildFailure` diagnostic with no backend session or raw Python exception.
3. Open the complete Ctrl+Space popup; require its description, availability,
   latency, pairing class, and pipeline stage preview. Confirm automatic
   completion appears in opcode position but never interrupts operands/comments;
   require the owned popup frame to stay inside the active screen, and require
   forced completion on a directive to remain reference-only. Accept a
   completion mid-opcode and require the whole token—not only its prefix—to be
   replaced. Complete a second opcode after GNU as's `;` statement separator
   and require the preview to follow that statement.
4. Feed an invalid opcode and require line 5 to be highlighted without starting
   a backend session. Edit it and require the now-stale marker/diagnostics to
   clear immediately and return to neutral styling.
5. Assemble+run the default sum loop and require EAX = 55 on the real RTL.
   Keep the source unsaved and require `Assembly *` to survive loading/running.
   Cancel a Quit while free-running and require the timer/run state to resume.
6. After the initial I-fill, hover and click the live occupied U and V stage
   cells; require distinct pre-retirement PCs to mark their exact Assembly
   lines while Visualizer keeps focus. Then select authored Trace and Konata
   rows and require exact retired PC→line highlighting, including distinct U/V
   rows retiring on one cycle. In every path the composed
   `Assembly * · L…` label retains both states. At completion, require HLT to
   remain a visible, clickable live cell linked to the authored `hlt` line.
7. Reject a candidate replacement load and require the prior live backend,
   program bytes, source map, marker, and tab label to remain coherent. Then edit
   after build and require the map to become stale rather than use obsolete PCs.
   Cancel generated-source replacement and require the dirty text to survive.
   Run a bare snippet and require selecting its generated fall-through HLT to
   clear—not retain—the previously linked editor line.
8. Verify C keyword/function priority (including `if (`), quoted comment markers, multiline
   comments, and compiler error-line navigation. Editing a compiler error must
   clear its stale line marker and red diagnostics state immediately.
   Confirm unsaved edits mark `C *`, Cancel preserves them, and explicit Discard
   permits a new template and clears the marker.
9. Compile the freestanding Fibonacci C template at O2 into editable Intel
   assembly, assemble+run it, and require EAX = 144.
10. Select the C-generated entry/loop in Trace and require its emitted assembly
    line to highlight.
11. Compile an array-initialization loop and require self-contained assembly
    with no implicit `memset` call. Require an implicit function call to fail
    at its C source line instead of becoming a later unresolved linker error.
12. Compile a floating-point C example and require Pentium x87—not SSE—
    assembly, assemble+run it on the RTL to EAX = 3, and require its selected
    in-flight instruction to highlight the exact generated assembly line.

Evidence: GNU as/ld produces an ELF32 at `0x08048000`; DWARF decoded-line data
maps every checked PC to the editor. The completion catalogue contains 291
unique mnemonics and excludes SSE/MMX/later-x86 examples. Both authored programs
reach HLT with the expected result.

Captures: `00_assembly_workbench.png`, `00a_assembly_compact.png`,
`00b_assembly_find.png`,
`01_opcode_completion_popup.png`,
`02_assembly_source_link.png`, `02a_live_uv_source_link.png`,
`02b_terminal_hlt_source_link.png`,
`03_c_workbench.png`,
`04_c_generated_assembly.png`, `05_c_run_source_link.png`,
`06_c_x87_source_link.png`.

## Visual review findings and changes made

The screenshot review found and corrected the following:

1. Disabled Run retained its bright green enabled appearance. It now has an
   explicit disabled style.
2. QSplitter resizing collapsed the Trace/timeline pane and gave unused width
   to the right pane. The outer split now starts at 900:740 and preserves a
   700-pixel left minimum.
3. Ten analysis tabs overflowed at the normal size because the right pane
   initially received only 40%. The corrected initial allocation displays all
   tabs.
4. Normal system-test `S_HALT` was rendered as a red “stuck” failure. It is now
   rendered as a neutral successful halt; genuine fetch/decode/F00F stalls
   retain the red diagnostic.
5. The guide previously requested only 240 paging clocks, which showed two
   walk events but zero valid TLB entries. The documented and verified budget
   is now 1200 clocks and requires valid translations.
6. The retired trace used the Qt default row height. It now uses fixed compact
   22-pixel rows.
   Its fixed wide byte/effect columns also squeezed compact disassembly into a
   sliver; the 1280-pixel profile now preserves a readable stretched
   instruction column while full width retains the detailed columns.
7. The bridge state-name table omitted unconditional RTL FSM members, shifting
   `S_PF`/`S_PIPE` into `S_PIPE`/`S_F00F_HANG` and making the x87 capture look
   63% halted. All 48 default states now match `state_e`; the regression parses
   and compares the complete enum before checking cycle attribution. A follow-up
   found nine of those states absent from the UI stage metadata, where the
   fallback also used the halt color; all 48 now render nonblank, categorized
   live cells and unknown future states fall back to system work, not halt.
   The terminal capture then exposed a latched bubble counter being counted
   through 256 HLT clocks; hazard events are now gated to `S_PIPE`, reducing the
   random-branch fixture from 92 to 71 real mispredict cycles and leaving the
   halted tail event-free.
8. Help was limited to a shortcut dialog. The Help menu now opens an indexed
   guide with dedicated loading, Pipeline View, and Assembly/C pages.
9. Stale SoC detection occurred after dangerous model construction. It now
   occurs before construction.
10. Register/table content hints forced the loaded window to 1446 pixels.
   Registers now switch to indexed pages and analysis can shrink safely.
11. The trace filter lacked traversal and weakly signaled empty results. It now
    has keyboard/button navigation and visible zero-match feedback.
12. New programs inherited stale Memory addresses and active trace filters.
    Program/snapshot starts now clear the query and follow their own EIP.
13. Reset-time modes and addresses could diverge silently from the running
    backend. The button now becomes **Apply + Reset**, and malformed addresses
    are rejected visibly.
14. Visual/smoke scripts resolved fixtures from the process working directory.
    They now use repository-relative paths and run from any directory.

## Coverage limits

- A current SoC build is unavailable because this checkout has no
  `rtl/ventium_soc.f`; therefore actual SoC port-I/O/PIC/PIT execution is not
  claimed. The incompatible-library recovery path is tested.
- No matching `.aux`/`.vlt` snapshot fixture exists in the checkout, so this
  run does not claim end-to-end snapshot restore coverage. Snapshot parsing and
  restore had separate backend coverage when the feature was introduced.
- Native desktop file-picker chrome and OS drag delivery are not represented by
  Qt’s offscreen plugin. Program loading itself is covered with raw, system, and
  multi-segment ELF inputs; keyboard/menu and internal drop-routing code remain
  in scope of static review.
- Screenshots under `/tmp` are review artifacts and are intentionally not
  committed.

## Acceptance result

The core, GUI control, linked-navigation, workload-analysis, Help, compact
layout, U/V comparison, Assembly→RTL, and C→Assembly→RTL scenarios pass under
the base Miniconda environment. The explicit exclusions above remain documented
rather than being reported as tested.
