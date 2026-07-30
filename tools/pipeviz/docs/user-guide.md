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

The launcher uses `python3` by default. To use a particular environment:

```sh
PIPEVIZ_PYTHON="$HOME/miniconda3/bin/python" \
  tools/pipeviz/run.sh build/verify/mb_brloop.cycle.flat
```

If PySide6 or Capstone is missing, the launcher prints the exact
`pip install -r tools/pipeviz/requirements.txt` command before exiting and
before spending time on a backend build.

The launcher also rebuilds when the bridge/ctypes ABI, RTL sources, file
lists/includes, or memory BFM is newer than the ignored backend. Run
`tools/pipeviz/run.sh --check` for a non-mutating readiness report that names a
stale input without building or opening the GUI.
Add `--soc` to check both native variants. `run.sh --build --soc` builds the SoC
variant and also launches the GUI in SoC mode; a missing SoC RTL file list is
reported explicitly instead of treating an old library as ready.
`run.sh --help` is also non-building: it checks Python imports, then prints
usage without requiring a backend.

`Open…` accepts raw `.flat`/`.bin`/`.img`/`.rom` images and little-endian
32-bit x86 ELF files. Empty files and DOS/PE executables are rejected with a
clear format error. For a raw
image, set **entry**, **load**, and **esp** before Reset when its layout differs
from the default.  ELF `PT_LOAD` addresses and its entry point are used
automatically.  Dropping a file on the window does the same thing.
A flat image may use a sibling `manifest.json`; its `entry` and `load_addr`
accept either JSON integers or `0x…` strings. It can fully describe a
repeatable launch:

```json
{
  "entry": "0x00100000",
  "load_addr": "0x00100000",
  "esp": "0x001ff000",
  "uv_issue": true,
  "system": false,
  "soc": false
}
```

Mode values must be JSON booleans; `soc: true` implies system boot and cannot
be combined with `system: false`. A malformed manifest is ignored as one unit,
so a valid early field cannot leak out of a later error. A new program without
`esp` starts from Pipeviz's default stack instead of inheriting the previous
program's custom value. The `.bin` suffix alone never forces BIOS boot; set
`system: true`, use `--system`, or toggle **system** explicitly.
**Open snapshot…** accepts a matching host-testbench `.aux`/`.vlt` pair. The
architectural clock remains absolute, but Trace retirement IDs, IPC, Pipeline,
sparkline, and Cycles attribution begin a fresh visible epoch at the restore
point because the checkpoint does not contain earlier visual history.
Use **File → Open example** to load an available verification workload without
locating its build path. The menu rescans whenever it opens, so an example built
after pipeviz starts becomes available immediately. After recompiling the
current program,
**Ctrl+Shift+R** re-reads it from disk while preserving the displayed reset
addresses and mode switches.
Changing entry/load/ESP or a mode switch marks the control **Apply + Reset**;
the running backend is unchanged until you apply it. If you change the setup
back to the values already running, the amber warning clears without resetting.
Invalid addresses are
highlighted and rejected instead of silently falling back to a default;
reload also leaves the current session intact until its preserved setup
validates.
System boot disables entry/load/ESP because the architectural reset vector,
BIOS top-alignment, and firmware stack setup determine those values.
If a requested SoC model is unavailable, Pipeviz warns and uses the core model.
The checkbox changes only after that fallback is constructed; if both
constructions fail, the old live session and its requested mode remain intact.

Use **Clock** (`.`) for an individual clock, **Insn** (`I` or Space) for the
next retirement, and **Step N** for a useful analysis window.  `F5` runs and
pauses. Choose an event class (any, mispredict, stall, I-fill, or page-walk);
`[` and `]` jump among only those visible events.
The upper U/V/FP stage board is live: hover an occupied cell to see its lane and
PC, then click it to highlight that in-flight instruction's linked Assembly
line. The Visualizer remains in place and the Assembly tab gains `L…`; use
`Alt+A` to inspect the marked line. `[paired]` means U and V are issuing
together now; `[blocked]` means a legal candidate is currently held by a
hazard, and the grey `stall · …` cell names the held instruction (not
necessarily the older instruction or memory request causing the hazard).
Click a retired Trace row or timing cell to
additionally pin the registers to that retirement; use Shift-click on a second
timing row to measure the cycle distance. Trace-to-timing selection follows the
retirement ID rather than only the cycle, so the exact U or V row remains
selected when a pair commits together. `F1` lists all shortcuts.
In a pinned register view, GPRs, EFLAGS, segment selectors, and x87 are the
post-commit state. `PC*`, segment `base*`, and CR0/CR3/CR4 are starred because
they are the pre-execution instruction/translation context used to find the
linked bytes. Segment limits and CR2 read `n/a` because the retirement record
does not capture them; hover a starred heading or value for the time-point
explanation. Control / mode shows the captured pre-execution USER/SYS, CPL, and
SMM state rather than duplicating the pin banner. The page-independent strip
above the register bank always says
**LIVE** or **PINNED n=… · retire cyc=…**. Check it before interpreting values,
especially in compact mode where the Segments page may not be open. Click its
**Unpin** button to return to the current live state and clear the cycle
playhead without advancing the model. It also clears the selected Trace/timing
row, dependency edges, PC-group shading, and Assembly line marker while keeping
the source map ready for the next selection. A Mem-map-originated pin also
clears its selected point and the clicked-byte Memory highlight; stepping also
unpins automatically.

