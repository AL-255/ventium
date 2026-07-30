# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Indexed in-application user guide."""
from collections import OrderedDict

from PySide6.QtGui import QFont
from PySide6.QtWidgets import (QDialog, QDialogButtonBox, QHBoxLayout, QLabel,
                               QListWidget, QTextBrowser, QVBoxLayout)


PAGES = OrderedDict((
    ("Getting started", """
<h1>Getting started</h1>
<p>Pipeviz runs the real verilated Ventium core. Open a raw image or 32-bit x86
ELF, choose the execution mode, then advance with <b>Clock</b>, <b>Insn</b>,
<b>Step N</b>, or <b>Run</b>.</p>
<ol>
 <li>Open or drop a program. ELF entry and segments are automatic. The
 <b>File → Open example</b> menu rescans and exposes the built verification
 workloads.</li>
 <li>Use Step N to establish a useful timeline.</li>
 <li>Find an event in the sparkline or with <code>[</code>/<code>]</code>.</li>
 <li>Click its timing/trace row to pin architectural state.</li>
 <li>Use the analysis tabs to explain the event.</li>
</ol>
<p>The four panes are linked: Pipeline and Trace selections pin Registers;
Hotspots, Branches, and Mem map navigate back to the responsible instruction.</p>
"""),
    ("Loading programs", """
<h1>Loading programs</h1>
<h2>Fast paths</h2>
<ul>
 <li><b>File → Open example</b> rescans and opens any built verification
 workload.</li>
 <li><b>Ctrl+O</b>, the Open button, or dropping a file opens a program.</li>
 <li><b>Ctrl+Shift+R</b> reloads rebuilt bytes while preserving the displayed
 reset addresses and mode switches.</li>
</ul>
<h2>ELF versus raw images</h2>
<p>A little-endian 32-bit x86 ELF supplies its entry point and every
 <code>PT_LOAD</code> address automatically; the load field is disabled because
 an ELF may have several segments. A raw <code>.flat</code>, <code>.bin</code>,
 <code>.img</code>, or <code>.rom</code> uses the entry, load, and ESP fields.
 Empty files and DOS/PE executables are rejected with a format explanation. A sibling
 <code>manifest.json</code> may provide <code>entry</code> and
 <code>load_addr</code> as JSON integers or <code>"0x…"</code> strings.</p>
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
recognize.</p>
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
<b>L…</b>; press Alt+A when you want to inspect or edit that line. A finished
HLT remains an occupied, clickable cell so the stop location is explicit.
<b>[paired]</b> means U/V issue now; <b>[blocked]</b> means a candidate pair is
held by a current hazard. A grey <code>stall · …</code> cell names that held
instruction; it does not claim that the instruction caused the hazard.</p>
<p>Click a row to place the cyan playhead, synchronize the Trace, pin Registers
after that retirement, and draw producer-to-consumer edges. An amber thick edge
marks a gating dependency such as a load-use stall. Shift-click another row to
place an amber anchor and measure the cycle delta. Use Up/Down, Page Up/Down,
Home, and End while the diagram has focus to select exact retirements. The cycle
zoom buttons (or Ctrl+- / Ctrl+=) trade context for cell detail without losing
the selected cycle.</p>
<p>The event selector beside ◀/▶ narrows <code>[</code>/<code>]</code>
navigation to any event, mispredicts, stalls, I-cache fills, or page walks.</p>
<h2>Examples</h2>
<ul>
 <li><b>Dual Fibonacci:</b> two independent recurrence chains let adjacent
 arithmetic occupy U and V together. Compare U/V issue on/off; paired mode
 completes the same results in fewer cycles.</li>
 <li><b>mb_brloop:</b> repeating <code>dec</code>/<code>jne</code> diagonals
 expose branch pairing and the flags dependency. Red event pixels locate
 mispredict recovery.</li>
 <li><b>mb_dmiss:</b> a load row stretches through stall cells. Click it, then
 use Data$, Memory →access, and Mem map to connect latency to an address stride.</li>
 <li><b>mb_fpindep:</b> purple FP execution cells show x87 overlap. Pin an
 <code>fadd</code> to inspect its post-retirement x87 stack.</li>
</ul>
"""),
    ("Assembly and C workbenches", """
<h1>Assembly and C workbenches</h1>
<h2>Assembly → RTL</h2>
<p>Open the <b>Assembly</b> workspace (Alt+A) for a line-numbered, highlighted
GNU Intel-syntax editor. <b>Assemble + Run</b> invokes GNU <code>as</code> and
<code>ld</code>, creates a 32-bit ELF at <code>0x08048000</code>, and loads it
into the same real RTL backend as an opened program. Ctrl+Enter is the keyboard
equivalent. A bare instruction snippet is automatically wrapped in
<code>.intel_syntax</code>, <code>_start</code>, and a fall-through HLT; an
explicit <code>_start:</code> is assembled exactly as written.</p>
<p>Within either source workspace, Ctrl+O opens that source type and Ctrl+S
saves the current file. An asterisk on the Assembly or C tab marks unsaved
changes. New/Open, C-to-Assembly replacement, and Quit offer
Save/Discard/Cancel protection. Back in Visualizer, Ctrl+O resumes its
program-opening role. Dropped <code>.s/.S/.asm</code> and
<code>.c/.h</code> files open in their source workspace rather than being
treated as raw executables. Each workspace remembers its last folder, and Enter
preserves indentation or advances it after labels/braces. A closing C brace
typed on a blank indented line dedents one level.</p>
<p>Ctrl+F opens an inline source search with all-match highlighting and a
current/total count. Enter or F3 moves forward, Shift+Enter or Shift+F3 moves
backward, and Escape closes the search.</p>
<p>Ctrl+Space opens the Ventium/P54C opcode catalogue. Every entry includes its
operand form, description, availability, estimated latency, U/V pairing class,
and a miniature F→D→X/M/W/FP pipeline preview. Mode- or build-gated operations
say so explicitly. Completion inserts only when the cursor is in an opcode
slot; elsewhere the full catalogue is safe, reference-only help. GNU as
semicolons separate statements, and completion follows the opcode in each
statement while ignoring separators/comment markers inside quoted data. Build
errors, including fatal compiler errors, highlight their source line.</p>
<h2>Source-linked investigation</h2>
<p>Assembly is built with a DWARF line table. Clicking an occupied live U/V/FP
stage cell, a Trace row, or a Pipeline timing row therefore marks the exact
assembly line for that PC; the Assembly tab displays its line number without
stealing focus from the Visualizer. Hovering a live cell exposes its lane and PC.
Unsaved and linked state coexist as <b>Assembly * · L…</b>. Editing after a
build invalidates that map until the next assembly, preventing stale links.
Selecting a generated wrapper instruction with no editor line clears the prior
marker rather than showing a stale association.</p>
<h2>C → editable assembly</h2>
<p>Open <b>C</b> (Alt+C), write a freestanding
<code>int main(void)</code>, choose O0/O1/O2/Os, then click
<b>Compile → Assembly</b>. Pipeviz uses GCC's freestanding GNU C11 32-bit
Pentium target with no libc, builtins, MMX, or SSE; floating point therefore
uses x87. It adds a small <code>_start</code>/HLT wrapper and opens the generated
Intel-syntax source in Assembly. Review or edit it before running. Compiler
errors also highlight their C line.</p>
<p>Generated artifacts stay under <code>tools/pipeviz/.generated/</code> and
are ignored by Git.</p>
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
clear it. The arrows beside the match count provide the same navigation.</p>
<p>If a single fast step produces more rows than fit in the rolling view, Trace
keeps and labels the newest 6,000 retirements. The Pipeline title similarly
labels a newest-cycle window after very large steps.</p>
"""),
    ("Caches and memory", """
<h1>Caches and memory</h1>
<p>Code$ and Data$ show set/way residency and occupancy. Data$ replays the
observed access stream through the matching 2-way geometry to estimate misses.
Hotspots attributes fetch-to-retire latency and D-cache misses to PCs. Its
<b>Σ lat</b> column sums the latency of every dynamic instruction at that PC;
because in-flight instructions overlap, this instruction-cycle total can exceed
the retired-lifecycle span shown in the header. That span is printed against the
full captured cycle window, exposing an in-flight tail. A held PC can be waiting
on an older instruction, so use <b>D$ miss</b> to identify the memory PC
producing replayed misses.</p>
<p>Memory can follow EIP, ESP, or the latest access. Mem map plots address
against retirement order: a diagonal is a stride, a horizontal band is a hot
location, and a cloud is irregular access. Click a point to select its trace
row, pin Registers, and highlight its exact bytes in Memory.</p>
"""),
    ("System and snapshots", """
<h1>System mode and snapshots</h1>
<p>System mode places a BIOS-style raw image so its last byte ends at 1 MiB and
starts the core at F000:FFF0. Use it for paging and protected-mode fixtures.
The SoC option additionally requires a current <code>build.sh --soc</code>
library for port I/O, PIC, and PIT behavior.</p>
<p>Open Snapshot accepts a matching <code>.aux</code>/<code>.vlt</code> pair.
Its timeline begins at the restored point because the snapshot stores model
and memory state, not the earlier visual history.</p>
"""),
    ("Shortcuts", """
<h1>Keyboard and mouse reference</h1>
<table cellspacing="6">
 <tr><td><b>Ctrl+O</b></td><td>open program, Assembly, or C for the active workspace</td></tr>
 <tr><td><b>Ctrl+S</b></td><td>save the active Assembly or C source</td></tr>
 <tr><td><b>Ctrl+F</b></td><td>find in the active Assembly or C source</td></tr>
 <tr><td><b>F3 / Shift+F3</b></td><td>next / previous source or Trace match</td></tr>
 <tr><td><b>Ctrl+Shift+O</b></td><td>open snapshot</td></tr>
 <tr><td><b>Ctrl+Shift+R</b></td><td>reload the current program from disk</td></tr>
 <tr><td><b>Ctrl+0</b></td><td>reset panel proportions</td></tr>
 <tr><td><b>Alt+V / Alt+A / Alt+C</b></td><td>Visualizer / Assembly / C workspace</td></tr>
 <tr><td><b>Alt+1 … Alt+0</b></td><td>select Code$ … Mem map analysis tab</td></tr>
 <tr><td><b>R</b></td><td>reset or restore snapshot</td></tr>
 <tr><td><b>.</b></td><td>one clock</td></tr>
 <tr><td><b>I / Space</b></td><td>next retired instruction</td></tr>
 <tr><td><b>F5</b></td><td>run/pause</td></tr>
 <tr><td><b>[ / ]</b></td><td>previous/next selected event class</td></tr>
 <tr><td><b>Ctrl+- / Ctrl+=</b></td><td>zoom the focused Pipeline cycle axis</td></tr>
 <tr><td><b>↑/↓, PgUp/PgDn, Home/End</b></td><td>traverse focused Pipeline rows</td></tr>
 <tr><td><b>/</b></td><td>focus the trace filter from anywhere</td></tr>
 <tr><td><b>Enter / F3</b></td><td>next filtered retirement (Visualizer)</td></tr>
 <tr><td><b>Shift+F3</b></td><td>previous filtered retirement (Visualizer)</td></tr>
 <tr><td><b>Escape</b></td><td>clear the trace filter</td></tr>
 <tr><td><b>Ctrl+Space</b></td><td>assembly opcode completion</td></tr>
 <tr><td><b>Ctrl+Enter</b></td><td>assemble+run, or compile C</td></tr>
 <tr><td><b>F1</b></td><td>this guide</td></tr>
</table>
<p>Click a trace/timing row to pin it. Shift-click a second timing row to
measure cycle distance. Click the IPC sparkline to seek a cycle.</p>
"""),
))


class UserGuideDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Pipeviz User Guide")
        self.resize(980, 700)
        root = QVBoxLayout(self)
        heading = QLabel("Pipeviz help")
        heading.setStyleSheet("font-size:16px;font-weight:bold;padding:4px;")
        root.addWidget(heading)
        body = QHBoxLayout()
        self.index = QListWidget()
        self.index.setFixedWidth(205)
        self.index.addItems(PAGES.keys())
        self.page = QTextBrowser()
        self.page.setOpenExternalLinks(False)
        font = QFont()
        font.setPointSize(10)
        self.page.setFont(font)
        body.addWidget(self.index)
        body.addWidget(self.page, 1)
        root.addLayout(body, 1)
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.close)
        root.addWidget(buttons)
        self.index.currentTextChanged.connect(self._set_page)
        self.show_page("Getting started")

    def _set_page(self, title):
        if title in PAGES:
            self.page.setHtml(PAGES[title])

    def show_page(self, title):
        titles = list(PAGES)
        row = titles.index(title) if title in PAGES else 0
        self.index.setCurrentRow(row)
        self._set_page(titles[row])
        self.page.verticalScrollBar().setValue(0)
