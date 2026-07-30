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

The repeatable acceptance harness is `tools/pipeviz/verify_interactions.py`.
It uses `PySide6.QtTest.QTest` for keyboard and mouse interaction and writes
only temporary ELF/PNG artifacts to its `--out` directory.

## Environment

Review date and timezone: 2026-07-29, America/Detroit.

| component | reviewed version |
|---|---|
| Python | `~/miniconda3/bin/python`, 3.13.14 |
| PySide6 | 6.11.1 |
| Capstone | 5.0.7 |
| Verilator | 5.046 (2026-02-28) |
| starting Pipeviz commit | `4b3f5fe` plus the fixes described below |
| Qt platform for repeatability | `offscreen`, Fusion dark style |
| principal window | 1640×980 |
| compact request | 1280×800; Qt honors the UI minimum as 1446×800 |

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

1. Construct and show a fresh `MainWindow`.
2. Confirm Reset, Clock, Insn, Step N, Run, and event navigation are disabled.
3. Confirm `.`, `R`, `F5`, `Ctrl+O`, and `Ctrl+Shift+O` actions exist.
4. Press F1 through `QTest`.
5. Select “Reading the Pipeline View” from the Help index.
6. Confirm at least six indexed topics and the stage-glyph explanation.

Expected and observed:

- Status says no image is loaded.
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
6. Click a trace row and verify Registers becomes pinned and the timing
   playhead follows.
7. Shift-click an earlier timing row and verify the delta anchor.
8. Click previous/next event controls.
9. Select Hotspots, click its top row, and verify the trace jumps to that PC.
10. Reset, click Run, wait for timer ticks, click Pause, and verify cycles
    advanced and the timer stopped.

Observed evidence:

- 212 instructions retired in 120 clocks.
- 106 U retirements and 106 V retirements; the filter reports 106 V rows.
- Pairing is effectively 100%; four mispredict event cycles are visible.
- Trace, timing selection, pinned registers, Hotspots, and PC navigation agree.

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
5. Open Cycles and require the full cycle sample count.
6. Click Clock and verify pinning clears back to live state.

Observed evidence:

- 263 retirements, including 88 x87 trace rows.
- 421 classified cycle samples.
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
- 484 instructions retired with 92 mispredict event cycles.
- Branches shows 41 distinct sites and both 0% and 100% outcomes in this
  unrolled randomized stream.

Capture: `05_elf_random_branches.png`.

### 6. System boot, paging, TLB, and workload switching

Fixture: `verif/sys/tests/ppage/ppage.bin`, N=1200.

Procedure:

1. Load the BIOS-style raw image and require automatic system mode.
2. Require top-of-1-MiB placement (`load=0x000f0000`).
3. Step 1200 clocks, open TLB, and require actual valid entries.
4. Load the user-mode branch fixture into the same window.
5. Require system/SoC options, trace, accesses, and Memory click pin to reset.

Observed evidence:

- 128 instructions retired; CR0 reached `0xe0000011`.
- 12 Code$ and 8 Data$ lines are resident.
- Six valid I/D TLB entries are displayed, including 4 KiB and large-page
  mappings.
- The expected terminal `S_HALT` is shown as a neutral green “halted” state,
  not a red “stuck” error.
- Switching to the branch image yields a clean user-mode session with no stale
  trace or memory selection.

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
3. Require at least 690 pixels for the linked Trace/timeline column.
4. Require fixed 22-pixel trace rows.

Observed evidence:

- Qt selects 1446×800 from the content minimum.
- The left analysis column remains 700 pixels rather than collapsing to its
  former 573-pixel minimum.
- All ten analysis tabs remain visible at the normal 1640-pixel size.
- The compact trace displays substantially more retirements vertically, while
  retaining readable 9-point text and row selection.

Capture: `08_compact_layout.png`.

### 9. Dual-Fibonacci U/V benefit

Source: `tools/pipeviz/examples/fibonacci_uv.c`.

The harness compiles the same freestanding, two-chain Fibonacci C program and
runs it twice: cycle mode off (U only) and cycle mode on (U/V). It captures
both at cycle 600, then runs to completion and verifies four 32-bit results in
target memory:

```text
0x198c09a0  0x726acb51  0xfe61a042  0x8a587533
```

Observed comparison:

| mode | clocks | retired | IPC | paired |
|---|---:|---:|---:|---:|
| single issue | 2451 | 1130 | 0.461 | 0.0% |
| U/V cycle mode | 1984 | 1133 | 0.571 | 85.3% |

U/V mode computes the same two recurrences in 467 fewer clocks (19.1% lower)
and raises IPC by 23.9%. At cycle 600, the single-issue trace contains only U
rows, while the U/V capture shows adjacent U/V retirements and a denser timing
diagonal.

Captures: `09_fibonacci_single_issue_active.png`,
`09_fibonacci_uv_active.png`.

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
7. Help was limited to a shortcut dialog. The Help menu now opens an indexed
   six-page guide, with a detailed Pipeline View page and examples.
8. Stale SoC detection occurred after dangerous model construction. It now
   occurs before construction.

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
layout, and U/V comparison scenarios pass under the base Miniconda environment.
The two explicit exclusions above remain documented rather than being reported
as tested.
