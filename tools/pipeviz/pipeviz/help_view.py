# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Indexed in-application user guide."""
from collections import OrderedDict

from PySide6.QtCore import Qt
from PySide6.QtGui import (QFont, QGuiApplication, QKeySequence, QShortcut,
                           QTextCursor, QTextDocument)
from PySide6.QtWidgets import (QDialog, QDialogButtonBox, QHBoxLayout, QLabel,
                               QLineEdit, QListWidget, QPushButton, QTextBrowser,
                               QVBoxLayout, QWidget)


PAGES = OrderedDict((
    ("Getting started", """
<h1>Getting started</h1>
<p>Pipeviz runs the real verilated Ventium core. Open a raw image or 32-bit x86
ELF, choose the execution mode, then advance with <b>Clock</b>, <b>Insn</b>,
<b>Step N</b>, or <b>Run</b>.</p>
<p>Entering Assembly or C automatically pauses continuous Run before the
transport toolbar is hidden. Returning to Visualizer never resumes without an
explicit F5/Run action. Program/snapshot choosers and Help also pause before
obscuring the live debugger; canceling or closing them does not auto-resume.</p>
<p>Insn advances clocks until the next retirement boundary; its feedback names
the actual elapsed clocks separately from whether it reached a retirement,
stopped with the program, or exhausted its safety limit.</p>
<p>Clock and Step N likewise add <b>program stopped</b> when the backend returns
early at terminal quiescence, so a smaller-than-requested clock count is never
left unexplained.</p>
<ol>
 <li>Open or drop a program. ELF entry and segments are automatic. The arrow
 beside <b>Open…</b> and <b>File → Open example</b> expose the same rescanned
 built verification workloads.</li>
 <li>Use Step N to establish a useful timeline.</li>
 <li>Find an event in the sparkline or with <code>[</code>/<code>]</code>.</li>
 <li>Click its timing/trace row to pin architectural state.</li>
 <li>Use the analysis tabs to explain the event.</li>
</ol>
<p>The four panes are linked: Pipeline and Trace selections pin Registers;
Hotspots, Branches, and Mem map navigate back to the responsible instruction.</p>
<p>The compact status row orders cycle/state/EIP before performance and cache
details so the current execution point survives narrow windows. Hover either
status or the last-action message for its complete untruncated text.</p>
<p>Launch fields and mode switches are disabled until a program exists. A
change that differs from the running setup turns Reset into
<b>Apply + Reset</b>; returning every field to its applied value removes that
warning without disturbing the model. Hover Apply + Reset to see the exact
pending fields/modes.</p>
"""),
    ("Loading programs", """
<h1>Loading programs</h1>
<h2>Fast paths</h2>
<p>The launcher uses <code>python3</code>, or the interpreter named by
<code>PIPEVIZ_PYTHON</code>. It preflights PySide6 and Capstone and points to
<code>requirements.txt</code> if either import is missing, before starting a
potentially long backend build. It also rebuilds when bridge/ABI, RTL
sources/file lists/includes, or the memory BFM is newer than the backend.
<code>run.sh --check</code> reports readiness without building or opening the
GUI and names the first stale input. Add <code>--soc</code> to check both
variants; <code>run.sh --build --soc</code> builds and launches the SoC
variant rather than dropping the flag at the build step.
<code>run.sh --help</code> never builds or requires the native model.</p>
<ul>
 <li>The arrow beside <b>Open…</b>, or <b>File → Open example</b>, rescans and
 opens any built verification workload. Clicking the main Open face retains
 the ordinary file chooser. With the split button focused, Down or Alt+Down
 opens its example menu.</li>
 <li><b>Ctrl+O</b>, the Open button, or dropping a file opens a program.</li>
 <li><b>Ctrl+Shift+R</b> reloads rebuilt bytes while preserving the displayed
 reset addresses and mode switches.</li>
</ul>
<p>An unavailable example is disabled, but hovering it shows the exact
repository build path(s) pipeviz rescans. Build that workload, then reopen the
menu; no application restart is needed.</p>
<p>A successful program, example, or snapshot load reveals the Visualizer even
when it starts from Assembly/C, so transport and status never remain hidden
behind an editor. Dropped Assembly/C source opens its matching workbench
instead; a failed load leaves the current workspace and session intact. Opening
the example menu or starting any program/snapshot load pauses continuous Run
before a menu, chooser, or error can obscure it. Dropped source files pause
before any unsaved-source confirmation for the same reason; resuming is
explicit.</p>
<h2>ELF versus raw images</h2>
<p>A little-endian 32-bit x86 ELF supplies its entry point and every
 <code>PT_LOAD</code> address automatically; the load field is disabled because
 an ELF may have several segments. A raw <code>.flat</code>, <code>.bin</code>,
 <code>.img</code>, or <code>.rom</code> uses the entry, load, and ESP fields.
 Empty files and DOS/PE executables are rejected with a format explanation. A sibling
 <code>manifest.json</code> may provide <code>entry</code>,
 <code>load_addr</code>, and <code>esp</code> as JSON integers or
 <code>"0x…"</code> strings, plus boolean <code>uv_issue</code>,
 <code>system</code>, and <code>soc</code>. SoC implies system mode. The
 manifest is applied as one validated unit.</p>
<p>A new program receives the default ESP unless its manifest specifies one;
 Reload still preserves the currently displayed setup. A generic
 <code>.bin</code> stays in user mode unless a manifest, command-line option,
 or explicit checkbox requests system boot.</p>
<p>Editing an address or mode marks <b>Apply + Reset</b>. Addresses must be
 32-bit hexadecimal values such as <code>0x08048000</code>; invalid input is
 highlighted and never silently replaced with a default.</p>
<h2>System images and snapshots</h2>
<p>Use <b>system</b> for a raw BIOS image that boots at F000:FFF0. <b>SoC</b>
 implies system and additionally needs a current <code>build.sh --soc</code>
 backend. Entry/load/ESP are disabled in system mode because reset-vector
 placement and firmware determine them. Use <b>Open snapshot</b> for a paired host-testbench
 <code>.aux</code>/<code>.vlt</code> checkpoint. On the command line,
 <code>--snapshot</code> is exclusive and restores exactly that target; it does
 not auto-load a demo afterward.</p>
"""),
    ("Reading the Pipeline View", """
<h1>How to read the Pipeline View</h1>
<h2>Axes and rows</h2>
<p>Each row is one retired instruction; time moves left to right in core cycles.
The frozen label gives retirement number, U/V lane, PC, mnemonic, and total
latency. Repeated PCs are shaded together, which makes loop iterations easy to
recognize. Mnemonics and dependency reads/writes come from the immutable bytes
captured with that retirement, so later code or address-map changes cannot
rewrite an older row.</p>
<h2>Stage glyphs</h2>
<table cellspacing="5">
 <tr><td><b>F</b></td><td>fetch</td><td><b>L</b></td><td>I-cache fill</td>
     <td><b>D</b></td><td>decode</td></tr>
 <tr><td><b>X</b></td><td>integer or x87 execute</td>
     <td><b>M</b></td><td>memory</td><td><b>W</b></td><td>writeback</td></tr>
 <tr><td><b>=</b></td><td>stall</td><td><b>!</b></td><td>mispredict flush</td>
     <td><b>S</b></td><td>system/microcode</td></tr>
</table>
<p>U and V rows retiring in the same cycle are a dual-issued pair. A clean,
dense diagonal means the front end is feeding the pipes. A long horizontal
run of stall cells means one instruction held resources for several cycles.</p>
<h2>Selections and dependencies</h2>
<p>The compact stage board above the timeline is the live, pre-retirement view.
Move over an occupied U, V, or FP cell to see its PC, then click it to mark the
exact linked Assembly line. The Visualizer stays open and the Assembly tab gains
<b>L…</b>; press Alt+A when you want to inspect or edit that line. Without a
pointer, Tab to the board's blue outline, choose an occupied lane with arrows
or Home/End, and press Enter. A finished
HLT remains an occupied, clickable cell so the stop location is explicit.
The live source mark describes this clock only: Clock, Insn, Step N, Run, and
Apply + Reset clear it before execution moves, while retaining the assembled
address map for the next selection.
<b>[paired]</b> means U/V issue now; <b>[blocked]</b> means a candidate pair is
held by a current hazard. A grey <code>stall · …</code> cell names that held
instruction; it does not claim that the instruction caused the hazard.</p>
<p>Click a row to place the cyan playhead, synchronize the Trace, pin Registers
after that retirement, and draw producer-to-consumer edges. An amber thick edge
marks a gating dependency such as a load-use stall. Shift-click another row to
place an amber anchor and measure the cycle delta. Use Up/Down, Page Up/Down,
Home, and End while the diagram has focus to select exact retirements. The cycle
zoom buttons (or Ctrl+- / Ctrl+=) trade context for cell detail without losing
the selected cycle. Trace links use the retirement ID, so U and V remain
individually selectable even when a pair commits in the same cycle.</p>
<p>In pinned Registers, GPRs, flags, selectors, and x87 are post-commit.
<b>PC*</b>, segment <b>base*</b>, and CR0/CR3/CR4 are starred because they are
the retiring instruction's pre-execution translation context. Segment limits
and CR2 show <code>n/a</code> because they are not captured per retirement;
Control / mode shows captured pre-execution USER/SYS, CPL, and SMM state.
Hover a starred label for the exact time-point explanation. The strip above
every register page says <b>LIVE</b> or
<b>PINNED n=… · retire cyc=…</b>, so the current time point remains explicit
even when compact mode is showing only Integer or x87. Click <b>Unpin</b> on
that strip to return to LIVE and clear the linked Trace/timing row, dependency
edges, playhead, Mem-map/Memory highlight, and Assembly line without executing
a clock. The source map remains ready for the next selection.</p>
<p>In x87, <code>empty=xx</code> is a logical ST mask: bit i=1 means ST(i) is
empty. A pinned header says <b>logical</b> because its values are already
rotated by TOP; hover the header or row for the exact interpretation. The
current bridge records x87 on every retirement. A partial or legacy record
without that snapshot shows explicit <code>x87 n/a</code> rows instead of stale
values.</p>
<p>The event selector beside ◀/▶ narrows <code>[</code>/<code>]</code>
navigation to any event, mispredicts, stalls, I-cache fills, or page walks.
The IPC/event strip is also a captured-history navigator: Tab to its blue
outline, use Left/Right for one cycle, Page Up/Page Down for 64 cycles, or
Home/End for the captured edges, then Enter to reopen the selected cycle.
Click or left-drag across the strip to scrub the same playhead continuously.
Seeking moves only the cycle playhead; it never guesses U or V from an
ambiguous dual-retire cycle or changes an exact Trace/Register pin. The action
line states the selected cycle and whether a retirement pin remained unchanged.
Selecting a Trace/Pipeline instruction instead reports its retirement, cycle,
lane, PC, and linked Assembly line. A long HLT tail says <b>waiting for
interrupt</b> while transport is still available, then <b>quiesced — program
stopped</b> only when the backend is terminal and stepping is disabled.</p>
<h2>Examples</h2>
<ul>
 <li><b>Dual Fibonacci:</b> two independent recurrence chains let adjacent
 arithmetic occupy U and V together. Compare U/V issue on/off; paired mode
 completes the same results in fewer cycles. The current acceptance run
 measures 2,451 clocks / 0.461 IPC in single-issue mode versus 1,984 clocks /
 0.571 IPC with U/V enabled, with 85.3% of instructions paired.</li>
 <li><b>mb_brloop:</b> repeating <code>dec</code>/<code>jne</code> diagonals
 expose branch pairing and the flags dependency. Red event pixels locate
 mispredict recovery.</li>
 <li><b>mb_dmiss:</b> a load row stretches through stall cells. Click it, then
 use Data$, Memory →access, and Mem map to connect latency to an address stride.</li>
 <li><b>mb_fpindep:</b> purple FP execution cells show x87 overlap. Pin an
 <code>fadd</code> to inspect its post-retirement x87 stack.</li>
</ul>
"""),
    ("Assembly and source editing", """
<h1>Assembly and source editing</h1>
<p>This topic covers the Assembly→RTL path and editing controls shared by both
source workspaces. Choose <b>C compiler workbench</b> in the index for the
focused C→Assembly workflow and dual-Fibonacci experiment.</p>
<h2>Assembly → RTL</h2>
<p>Open the <b>Assembly</b> workspace (Alt+A) for a line-numbered, highlighted
GNU Intel-syntax editor. <b>Assemble + Run</b> invokes GNU <code>as</code> and
<code>ld</code>, creates a 32-bit ELF at <code>0x08048000</code>, and loads it
into the same real RTL backend as an opened program. Ctrl+Enter is the keyboard
equivalent. A bare instruction snippet is automatically wrapped in
<code>.intel_syntax</code>, <code>_start</code>, and a fall-through HLT; an
explicit <code>_start:</code> is assembled exactly as written.</p>
<p>Ctrl+B assembles without loading the backend.</p>
<h2>Files and safe replacement</h2>
<p>Within either source workspace, Ctrl+N creates its runnable template, Ctrl+O
opens that source type, Ctrl+S saves the current file, and Ctrl+Shift+S saves
under a new name. An asterisk on the Assembly or C tab marks unsaved changes.
Save as appends <code>.s</code> or
<code>.c</code> to a bare name when its typed-file filter is selected and
reports the final filename globally.
The lower-right source badge remains visible when a later Build/Compile replaces
the transient status message; it names the saved file, built-in template, or
C-compiler origin, and its tooltip gives the full path.
Open reports that same real filename in both places; Assembly never labels an
opened file as compiler-generated.
New/Open, C-to-Assembly replacement, and Quit offer
Save/Discard/Cancel protection. Back in Visualizer, Ctrl+O resumes its
program-opening role. Dropped <code>.s/.S/.asm</code> and
<code>.c/.h</code> files open in their source workspace rather than being
treated as raw executables.</p>
<h2>Editing comfortably</h2>
<p>Each workspace remembers its last folder, and Enter
preserves indentation or advances it after labels/braces. A closing C brace
typed on a blank indented line dedents one level. Plain Tab indents source;
Ctrl+Tab moves to diagnostics and Ctrl+Shift+Tab moves toward the primary
Run/Compile control without changing source. These navigation chords also close
a live completion popup instead of inserting its selected opcode. With one or
more lines selected, Tab and Shift+Tab indent/outdent the complete block as one
undoable edit rather than replacing the selection. In leading whitespace,
Backspace removes spaces to the previous four-column stop as one undoable edit.
Ctrl+/ toggles <code>#</code> Assembly or <code>//</code> C line comments,
preserving indentation and handling a selected block in one undo step.</p>
<h2>Navigation and structure</h2>
<p>Home first moves to the line's first non-whitespace column, then toggles to
column zero; Shift+Home extends the selection and Ctrl+Home still moves to the
start of the document. Ctrl+-/Ctrl+= changes source text and line-number size
from 8 to 24 pt; Ctrl+wheel uses the same bounds, and Ctrl+0 restores 10 pt
while in Assembly/C.</p>
<p>Moving beside <code>()</code>, <code>[]</code>, or <code>{}</code>
highlights its structurally matching pair; an unmatched or misnested delimiter
is marked red. Delimiters inside quoted text, Assembly <code>#</code> comments,
and C line/block comments are ignored.</p>
<p>Click a line number to select that complete source line, then drag or
Shift-click another number to extend a whole-line range for Tab/Shift+Tab
indentation and Ctrl+/ comment toggling.</p>
<p>The source badge may elide a long filename visually; its tooltip and
accessible description retain the complete saved path or generated/template
origin plus not-saved and unsaved-change state.</p>
<p>The adjacent Assembly/C status preserves its full build, stale-map, or
PC/line message in both a tooltip and accessible description if the compact
label is clipped. A persistent one-based <b>Ln · Col</b> readout beside it
tracks the active source caret independently of transient build messages; an
<b>nL</b> suffix confirms how many lines a selection spans. Click that readout
or press Ctrl+G to enter a validated line number and return focus to the
centered editor line. Both workbenches remain usable at the tested
900×620 compact window size.</p>
<h2>Find in source</h2>
<p>Ctrl+F opens an inline source search with all-match highlighting and a
current/total count. Enter or F3 moves forward, Shift+Enter or Shift+F3 moves
backward, and Escape closes the search. It is a case-insensitive literal search;
navigation disables for an empty/no-match query, and the live result is announced
accessibly. Highlighting caps at 2,000 matches for responsiveness. Click a line
number to select the whole source line and return typing focus to the editor.</p>
<h2>Opcode completion</h2>
<p>Ctrl+Space opens the Ventium/P54C opcode catalogue. Every entry includes its
operand form, description, availability, estimated latency, U/V pairing class,
and a miniature F→D→X/M/W/FP pipeline preview. Common ALU/no-op entries describe
the selected operation rather than an unrelated family member. Normal user
availability is neutral; mode- or build-gated operations say so explicitly in
amber. Each list row shows mnemonic, pipe class, and operands without repeating
the mnemonic; the detail pane shows the complete signature. Regression covers
every RTL decoder family and all 121 exact 32-bit P5 timing mnemonics. Use
Up/Down or Page
Up/Page Down to choose, Home/End for the
first/last entry, Enter/Tab or a double-click to insert, and Escape to close;
these controls remain visible in the popup footer. Completion inserts only when
the cursor is in an opcode slot;
elsewhere the full catalogue is safe, reference-only help. GNU as
semicolons separate statements, and completion follows the opcode in each
statement while ignoring separators/comment markers inside quoted data.
Clicking or scrolling the editor dismisses the popup so it never remains
detached from its caret anchor; its own list remains pointer-scrollable.
Accepted mnemonics preserve the token's uppercase, capitalized, or lowercase
style, including when completion replaces text on both sides of the cursor.
Digits keep refining names such as <code>cmpxchg8b</code>, while Backspace and
Delete refresh the current matches.</p>
<h2>Diagnostics and build freshness</h2>
<p>Build errors highlight their source line
in red; successful GCC/GNU-as warnings remain runnable but mark their line and
diagnostics in amber. The first diagnostic line is actionable:
focus it and press Enter, or double-click it, to return to the marked editor
line. When a warning-producing C compile opens Assembly, its amber status points
back to the C details with Alt+C. Fatal compiler errors use the same jump path. Editing
the source clears diagnostics from the old revision instead of leaving a stale
green or red result visible. Ctrl+Shift+R is intentionally Visualizer-only:
it reloads an already-built program rather than rebuilding editor text. Use
Assemble + Run, or Compile → Assembly followed by Assemble + Run, to keep edits
and PC links coherent.</p>
<h2>Source-linked investigation</h2>
<p>Assembly is built with a DWARF line table. Clicking an occupied live U/V/FP
stage cell, a Trace row, or a Pipeline timing row therefore marks the exact
assembly line for that PC; the Assembly tab displays its line number without
stealing focus from the Visualizer. Hovering a live cell exposes its lane and PC.
The Assembly status retains U or V for a retired selection, so the source view
does not discard which half of a same-cycle pair led there. Retired x87
operations are labeled FP rather than U.
Unsaved and linked state coexist as <b>Assembly * · L…</b>. Editing after a
build invalidates that map until the next assembly, preventing stale links.
Selecting a generated wrapper instruction with no editor line clears the prior
marker rather than showing a stale association.</p>
"""),
    ("C compiler workbench", """
<h1>C compiler workbench</h1>
<h2>C → editable assembly</h2>
<p>Open <b>C</b> (Alt+C), write a freestanding
<code>int main(void)</code>, choose O0/O1/O2/Os, then click
<b>Compile → Assembly</b>. Pipeviz uses GCC's freestanding GNU C11 32-bit
Pentium target with no libc, builtins, MMX, or SSE; floating point therefore
uses x87. It adds a small <code>_start</code>/HLT wrapper and opens the generated
Intel-syntax source in Assembly. Review or edit it before running. Compiler
errors also highlight their C line; press Enter on the focused diagnostic or
double-click it to jump there. Editing C or changing the optimization level
clears the prior compiler result and asks for a fresh compile. The diagnostic
pane stays shallow while empty, expands for real output, and collapses after
that output becomes stale. Long compiler lines wrap to the pane width instead
of requiring horizontal scrolling.</p>
<p>Hover an optimization choice for its purpose: O0 is the most direct and
source-like, O1 is a moderate compromise, O2 is the performance-oriented
default for U/V experiments, and Os favors compact code. Every advertised level
is compiled and assembled by the authoring regression.</p>
<h2>Run the built-in U/V experiment</h2>
<p>The C toolbar's <b>New U/V demo</b> is a real experiment: two independent Fibonacci
chains run for a volatile, runtime-loaded 120 iterations, so O2 cannot replace
them with constants. Its opening comments retain the same-ELF procedure and
expected EAX in saved copies. Compile at O2, Assemble + Run, then run the same ELF once
with <b>U/V issue</b> enabled and once disabled (apply/reset after each change).
Both runs return EAX <code>0x198c09a0</code>; the enabled run should show
hundreds of V retirements and finish materially sooner. The regression requires
more than 400 V retirements and at least a 20% cycle advantage.</p>
<p>Generated artifacts stay under <code>tools/pipeviz/.generated/</code> and
are ignored by Git.</p>
<h2>Shared source controls</h2>
<p>Ctrl+N activates <b>New U/V demo</b>; Ctrl+O opens C; Ctrl+S and Ctrl+Shift+S save.
Ctrl+B and Ctrl+Enter both compile into Assembly. Ctrl+F searches, Ctrl+G goes
to a line, and Ctrl+/ toggles C line comments. For indentation, gutter
selection, matching delimiters, zoom, diagnostics, and source-linked
investigation details, choose <b>Assembly and source editing</b> in the index.</p>
"""),
    ("Trace and filters", """
<h1>Retired-instruction trace</h1>
<p>The compact trace lists retire number/cycle, stall delta, U/V lane, PC, raw
bytes, disassembly, and architectural effects. Byte colors separate x86
prefixes, opcode, ModRM/SIB, displacement, immediate, and branch-relative
fields.</p>
<p>Filters combine with spaces: <code>mov</code>, <code>pc:08048</code>,
<code>n&gt;=100</code>, <code>cyc&gt;=133</code>, <code>pipe:V</code>,
<code>stall</code>, and
<code>@</code> for memory accesses. Click any result to synchronize the timing
view and pin Registers. Press <code>/</code> to focus the filter, Enter or F3
to move to the next result, Shift+F3 for the previous result, and Escape to
clear it. The arrows beside the match count provide the same navigation.
Malformed structured terms such as <code>n&gt;200</code> or
<code>pc:xyz</code> report their expected syntax on hover and keep all rows
visible while you correct them.
Clearing an unselected exploratory filter returns to the newest rows; selecting
a result preserves that historical context instead.</p>
<p>If a single fast step produces more rows than fit in the rolling view, Trace
keeps and labels the newest 6,000 retirements. The Pipeline title similarly
labels a newest-cycle window after very large steps. Hotspots and Branches use
Pipeline's longer analysis window; if their PC has fallen out of Trace,
drill-down selects its nearest retained Pipeline retirement and reports that
fallback instead of becoming a silent no-op.</p>
<p>Branches reports <b>taken/resolved</b>, <b>taken %</b>, and a ten-slot
<b>bias bar</b>. A capture-tail branch remains a hit but has no next retired PC,
so it is excluded from the resolved denominator and taken percentage.</p>
<p>The Trace table announces whether no program or no retirement exists, then
its populated row count. Filter results announce visible/total counts; invalid
structured syntax announces the correction while retaining every row.</p>
<p>Hover any Trace or analysis-table header for its full field meaning, units,
denominator, flag order, or bar normalization; compact labels such as
<b>Δ</b>, <b>U/W/P</b>, <b>big</b>, and <b>D</b> are never left implicit.</p>
"""),
    ("Caches and memory", """
<h1>Caches and memory</h1>
<p>Code$ and Data$ show set/way residency and occupancy. Data$ replays the
observed access stream through the matching 2-way geometry to estimate misses.
Every table header has a semantic tooltip; hover abbreviated cache/TLB/profile
columns for address bits, permission order, units, and normalization.
Each occupancy map exposes its resident count and exact set/way/MRU geometry as
a textual description in addition to the painted grid. Hover a cell for its
set, way, residency/MRU, tag, and line address; resident cells highlight and
center their corresponding table row until the pointer leaves. Empty analysis tables
announce the same explanation they paint; populated tables announce their row
count instead of retaining a stale empty-state message.
For a restored snapshot it seeds replay from the resident tags and MRU order at
the session boundary, so the first post-restore access is not falsely cold.
Hotspots attributes fetch-to-retire latency and D-cache misses to PCs. Its
<b>Σ lat</b> column sums the latency of every dynamic instruction at that PC;
because in-flight instructions overlap, this instruction-cycle total can exceed
the retired-lifecycle span shown in the header. That span is printed against the
full captured cycle window, exposing an in-flight tail. A held PC can be waiting
on an older instruction, so use <b>D$ miss/access</b> to identify the memory PC
producing replayed misses; the separate <b>Σlat bar</b> is normalized to the
largest Σ-latency PC and does not represent miss cost.</p>
<p>Cycles classifies every captured clock once. <b>front end</b> combines fetch
and decode; <b>slow path</b> combines integer execute, load/store, string, and
I/O micro-operations. Its accessible description reports clocks and percentages
for every non-empty category, plus retired count and IPC.</p>
<p>Prefetch announces its linear fetch address, EIP, fetch word, all 16 buffer
bytes, and whether the slow-path buffer is idle or what it decodes.</p>
<p>Memory displays physical backend bytes. EIP, ESP, and the latest explicit
memory operand are resolved through segmentation and legacy page tables. Page
Up/Page Down or the arrow buttons move by one contiguous visible block and
exits follow mode; navigation is disabled before a program is loaded. Its custom-painted
dump exposes the visible range, each hex/ASCII row, and visible marker addresses
as an accessible textual description. Mem
map intentionally plots the effective offset used by the timing D-cache against
retirement order: a diagonal is a stride, a horizontal band is a hot location,
and a cloud is irregular access. Click a point or use arrows, Page Up/Page Down,
Home, and End on the focused plot to select its trace row, pin Registers, and
highlight its translated physical bytes; Enter/Space reopens the selection.
When all ten analysis tab names do not fit, a complete
<b>Alt+1 · Code$ … Alt+0 · Mem map</b> selector replaces the clipped scrolling
strip. Pointer/arrow selection and Alt+1…Alt+0 operate the same views.
Until an access exists, Alt+0 leaves focus on that visible analysis navigator
instead of placing a dead empty canvas in the Tab order.
Implicit stack and repeated-string traffic is not included in this client-side
operand replay.</p>
"""),
    ("System and snapshots", """
<h1>System mode and snapshots</h1>
<p>System mode places a BIOS-style raw image so its last byte ends at 1 MiB and
starts the core at F000:FFF0. Use it for paging and protected-mode fixtures.
The SoC option additionally requires a current <code>build.sh --soc</code>
library for port I/O, PIC, and PIT behavior. If it is unavailable, Pipeviz
warns and falls back to the core model. If that fallback also fails, the old
live backend and visible mode remain unchanged.</p>
<p>Open Snapshot accepts a matching <code>.aux</code>/<code>.vlt</code> pair.
Its timeline begins at the restored point because the snapshot stores model
and memory state, not the earlier visual history. The architectural clock stays
absolute, while retirement IDs, IPC, Pipeline, sparkline, and Cycles start a
fresh visible epoch at that point.</p>
"""),
    ("Shortcuts", """
<h1>Keyboard and mouse reference</h1>
<table cellspacing="6">
 <tr><td><b>Ctrl+N</b></td><td>new Assembly or C template in the active source workspace</td></tr>
 <tr><td><b>Ctrl+O</b></td><td>open program, Assembly, or C for the active workspace</td></tr>
 <tr><td><b>Ctrl+S</b></td><td>save the active Assembly or C source</td></tr>
 <tr><td><b>Ctrl+Shift+S</b></td><td>save the active source under a new name</td></tr>
 <tr><td><b>Ctrl+F</b></td><td>find in the active Assembly or C source</td></tr>
 <tr><td><b>F3 / Shift+F3</b></td><td>next / previous source or Trace match</td></tr>
 <tr><td><b>Ctrl+Shift+O</b></td><td>open snapshot</td></tr>
 <tr><td><b>Ctrl+Shift+R</b></td><td>reload the current program from disk</td></tr>
 <tr><td><b>Ctrl+0</b></td><td>reset Visualizer panel proportions, or source text to 10 pt</td></tr>
 <tr><td><b>Alt+V / Alt+A / Alt+C</b></td><td>switch workspace and focus Pipeline / Assembly / C</td></tr>
 <tr><td><b>Alt+1 … Alt+0</b></td><td>open Visualizer, then select and focus Code$ … Mem map analysis</td></tr>
 <tr><td><b>R</b></td><td>reset or restore snapshot</td></tr>
 <tr><td><b>.</b></td><td>one clock</td></tr>
 <tr><td><b>I / Space</b></td><td>next retired instruction</td></tr>
 <tr><td><b>F5</b></td><td>run/pause</td></tr>
 <tr><td><b>[ / ]</b></td><td>previous/next selected event class</td></tr>
 <tr><td><b>Ctrl+- / Ctrl+=</b></td><td>zoom the focused Pipeline cycle axis, or Assembly/C source text</td></tr>
 <tr><td><b>Ctrl+wheel</b></td><td>zoom Assembly/C source text under the pointer</td></tr>
 <tr><td><b>↑/↓, PgUp/PgDn, Home/End</b></td><td>traverse focused Pipeline rows</td></tr>
 <tr><td><b>Tab / Shift+Tab</b></td><td>leave a focused Trace or analysis table; arrows navigate its content</td></tr>
 <tr><td><b>Source Tab / Shift+Tab</b></td><td>indent/outdent the caret or selected source lines</td></tr>
 <tr><td><b>Source Backspace</b></td><td>remove leading soft indentation to the previous four-column stop</td></tr>
 <tr><td><b>Gutter click / drag / Shift-click</b></td><td>select or extend complete source-line ranges</td></tr>
 <tr><td><b>Board arrows + Enter</b></td><td>choose and open an occupied live U/V/FP source line</td></tr>
 <tr><td><b>IPC arrows/Pg/Home/End</b></td><td>seek captured cycles; Enter reopens one</td></tr>
 <tr><td><b>/</b></td><td>focus the trace filter from anywhere</td></tr>
 <tr><td><b>Enter / F3</b></td><td>next filtered retirement (Visualizer)</td></tr>
 <tr><td><b>Shift+F3</b></td><td>previous filtered retirement (Visualizer)</td></tr>
 <tr><td><b>Escape</b></td><td>clear a focused Trace filter; in focused Pipeline, Unpin to LIVE</td></tr>
 <tr><td><b>Ctrl+Space</b></td><td>assembly opcode completion</td></tr>
 <tr><td><b>Popup Home / End</b></td><td>first / last opcode completion without moving source</td></tr>
 <tr><td><b>Ctrl+B</b></td><td>assemble without running, or compile C to Assembly</td></tr>
 <tr><td><b>Ctrl+Enter</b></td><td>assemble+run, or compile C</td></tr>
 <tr><td><b>Ctrl+/</b></td><td>toggle Assembly/C line comments</td></tr>
 <tr><td><b>Ctrl+G</b></td><td>go to a source line in Assembly/C</td></tr>
 <tr><td><b>Home / Shift+Home</b></td><td>in a source editor, toggle first code column/column zero, optionally selecting</td></tr>
 <tr><td><b>Ctrl+Tab / Ctrl+Shift+Tab</b></td><td>leave an Assembly or C editor without inserting indentation</td></tr>
 <tr><td><b>Ctrl+F, F3 / Shift+F3</b></td><td>find text in this guide topic</td></tr>
 <tr><td><b>F1</b></td><td>this guide</td></tr>
</table>
<p>Click a trace/timing row to pin it; use the register strip's <b>Unpin</b>
button or focused-Pipeline Escape with an empty filter to return to LIVE without executing.
Shift-click a second timing row to
measure cycle distance. Click or keyboard-navigate the IPC sparkline to seek a
cycle.</p>
"""),
))


class UserGuideDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Pipeviz User Guide")
        self.setAccessibleName("Pipeviz user guide")
        screen = parent.screen() if parent is not None else QGuiApplication.primaryScreen()
        if screen is not None:
            available = screen.availableGeometry()
            width = max(600, min(980, available.width() - 48))
            height = max(480, min(700, available.height() - 64))
        else:
            width, height = 980, 700
        self.resize(width, height)
        root = QVBoxLayout(self)
        heading = QLabel("Pipeviz help")
        heading.setStyleSheet("font-size:16px;font-weight:bold;padding:4px;")
        header = QHBoxLayout()
        header.addWidget(heading)
        header.addStretch()
        find_button = QPushButton("Find…  Ctrl+F")
        find_button.setAccessibleName("Find in current guide topic")
        find_button.setToolTip("Open search for the currently indexed guide topic")
        find_button.setAccessibleDescription(find_button.toolTip())
        find_button.clicked.connect(self._focus_find)
        header.addWidget(find_button)
        root.addLayout(header)
        self.find_bar = QWidget()
        find_layout = QHBoxLayout(self.find_bar)
        find_layout.setContentsMargins(0, 0, 0, 0)
        find_label = QLabel("Find in current topic:")
        self.find_edit = QLineEdit()
        self.find_edit.setAccessibleName("Find text in current guide topic")
        self.find_edit.setPlaceholderText("Search this page…")
        self.find_edit.setToolTip(
            "Case-insensitive search in the currently indexed guide topic")
        self.find_edit.setAccessibleDescription(self.find_edit.toolTip())
        self.find_edit.setClearButtonEnabled(True)
        find_label.setBuddy(self.find_edit)
        find_layout.addWidget(find_label)
        find_layout.addWidget(self.find_edit, 1)
        self.find_prev = QPushButton("Previous")
        self.find_prev.setAccessibleName("Previous guide match")
        self.find_prev.setToolTip("Select the previous match (Shift+F3)")
        self.find_prev.setAccessibleDescription(self.find_prev.toolTip())
        self.find_next = QPushButton("Next")
        self.find_next.setAccessibleName("Next guide match")
        self.find_next.setToolTip("Select the next match (F3 or Enter)")
        self.find_next.setAccessibleDescription(self.find_next.toolTip())
        find_layout.addWidget(self.find_prev)
        find_layout.addWidget(self.find_next)
        self.find_result = QLabel("")
        self.find_result.setAccessibleName("Guide search result")
        self.find_result.setMinimumWidth(88)
        find_layout.addWidget(self.find_result)
        root.addWidget(self.find_bar)
        self.find_bar.hide()
        body = QHBoxLayout()
        self.index = QListWidget()
        self.index.setAccessibleName("User guide topic index")
        self.index.setFixedWidth(max(170, min(205, width // 4)))
        self.index.addItems(PAGES.keys())
        self.page = QTextBrowser()
        self.page.setAccessibleName("User guide topic content")
        self.page.setOpenExternalLinks(False)
        font = QFont()
        font.setPointSize(10)
        self.page.setFont(font)
        body.addWidget(self.index)
        body.addWidget(self.page, 1)
        root.addLayout(body, 1)
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.close)
        self.close_btn = buttons.button(QDialogButtonBox.Close)
        self.close_btn.setAccessibleName("Close Pipeviz user guide")
        self.close_btn.setToolTip("Close this guide and return to Pipeviz")
        self.close_btn.setAccessibleDescription(self.close_btn.toolTip())
        root.addWidget(buttons)
        self.index.currentTextChanged.connect(self._set_page)
        self.find_edit.textChanged.connect(self._find_first)
        self.find_edit.returnPressed.connect(self._find_next_match)
        self.find_prev.clicked.connect(self._find_previous_match)
        self.find_next.clicked.connect(self._find_next_match)
        find_shortcut = QShortcut(QKeySequence.Find, self)
        find_shortcut.activated.connect(self._focus_find)
        next_shortcut = QShortcut(QKeySequence.FindNext, self)
        next_shortcut.activated.connect(self._find_next_match)
        previous_shortcut = QShortcut(QKeySequence.FindPrevious, self)
        previous_shortcut.activated.connect(self._find_previous_match)
        hide_find_shortcut = QShortcut(QKeySequence(Qt.Key_Escape), self.find_bar)
        hide_find_shortcut.setContext(Qt.WidgetWithChildrenShortcut)
        hide_find_shortcut.activated.connect(self._hide_find)
        self._find_shortcuts = (find_shortcut, next_shortcut, previous_shortcut,
                                hide_find_shortcut)
        self.show_page("Getting started")

    def _set_page(self, title):
        if title in PAGES:
            self.page.setHtml(PAGES[title])
            self.page.setAccessibleDescription(
                f"{title}. Use Ctrl+F to find text in this topic; "
                "Shift+Tab returns to the topic index.")
            self._find_first()

    def _focus_find(self):
        self.find_bar.show()
        self.find_edit.setFocus(Qt.ShortcutFocusReason)
        self.find_edit.selectAll()

    def _hide_find(self):
        self._reset_find()
        self.index.setFocus(Qt.ShortcutFocusReason)

    def _reset_find(self):
        self.find_edit.clear()
        self.find_bar.hide()

    def hideEvent(self, event):
        # Find is a transient interaction, not guide-navigation history. A
        # Close-button dismissal must not resurrect an old query/selection when
        # a later F1 invocation opens a different topic.
        self._reset_find()
        super().hideEvent(event)

    def _find_first(self):
        self._find_match(restart=True)

    def _find_next_match(self):
        self._find_match()

    def _find_previous_match(self):
        self._find_match(backward=True)

    def _find_match(self, backward=False, restart=False):
        query = self.find_edit.text()
        folded_query = query.casefold()
        total = self.page.toPlainText().casefold().count(folded_query) if query else 0
        enabled = bool(total)
        self.find_prev.setEnabled(enabled)
        self.find_next.setEnabled(enabled)
        if not query:
            self.find_result.clear()
            self.find_result.setAccessibleDescription("No guide search is active.")
            cursor = self.page.textCursor()
            cursor.clearSelection()
            self.page.setTextCursor(cursor)
            return
        if not total:
            self.find_result.setText("No matches")
            self.find_result.setAccessibleDescription(
                f'No matches for "{query}" in this topic.')
            cursor = self.page.textCursor()
            cursor.clearSelection()
            self.page.setTextCursor(cursor)
            return
        flags = QTextDocument.FindBackward if backward else QTextDocument.FindFlags()
        if restart:
            cursor = self.page.textCursor()
            cursor.movePosition(QTextCursor.End if backward else QTextCursor.Start)
            self.page.setTextCursor(cursor)
        if not self.page.find(query, flags):
            cursor = self.page.textCursor()
            cursor.movePosition(QTextCursor.End if backward else QTextCursor.Start)
            self.page.setTextCursor(cursor)
            self.page.find(query, flags)
        cursor = self.page.textCursor()
        ordinal = (self.page.toPlainText()[:cursor.selectionStart()]
                   .casefold().count(folded_query) + 1)
        self.find_result.setText(f"{ordinal} of {total}")
        self.find_result.setAccessibleDescription(
            f'Match {ordinal} of {total} for "{query}" in this topic.')

    def show_page(self, title):
        titles = list(PAGES)
        row = titles.index(title) if title in PAGES else 0
        self.index.setCurrentRow(row)
        self._set_page(titles[row])
        self.page.verticalScrollBar().setValue(0)
