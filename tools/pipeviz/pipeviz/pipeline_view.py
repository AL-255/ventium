# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The main pipeline panel.

  * StageBoard — a LIVE snapshot of the classic P5 in-order stages
    (PF -> D1 -> D2 -> EX -> WB, plus the FP X1/X2/WF/ER stages) as U / V / FP
    lanes, the cell(s) the core works in THIS clock lit + labelled with the
    occupying instruction. Derived from the FSM `state` (rtl/core/core.sv).

  * Konata — a gem5/Konata-style per-instruction pipeline timing diagram:
    **Y axis = instructions** (one row each, retire order, newest at bottom),
    **X axis = cycles** (time). Each instruction's lifecycle is reconstructed
    from the per-cycle FSM trace and drawn as a horizontal run of coloured stage
    cells (F fetch/fill, D decode, X execute, M mem, W writeback; '=' stalls
    stretch a stage), so consecutive instructions cascade diagonally — the
    classic superscalar pipeline diagram. A frozen left gutter holds the
    instruction labels; a synced top axis shows the cycle ticks.
"""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QLabel, QScrollArea,
                               QSizePolicy, QHBoxLayout, QGridLayout, QToolButton)
from PySide6.QtGui import (QPainter, QColor, QFont, QFontMetrics, QPen,
                           QKeySequence, QShortcut)
from PySide6.QtCore import Qt, QRect, QSize, QPoint, Signal

from . import disasm
from .disasm import (C_PIPE, C_FILL, C_SLOW, C_FP, C_WALK, C_HALT,
                     C_STALL, C_MISPRED)

INT_STAGES = ["PF", "D1", "D2", "EX", "WB"]
FP_STAGES = ["X1", "X2", "WF", "ER"]
GROUPS = [("U", INT_STAGES, C_PIPE), ("V", INT_STAGES, C_PIPE), ("FP", FP_STAGES, C_FP)]
_BG = "#0d1117"
_GRID = "#30363d"
_DIM = "#161b22"
_TXT = "#c9d1d9"
_MUT = "#8b949e"
_FOCUS = "#58a6ff"


def _mono(pt=9, bold=False):
    f = QFont("monospace"); f.setStyleHint(QFont.Monospace); f.setPointSize(pt); f.setBold(bold)
    return f


# ===========================================================================
# Live stage board
# ===========================================================================
class StageBoard(QWidget):
    instructionClicked = Signal(int, str)  # live PC, U/V/FP lane

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(100)   # tightened so the starved Konata view gets the rows
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.NoFocus)
        self.setAccessibleName("Live pipeline stage board")
        self.setAccessibleDescription(
            "Occupied U, V, and FP cells can be clicked or selected with arrow "
            "keys and Enter to locate authored assembly")
        self._cells = self._blank()
        self._lane_pcs = {}
        self._lane_rects = []
        self._kbd_lane = None
        self._status = "no image loaded"
        self._statecol = _DIM
        self._sync_accessible_description()

    def _sync_accessible_description(self):
        navigation = (
            "Occupied lanes can be clicked, or use arrow keys to choose one "
            "and Enter to open its linked Assembly line.")
        if not self._lane_pcs:
            self.setAccessibleDescription(
                f"{self._status}. No occupied source-linked lane. {navigation}")
            return
        occupied = []
        for lane in ("U", "V", "FP"):
            if lane not in self._lane_pcs:
                continue
            text = self._cells[lane][1] or "instruction"
            occupied.append(
                f"{lane}: PC 0x{int(self._lane_pcs[lane]):08x}, {text}")
        selected = (
            f" Keyboard lane {self._kbd_lane} selected."
            if self._kbd_lane in self._lane_pcs else "")
        self.setAccessibleDescription(
            f"{self._status}. Occupied " + "; ".join(occupied)
            + f".{selected} {navigation}")

    def _blank(self):
        return {"U": ([], ""), "V": ([], ""), "FP": ([], "")}

    def set_state(self, s, backend, bits):
        name = backend.state_name(s.state)
        lane, stage, color, desc = disasm.stage_of(name)
        self._statecol = color
        cells = self._blank()
        pcs = {}

        base = s.cs_base

        def dis(addr):
            code = backend.mem_read_linear(
                (int(base) + int(addr)) & 0xFFFFFFFF, 16,
                s.cr0, s.cr3, s.cr4)
            if code is None:
                return "unmapped"
            t, sz = disasm.text(code, addr, bits)
            return t

        issuing = (name == "S_PIPE" and s.stall_cnt == 0 and s.mispred_bubbles == 0
                   and s.pending_mem_pen == 0)
        if name == "S_PIPE":
            if s.ud_is_fp:
                cells["FP"] = ([0, 1, 3], dis(s.eip))
                pcs["FP"] = s.eip
            elif issuing:
                cells["U"] = ([3, 4], dis(s.eip))
                pcs["U"] = s.eip
                if s.pipe_pair:
                    cells["V"] = ([3, 4], dis(s.eip + s.ud_len))
                    pcs["V"] = s.eip + s.ud_len
            else:
                # Keep naming the held instruction while the pipe is blocked.  A
                # bare "stall" cell stated the symptom but hid which source line
                # owns it—the most useful fact for the cell's click-through.
                cells["U"] = ([3], f"stall · {dis(s.eip)}")
                pcs["U"] = s.eip
                self._statecol = C_STG_STALL    # not exec-green
        elif name == "S_PF":
            cells["U"] = ([0], f"I-fill {s.pf_word}/8")
            pcs["U"] = s.eip
        elif name == "S_FETCH":
            cells["U"] = ([0], dis(s.eip))
            pcs["U"] = s.eip
        elif name == "S_DECODE":
            cells["U"] = ([1, 2], dis(s.eip))
            pcs["U"] = s.eip
        elif name in ("S_LOAD", "S_LOAD2"):
            cells["U"] = ([3], "load " + dis(s.q_pc))
            pcs["U"] = s.q_pc
        elif name == "S_EXEC":
            cells["U"] = ([3], dis(s.q_pc))
            pcs["U"] = s.q_pc
        elif name in ("S_STORE", "S_USEQ", "S_IO", "S_INS"):
            cells["U"] = ([4], dis(s.q_pc))
            pcs["U"] = s.q_pc
        elif name == "S_FLOAD":
            cells["FP"] = ([0], "fp load")
            pcs["FP"] = s.q_pc
        elif name == "S_FEXEC":
            cells["FP"] = ([0, 1], dis(s.q_pc))
            pcs["FP"] = s.q_pc
        elif name in ("S_FSTORE", "S_FENV_ST", "S_FENV_LD"):
            cells["FP"] = ([3], "fp store")
            pcs["FP"] = s.q_pc
        elif name == "S_WALK":
            # An I-side walk belongs to the fetch PC; a D-side walk belongs to
            # the already-decoded instruction held in q_pc.
            pc = s.q_pc if s.walk_for_d else s.eip
            cells["U"] = ([3], f"{stage} · {dis(pc)}")
            pcs["U"] = pc
        elif name in ("S_HALT", "S_HLTWAIT", "S_F00F_HANG"):
            cells["U"] = ([4], stage)
            pcs["U"] = s.q_pc
        elif name != "S_RESET":
            # Keep every slow/system FSM state visible even when it has no
            # dedicated stage-board branch. The full state metadata determines
            # a representative physical lane; q_pc names the held instruction.
            pc = s.eip if lane == "FE" else s.q_pc
            if lane == "FP":
                cells["FP"] = ([0, 1, 3], f"{stage} · {dis(pc)}")
                pcs["FP"] = pc
            else:
                index = 0 if lane == "FE" else 3 if lane in ("U", "MEM") else 4
                cells["U"] = ([index], f"{stage} · {dis(pc)}")
                pcs["U"] = pc

        if s.fp_occ_pending and not cells["FP"][0]:
            cells["FP"] = ([0, 1, 3], "occ (busy)")
            pcs["FP"] = s.eip

        self._cells = cells
        self._lane_pcs = pcs
        # Do not put a dead, empty snapshot into the Tab order. It becomes a
        # keyboard control only while at least one lane has a source target.
        self.setFocusPolicy(Qt.StrongFocus if pcs else Qt.NoFocus)
        if self._kbd_lane not in pcs:
            self._kbd_lane = next(
                (lane for lane in ("U", "V", "FP") if lane in pcs), None)
        # Hit rectangles embed the PC from the frame that painted them. Invalidate
        # them immediately so a click delivered between a timer update and the
        # queued repaint can never navigate to the previous instruction.
        self._lane_rects = []
        haz = []
        # These counters are meaningful only while the fast-path FSM consumes
        # them. RTL intentionally leaves their last values latched in HALT and
        # system states; presenting those as live hazards fabricated activity.
        if name == "S_PIPE":
            if s.stall_cnt:
                haz.append(f"stall={s.stall_cnt}")
            if s.mispred_bubbles:
                haz.append(f"mispredict-bubble={s.mispred_bubbles}")
            if s.pending_mem_pen:
                haz.append(f"D$-pen={s.pending_mem_pen}")
        if s.fp_occ_pending: haz.append("fp-occupancy")
        hz = ("    " + ", ".join(haz)) if haz else ""
        if name != "S_PIPE":
            pair = ""
        elif not issuing:
            pair = "  [blocked]"
        elif s.ud_is_fp:
            pair = "  [FP]"
        elif s.pipe_pair:
            pair = "  [paired]"
        else:
            pair = "  [single]"
        self._status = f"{name}  ({desc})   eip=0x{s.eip:08x}   cyc={s.core_cyc}{pair}{hz}"
        self._sync_accessible_description()
        self.update()

    def reset(self):
        self._cells = self._blank()
        self._lane_pcs = {}
        self._lane_rects = []
        self._kbd_lane = None
        self.setFocusPolicy(Qt.NoFocus)
        self._status = "reset"
        self._statecol = _DIM
        self.unsetCursor()
        self.setToolTip("")
        self._sync_accessible_description()
        self.update()

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(_BG))
        W = self.width()
        lane_h = 18          # compact: this snapshot is sparse, give rows to Konata
        title_y = 3          # section titles band (lowered so it isn't clipped)
        hdr_y = 16           # stage-label band (separated from titles -> no collision)
        top = 28             # cells start
        lane_label_w = 38
        # collapse the FP group when idle so the integer stages get the width.
        fp_idle = not self._cells.get("FP", ([], ""))[0]
        int_frac = 0.86 if fp_idle else 0.62
        int_w = int((W - lane_label_w - 16) * int_frac)
        fp_x0 = lane_label_w + int_w + 16

        p.setFont(_mono(9, True)); p.setPen(QColor(C_PIPE))
        p.drawText(QRect(lane_label_w, title_y, int_w, 14), Qt.AlignLeft,
                   "Integer pipeline  (U / V)")
        if not fp_idle:                              # busy: title here; idle: in-lane
            p.setPen(QColor(C_FP))
            p.drawText(QRect(fp_x0, title_y, W - fp_x0 - 8, 14), Qt.AlignRight,
                       "FP pipeline")

        icw = int_w / len(INT_STAGES)
        fcw = (W - fp_x0 - 6) / len(FP_STAGES)
        # vertical gridlines anchoring every stage column, so the lit cell reads
        # as "the work is in stage EX" rather than a box floating in space. Drawn
        # at a clearly-visible luminance (three review rounds reported the old
        # near-black #222c37 lines as "absent" — the column structure must read
        # even when every cell is empty).
        grid_top, grid_bot = hdr_y - 1, top + 3 * lane_h + 1
        p.setPen(QColor("#454f5d"))
        for i in range(len(INT_STAGES) + 1):
            gx = int(lane_label_w + i * icw)
            p.drawLine(gx, grid_top, gx, grid_bot)
        if not fp_idle:
            for i in range(len(FP_STAGES) + 1):
                gx = int(fp_x0 + i * fcw)
                p.drawLine(gx, grid_top, gx, grid_bot)
        # stage-header band — raised to legend-white so the PF/D1/D2/EX/WB
        # column captions are as legible as the colour legend below.
        p.setFont(_mono(8, True)); p.setPen(QColor("#aab4c0"))
        for i, st in enumerate(INT_STAGES):
            p.drawText(QRect(int(lane_label_w + i * icw), hdr_y, int(icw), 12),
                       Qt.AlignCenter, st)
        if not fp_idle:
            for i, st in enumerate(FP_STAGES):
                p.drawText(QRect(int(fp_x0 + i * fcw), hdr_y, int(fcw), 12),
                           Qt.AlignCenter, st)

        lanes = [("U", "U", INT_STAGES, lane_label_w, icw, False),
                 ("V", "V", INT_STAGES, lane_label_w, icw, False),
                 ("FP", "FP", FP_STAGES, fp_x0, fcw, fp_idle)]
        self._lane_rects = []
        for r, (key, label, stages, x0, cw, idle) in enumerate(lanes):
            y = top + r * lane_h
            # lane label: as bright as U/V even when idle (was a near-invisible grey),
            # FP-purple when the FP pipe is actually busy.
            p.setFont(_mono(9, True))
            p.setPen(QColor(C_FP if (key == "FP" and not idle) else _MUT))
            p.drawText(QRect(2, y, lane_label_w - 4, lane_h),
                       Qt.AlignVCenter | Qt.AlignRight, label)
            if key == "FP" and idle:
                # one flat 'idle' strip + inline label, NOT 4 ghost empty stage cells
                # floating with no context off to the right.
                strip = QRect(int(x0) + 1, y + 2, int(W - x0 - 8), lane_h - 6)
                p.fillRect(strip, QColor("#12161d"))
                p.setPen(QColor("#6b7480")); p.setFont(_mono(8))
                p.drawText(strip.adjusted(0, 0, -5, 0),
                           Qt.AlignVCenter | Qt.AlignRight, "x87 FP idle")
                continue
            lit_idxs, text = self._cells.get(key, ([], ""))
            for i, st in enumerate(stages):
                cx = x0 + i * cw
                cell = QRect(int(cx) + 1, y + 2, int(cw) - 2, lane_h - 6)
                if i in lit_idxs:
                    p.fillRect(cell, QColor(self._statecol))
                    p.setPen(QColor(self._statecol).lighter(130)); p.drawRect(cell)
                    if key in self._lane_pcs:
                        self._lane_rects.append(
                            (QRect(cell), key, int(self._lane_pcs[key])))
                else:
                    # de-emphasise empty cells: faint fill, no hard border, so the
                    # single active stage is what the eye lands on.
                    p.fillRect(cell, QColor("#0f141b" if idle else _DIM))
            if lit_idxs and text:
                # draw the label in the LAST occupied stage cell only (one column),
                # so it never straddles a column divider.
                hi = max(lit_idxs)
                cell = QRect(int(x0 + hi * cw) + 1, y + 2, int(cw) - 2, lane_h - 6)
                p.setPen(QColor("#0d1117") if QColor(self._statecol).lightness() > 140
                         else QColor(_TXT))
                p.setFont(_mono(8, True))
                fm = QFontMetrics(p.font())
                p.drawText(cell, Qt.AlignVCenter | Qt.AlignHCenter,
                           fm.elidedText(text, Qt.ElideRight, cell.width() - 3))
        # redraw the INTERNAL column gridlines ON TOP of the lane cells so the
        # PF|D1|D2|EX|WB boundaries stay crisp even where a fast-path uop lights two
        # adjacent stages (EX+WB) as same-colour blocks with no visible break.
        p.setPen(QColor("#5a6573"))
        for i in range(1, len(INT_STAGES)):
            gx = int(lane_label_w + i * icw)
            p.drawLine(gx, top, gx, top + 3 * lane_h)
        if not fp_idle:
            for i in range(1, len(FP_STAGES)):
                gx = int(fp_x0 + i * fcw)
                p.drawLine(gx, top, gx, top + 3 * lane_h)
        p.setFont(_mono(9)); p.setPen(QColor(_TXT))
        p.drawText(QRect(4, top + 3 * lane_h + 2, W - 8, 14), Qt.AlignLeft, self._status)
        if self.hasFocus():
            # A full-widget ring makes Tab/Shift+Tab location obvious; a second
            # outline identifies the exact occupied lane Enter will open.
            focus_pen = QPen(QColor(_FOCUS)); focus_pen.setWidth(2)
            p.setPen(focus_pen)
            p.drawRect(self.rect().adjusted(1, 1, -2, -2))
            for rect, lane, _pc in self._lane_rects:
                if lane == self._kbd_lane:
                    p.drawRect(rect.adjusted(1, 1, -1, -1))
        p.end()

    def _lane_at(self, point):
        return next(
            ((lane, pc) for rect, lane, pc in self._lane_rects
             if rect.contains(point)),
            None)

    def mouseMoveEvent(self, event):
        point = event.position().toPoint()
        hit = self._lane_at(point)
        if hit is None:
            self.unsetCursor()
            self.setToolTip("")
        else:
            lane, pc = hit
            self.setCursor(Qt.PointingHandCursor)
            self.setToolTip(
                f"{lane} in-flight instruction · PC 0x{pc:08x}\n"
                "Click to highlight its line in linked Assembly source")
        super().mouseMoveEvent(event)

    def leaveEvent(self, event):
        self.unsetCursor()
        self.setToolTip("")
        super().leaveEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            hit = self._lane_at(event.position().toPoint())
            if hit is not None:
                lane, pc = hit
                self._kbd_lane = lane
                self._sync_accessible_description()
                self.setFocus(Qt.MouseFocusReason)
                self.instructionClicked.emit(pc, lane)
                event.accept()
                return
        super().mousePressEvent(event)

    def focusInEvent(self, event):
        if self._kbd_lane not in self._lane_pcs:
            self._kbd_lane = next(
                (lane for lane in ("U", "V", "FP")
                 if lane in self._lane_pcs), None)
        self._sync_accessible_description()
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event):
        self.update()
        super().focusOutEvent(event)

    def keyPressEvent(self, event):
        lanes = [lane for lane in ("U", "V", "FP") if lane in self._lane_pcs]
        key = event.key()
        if key in (Qt.Key_Left, Qt.Key_Up, Qt.Key_Right, Qt.Key_Down,
                   Qt.Key_Home, Qt.Key_End):
            if not lanes:
                event.accept()
                return
            if key == Qt.Key_Home:
                index = 0
            elif key == Qt.Key_End:
                index = len(lanes) - 1
            else:
                current = (
                    lanes.index(self._kbd_lane)
                    if self._kbd_lane in lanes else 0)
                delta = -1 if key in (Qt.Key_Left, Qt.Key_Up) else 1
                index = max(0, min(len(lanes) - 1, current + delta))
            self._kbd_lane = lanes[index]
            self._sync_accessible_description()
            self.update()
            event.accept()
            return
        if key in (Qt.Key_Return, Qt.Key_Enter):
            if self._kbd_lane in self._lane_pcs:
                self.instructionClicked.emit(
                    int(self._lane_pcs[self._kbd_lane]), self._kbd_lane)
            event.accept()
            return
        super().keyPressEvent(event)


# ===========================================================================
# gem5 / Konata-style per-instruction pipeline view:
#   Y axis = instructions (one row each, retire order, newest at the bottom)
#   X axis = cycles (time, left -> right)
# Each instruction's lifecycle is reconstructed from the per-cycle FSM trace and
# drawn as a horizontal run of coloured stage cells (F fetch/fill, D decode,
# X execute, M mem, W writeback; stalls '=' stretch a stage). Consecutive
# instructions therefore cascade diagonally — the classic superscalar pipeline
# timing diagram. Dual-issued U+V instructions each get a row and share their
# execute/commit cycle column.
# ===========================================================================
ROW_H = 16
CELL_W = 20      # per-cycle column width — wide enough for a legible F/D/X glyph
_KONATA_CYCLE_CAP = 50000
                 # AND so the steep dual-issue diagonal fills more of the panel
                 # (fewer cycles per viewport-width) instead of a thin right strip.
GUTTER_W = 340   # widened to fit full mnemonics (e.g. 'mov eax, dword ptr [esi]')
HDR_H = 18


def _cycle_tick_step(cell_width):
    """Choose a readable axis interval for the current horizontal zoom."""
    for step in (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000):
        if step * cell_width >= 72:
            return step
    return 5000


# Per-stage colours for the Konata cells — each P5 stage gets a DISTINCT hue so
# fetch/decode/exec/mem/writeback are tellable apart by colour, not just letter.
C_STG_FILL = "#e0a72e"    # I-cache fill          (amber)
C_STG_FETCH = "#4a9eff"   # slow front-end fetch  (blue)
C_STG_DEC = "#39c5cf"     # decode                (teal)
C_STG_MEM = "#f0883e"     # load/store address    (orange)
C_STG_WB = "#7d8fc9"      # writeback (slate-blue — out of the wb/FP/walk purple cluster)
C_STG_EXEC = C_PIPE       # execute (integer)     (green)
C_STG_STALL = "#7a828d"   # stall / bubble        (grey — distinct from amber fill)
C_STG_SYS = "#a87f55"     # system / microcode    (bronze — a DEDICATED Konata-cell
                          # colour, pulled clear of the L-fill amber it used to share
                          # via C_SYS so the 'S' glyph is decodable + has a legend swatch)

_GPR_NAMES = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]  # by GPR index
_FLAG_REG = 8         # dependency-edge sentinel for an EFLAGS dependency (label 'flags')

# Konata cell glyph -> full stage name, for the per-cell hover tooltip.
_GLYPH_STAGE = {"F": "Fetch", "L": "I-cache line fill", "D": "Decode",
                "X": "Execute", "M": "Mem (load/store)", "W": "Writeback",
                "=": "Stall / bubble", "!": "Mispredict flush", "w": "Page-walk",
                ".": "Halt", "S": "System / microcode"}


def _recolor_fp(cells, mnem):
    """Cycle-mode x87 ops execute on the S_PIPE fast path (green X); recolour
    their execute cells to the FP purple when the mnemonic is an x87 op."""
    if not (mnem[:1] == "f" and mnem[:2] not in ("fs", "gs")):
        return list(cells)
    return [(cy, ch, C_FP if co == C_STG_EXEC else co) for (cy, ch, co) in cells]


def _add_frontend(cells, history_start=1):
    """The dual-issue fast path collapses fetch/decode/execute into one clock, so
    a fast-path op reconstructs as a single 'X' cell. The Ventium is still a P5
    5-stage pipeline, so synthesise the in-flight Fetch + Decode stages in the two
    cycles preceding the commit — this makes consecutive instructions cascade
    through F -> D -> X like a real superscalar pipeline diagram, instead of a
    lone X. Only added when the op has NO real front-end cells already (an
    I-cache fill 'L' or slow-path F/D); a stall '=' or bare 'X' gets the shadow.
    Clamp that illustrative shadow to the captured timeline: the first
    instruction must never invent cycle -1/0 (or pre-snapshot history)."""
    # Inspect the whole pending lifecycle, not only its first cell. A short
    # pre-fill stall followed by real L/F/D work used to receive an additional
    # synthetic F/D prefix, visually duplicating the front end.
    if not cells or any(cell[1] in ("L", "F", "D", "M", "W") for cell in cells):
        return cells
    a0 = cells[0][0]
    frontend = [
        (a0 - 2, "F", C_STG_FETCH),
        (a0 - 1, "D", C_STG_DEC),
    ]
    return [cell for cell in frontend if cell[0] >= history_start] + cells


def _stage_cell(name, ret, stall, mispred):
    """Map one cycle's FSM state to a (letter, colour) lifecycle cell."""
    if name == "S_PIPE":
        if mispred:
            return ("!", C_MISPRED)
        if ret:
            return ("X", C_STG_EXEC)    # issue + execute + writeback (fast path)
        return ("=", C_STG_STALL)       # materialised stall / bubble
    if name == "S_PF":
        return ("L", C_STG_FILL)        # I-cache Line fill (distinct glyph from fetch)
    if name == "S_FETCH":
        return ("F", C_STG_FETCH)
    if name == "S_DECODE":
        return ("D", C_STG_DEC)
    if name in ("S_LOAD", "S_LOAD2", "S_ENTER"):
        return ("M", C_STG_MEM)
    if name == "S_EXEC":
        return ("X", C_STG_EXEC)
    if name in ("S_STORE", "S_USEQ", "S_IO", "S_INS"):
        return ("W", C_STG_WB)
    if name == "S_FLOAD":
        return ("F", C_FP)
    if name == "S_FEXEC":
        return ("X", C_FP)
    if name in ("S_FSTORE", "S_FENV_ST", "S_FENV_LD"):
        return ("W", C_FP)
    if name == "S_WALK":
        return ("w", C_WALK)
    if name in ("S_HALT", "S_HLTWAIT", "S_F00F_HANG"):
        return (".", C_HALT)
    return ("S", C_STG_SYS)