In x87, `empty=xx` is a logical ST mask: bit *i*=1 means ST(*i*) is empty.
Pinned values are labeled `logical` because the retirement record already
rotates the physical stack by TOP; hover the header or an ST row for the exact
interpretation. The current bridge records this snapshot on every retirement,
including integer instructions. If a partial or older backend record lacks one,
its pinned x87 page says `n/a` instead of preserving unrelated live or prior
values. Unpin returns to the current live stack.

The timing diagram itself is keyboard accessible: Up/Down selects adjacent
retirements, Page Up/Page Down moves ten rows, and Home/End reaches the capture
edges. `Ctrl+-` and `Ctrl+=` zoom the cycle axis around the selected cycle.
Its mnemonic and producer/consumer analysis use the bytes captured with each
retirement, not a later read through the current memory map. This keeps old rows
faithful across self-modifying code and segment/page-table transitions.

The register bank automatically changes from three simultaneous columns to
indexed **Integer / Segments / x87** pages when the right pane becomes narrow.
The LIVE/PINNED strip remains visible while switching pages, and the selected
page survives a wide/compact transition. This keeps every value readable and
its time point explicit at 1280×800. **View → Reset panel layout**
(`Ctrl+0`) restores the recommended proportions after exploratory resizing.
`Alt+1` through `Alt+0` jump directly among Code$, Data$, TLB, Prefetch,
Hotspots, Branches, Mix, Cycles, Memory, and Mem map.

Trace filters are space-separated AND terms: free text plus exact-field
`pc:08048`, retirement `n>=100` / `n<=200` / `n=150`, cycle
`cyc>=133`, `pipe:U` / `pipe:V`, `stall`, and `@` for memory accesses.
The gold `@…` value is the instruction’s effective offset—the same address
domain used by the timing D-cache. Memory drill-down separately retains its
segment-linear and translated physical address.
Use `/` from anywhere, then Enter/F3, Shift+F3, and Escape to focus, traverse,
and clear results. With the Pipeline diagram focused and the filter already
empty, Escape instead returns a pinned retirement to LIVE without advancing.
If you only inspected a filter, clearing it restores the
newest live rows; if you selected a result, that historical context remains.
Malformed structured terms (for example `n>200` or `pc:xyz`) turn red, explain
the accepted syntax on hover, and leave the trace visible while you correct
them; a valid free-text query with no hits still shows an ordinary zero-result
state.
Hotspots and Branches rows activate with Enter as well as the mouse.
Large steps remain bounded and honest: Trace labels its newest 6,000
retirements, Pipeline labels its newest 50,000-cycle window, and the compact
IPC strip retains the newest 12,000 cycles.
**Cycles** classifies every captured clock exactly once. **front end** combines
fetch/decode, while **slow path** combines the integer execute, load/store,
string, and I/O micro-operation states; neither label pretends `S_EXEC` is
always a memory access.

## Write and run an assembly experiment

Select the **Assembly** workspace (`Alt+A`). The initial GNU Intel-syntax
template is immediately runnable. Workspace shortcuts also place keyboard focus
where it is useful: `Alt+A` in Assembly, `Alt+C` in C, and `Alt+V` on the
Pipeline timing diagram.

```asm
.intel_syntax noprefix
.section .text
.global _start
_start:
    mov eax, 0
    mov ecx, 10
.sum:
    add eax, ecx
    dec ecx
    jnz .sum
    hlt
```

**Assemble** checks and links the source; **Assemble + Run** (`Ctrl+Enter`)
also loads the resulting ELF into the Visualizer. Diagnostics name and
highlight the failing line. `Ctrl+Space` opens completion over the complete
Ventium/P54C mnemonic catalogue. Selecting an entry shows its operand form,
description, mode/build availability, approximate latency, pairing class
(`UV`, `PU`, `PV`, `NP`, `FP`, or `SYS`), and a miniature stage diagram.
At a directive, comment, or operand it remains a reference-only catalogue, so
accepting an entry cannot corrupt non-opcode text.
GNU as semicolons separate statements, so completion and the instruction
preview also follow a second opcode on the same source line. Statement scanning
respects quoted data: a semicolon or `#`/`//` inside `.asciz "…"` is never
mistaken for a separator or comment.
Enter preserves the current indentation and advances one level after an
assembly label or C opening brace. Typing a closing C brace on an otherwise
blank indented line dedents one level first.
A bare list of instructions is also accepted: pipeviz supplies Intel-syntax,
`_start`, and a fall-through HLT boilerplate. A source that declares its own
`_start:` remains exact.

