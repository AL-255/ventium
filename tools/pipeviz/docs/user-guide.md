<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# Pipeline visualizer user guide

Pipeviz is most useful when it answers a concrete performance question.  Load a
program, run far enough to establish a pattern, then use the linked timeline,
trace, analysis tabs, and register history to explain *why* it occurred.

## Start a session

From the repository root, build and launch with a supplied program:

```sh
tools/pipeviz/run.sh build/verify/mb_brloop.cycle.flat
```

`Open…` accepts raw images and little-endian 32-bit x86 ELF files.  For a raw
image, set **entry**, **load**, and **esp** before Reset when its layout differs
from the default.  ELF `PT_LOAD` addresses and its entry point are used
automatically.  Dropping a file on the window does the same thing.

Use **Clock** (`.`) for an individual clock, **Insn** (`I` or Space) for the
next retirement, and **Step N** for a useful analysis window.  `F5` runs and
pauses; `[` and `]` jump among visible stalls, fills, walks, and mispredicts.
Click a trace row or timing cell to pin the registers to that retirement; use
Shift-click on a second timing row to measure the cycle distance.  `F1` lists
all shortcuts.

## Worked examples

All commands below are run from the repository root.  The same examples are
checked by `tools/pipeviz/verify_examples.py`, so documentation and expected
visual evidence stay exercised as the UI evolves.

### 1. Dual issue and branch recovery

```sh
tools/pipeviz/run.sh build/verify/mb_brloop.cycle.flat
```

Step **120 clocks**.  In the status row, look for a high `pair%` and nonzero
`mispred`.  The U/V rows in the timing view form a dense diagonal.  Select a
`jne` row near the bottom: the dependency overlay highlights the EFLAGS
producer, while same-PC highlighting makes repeated loop iterations obvious.
Open **Branches** to compare the branch’s taken rate and BTB result with the
mispredict event markers in the sparkline.  Shift-click two loop iterations to
measure the steady-state iteration cost.

This is the fastest way to distinguish a branch-limited loop from one that is
simply not finding V-pipe pairings.

### 2. D-cache pressure, latency, and address stride

```sh
tools/pipeviz/run.sh build/verify/mb_dmiss.cycle.flat
```

Step **160 clocks**, then jump among events with `]`.  Select a long-latency
load in the timing view: its stretched stall cells and the amber dependency
edge show which consumer was held back.  In **Data$**, inspect the resident
lines and replayed miss-rate.  In **Memory**, choose `→ access` to follow the
most recent load/store and see its bytes outlined in gold.  Finally, open
**Mem map**: this workload’s stride appears as a diagonal scatter; click an
outlier to jump directly to its trace row and pinned architectural state.

Use **Hotspots** after this drill-down to identify the PCs that own the cost,
rather than merely observing that the global IPC fell.

### 3. x87 throughput and architectural results

```sh
tools/pipeviz/run.sh build/verify/mb_fpindep.cycle.flat
```

Step **420 clocks**.  The FP lane on the stage board and purple timing cells
show when x87 work overlaps integer issue.  Click an FP retirement near the
end of the trace.  The Registers panel becomes pinned and displays that
instruction’s post-commit x87 stack, control word, status word, tags, and the
80-bit representation of ST values.  Compare its cycle with adjacent integer
rows in the timeline to see whether the FP pipe is the limiting resource or is
overlapping successfully.

### 4. System boot, translation, and cache warm-up

```sh
tools/pipeviz/run.sh verif/sys/tests/ppage/ppage.bin
```

Pipeviz automatically selects **system** mode for this BIOS-style image.  Step
**240 clocks**.  Watch the status row for fill/walk activity, then inspect the
**TLB** tab and the Code$/Data$ occupancy heatmaps.  The trace uses the live
16/32-bit code-segment mode for disassembly, so it remains readable while the
boot code changes execution mode.  Use the **Cycles** tab to separate page
walk or fill time from ordinary issue/retirement time.

## Reproducible verification

Run the guide’s offscreen checks with the requested Python environment:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python \
  tools/pipeviz/verify_examples.py
```

The script loads each example through the real GUI, advances its documented
clock budget, and asserts that the trace/timing data and the expected cache or
memory evidence are present.  It writes no repository artifacts.  For a broad
visual regression sweep (including all analysis tabs and PNG captures), run:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python \
  tools/pipeviz/gen_review_shots.py /tmp/pipeviz_review
```

The optional `test386` workload needs a current `libventium_viz_soc.so` built
with `tools/pipeviz/build.sh --soc`.  The visual sweep reports and safely skips
an old incompatible SoC library instead of crashing the GUI process.