class _KonataPlot(QWidget):
    """The cell grid (cycles x instructions). Reconstructs per-instruction
    lifecycles from the per-cycle trace and paints only the visible region."""
    rowClicked = Signal(int)     # emits the retire n of the clicked instruction
    zoomRequested = Signal(int)  # focused Ctrl+- / Ctrl+=, reliable after dialogs
    escapeRequested = Signal()   # clear filter first, otherwise return pin to LIVE

    def __init__(self, parent=None):
        super().__init__(parent)
        self.bits = 32
        self.cs_base = 0
        self.backend = None
        self.insns = []          # [{n,pc,pipe,mnem,cells:[(cyc,ch,color)],c0,c1,reads,writes}]
        self.history_start = 1
        self.base_cyc = 1
        self.max_cyc = 1
        self.cell_w = CELL_W
        self.sel_row = None
        self.sel_pc = None       # selected PC → tint all its other executions (loop)
        self._dep_edges = []     # [(prod_row, reg_idx, gating?)] producers of sel_row's sources
        self._dep_for_row = -1   # sel_row the edges were computed for (recompute on change)
        self.playhead = None     # pinned cycle (vertical marker)
        self.anchor = None       # shift-click second marker → cycle-range Δ measure
        self.stat = dict(uret=0, vret=0, fill=0, stall=0, mispred=0, walk=0)
        self._pending = []       # accumulated cells since the last retirement
        self._cyc_row = {}       # retire cyc -> row index
        self.empty_message = (
            "no program loaded — use File → Open example or Ctrl+O")
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setAccessibleName("Pipeline timing diagram")
        self.setAccessibleDescription(
            "Use arrows, Page Up and Page Down, Home and End to select "
            "retirements; Ctrl plus and minus zoom; Escape returns to live state")
        self.setToolTip(
            "Click a row to pin it; Shift-click sets a cycle-distance anchor. "
            "Use Up/Down, Page Up/Down, Home, and End to traverse retirements.")
        self._sync_accessible_description()

    def reset(self, backend, bits, history_start=1):
        self.backend = backend
        self.bits = bits
        self.insns = []
        self.history_start = max(1, int(history_start))
        self.base_cyc = self.history_start
        self.max_cyc = self.history_start - 1
        self.sel_row = None
        self.sel_pc = None
        self._dep_edges = []
        self._dep_for_row = -1
        self.playhead = None
        self.anchor = None
        self.stat = dict(uret=0, vret=0, fill=0, stall=0, mispred=0, walk=0)
        self._pending = []
        self._cyc_row = {}
        self.empty_message = (
            "no instructions retired in the captured cycle window"
            if self.history_start > 1 else
            "no instructions retired yet — use Insn, Step N, or Run")
        # setFixedSize() is used while populated. Reset both constraints here so
        # a shorter replacement session cannot inherit the old giant canvas and
        # stale scrollbar range until its first retirement.
        self.setFixedSize(1, 1)
        self._sync_accessible_description()

    def _resize_canvas(self):
        w = (self.max_cyc - self.base_cyc + 3) * self.cell_w
        # one row of bottom slack so a row-aligned bottom-follow scroll keeps the
        # newest instruction fully visible (never a clipped half-row at the top).
        h = max(1, len(self.insns) * ROW_H + ROW_H)
        self.setFixedSize(max(1, w), h)

    def _sync_accessible_description(self):
        navigation = (
            "Use Up and Down, Page Up and Page Down, Home and End to select "
            "retirements; Control plus and minus zoom; Escape returns live.")
        if not self.insns:
            self.setAccessibleDescription(f"{self.empty_message}. {navigation}")
            return
        context = (
            f"{len(self.insns)} retirements, cycles {self.base_cyc} through "
            f"{self.max_cyc}.")
        if self.sel_row is not None and 0 <= self.sel_row < len(self.insns):
            insn = self.insns[self.sel_row]
            context += (
                f" Selected retirement n={int(insn['n'])}, lane {insn['pipe']}, "
                f"PC 0x{int(insn['pc']):08x}, {insn['mnem']}, "
                f"cycles {int(insn['c0'])} through {int(insn['c1'])}.")
        else:
            context += " No exact retirement selected."
        if self.playhead is not None:
            context += f" Playhead cycle {int(self.playhead)}."
        self.setAccessibleDescription(f"{context} {navigation}")

    def set_cell_width(self, width):
        self.cell_w = max(6, int(width))
        self._resize_canvas()
        self.update()

    def _retired_decode(self, backend, rec, pc):
        """Decode the immutable bytes captured for this retirement.

        Re-reading ``current CS.base + PC`` is wrong after paging/segmentation
        changes and for self-modifying code. It can also make the dependency
        overlay analyze a different opcode than Trace. Older/incomplete bridges
        may omit a record, so retain a clearly scoped live-memory fallback.
        """
        if rec is not None and int(rec.nbytes):
            code = bytes(rec.bytes[:int(rec.nbytes)])
            bits = 32 if rec.d32 else 16
        else:
            code = backend.mem_read(self.cs_base + pc, 16)
            bits = self.bits
        _size, mn, ops, _fields = disasm.disasm_one(code, pc, bits)
        text = f"{mn} {ops}".strip() or "?"
        reads, rflags = disasm.read_regs(code, pc, bits)
        writes, wflags = disasm.written_regs(code, pc, bits)
        return text, reads, writes, rflags, wflags

    def _compute_deps(self, row):
        """For the selected consumer row, find the PRODUCER of each source GPR — the
        most-recent prior instruction that wrote it — by a bounded backward scan of
        insns[]. An edge is 'gating' (drawn amber) when its producer commits DURING
        the consumer's lifecycle (the value arrived late, so it plausibly caused the
        wait); otherwise the dependency was satisfied early and is drawn dim. This is
        a pure dataflow fact (def-use), so a dim edge never falsely claims to be a
        stall cause — it just shows where the value came from."""
        self._dep_edges = []
        if not (row is not None and 0 <= row < len(self.insns)):
            return
        cons = self.insns[row]
        need = set(cons.get("reads", ()))
        need_flags = bool(cons.get("rfl"))    # conditional branch / adc / etc. read EFLAGS
        if not need and not need_flags:
            return
        found = {}                            # GPR index -> producer row
        flag_prod = None                      # producer row of the EFLAGS value
        for j in range(row - 1, max(-1, row - 400), -1):
            pj = self.insns[j]
            for w in pj.get("writes", ()):
                if w in need and w not in found:
                    found[w] = j
            if need_flags and flag_prod is None and pj.get("wfl"):
                flag_prod = j
            if len(found) == len(need) and (not need_flags or flag_prod is not None):
                break
        # amber 'gating' is RELIABLE only when the producer's result arrives right as
        # the consumer's stall LIFTS — i.e. its commit lands within ±1 cycle of the
        # last '=' stall cell. That distinguishes a true RAW/load-use (the value was
        # the thing being waited on) from a producer that merely commits somewhere in
        # a long structural stall (e.g. dmiss 'dec ecx' stalls BEHIND a load, not on
        # its ecx producer — that edge stays dim, no false stall-cause claim).
        stalls = [cyc for (cyc, ch, _) in cons["cells"] if ch == "="]
        s_end = max(stalls) if stalls else None
        def _gating(jrow):
            return s_end is not None and (s_end - 1 <= self.insns[jrow]["c1"] <= s_end + 2)
        for reg, j in found.items():
            self._dep_edges.append((j, reg, _gating(j)))
        if flag_prod is not None:             # _FLAG_REG=8 sentinel -> labelled 'flags'
            self._dep_edges.append((flag_prod, _FLAG_REG, _gating(flag_prod)))

    def ingest(self, backend, since_cyc):
        new = backend.get_cycles(since_cyc, 8192)
        # Fetch the matching immutable retirement records once per cycle batch.
        # U/V IDs are contiguous in current bridges, but build the map by the
        # actual record ID so snapshot epochs and a missing old record stay safe.
        retire_ids = [
            int(retire_n)
            for cycle in new
            for retired, retire_n in (
                (getattr(cycle, "retU", 0), getattr(cycle, "nU", 0)),
                (getattr(cycle, "retV", 0), getattr(cycle, "nV", 0)))
            if retired
        ]
        retire_by_n = {}
        if retire_ids:
            first_n, last_n = min(retire_ids), max(retire_ids)
            retire_by_n = {
                int(record.n): record
                for record in backend.get_retires(
                    first_n, last_n - first_n + 1)
            }
        for c in new:
            name = backend.state_name(c.state)
            # Bubble/penalty registers retain their last value outside S_PIPE.
            # Gate them by their consuming state so HALT/system clocks do not
            # become hundreds of phantom stalls or mispredicts.
            stall = (
                name == "S_PIPE"
                and (c.stall_cnt > 0 or c.pending_mem_pen > 0))
            mispred = name == "S_PIPE" and c.mispred_bubbles > 0
            ret = bool(c.retU or c.retV)
            ch, col = _stage_cell(name, ret, stall, mispred)
            self._pending.append((c.cyc, ch, col))
            self.max_cyc = c.cyc
            if name == "S_PF":
                self.stat["fill"] += 1
            if name == "S_WALK":
                self.stat["walk"] += 1
            if mispred:
                self.stat["mispred"] += 1
            if stall and name == "S_PIPE":
                self.stat["stall"] += 1
            if c.retU:
                mn, reads, writes, rfl, wfl = self._retired_decode(
                    backend, retire_by_n.get(int(c.nU)), c.pcU)
                cells = _add_frontend(
                    _recolor_fp(self._pending, mn), self.history_start)
                self.insns.append(dict(n=c.nU, pc=c.pcU, pipe="U", mnem=mn,
                                       cells=cells, c0=cells[0][0], c1=c.cyc,
                                       reads=reads, writes=writes, rfl=rfl, wfl=wfl))
                self._cyc_row[c.cyc] = len(self.insns) - 1
                self.stat["uret"] += 1
                self._pending = []
            if c.retV:
                mn, reads, writes, rfl, wfl = self._retired_decode(
                    backend, retire_by_n.get(int(c.nV)), c.pcV)
                vcol = C_FP if (mn[:1] == "f" and mn[:2] not in ("fs", "gs")) else C_PIPE
                cells = _add_frontend(
                    [(c.cyc, "X", vcol)], self.history_start)
                self.insns.append(dict(n=c.nV, pc=c.pcV, pipe="V", mnem=mn,
                                       cells=cells, c0=cells[0][0], c1=c.cyc,
                                       reads=reads, writes=writes, rfl=rfl, wfl=wfl))
                self._cyc_row[c.cyc] = len(self.insns) - 1
                self.stat["vret"] += 1
        if len(self.insns) > 9000:          # rolling cap
            drop = len(self.insns) - 9000
            self.insns = self.insns[drop:]
            self._cyc_row = {v["c1"]: i for i, v in enumerate(self.insns)}
            if self.sel_row is not None:
                self.sel_row -= drop
            self._dep_for_row = -1        # row indices shifted → recompute dep edges
        self.base_cyc = (self.insns[0]["c0"] if self.insns
                         else self.history_start)
        self._resize_canvas()
        self._sync_accessible_description()
        return self.max_cyc

    def _x(self, cyc):
        return (cyc - self.base_cyc) * self.cell_w

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(ev.rect(), QColor(_BG))
        if not self.insns:
            p.setPen(QColor(_MUT)); p.setFont(_mono(10))
            p.drawText(self.rect(), Qt.AlignCenter, self.empty_message)
            if self.hasFocus():
                pen = QPen(QColor(_FOCUS)); pen.setWidth(2); p.setPen(pen)
                p.drawRect(ev.rect().adjusted(1, 1, -2, -2))
            p.end(); return
        vis = ev.rect()
        if self._dep_for_row != self.sel_row:        # recompute dep edges on re-select
            self._compute_deps(self.sel_row)
            self._dep_for_row = self.sel_row
        # vertical gridlines every 10 cycles so a cell's cycle is readable —
        # dim-but-legible (#2b3340 ≈ 2x the old near-black #171c24 contrast),
        # kept below the stage board's #454f5d so they don't fight the dense cells.
        p.setPen(QColor("#2b3340"))
        tick = _cycle_tick_step(self.cell_w)
        gc = self.base_cyc + ((tick - self.base_cyc % tick) % tick)
        while True:
            gx = self._x(gc)
            if gx > vis.right():
                break
            if gx >= vis.left():
                p.drawLine(gx, vis.top(), gx, vis.bottom())
            gc += tick
            if gc > self.max_cyc + tick:
                break
        # column highlights drawn BEHIND the cells — opaque cells then paint on top,
        # so the tint only shows through the inter-cell gaps and never washes a
        # glyph out (the playhead used to alpha-blend OVER the cells it crossed).
        if self.playhead is not None and self.anchor is not None:
            xa = self._x(self.anchor) + self.cell_w // 2
            xp = self._x(self.playhead) + self.cell_w // 2
            blo, bhi = sorted((xa, xp))
            p.fillRect(QRect(blo, vis.top(), max(1, bhi - blo), vis.height()),
                       QColor(240, 180, 70, 30))        # translucent AMBER Δ band
            p.setPen(QColor("#e3b341"))                 # amber Δ-anchor line (behind cells)
            p.drawLine(xa, vis.top(), xa, vis.bottom())
        if self.playhead is not None:
            pcolx = self._x(self.playhead)
            if pcolx <= vis.right() and pcolx + self.cell_w >= vis.left():
                p.fillRect(QRect(pcolx, vis.top(), self.cell_w, vis.height()),
                           QColor(57, 197, 207, 34))    # playhead column tint
            px = self._x(self.playhead) + self.cell_w // 2
            if vis.left() - 2 <= px <= vis.right() + 2:
                p.setPen(QColor("#39c5cf"))             # cyan playhead line (behind cells)
                p.drawLine(px, vis.top(), px, vis.bottom())
        r0 = max(0, vis.top() // ROW_H - 1)
        r1 = min(len(self.insns), vis.bottom() // ROW_H + 2)
        xlo, xhi = vis.left() - self.cell_w, vis.right() + self.cell_w
        for r in range(r0, r1):
            ins = self.insns[r]
            y = r * ROW_H
            if r % 2:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#0f141b"))
            if r == self.sel_row:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#1c2531"))
            elif self.sel_pc is not None and ins["pc"] == self.sel_pc:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#172230"))
            cells = ins["cells"]
            i = 0
            while i < len(cells):
                cyc, ch, col = cells[i]
                if ch == "=":            # collapse a contiguous stall run into one block
                    j = i
                    while j < len(cells) and cells[j][1] == "=":
                        j += 1
                    x0 = self._x(cells[i][0])
                    x1 = self._x(cells[j - 1][0]) + self.cell_w - 1
                    if x1 >= xlo and x0 <= xhi:
                        # inset the bar (3px gap on the left) so its border never
                        # abuts / clips the preceding lettered cell's glyph.
                        span = QRect(
                            x0 + 2, y + 1,
                            max(self.cell_w - 4, x1 - x0 - 3), ROW_H - 2)
                        p.fillRect(span, QColor(col))
                        # light border so the stall span stands out on any row
                        # background (incl. the amber Δ band / zebra stripe).
                        p.setPen(QColor("#aab4c0")); p.drawRect(span)
                        if span.width() >= 12:
                            p.setFont(_mono(8 if self.cell_w < 18 else 9, True))
                            p.setPen(QColor("#0d1117"))
                            p.drawText(
                                span, Qt.AlignCenter,
                                f"={j - i}" if j - i > 1 else "=")
                    i = j
                else:
                    x = self._x(cyc)
                    if xlo <= x <= xhi:
                        cell = QRect(x, y + 1, self.cell_w - 1, ROW_H - 2)
                        p.fillRect(cell, QColor(col))
                        if self.cell_w >= 11:
                            p.setFont(_mono(8 if self.cell_w < 18 else 9, True))
                            p.setPen(
                                QColor("#0d1117")
                                if QColor(col).lightness() > 130 else QColor(_TXT))
                            p.drawText(cell, Qt.AlignCenter, ch)
                    i += 1
            # off-screen continuation cue: a chevron when this row's lifecycle runs
            # past the right viewport edge (scroll right for the rest). Paint it on an
            # opaque chip in the ROW's own background colour so it cleanly MASKS the
            # last cell's right sliver instead of muddying amber-on-blue INSIDE that
            # edge cell (it used to render as an unreadable 'F›' collision); on the
            # dark margin the chip matches the row bg and is invisible, so the
            # non-edge rows (chevron already on empty margin) look unchanged.
            if self._x(ins["c1"]) > vis.right():
                rowbg = ("#1c2531" if r == self.sel_row
                         else "#172230" if (self.sel_pc is not None
                                            and ins["pc"] == self.sel_pc)
                         else "#0f141b" if r % 2 else _BG)
                p.fillRect(QRect(vis.right() - 9, y + 1, 9, ROW_H - 2), QColor(rowbg))
                p.setFont(_mono(10, True)); p.setPen(QColor("#d29922"))   # amber 'more →'
                p.drawText(QRect(vis.right() - 11, y, 11, ROW_H),
                           Qt.AlignVCenter | Qt.AlignRight, "›")
        # producer→consumer DEPENDENCY EDGES for the selected instruction: a thin line
        # from each source register's PRODUCER (its commit cell) to this consumer's
        # first cell, labelled with the register. Amber + thick when the producer
        # commits DURING the consumer's lifecycle (a live dep that plausibly gated it);
        # dim when the value was ready early — a pure def-use trace that shows where an
        # input came from and never falsely claims to be the stall cause.
        if self._dep_edges and self.sel_row is not None and 0 <= self.sel_row < len(self.insns):
            p.save()
            cons = self.insns[self.sel_row]
            # anchor the arrowhead to the LEFT EDGE of the consumer's first cell (not its
            # centre) so the dot + edge terminus never overdraw the centred F/D/X glyph —
            # a near-vertical short edge used to land the dot right on top of the 'F'.
            cx = self._x(cons["c0"])
            cy = self.sel_row * ROW_H + ROW_H // 2
            p.setFont(_mono(8, True))
            for (j, reg, gating) in self._dep_edges:
                prod = self.insns[j]
                ex = self._x(prod["c1"]) + self.cell_w // 2
                ey = j * ROW_H + ROW_H // 2
                col = QColor("#e3b341" if gating else "#6e7681")
                pen = QPen(col); pen.setWidth(2 if gating else 1)
                p.setPen(pen)
                p.drawLine(ex, ey, cx, cy)
                p.setBrush(col); p.drawEllipse(QPoint(cx, cy), 2, 2)    # arrowhead at consumer
                p.setBrush(Qt.NoBrush)
                lbl = "flags" if reg == _FLAG_REG else (_GPR_NAMES[reg] if 0 <= reg < 8 else "?")
                lw = QFontMetrics(p.font()).horizontalAdvance(lbl) + 4
                # place the label in CLEAR space, never over the producer's own F/D/X
                # cells: prefer just RIGHT of its last cell; if that would clip the
                # viewport, tuck it just LEFT of its FIRST cell (the empty pre-fetch
                # columns); only if neither fits, clamp into view. The old code flipped
                # left ONTO the cells, occluding the F glyph when the producer sat near
                # the right frontier (brloop row 210), or left it clipped at the edge.
                rx = self._x(prod["c1"]) + self.cell_w + 3
                lx_left = self._x(prod["c0"]) - 3 - lw
                if rx + lw <= vis.right() - 2:
                    lx = rx
                elif lx_left >= vis.left() + 2:
                    lx = lx_left
                else:
                    lx = max(vis.left() + 2, vis.right() - 2 - lw)
                p.fillRect(QRect(lx, ey - 6, lw, 11), QColor("#0d1117"))
                p.setPen(col)
                p.drawText(QRect(lx, ey - 6, lw, 11), Qt.AlignCenter, lbl)
            p.restore()
        # Δ-measure LABEL only (the band fill + amber anchor line are drawn BEHIND
        # the cells so they can't punch through a glyph); the label sits on top.
        if self.playhead is not None and self.anchor is not None:
            xa = self._x(self.anchor) + self.cell_w // 2
            xp = self._x(self.playhead) + self.cell_w // 2
            lo, hi = sorted((xa, xp))
            dn = abs(self.playhead - self.anchor)
            p.setFont(_mono(8, True))
            lbl = f"Δ{dn}cyc"
            lw = QFontMetrics(p.font()).horizontalAdvance(lbl) + 6
            lx = max(lo, min((lo + hi) // 2 - lw // 2, hi - lw))
            ly = vis.top() + 16            # below the cyan 'cyc N' badge strip so the
            p.fillRect(QRect(lx, ly, lw, 12), QColor("#241c08"))   # two never abut
            p.setPen(QColor("#f0c674"))
            p.drawText(QRect(lx, ly, lw, 12), Qt.AlignCenter, lbl)
        # playhead 'cyc N' callout (the cyan line + column tint are BEHIND the cells)
        if self.playhead is not None:
            px = self._x(self.playhead) + self.cell_w // 2
            if vis.left() - 2 <= px <= vis.right() + 2:
                lbl = f"cyc {self.playhead}"
                p.setFont(_mono(8, True))
                tw = QFontMetrics(p.font()).horizontalAdvance(lbl) + 8
                bx = min(max(px - tw // 2, vis.left()), max(vis.left(), vis.right() - tw))
                p.fillRect(QRect(bx, vis.top(), tw, 13), QColor("#0b3036"))
                p.setPen(QColor("#7ce0e8"))
                p.drawText(QRect(bx, vis.top(), tw, 13), Qt.AlignCenter, lbl)
        if self.hasFocus():
            # The plot is a large canvas inside a scroll area, so outline the
            # currently exposed paint region rather than its mostly off-screen
            # full geometry.
            pen = QPen(QColor(_FOCUS)); pen.setWidth(2); p.setPen(pen)
            p.drawRect(vis.adjusted(1, 1, -2, -2))
        p.end()

    def focusInEvent(self, event):
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event):
        self.update()
        super().focusOutEvent(event)

    def mouseMoveEvent(self, ev):
        x = (ev.position().x() if hasattr(ev, "position") else ev.x())
        y = (ev.position().y() if hasattr(ev, "position") else ev.y())
        r = int(y // ROW_H)
        if 0 <= r < len(self.insns):
            ins = self.insns[r]
            # which exact cell is under the cursor → its cycle + full stage name
            cyc = int(x // self.cell_w) + self.base_cyc
            cell = next((c for c in ins["cells"] if c[0] == cyc), None)
            cellinfo = (f"\ncycle {cyc}: {_GLYPH_STAGE.get(cell[1], cell[1])}"
                        if cell else "")
            # per-instruction cycle breakdown: where this op's cycles went (the
            # stall count is the diagnostic — '8×Stall' means 8 cyc lost).
            cnt = {}
            for c in ins["cells"]:
                cnt[c[1]] = cnt.get(c[1], 0) + 1
            brk = "  ".join(f"{n}×{_GLYPH_STAGE.get(g, g)}"
                            for g, n in sorted(cnt.items(), key=lambda gn: -gn[1]))
            src = ",".join([_GPR_NAMES[s] for s in ins.get("reads", ())]
                           + (["flags"] if ins.get("rfl") else [])) or "—"
            dst = ",".join([_GPR_NAMES[d] for d in ins.get("writes", ())]
                           + (["flags"] if ins.get("wfl") else [])) or "—"
            self.setToolTip(
                f"n={ins['n']}  {ins['pipe']}  {ins['pc']:#010x}  {ins['mnem']}\n"
                f"cycles {ins['c0']}..{ins['c1']}  (commit @ {ins['c1']}, "
                f"{ins['c1'] - ins['c0'] + 1} cyc){cellinfo}\n"
                f"breakdown: {brk}\n"
                f"reads {src} · writes {dst}\n"
                f"click: pin regs + trace data deps · shift-click: Δ-measure anchor")

    def mousePressEvent(self, ev):
        self.setFocus(Qt.MouseFocusReason)
        y = (ev.position().y() if hasattr(ev, "position") else ev.y())
        r = int(y // ROW_H)
        if not (0 <= r < len(self.insns)):
            return
        cyc = self.insns[r]["c1"]
        if ev.modifiers() & Qt.ShiftModifier:
            # second marker: measure the cycle range to the current playhead.
            self.anchor = None if self.anchor == cyc else cyc
            self._sync_accessible_description()
            self.update()
            return
        self.select_row(r)

    def select_row(self, row, emit=True):
        if not self.insns:
            return
        row = max(0, min(int(row), len(self.insns) - 1))
        selected = self.insns[row]
        self.sel_row = row
        self.sel_pc = selected["pc"]
        self.playhead = selected["c1"]
        self._sync_accessible_description()
        self.update()
        if emit:
            self.rowClicked.emit(int(selected["n"]))

    def keyPressEvent(self, event):
        """Make the timing diagram usable without pixel-precise clicking."""
        key = event.key()
        if key == Qt.Key_Escape:
            self.escapeRequested.emit()
            event.accept()
            return
        if event.modifiers() & Qt.ControlModifier:
            if key == Qt.Key_Minus:
                self.zoomRequested.emit(-1)
                event.accept()
                return
            if key in (Qt.Key_Equal, Qt.Key_Plus):
                self.zoomRequested.emit(1)
                event.accept()
                return
        if key not in (Qt.Key_Up, Qt.Key_Down, Qt.Key_PageUp,
                       Qt.Key_PageDown, Qt.Key_Home, Qt.Key_End):
            super().keyPressEvent(event)
            return
        if not self.insns:
            event.accept()
            return
        if key == Qt.Key_Home:
            row = 0
        elif key == Qt.Key_End:
            row = len(self.insns) - 1
        elif self.sel_row is None:
            row = len(self.insns) - 1 if key in (Qt.Key_Up, Qt.Key_PageUp) else 0
        else:
            delta = {
                Qt.Key_Up: -1,
                Qt.Key_Down: 1,
                Qt.Key_PageUp: -10,
                Qt.Key_PageDown: 10,
            }.get(key, 0)
            row = self.sel_row + delta
        self.select_row(row)
        event.accept()


class _KonataGutter(QWidget):
    """Frozen left column: instruction labels (n / pipe / PC / mnemonic),
    vertically synced to the plot's scroll offset."""
    def __init__(self, plot, scroll, parent=None):
        super().__init__(parent)
        self.plot = plot
        self.scroll = scroll
        self.setFixedWidth(GUTTER_W)

    def mousePressEvent(self, ev):
        voff = self.scroll.verticalScrollBar().value()
        y = (ev.position().y() if hasattr(ev, "position") else ev.y())
        r = int((y + voff) // ROW_H)
        if 0 <= r < len(self.plot.insns):
            self.plot.setFocus(Qt.MouseFocusReason)
            self.plot.select_row(r)
            self.update()

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0b0f14"))
        p.setPen(QColor("#30363d"))
        p.drawLine(self.width() - 1, 0, self.width() - 1, self.height())
        voff = self.scroll.verticalScrollBar().value()
        ins = self.plot.insns
        r0 = max(0, voff // ROW_H - 1)
        r1 = min(len(ins), (voff + self.height()) // ROW_H + 2)
        p.setFont(_mono(8))
        fm = QFontMetrics(p.font())
        for r in range(r0, r1):
            it = ins[r]
            y = r * ROW_H - voff
            if r % 2:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#0f141b"))
            if r == self.plot.sel_row:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#1c2531"))
            elif self.plot.sel_pc is not None and it["pc"] == self.plot.sel_pc:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#172230"))
                p.fillRect(QRect(0, y, 2, ROW_H), QColor("#3b82c4"))  # same-PC marker
            p.setPen(QColor("#586069"))
            p.drawText(QRect(2, y, 42, ROW_H), Qt.AlignVCenter | Qt.AlignRight, str(it["n"]))
            p.setPen(QColor("#79c0ff" if it["pipe"] == "U" else "#e3b341"))
            p.drawText(QRect(46, y, 12, ROW_H), Qt.AlignVCenter | Qt.AlignHCenter, it["pipe"])
            p.setPen(QColor("#6e7681"))
            p.drawText(QRect(60, y, 56, ROW_H), Qt.AlignVCenter | Qt.AlignLeft, f"{it['pc']:08x}")
            # stall badge: total cycles this instruction occupied (>2 = it stalled)
            span = it["c1"] - it["c0"] + 1
            mnem_w = GUTTER_W - 120
            if span > 2:
                bw = 36
                mnem_w -= bw
                # colour-grade the latency by magnitude — dim for a normal fast-path
                # op, amber for a moderate stall, red for a heavy one — so the slow
                # instructions pop out of the gutter at a glance.
                lc = "#6e7681" if span <= 4 else (C_STALL if span < 10 else C_MISPRED)
                p.setPen(QColor(lc))
                p.drawText(QRect(GUTTER_W - bw - 6, y, bw, ROW_H),
                           Qt.AlignVCenter | Qt.AlignRight, f"{span}c")
            # split-colour: a NEUTRAL-grey mnemonic (same for every op) + the
            # operand(s) (a branch's target, a load's address) in the class accent,
            # so only the target is coloured (a branch's 'jne' is grey, not orange).
            parts = it["mnem"].split(" ", 1)
            mn = parts[0]; ops = parts[1] if len(parts) > 1 else ""
            _, icol = disasm.insn_class(mn)
            p.setPen(QColor("#828c99"))   # dim mnemonic — matches trace _MNEM_GREY
            p.drawText(QRect(118, y, mnem_w, ROW_H), Qt.AlignVCenter | Qt.AlignLeft, mn)
            mw = fm.horizontalAdvance(mn + " ")
            # operand field-coloring — same palette as the trace InsnDelegate &
            # the bytes legend: immediate=salmon, displacement=gold, branch
            # target=orange, registers/brackets class-coloured.
            if ops and mw < mnem_w:
                ox, limit = 118 + mw, 118 + mnem_w - 2
                is_br = (icol == disasm.CC_BRANCH)
                for txt, col in disasm.operand_segments(ops, is_br, icol):
                    if ox >= limit:
                        break
                    p.setPen(QColor(col))
                    p.drawText(QRect(ox, y, limit - ox, ROW_H),
                               Qt.AlignVCenter | Qt.AlignLeft, txt)
                    ox += fm.horizontalAdvance(txt)
        p.end()


class _KonataHeader(QWidget):
    """Top cycle axis, horizontally synced to the plot's scroll offset."""
    def __init__(self, plot, scroll, parent=None):
        super().__init__(parent)
        self.plot = plot
        self.scroll = scroll
        self.setFixedHeight(HDR_H)

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#161b22"))
        hoff = self.scroll.horizontalScrollBar().value()
        base, maxc = self.plot.base_cyc, self.plot.max_cyc
        p.setFont(_mono(7))
        p.setPen(QColor("#8b949e"))
        p.drawText(QRect(2, 0, GUTTER_W - 4, HDR_H), Qt.AlignVCenter | Qt.AlignLeft,
                   "inst ↓ / cycle →")
        # label the per-row latency column (the '3c'/'11c' badges) in the gutter band
        p.setPen(QColor("#6e7681"))
        p.drawText(QRect(GUTTER_W - 50, 0, 44, HDR_H), Qt.AlignVCenter | Qt.AlignRight, "lat")
        tick = _cycle_tick_step(self.plot.cell_w)
        c = base + ((tick - base % tick) % tick)
        while c <= maxc + tick:
            x = GUTTER_W + (c - base) * self.plot.cell_w - hoff
            if x > self.width():
                break
            if x >= GUTTER_W:
                p.setPen(QColor("#586069"))
                label_w = max(40, len(str(c)) * 7 + 8)
                p.drawText(
                    QRect(x - label_w // 2, 0, label_w, HDR_H),
                    Qt.AlignCenter, str(c))
            c += tick
        p.end()


class Konata(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(2, 2, 2, 2); v.setSpacing(2)
        self.title = QLabel("Pipeline view  (gem5/Konata — instruction × cycle)")
        self.title.setStyleSheet("font-weight:bold;")
        title_row = QHBoxLayout()
        title_row.setContentsMargins(0, 0, 0, 0)
        title_row.setSpacing(3)
        title_row.addWidget(self.title)
        title_row.addStretch(1)
        zoom_caption = QLabel("cycle zoom")
        zoom_caption.setStyleSheet("color:#6e7681;font-size:8px;")
        title_row.addWidget(zoom_caption)
        self.zoom_out_btn = QToolButton()
        self.zoom_out_btn.setText("−")
        self.zoom_out_btn.setAccessibleName("Zoom pipeline cycles out")
        self.zoom_out_btn.setToolTip("Zoom out the cycle axis (Ctrl+-)")
        self.zoom_reset_btn = QToolButton()
        self.zoom_reset_btn.setText("100%")
        self.zoom_reset_btn.setAccessibleName("Reset pipeline cycle zoom")
        self.zoom_reset_btn.setToolTip("Restore the default cycle scale")
        self.zoom_in_btn = QToolButton()
        self.zoom_in_btn.setText("+")
        self.zoom_in_btn.setAccessibleName("Zoom pipeline cycles in")
        self.zoom_in_btn.setToolTip("Zoom in the cycle axis (Ctrl+=)")
        for button in (self.zoom_out_btn, self.zoom_reset_btn, self.zoom_in_btn):
            button.setAutoRaise(True)
            button.setFixedHeight(18)
            title_row.addWidget(button)
        self.zoom_out_btn.setFixedWidth(20)
        self.zoom_reset_btn.setFixedWidth(42)
        self.zoom_in_btn.setFixedWidth(20)
        v.addLayout(title_row)
        # legend on its OWN line so it can't clip off the right edge
        lw = self._legend_widget()
        lh = QHBoxLayout(); lh.setContentsMargins(0, 0, 0, 0)
        lh.addWidget(lw); lh.addStretch(1)
        v.addLayout(lh)

        self.scroll = QScrollArea()
        # The timing plot is the keyboard control and exposes row navigation,
        # selection, and focus feedback. The containing scroll area otherwise
        # creates an unlabeled, visually inert Tab stop immediately before it.
        self.scroll.setFocusPolicy(Qt.NoFocus)
        self.scroll.setAccessibleName("Pipeline timing viewport")
        self.scroll.setWidgetResizable(False)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        self.scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        self.plot = _KonataPlot()
        self.scroll.setWidget(self.plot)
        self.header = _KonataHeader(self.plot, self.scroll)
        self.gutter = _KonataGutter(self.plot, self.scroll)

        grid = QGridLayout(); grid.setContentsMargins(0, 0, 0, 0); grid.setSpacing(0)
        grid.addWidget(self.header, 0, 0, 1, 2)
        grid.addWidget(self.gutter, 1, 0)
        grid.addWidget(self.scroll, 1, 1)
        v.addLayout(grid, 1)

        # snap wheel/keyboard scrolling to whole rows / whole cycle-columns so a
        # row is never sliced in half at the viewport edge.
        self.scroll.verticalScrollBar().setSingleStep(ROW_H)
        self.scroll.horizontalScrollBar().setSingleStep(self.plot.cell_w)
        # Auto-follow ("stick to the newest row/cycle") is EXPLICIT state, toggled
        # only by a user scroll. Inferring it each tick from value>=max-eps is
        # fragile: iter-9 row-snapped the at-rest position below max, so the next
        # tick read "not at bottom" and follow died — the viewport stranded on old
        # rows while cycles ran ahead, leaving the grid blank. The guard flag keeps
        # our own programmatic scrolls from clearing the stick.
        self._stick_v = True
        self._stick_h = True
        self._adjusting = False
        self.scroll.verticalScrollBar().valueChanged.connect(self._on_vscroll)
        self.scroll.horizontalScrollBar().valueChanged.connect(self._on_hscroll)
        self._last_cyc = 0
        self._history_truncated = False
        self._zoom_widths = (8, 12, CELL_W, 28, 40)
        self._zoom_index = self._zoom_widths.index(CELL_W)
        self.zoom_out_btn.clicked.connect(lambda: self._change_zoom(-1))
        self.zoom_in_btn.clicked.connect(lambda: self._change_zoom(1))
        self.zoom_reset_btn.clicked.connect(self.reset_zoom)
        self.plot.zoomRequested.connect(self._change_zoom)
        QShortcut(QKeySequence("Ctrl+-"), self).activated.connect(
            lambda: self._change_zoom(-1))
        QShortcut(QKeySequence("Ctrl+="), self).activated.connect(
            lambda: self._change_zoom(1))
        self._sync_zoom_controls()

    def _on_vscroll(self, val):
        # Force a FULL repaint of the plot's visible area on every scroll. The
        # QScrollArea optimises scrolling by blitting the existing pixels and only
        # repainting the newly-exposed strip — but the plot draws viewport-anchored
        # overlays (the playhead `cyc N` callout, the Δ-measure label, the column
        # tints) positioned from `ev.rect()`, which during a blit is just that thin
        # strip, so those overlays smeared / ghosted as you scrolled. A full update
        # makes ev.rect() cover the whole viewport again; Qt coalesces it with the
        # blit's strip paint, so there is no extra flicker.
        self.plot.update()
        self.gutter.update()
        if not self._adjusting:
            self._stick_v = val >= self.scroll.verticalScrollBar().maximum() - ROW_H

    def _on_hscroll(self, val):
        self.plot.update()        # full repaint — see _on_vscroll (blit smears the overlays)
        self.header.update()
        if not self._adjusting:
            self._stick_h = (
                val >= self.scroll.horizontalScrollBar().maximum() - self.plot.cell_w)

    def _sync_zoom_controls(self):
        pct = round(self.plot.cell_w / CELL_W * 100)
        self.zoom_reset_btn.setText(f"{pct}%")
        self.zoom_out_btn.setEnabled(self._zoom_index > 0)
        self.zoom_in_btn.setEnabled(self._zoom_index < len(self._zoom_widths) - 1)

    def _change_zoom(self, delta):
        self.set_zoom_index(self._zoom_index + int(delta))

    def reset_zoom(self):
        self.set_zoom_index(self._zoom_widths.index(CELL_W))

    def set_zoom_index(self, index):
        index = max(0, min(int(index), len(self._zoom_widths) - 1))
        if index == self._zoom_index:
            return
        hb = self.scroll.horizontalScrollBar()
        viewport_w = self.scroll.viewport().width()
        old_w = self.plot.cell_w
        # Preserve the user's investigation point, not an arbitrary pixel. When
        # the viewport is following live execution, the playhead/newest cycle is
        # the most useful anchor; after a manual scroll, preserve the centre cycle.
        if self._stick_h:
            focus_cyc = (
                self.plot.playhead
                if self.plot.playhead is not None else self.plot.max_cyc)
        else:
            focus_cyc = (
                self.plot.base_cyc
                + (hb.value() + viewport_w // 2) / max(1, old_w))
        self._zoom_index = index
        self.plot.set_cell_width(self._zoom_widths[index])
        hb.setSingleStep(self.plot.cell_w)
        self._sync_zoom_controls()
        self.header.update()
        self._adjusting = True
        target = self.plot._x(focus_cyc) - viewport_w // 2
        hb.setValue(max(0, min(hb.maximum(), int(target))))
        self._adjusting = False

    def _legend_widget(self):
        # Each swatch is tightly coupled to ITS label (3px), with a clear gap
        # between entries (14px) so the swatch->label pairing is unambiguous.
        w = QWidget(); h = QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0); h.setSpacing(14)
        items = [("F fetch", C_STG_FETCH), ("L fill", C_STG_FILL), ("D dec", C_STG_DEC),
                 ("M mem", C_STG_MEM), ("X exec", C_STG_EXEC), ("W wb", C_STG_WB),
                 ("= stall", C_STG_STALL), ("! flush", C_MISPRED), ("S sys", C_STG_SYS),
                 ("FP", C_FP), ("walk", C_WALK)]
        for txt, col in items:
            it = QWidget(); ih = QHBoxLayout(it); ih.setContentsMargins(0, 0, 0, 0); ih.setSpacing(3)
            sw = QLabel(); sw.setStyleSheet(f"background:{col}; border:1px solid #30363d;")
            sw.setFixedSize(12, 12)
            lab = QLabel(txt); lab.setStyleSheet("color:#9aa3ad; font-size:9px;")
            ih.addWidget(sw); ih.addWidget(lab)
            h.addWidget(it)
        return w

    def reset(self, backend, bits):
        # A snapshot retains its absolute clock but intentionally has no
        # pre-restore visual history. Anchor the new timeline at the *next*
        # clock; assuming cycle 1 made the first post-snapshot sample look like
        # a truncated 50k-cycle capture and allowed synthetic F/D cells before
        # the restore point. A cold model's cycle_count() is zero, so this is
        # unchanged for ordinary program loads.
        history_start = max(1, int(backend.cycle_count()) + 1)
        self.plot.reset(backend, bits, history_start=history_start)
        self._last_cyc = history_start - 1
        self._history_truncated = False
        self.title.setText("Pipeline view  (gem5/Konata — instruction × cycle)")
        self._stick_v = True
        self._stick_h = True
        self._adjusting = True
        self.scroll.verticalScrollBar().setValue(0)
        self.scroll.horizontalScrollBar().setValue(0)
        self._adjusting = False
        self.gutter.update(); self.header.update()

    def set_bits(self, bits):
        self.plot.bits = bits

    def stats(self):
        return self.plot.stat

    def highlight_cycle(self, cyc):
        self.plot.playhead = cyc
        row = self.plot._cyc_row.get(cyc)
        if row is None:
            # A cycle without a retirement still needs to scroll into view.
            # Keep the current vertical investigation position rather than
            # jumping to an unrelated instruction row.
            y = (
                self.scroll.verticalScrollBar().value()
                + self.scroll.viewport().height() // 2)
        else:
            y = row * ROW_H + ROW_H // 2
        self.scroll.ensureVisible(self.plot._x(cyc), y, 40, 60)
        # Cycle seek and instruction selection are deliberately independent.
        # U and V may retire together, so choosing one row from _cyc_row would
        # silently fabricate an exact selection while Trace/Registers remained
        # pinned to another retirement. Preserve the existing exact row (or
        # none) and move only the playhead.
        self.plot._sync_accessible_description()
        self.plot.update()
        self.gutter.update()

    def select_n(self, n):
        """Select one exact retirement.

        A retire cycle is insufficient because U and V commonly commit in the
        same cycle. Trace-originated navigation therefore resolves by the
        architectural retirement ID and updates the timing row without
        re-emitting the timing-to-Trace signal.
        """
        n = int(n)
        row = next(
            (index for index, insn in enumerate(self.plot.insns)
             if int(insn["n"]) == n),
            None)
        if row is None:
            return False
        self.plot.select_row(row, emit=False)
        selected = self.plot.insns[row]
        self.scroll.ensureVisible(
            self.plot._x(selected["c1"]),
            row * ROW_H + ROW_H // 2, 40, 60)
        self.gutter.update()
        return True

    def clear_selection(self):
        self.plot.playhead = None
        self.plot.anchor = None
        self.plot.sel_row = None
        self.plot.sel_pc = None
        self.plot._dep_edges = []
        self.plot._dep_for_row = -1
        self.plot._sync_accessible_description()
        self.plot.update()
        self.gutter.update()

    def update_from(self, backend):
        total = backend.cycle_count()
        if total <= self._last_cyc:
            return
        start = self._last_cyc + 1
        if total - start + 1 > _KONATA_CYCLE_CAP:
            start = total - _KONATA_CYCLE_CAP + 1
            self.plot.reset(backend, self.plot.bits, history_start=start)
            self._last_cyc = start - 1
            self._history_truncated = True
        while self._last_cyc < total:
            previous = self._last_cyc
            self._last_cyc = self.plot.ingest(
                backend, self._last_cyc + 1)
            if self._last_cyc <= previous:
                break
        if self._history_truncated:
            captured = max(0, self._last_cyc - self.plot.history_start + 1)
            self.title.setText(
                "Pipeline view  "
                f"(latest {captured:,} of {total:,} cycles — instruction × cycle)")
        self.plot.update(); self.gutter.update(); self.header.update()
        # re-stick to the newest row/cycle unless the user scrolled away. Guard so
        # these programmatic scrolls don't clear the stick via the scroll handlers.
        self._adjusting = True
        vb = self.scroll.verticalScrollBar(); hb = self.scroll.horizontalScrollBar()
        if self._stick_v:
            vb.setValue((vb.maximum() // ROW_H) * ROW_H)   # row-aligned bottom
        if self._stick_h:
            # Anchor the left edge to the topmost VISIBLE row's first cell — NOT
            # the raw FSM max-cycle. A long non-retiring tail (S_DECODE / S_PF /
            # S_WALK) runs max_cyc far past the last drawn cell, so following to
            # hb.maximum() scrolls every visible row's cells off the left into
            # blank space (the diagram reads as broken). Clamp to maximum so a
            # fast path whose cascade already fits still follows the newest cycle.
            ins = self.plot.insns
            if ins:
                top_row = min(len(ins) - 1, max(0, vb.value() // ROW_H))
                left_x = self.plot._x(ins[top_row]["c0"]) - 6
                hb.setValue(min(hb.maximum(), max(0, left_x)))
            else:
                hb.setValue(hb.maximum())
        self._adjusting = False


# ===========================================================================
# IPC / stall / event sparkline strip — a compact performance-over-time view.
# X = cycles (newest at right, 1px/cycle), top track = windowed IPC (0..2),
# bottom track = per-cycle event pixels (mispredict / stall / I-fill / walk).
# ===========================================================================
class SparklineStrip(QWidget):
    """Performance-over-time strip AND a navigation overview: click anywhere to
    drop the Konata playhead at that cycle. X = cycles (newest at right,
    1px/cycle); top track = windowed IPC (0..2), middle = per-cycle event pixels,
    bottom = the event-colour key."""
    CAP = 12000
    cycleClicked = Signal(int)     # emits the cycle under a click (seek)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(58)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.backend = None
        self._last_cyc = 0
        self.ret = []        # retirements per cycle (0/1/2)
        self.ev = []         # '' | 'm' mispred | 's' stall | 'f' fill | 'w' walk
        self._last_state = ""
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.NoFocus)
        self.setAccessibleName("IPC and pipeline event history")
        self.setAccessibleDescription(
            "Use Left and Right, Page Up and Page Down, Home and End to seek "
            "captured cycles; Enter reopens the selected cycle")
        self._hover_x = -1
        self._kbd_cyc = None
        self._dragging = False
        self.setToolTip("Open a program and step to collect navigable history")
        self._sync_accessible_description()

    def _sync_accessible_description(self):
        navigation = (
            "Click or drag across the history to seek. Use Left and Right, "
            "Page Up and Page Down, Home and End to choose a captured cycle; "
            "Enter reopens it.")
        bounds = self._cycle_bounds()
        if bounds is None:
            state = (
                "No captured cycle history."
                if self.backend is not None else "No program loaded.")
            self.setAccessibleDescription(f"{state} {navigation}")
            return
        recent = self.ret[max(0, len(self.ret) - 64):]
        ipc = sum(recent) / max(1, len(recent))
        events = sum(1 for event in self.ev if event)
        chosen = (
            f" Cycle {int(self._kbd_cyc)} selected."
            if self._kbd_cyc is not None else "")
        self.setAccessibleDescription(
            f"Captured cycles {bounds[0]} through {bounds[1]}; recent IPC "
            f"{ipc:.2f}; {events} marked events.{chosen} {navigation}")

    def reset(self, backend):
        self.backend = backend
        # Like Konata, snapshots begin a fresh *visible* history at their
        # restored absolute clock rather than backfilling nonexistent samples.
        self._last_cyc = int(backend.cycle_count())
        self.ret = []; self.ev = []
        self._last_state = ""
        self._kbd_cyc = None
        self._dragging = False
        self.setFocusPolicy(Qt.NoFocus)
        self.setToolTip("Step the core to collect keyboard-navigable history")
        self._sync_accessible_description()
        self.update()

    def ingest(self):
        if self.backend is None:
            return
        total = self.backend.cycle_count()
        if total - self._last_cyc > self.CAP:
            self.ret = []
            self.ev = []
            self._last_cyc = total - self.CAP
        while self._last_cyc < total:
            new = self.backend.get_cycles(self._last_cyc + 1, 8192)
            if not new:
                break
            for c in new:
                self.ret.append((1 if c.retU else 0) + (1 if c.retV else 0))
                name = self.backend.state_name(c.state)
                if name == "S_PIPE" and c.mispred_bubbles > 0:
                    e = "m"
                elif name == "S_WALK":
                    e = "w"
                elif name == "S_PF":
                    e = "f"
                elif (name == "S_PIPE"
                      and (c.stall_cnt > 0 or c.pending_mem_pen > 0)):
                    e = "s"
                else:
                    e = ""
                self.ev.append(e)
                self._last_cyc = c.cyc
                self._last_state = name
        if len(self.ret) > self.CAP:
            self.ret = self.ret[-self.CAP:]; self.ev = self.ev[-self.CAP:]
        self.setFocusPolicy(Qt.StrongFocus if self.ret else Qt.NoFocus)
        if self.ret:
            self.setToolTip(
                "Click or drag to seek; keyboard: Left/Right, Page Up/Down, Home/End, "
                "Enter")
        bounds = self._cycle_bounds()
        if self._kbd_cyc is not None and bounds is not None:
            self._kbd_cyc = max(bounds[0], min(bounds[1], self._kbd_cyc))
        self._sync_accessible_description()
        self.update()

    # stall = grey (C_STG_STALL), matching the Konata '=' stall convention and
    # distinct from the amber I-fill (they were both amber and indistinguishable).
    _EVCOL = {"m": C_MISPRED, "s": C_STG_STALL, "f": C_FILL, "w": C_WALK}
    _EVKEY = [("m", "mispred"), ("s", "stall"), ("f", "I-fill"), ("w", "walk")]
    _LABELW = 40

    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0b0f14"))
        W, H = self.width(), self.height()
        n = len(self.ret)
        labelw = self._LABELW
        ipc_y0, ipc_h = 2, 26
        evt_y0, evt_h = 30, 9
        key_y = 43
        plotw = max(1, W - labelw - 4)
        # event-colour KEY (always drawn, so the event pixels are decodable)
        p.setFont(_mono(7)); kx = labelw
        for code, lbl in self._EVKEY:
            p.fillRect(QRect(kx, key_y + 2, 8, 8), QColor(self._EVCOL[code]))
            p.setPen(QColor("#8b949e"))
            p.drawText(QRect(kx + 11, key_y, 50, 12), Qt.AlignVCenter | Qt.AlignLeft, lbl)
            kx += 11 + len(lbl) * 6 + 14
        p.setPen(QColor("#586069")); p.setFont(_mono(7))
        p.drawText(QRect(2, key_y, labelw - 4, 12), Qt.AlignVCenter | Qt.AlignRight, "key")
        if n == 0:
            p.setPen(QColor(_MUT)); p.setFont(_mono(8))
            message = ("open a program to collect IPC / stall history"
                       if self.backend is None else
                       "step the core to collect IPC / stall history")
            p.drawText(QRect(labelw, ipc_y0, plotw, ipc_h), Qt.AlignCenter,
                       message)
            if self.hasFocus():
                pen = QPen(QColor(_FOCUS)); pen.setWidth(2); p.setPen(pen)
                p.drawRect(self.rect().adjusted(1, 1, -2, -2))
            p.end(); return
        start = max(0, n - plotw)
        shown = n - start
        bw = plotw / shown          # px per cycle — widen so the bars FILL the panel
        win = 16
        for idx, i in enumerate(range(start, n)):
            x = labelw + int(idx * bw)
            cw = max(1, int((idx + 1) * bw) - int(idx * bw))   # contiguous, gap-free
            lo = max(0, i - win + 1)
            ipc = sum(self.ret[lo:i + 1]) / (i - lo + 1)
            # cap the drawable height at ipc_h-2 so a sustained IPC=2.0 keeps 2px
            # of headroom and never saturates flush to the band's top edge.
            bh = int(min(2.0, ipc) / 2.0 * (ipc_h - 2))
            p.fillRect(QRect(x, ipc_y0 + ipc_h - bh, cw, bh), QColor("#2ea043"))
            e = self.ev[i]
            if e:
                p.fillRect(QRect(x, evt_y0, cw, evt_h), QColor(self._EVCOL[e]))
        # IPC=1 / IPC=2 rule lines drawn AFTER the bars so a peaked bar can't
        # paint over its own reference line.
        p.setPen(QColor("#30363d"))
        for lvl in (1.0, 2.0):
            y = ipc_y0 + ipc_h - int(lvl / 2.0 * (ipc_h - 2))
            p.drawLine(labelw, y, W - 2, y)
        # hover seek-marker
        if self._hover_x >= labelw:
            p.setPen(QColor("#39c5cf"))
            p.drawLine(self._hover_x, ipc_y0, self._hover_x, evt_y0 + evt_h)
        if self.hasFocus() and self._kbd_cyc is not None:
            marker_x = self._x_for_cyc(self._kbd_cyc)
            if marker_x is not None:
                pen = QPen(QColor(_FOCUS)); pen.setWidth(2); p.setPen(pen)
                p.drawLine(marker_x, ipc_y0, marker_x, evt_y0 + evt_h)
        # 'stuck' diagnostic: a long trailing run of zero-retire cycles in a
        # front-end state (S_DECODE/S_FETCH livelock) — the strip would otherwise
        # read as a dead flat band rather than "the core is wedged, not idle".
        k = 0
        while k < n and self.ret[n - 1 - k] == 0:
            k += 1
        if k >= 64 and self._last_state in ("S_DECODE", "S_FETCH", "S_F00F_HANG"):
            p.fillRect(QRect(labelw, ipc_y0, plotw, ipc_h), QColor(40, 12, 12))
            p.setPen(QColor(C_MISPRED)); p.setFont(_mono(8, True))
            p.drawText(QRect(labelw, ipc_y0, plotw, ipc_h), Qt.AlignCenter,
                       f"⚠ stuck in {self._last_state} — {k}c, 0 retired")
        elif k >= 64 and self._last_state in ("S_HALT", "S_HLTWAIT"):
            # HALT is a normal terminal outcome for system fixtures, not a
            # front-end livelock.  Keep the end-state visible without presenting
            # a successful boot/test completion as a red failure.
            p.fillRect(QRect(labelw, ipc_y0, plotw, ipc_h), QColor(12, 32, 22))
            p.setPen(QColor("#3fb950")); p.setFont(_mono(8, True))
            p.drawText(QRect(labelw, ipc_y0, plotw, ipc_h), Qt.AlignCenter,
                       f"halted — program stopped ({k} idle clocks)")
        # left labels: current windowed IPC (last 64 cyc)
        cur = sum(self.ret[max(0, n - 64):]) / min(64, n)
        p.setPen(QColor("#9aa3ad")); p.setFont(_mono(8, True))
        p.drawText(QRect(2, ipc_y0, labelw - 4, ipc_h), Qt.AlignRight | Qt.AlignVCenter,
                   f"IPC\n{cur:.2f}")
        p.setPen(QColor("#586069")); p.setFont(_mono(7))
        p.drawText(QRect(2, evt_y0 - 1, labelw - 4, evt_h + 2),
                   Qt.AlignRight | Qt.AlignVCenter, "evt")
        # IPC y-axis caps: 2 (top), 1 (mid), 0 (bottom)
        p.setPen(QColor("#3d444d")); p.setFont(_mono(6))
        p.drawText(QRect(labelw + 1, ipc_y0 - 1, 12, 8), Qt.AlignLeft, "2")
        p.drawText(QRect(labelw + 1, ipc_y0 + ipc_h // 2 - 4, 12, 8), Qt.AlignLeft, "1")
        p.drawText(QRect(labelw + 1, ipc_y0 + ipc_h - 8, 12, 8), Qt.AlignLeft, "0")
        if self.hasFocus():
            pen = QPen(QColor(_FOCUS)); pen.setWidth(2); p.setPen(pen)
            p.drawRect(self.rect().adjusted(1, 1, -2, -2))
        p.end()

    def _cycle_bounds(self):
        if not self.ret:
            return None
        return self._last_cyc - len(self.ret) + 1, self._last_cyc

    def _x_for_cyc(self, cyc):
        bounds = self._cycle_bounds()
        if bounds is None:
            return None
        n = len(self.ret)
        plotw = max(1, self.width() - self._LABELW - 4)
        start = max(0, n - plotw)
        shown = n - start
        first_shown = bounds[0] + start
        index = int(cyc) - first_shown
        if not 0 <= index < shown:
            return None
        bw = plotw / shown
        return self._LABELW + int((index + 0.5) * bw)

    def next_event(self, from_cyc, direction, cls="any"):
        """Cycle of the next (direction +1) / previous (-1) event — a mispredict
        'm', stall 's', I-fill 'f' or page-walk 'w' (or 'any') — scanning outward
        from from_cyc. Returns the cycle, or None if there's no further event."""
        n = len(self.ev)
        if n == 0:
            return None
        direction = 1 if direction > 0 else -1
        first_cyc = self._last_cyc - n + 1
        i = int(from_cyc) - first_cyc + direction
        # An outward search beyond the corresponding edge has no match. From
        # the opposite edge, start at the first/last captured cycle.
        if i < 0:
            if direction < 0:
                return None
            i = 0
        elif i >= n:
            if direction > 0:
                return None
            i = n - 1
        while 0 <= i < n:
            e = self.ev[i]
            if e and (cls == "any" or e == cls):
                return self._last_cyc - (n - 1 - i)
            i += direction
        return None

    def _cyc_at(self, x):
        n = len(self.ret)
        if n == 0:
            return None
        plotw = max(1, self.width() - self._LABELW - 4)
        x = int(x)
        if x < self._LABELW or x >= self._LABELW + plotw:
            return None
        start = max(0, n - plotw)
        shown = n - start
        bw = plotw / shown                          # must match paintEvent's scale
        i = start + int((x - self._LABELW) / bw)
        return self._last_cyc - (n - 1 - i) if 0 <= i < n else None

    def mousePressEvent(self, ev):
        cyc = self._cyc_at(ev.position().x() if hasattr(ev, "position") else ev.x())
        if cyc is not None and ev.button() == Qt.LeftButton:
            self._dragging = True
            self._kbd_cyc = int(cyc)
            self._sync_accessible_description()
            self.setFocus(Qt.MouseFocusReason)
            self.cycleClicked.emit(int(cyc))     # seek the Konata playhead here
            ev.accept()
            return
        super().mousePressEvent(ev)

    def leaveEvent(self, event):
        self._hover_x = -1
        self.unsetCursor()
        self.setToolTip(
            "Click or drag to seek; keyboard: Left/Right, Page Up/Down, Home/End, "
            "Enter")
        self.update()
        super().leaveEvent(event)

    def mouseMoveEvent(self, ev):
        x = int(ev.position().x() if hasattr(ev, "position") else ev.x())
        self._hover_x = x
        cyc = self._cyc_at(x)
        if (self._dragging and ev.buttons() & Qt.LeftButton
                and cyc is not None and int(cyc) != self._kbd_cyc):
            self._kbd_cyc = int(cyc)
            self._sync_accessible_description()
            self.cycleClicked.emit(int(cyc))
        if cyc is not None:
            self.setCursor(Qt.SizeHorCursor)
            i = len(self.ev) - 1 - (self._last_cyc - cyc)
            ev_name = {"m": "mispredict", "s": "stall", "f": "I-fill", "w": "page-walk"}.get(self.ev[i], "")
            self.setToolTip(f"cyc {cyc}: {self.ret[i]} retired"
                            + (f", {ev_name}" if ev_name else "")
                            + "  ·  click/drag to seek; arrows navigate")
        else:
            self._hover_x = -1
            self.unsetCursor()
            self.setToolTip(
                "IPC/key labels are not seek targets; move over the history plot")
        self.update()

    def mouseReleaseEvent(self, ev):
        if ev.button() == Qt.LeftButton and self._dragging:
            self._dragging = False
            ev.accept()
            return
        super().mouseReleaseEvent(ev)

    def focusInEvent(self, event):
        if self._kbd_cyc is None and self.ret:
            self._kbd_cyc = self._last_cyc
        self._sync_accessible_description()
        self.update()
        super().focusInEvent(event)

    def focusOutEvent(self, event):
        self.update()
        super().focusOutEvent(event)

    def keyPressEvent(self, event):
        key = event.key()
        nav = (Qt.Key_Left, Qt.Key_Right, Qt.Key_PageUp, Qt.Key_PageDown,
               Qt.Key_Home, Qt.Key_End)
        if key in nav:
            bounds = self._cycle_bounds()
            if bounds is not None:
                current = (
                    self._kbd_cyc
                    if self._kbd_cyc is not None else bounds[1])
                if key == Qt.Key_Home:
                    current = bounds[0]
                elif key == Qt.Key_End:
                    current = bounds[1]
                else:
                    delta = {
                        Qt.Key_Left: -1,
                        Qt.Key_Right: 1,
                        Qt.Key_PageUp: -64,
                        Qt.Key_PageDown: 64,
                    }[key]
                    current = max(bounds[0], min(bounds[1], current + delta))
                self._kbd_cyc = int(current)
                self._sync_accessible_description()
                self.cycleClicked.emit(self._kbd_cyc)
                self.update()
            event.accept()
            return
        if key in (Qt.Key_Return, Qt.Key_Enter):
            if self._kbd_cyc is not None:
                self.cycleClicked.emit(int(self._kbd_cyc))
            event.accept()
            return
        super().keyPressEvent(event)


# ===========================================================================
# Composite panel
# ===========================================================================
class PipelineView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(2, 6, 2, 2); v.setSpacing(4)
        bt = QLabel("Pipelines — U / V (integer dual-issue) + FP (x87)")
        bt.setStyleSheet("font-weight:bold;")
        v.addWidget(bt)
        self.board = StageBoard()
        v.addWidget(self.board)
        self.spark = SparklineStrip()
        v.addWidget(self.spark)
        self.konata = Konata()
        v.addWidget(self.konata, 1)
        # click the sparkline overview to seek the Konata playhead to that cycle
        self.spark.cycleClicked.connect(self.konata.highlight_cycle)
        self._bits = 32

    # back-compat alias (the status bar reads pipeline.waterfall.stats()).
    @property
    def waterfall(self):
        return self.konata

    def set_bits(self, bits):
        self._bits = bits
        self.konata.set_bits(bits)

    def reset(self, backend):
        self.board.reset()
        self.spark.reset(backend)
        self.konata.reset(backend, self._bits)

    def stats(self):
        return self.konata.stats()

    def highlight_cycle(self, cyc):
        self.konata.highlight_cycle(cyc)

    def select_n(self, n):
        return self.konata.select_n(n)

    def clear_selection(self):
        self.konata.clear_selection()

    def update_from(self, backend, state):
        bits = 32 if state.cs_d else 16
        self.konata.plot.bits = bits
        self.konata.plot.cs_base = state.cs_base
        self.board.set_state(state, backend, bits)
        self.spark.ingest()
        self.konata.update_from(backend)