`Ctrl+O` opens Assembly source and `Ctrl+S` saves it; the corresponding buttons
remain available for mouse use. The Assembly tab gains `*` while changes are
unsaved. In the C workspace the same shortcuts open/save C, and its tab uses the
same dirty marker. When the typed-file filter is selected, a bare Save As name
receives `.s` or `.c` automatically. A successful save clears the dirty marker
and reports the final on-disk filename in both the workbench and global action
row. Opening likewise identifies the real filename—an Assembly file is never
mislabelled as compiler-generated—and clears any obsolete PC map before the
new source can be linked. Visualizer restores Ctrl+O to opening executable programs.
Dropping `.s`/`.S`/`.asm` or `.c`/`.h` routes the file to its source workspace;
it is never mistaken for a raw executable.
Each workbench remembers its most recent source folder for later Open/Save As
dialogs, including after starting a new template.
New/Open, generated C-to-Assembly replacement, and application close never
silently discard a dirty editor: choose Save, Discard, or Cancel.
For longer generated files, `Ctrl+F` opens an inline search with highlighted
matches and a current/total counter. Enter/F3 advances, Shift+Enter/Shift+F3
moves backward, and Escape closes it.

The assembler emits a DWARF line table. After running, click any occupied live
U/V/FP stage cell, authored Trace row, or Pipeline timing row: the Assembly tab
becomes **Assembly · L…** and that exact source line is highlighted. Live U and
V issue slots and U/V retirements sharing a cycle retain separate line
identities. Live-cell navigation does not require the instruction to have
retired, and it does not steal focus from the Visualizer. Editing the source
invalidates the old map until it is assembled again, so a stale build cannot
highlight the wrong line. A terminal HLT remains visible and clickable after
the run stops, which makes the experiment's exact stopping instruction clear.
When the current built source has not been saved, both states remain visible as
**Assembly * · L…** rather than one label hiding the other.
Instructions synthesized outside the editor, such as a bare snippet's
fall-through HLT, explicitly clear the prior line marker instead of leaving a
stale source association.

GNU `as`, `ld`, and `objdump` must be available in `PATH`. Generated source,
object, and ELF files stay in `tools/pipeviz/.generated/`, which Git ignores.

## Compile C into editable assembly

Select **C** (`Alt+C`) and write a freestanding `int main(void)`. Standard
library calls and hosted headers are intentionally unavailable; the point is a
small, inspectable microarchitecture experiment. Choose `-O0`, `-O1`, `-O2`,
or `-Os`, then press **Compile → Assembly** (`Ctrl+Enter`). Pipeviz invokes:

- GCC's 32-bit Pentium target;
- Intel assembly syntax with SSE/MMX excluded by the P5 target;
- GNU C11, freestanding, non-PIE, stack-protector-free code;
- no builtin calls or loop-to-`memset` substitutions, so generated snippets
  remain self-contained;
- line-linked errors for implicit function calls rather than deferred link
  failures, including fatal errors such as a missing header; and
- a tiny `_start` wrapper that calls `main` and halts.

The generated source opens in Assembly rather than running immediately. This
lets you compare optimization levels, edit scheduling or register choices,
inspect completion previews, and only then assemble and run it. Compiler errors
remain in C and highlight their responsible line; assembler errors remain in
Assembly. Build/compiler diagnostics belong to the exact source revision that
produced them: editing either source clears the prior result, and changing C's
optimization level clears the old compiler result and prompts you to compile
again.

Run the dedicated regression for the entire authoring path:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python \
  tools/pipeviz/verify_authoring.py
```

It verifies the 291-mnemonic catalogue against every current RTL decoder family,
syntax highlighting, opcode-scoped completion and its description/pipeline
preview, compact layout, transactional load failure, build errors, ELF/DWARF
mapping, exact live and retired U/V source identity, a hand-written assembly result, and
C → assembly → RTL execution. It also compiles an array loop without hidden
library calls and runs floating-point C through generated x87 assembly on the
RTL, verifying EAX = 3 and exact assembly-line navigation.

## Worked examples

All commands below are run from the repository root.  The supplied fixture
examples are checked by `tools/pipeviz/verify_examples.py`; the compiled
dual-Fibonacci comparison and GUI interactions are checked by
`tools/pipeviz/verify_interactions.py`.

### 1. U–V advantage with dual Fibonacci

`examples/fibonacci_uv.c` is a freestanding C program containing two independent
Fibonacci recurrences. Build it and open the resulting ELF:

```sh
gcc -m32 -march=pentium -O2 -ffreestanding -fno-pic -fno-pie \
  -fno-stack-protector -nostdlib -static -Wl,--build-id=none \
  -Wl,-Ttext=0x08048000 -Wl,-e,_start -DDUAL=1 \
  -o /tmp/fibonacci_dual.elf tools/pipeviz/examples/fibonacci_uv.c
tools/pipeviz/run.sh /tmp/fibonacci_dual.elf
```

First untick **U/V issue**, apply/reset, and advance 600 clocks: every retirement
is in the U lane. Then tick **U/V issue**, apply/reset, and advance the same
amount: the Trace and timing diagram show adjacent arithmetic in U/V pairs. Continue each run to
completion to compare the status line. In the July 29 acceptance run, the same
two-chain result took 2,451 clocks at 0.461 IPC without U–V issue and 1,984
clocks at 0.571 IPC with it; 85.3% of the instructions were paired. The
interactive regression verifies both the computed Fibonacci values and a
minimum 20% IPC advantage:

```sh
QT_QPA_PLATFORM=offscreen ~/miniconda3/bin/python \
  tools/pipeviz/verify_interactions.py
```

### 2. Dual issue and branch recovery

```sh
tools/pipeviz/run.sh build/verify/mb_brloop.cycle.flat
```

Step **120 clocks**.  In the status row, look for a high `pair%` and nonzero
`mispred`.  The U/V rows in the timing view form a dense diagonal.  Select a
`jne` row near the bottom: the dependency overlay highlights the EFLAGS
producer, while same-PC highlighting makes repeated loop iterations obvious.
Open **Branches** to compare the branch’s resolved taken rate and bias with the
mispredict event markers in the sparkline. A branch at the capture tail has no
next retired PC yet, so it remains a hit but is excluded from the taken-rate
denominator. Shift-click two loop iterations to measure the steady-state
iteration cost.

This is the fastest way to distinguish a branch-limited loop from one that is
simply not finding V-pipe pairings.

### 3. D-cache pressure, latency, and address stride

```sh
tools/pipeviz/run.sh build/verify/mb_dmiss.cycle.flat
```

Step **160 clocks**, then jump among events with `]`.  Select a long-latency
load in the timing view: its stretched stall cells and the amber dependency
edge show which consumer was held back.  In **Data$**, inspect the resident
lines and replayed miss-rate. The bracketed origin says whether replay
started `[empty]` or was `[seed N]` from the resident tags and MRU order of a
restored snapshot; hover it for hit/cold/conflict totals. This prevents the
visualization boundary from looking like a cold cache. In **Memory**, choose
`→ access` to follow the most recent load/store
and see its physical bytes outlined in gold. Pipeviz resolves the retired
instruction’s effective offset through its pre-execution segment base and
legacy 4 KiB/4 MiB page tables; `→ EIP` and `→ ESP` do the same for the live
state. Page Up/Page Down (or the adjacent arrows) moves the inspector by 256
physical bytes and leaves follow mode. Those navigators remain disabled until
a program is loaded. **Mem map** deliberately keeps the effective offset—the address used by
the timing D-cache—so this workload’s stride appears as a diagonal scatter;
click an outlier, or focus the plot and use arrows, Page Up/Page Down, Home, or
End, to jump directly to its trace row, pinned architectural state, and
translated physical bytes. Enter/Space reopens the selected point. An
untranslated point clears any prior physical-byte highlight rather than
leaving a stale one. These captured/replayed points cover explicit
Capstone memory operands; implicit stack and repeated-string traffic remains
visible in cycle timing but is not claimed in the scatter or replay rate.

Use **Hotspots** after this drill-down to identify where latency accumulates,
rather than merely observing that the global IPC fell. **Σ lat** is the sum of
fetch-to-retire latency for every dynamic instruction at that PC. A held
instruction can be waiting on an older operation, so compare it with **D$
miss**, which identifies the memory PC that generated replayed misses. In-flight
instructions overlap, so the instruction-cycle sum can be larger than the
retired-lifecycle span printed beside it; **share** compares PCs within that
summed latency, not against wall time. The header also shows that retired span
against the full captured cycle window, so an in-flight tail is explicit rather
than silently attributed to the last retirement.

### 4. x87 throughput and architectural results

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

### 5. System boot, translation, and cache warm-up

```sh
tools/pipeviz/run.sh verif/sys/tests/ppage/ppage.bin
```

Pipeviz automatically selects **system** mode for this BIOS-style image.  Step
**1200 clocks**—the early setup code has not enabled paging yet at 240 clocks.
Watch the status row for fill/walk activity, then inspect the **TLB** tab and
the Code$/Data$ occupancy heatmaps.  The trace uses the live
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
