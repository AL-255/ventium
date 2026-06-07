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
                               QSizePolicy, QHBoxLayout, QGridLayout)
from PySide6.QtGui import QPainter, QColor, QFont, QFontMetrics
from PySide6.QtCore import Qt, QRect, QSize, Signal

from . import disasm
from .disasm import (C_PIPE, C_FILL, C_SLOW, C_FP, C_WALK, C_SYS, C_HALT,
                     C_STALL, C_MISPRED)

INT_STAGES = ["PF", "D1", "D2", "EX", "WB"]
FP_STAGES = ["X1", "X2", "WF", "ER"]
GROUPS = [("U", INT_STAGES, C_PIPE), ("V", INT_STAGES, C_PIPE), ("FP", FP_STAGES, C_FP)]
_BG = "#0d1117"
_GRID = "#30363d"
_DIM = "#161b22"
_TXT = "#c9d1d9"
_MUT = "#8b949e"


def _mono(pt=9, bold=False):
    f = QFont("monospace"); f.setStyleHint(QFont.Monospace); f.setPointSize(pt); f.setBold(bold)
    return f


# ===========================================================================
# Live stage board
# ===========================================================================
class StageBoard(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(100)   # tightened so the starved Konata view gets the rows
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self._cells = self._blank()
        self._status = "no image loaded"
        self._statecol = _DIM

    def _blank(self):
        return {"U": ([], ""), "V": ([], ""), "FP": ([], "")}

    def set_state(self, s, backend, bits):
        name = backend.state_name(s.state)
        lane, stage, color, desc = disasm.stage_of(name)
        self._statecol = color
        cells = self._blank()

        base = s.cs_base

        def dis(addr):
            t, sz = disasm.text(backend.mem_read(base + addr, 16), addr, bits)
            return t

        issuing = (name == "S_PIPE" and s.stall_cnt == 0 and s.mispred_bubbles == 0
                   and s.pending_mem_pen == 0)
        if name == "S_PIPE":
            if s.ud_is_fp:
                cells["FP"] = ([0, 1, 3], dis(s.eip))
            elif issuing:
                cells["U"] = ([3, 4], dis(s.eip))
                if s.pipe_pair:
                    cells["V"] = ([3, 4], dis(s.eip + s.ud_len))
            else:
                cells["U"] = ([3], "stall")
                self._statecol = C_STG_STALL    # not exec-green
        elif name == "S_PF":
            cells["U"] = ([0], f"I-fill {s.pf_word}/8")
        elif name == "S_FETCH":
            cells["U"] = ([0], dis(s.eip))
        elif name == "S_DECODE":
            cells["U"] = ([1, 2], dis(s.eip))
        elif name in ("S_LOAD", "S_LOAD2"):
            cells["U"] = ([3], "load " + dis(s.eip))
        elif name == "S_EXEC":
            cells["U"] = ([3], dis(s.eip))
        elif name in ("S_STORE", "S_USEQ", "S_IO", "S_INS"):
            cells["U"] = ([4], dis(s.eip))
        elif name == "S_FLOAD":
            cells["FP"] = ([0], "fp load")
        elif name == "S_FEXEC":
            cells["FP"] = ([0, 1], dis(s.eip))
        elif name in ("S_FSTORE", "S_FENV_ST", "S_FENV_LD"):
            cells["FP"] = ([3], "fp store")

        if s.fp_occ_pending and not cells["FP"][0]:
            cells["FP"] = ([0, 1, 3], "occ (busy)")

        self._cells = cells
        haz = []
        if s.stall_cnt: haz.append(f"stall={s.stall_cnt}")
        if s.mispred_bubbles: haz.append(f"mispredict-bubble={s.mispred_bubbles}")
        if s.pending_mem_pen: haz.append(f"D$-pen={s.pending_mem_pen}")
        if s.fp_occ_pending: haz.append("fp-occupancy")
        hz = ("    " + ", ".join(haz)) if haz else ""
        pair = "  [paired]" if (name == "S_PIPE" and s.pipe_pair) else (
            "  [single]" if name == "S_PIPE" else "")
        self._status = f"{name}  ({desc})   eip=0x{s.eip:08x}   cyc={s.core_cyc}{pair}{hz}"
        self.update()

    def reset(self):
        self._cells = self._blank(); self._status = "reset"; self._statecol = _DIM
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
        p.setFont(_mono(9)); p.setPen(QColor(_TXT))
        p.drawText(QRect(4, top + 3 * lane_h + 2, W - 8, 14), Qt.AlignLeft, self._status)
        p.end()


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
                 # AND so the steep dual-issue diagonal fills more of the panel
                 # (fewer cycles per viewport-width) instead of a thin right strip.
GUTTER_W = 300
HDR_H = 18


# Per-stage colours for the Konata cells — each P5 stage gets a DISTINCT hue so
# fetch/decode/exec/mem/writeback are tellable apart by colour, not just letter.
C_STG_FILL = "#e0a72e"    # I-cache fill          (amber)
C_STG_FETCH = "#4a9eff"   # slow front-end fetch  (blue)
C_STG_DEC = "#39c5cf"     # decode                (teal)
C_STG_MEM = "#f0883e"     # load/store address    (orange)
C_STG_WB = "#7d8fc9"      # writeback (slate-blue — out of the wb/FP/walk purple cluster)
C_STG_EXEC = C_PIPE       # execute (integer)     (green)
C_STG_STALL = "#7a828d"   # stall / bubble        (grey — distinct from amber fill)

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


def _add_frontend(cells):
    """The dual-issue fast path collapses fetch/decode/execute into one clock, so
    a fast-path op reconstructs as a single 'X' cell. The Ventium is still a P5
    5-stage pipeline, so synthesise the in-flight Fetch + Decode stages in the two
    cycles preceding the commit — this makes consecutive instructions cascade
    through F -> D -> X like a real superscalar pipeline diagram, instead of a
    lone X. Only added when the op has NO real front-end cells already (an
    I-cache fill 'L' or slow-path F/D); a stall '=' or bare 'X' gets the shadow."""
    if not cells or cells[0][1] in ("L", "F", "D", "M", "W"):
        return cells
    a0 = cells[0][0]
    return [(a0 - 2, "F", C_STG_FETCH), (a0 - 1, "D", C_STG_DEC)] + cells


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
    if name in ("S_LOAD", "S_LOAD2"):
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
    if name in ("S_HALT", "S_F00F_HANG"):
        return (".", C_HALT)
    return ("S", C_SYS)


class _KonataPlot(QWidget):
    """The cell grid (cycles x instructions). Reconstructs per-instruction
    lifecycles from the per-cycle trace and paints only the visible region."""
    rowClicked = Signal(int)     # emits the retire n of the clicked instruction

    def __init__(self, parent=None):
        super().__init__(parent)
        self.bits = 32
        self.cs_base = 0
        self.backend = None
        self._mn_cache = {}
        self.insns = []          # [{n,pc,pipe,mnem,cells:[(cyc,ch,color)],c0,c1}]
        self.base_cyc = 1
        self.max_cyc = 1
        self.sel_row = None
        self.sel_pc = None       # selected PC → tint all its other executions (loop)
        self.playhead = None     # pinned cycle (vertical marker)
        self.anchor = None       # shift-click second marker → cycle-range Δ measure
        self.stat = dict(uret=0, vret=0, fill=0, stall=0, mispred=0, walk=0)
        self._pending = []       # accumulated cells since the last retirement
        self._cyc_row = {}       # retire cyc -> row index
        self.setMouseTracking(True)

    def reset(self, backend, bits):
        self.backend = backend
        self.bits = bits
        self._mn_cache = {}
        self.insns = []
        self.base_cyc = 1
        self.max_cyc = 1
        self.sel_row = None
        self.sel_pc = None
        self.playhead = None
        self.anchor = None
        self.stat = dict(uret=0, vret=0, fill=0, stall=0, mispred=0, walk=0)
        self._pending = []
        self._cyc_row = {}
        self.setMinimumSize(1, 1)

    def _mn(self, pc):
        key = (pc, self.cs_base, self.bits)
        t = self._mn_cache.get(key)
        if t is None and self.backend is not None:
            sz, mn, ops, _ = disasm.disasm_one(
                self.backend.mem_read(self.cs_base + pc, 16), pc, self.bits)
            t = f"{mn} {ops}".strip()
            self._mn_cache[key] = t
        return t or "?"

    def ingest(self, backend, since_cyc):
        new = backend.get_cycles(since_cyc, 8192)
        for c in new:
            name = backend.state_name(c.state)
            stall = (c.stall_cnt > 0 or c.pending_mem_pen > 0)
            mispred = c.mispred_bubbles > 0
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
                mn = self._mn(c.pcU)
                cells = _add_frontend(_recolor_fp(self._pending, mn))
                self.insns.append(dict(n=c.nU, pc=c.pcU, pipe="U", mnem=mn,
                                       cells=cells, c0=cells[0][0], c1=c.cyc))
                self._cyc_row[c.cyc] = len(self.insns) - 1
                self.stat["uret"] += 1
                self._pending = []
            if c.retV:
                mn = self._mn(c.pcV)
                vcol = C_FP if (mn[:1] == "f" and mn[:2] not in ("fs", "gs")) else C_PIPE
                cells = _add_frontend([(c.cyc, "X", vcol)])
                self.insns.append(dict(n=c.nV, pc=c.pcV, pipe="V", mnem=mn,
                                       cells=cells, c0=cells[0][0], c1=c.cyc))
                self._cyc_row[c.cyc] = len(self.insns) - 1
                self.stat["vret"] += 1
        if len(self.insns) > 9000:          # rolling cap
            drop = len(self.insns) - 9000
            self.insns = self.insns[drop:]
            self._cyc_row = {v["c1"]: i for i, v in enumerate(self.insns)}
            if self.sel_row is not None:
                self.sel_row -= drop
        self.base_cyc = self.insns[0]["c0"] if self.insns else 1
        w = (self.max_cyc - self.base_cyc + 3) * CELL_W
        # one row of bottom slack so a row-aligned bottom-follow scroll keeps the
        # newest instruction fully visible (never a clipped half-row at the top).
        h = max(1, len(self.insns) * ROW_H + ROW_H)
        self.setFixedSize(max(1, w), h)
        return self.max_cyc

    def _x(self, cyc):
        return (cyc - self.base_cyc) * CELL_W

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(ev.rect(), QColor(_BG))
        if not self.insns:
            p.setPen(QColor(_MUT)); p.setFont(_mono(10))
            p.drawText(self.rect(), Qt.AlignCenter, "step the core to fill the pipeline view")
            p.end(); return
        vis = ev.rect()
        # vertical gridlines every 10 cycles so a cell's cycle is readable —
        # dim-but-legible (#2b3340 ≈ 2x the old near-black #171c24 contrast),
        # kept below the stage board's #454f5d so they don't fight the dense cells.
        p.setPen(QColor("#2b3340"))
        gc = self.base_cyc + ((10 - self.base_cyc % 10) % 10)
        while True:
            gx = self._x(gc)
            if gx > vis.right():
                break
            if gx >= vis.left():
                p.drawLine(gx, vis.top(), gx, vis.bottom())
            gc += 10
            if gc > self.max_cyc + 10:
                break
        # column highlights drawn BEHIND the cells — opaque cells then paint on top,
        # so the tint only shows through the inter-cell gaps and never washes a
        # glyph out (the playhead used to alpha-blend OVER the cells it crossed).
        if self.playhead is not None and self.anchor is not None:
            xa = self._x(self.anchor) + CELL_W // 2
            xp = self._x(self.playhead) + CELL_W // 2
            blo, bhi = sorted((xa, xp))
            p.fillRect(QRect(blo, vis.top(), max(1, bhi - blo), vis.height()),
                       QColor(240, 180, 70, 30))        # translucent AMBER Δ band
        if self.playhead is not None:
            pcolx = self._x(self.playhead)
            if pcolx <= vis.right() and pcolx + CELL_W >= vis.left():
                p.fillRect(QRect(pcolx, vis.top(), CELL_W, vis.height()),
                           QColor(57, 197, 207, 34))    # playhead column tint
        r0 = max(0, vis.top() // ROW_H - 1)
        r1 = min(len(self.insns), vis.bottom() // ROW_H + 2)
        xlo, xhi = vis.left() - CELL_W, vis.right() + CELL_W
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
                    x0 = self._x(cells[i][0]); x1 = self._x(cells[j - 1][0]) + CELL_W - 1
                    if x1 >= xlo and x0 <= xhi:
                        # inset the bar (3px gap on the left) so its border never
                        # abuts / clips the preceding lettered cell's glyph.
                        span = QRect(x0 + 2, y + 1, max(CELL_W - 4, x1 - x0 - 3), ROW_H - 2)
                        p.fillRect(span, QColor(col))
                        # light border so the stall span stands out on any row
                        # background (incl. the amber Δ band / zebra stripe).
                        p.setPen(QColor("#aab4c0")); p.drawRect(span)
                        p.setFont(_mono(8, True)); p.setPen(QColor("#0d1117"))
                        p.drawText(span, Qt.AlignCenter, f"={j - i}" if j - i > 1 else "=")
                    i = j
                else:
                    x = self._x(cyc)
                    if xlo <= x <= xhi:
                        cell = QRect(x, y + 1, CELL_W - 1, ROW_H - 2)
                        p.fillRect(cell, QColor(col))
                        p.setFont(_mono(8, True))
                        p.setPen(QColor("#0d1117") if QColor(col).lightness() > 130 else QColor(_TXT))
                        p.drawText(cell, Qt.AlignCenter, ch)
                    i += 1
            # off-screen continuation cue: a chevron when this row's lifecycle runs
            # past the right viewport edge (scroll right for the rest).
            if self._x(ins["c1"]) > vis.right():
                p.setFont(_mono(10, True)); p.setPen(QColor("#7d8590"))
                p.drawText(QRect(vis.right() - 11, y, 11, ROW_H),
                           Qt.AlignVCenter | Qt.AlignRight, "›")
        # Δ-measure MARKERS (the amber band fill itself was drawn behind the cells):
        # an amber endpoint line at the anchor + the Δ<n>cyc label centred on the band.
        if self.playhead is not None and self.anchor is not None:
            xa = self._x(self.anchor) + CELL_W // 2
            xp = self._x(self.playhead) + CELL_W // 2
            lo, hi = sorted((xa, xp))
            p.setPen(QColor("#e3b341"))                  # anchor endpoint marker (amber)
            p.drawLine(xa, vis.top(), xa, vis.bottom())
            dn = abs(self.playhead - self.anchor)
            p.setFont(_mono(8, True))
            lbl = f"Δ{dn}cyc"
            lw = QFontMetrics(p.font()).horizontalAdvance(lbl) + 6
            lx = max(lo, min((lo + hi) // 2 - lw // 2, hi - lw))
            p.fillRect(QRect(lx, vis.top() + 1, lw, 12), QColor("#241c08"))
            p.setPen(QColor("#f0c674"))
            p.drawText(QRect(lx, vis.top() + 1, lw, 12), Qt.AlignCenter, lbl)
        # playhead MARKER (the column tint was drawn behind the cells): a vertical
        # cyan line + a cycle-number callout pinned to the top of the visible region.
        if self.playhead is not None:
            px = self._x(self.playhead) + CELL_W // 2
            if vis.left() - 2 <= px <= vis.right() + 2:
                p.setPen(QColor("#39c5cf"))
                p.drawLine(px, vis.top(), px, vis.bottom())
                lbl = f"cyc {self.playhead}"
                p.setFont(_mono(8, True))
                tw = QFontMetrics(p.font()).horizontalAdvance(lbl) + 8
                bx = min(max(px - tw // 2, vis.left()), max(vis.left(), vis.right() - tw))
                p.fillRect(QRect(bx, vis.top(), tw, 13), QColor("#0b3036"))
                p.setPen(QColor("#7ce0e8"))
                p.drawText(QRect(bx, vis.top(), tw, 13), Qt.AlignCenter, lbl)
        p.end()

    def mouseMoveEvent(self, ev):
        x = (ev.position().x() if hasattr(ev, "position") else ev.x())
        y = (ev.position().y() if hasattr(ev, "position") else ev.y())
        r = int(y // ROW_H)
        if 0 <= r < len(self.insns):
            ins = self.insns[r]
            # which exact cell is under the cursor → its cycle + full stage name
            cyc = int(x // CELL_W) + self.base_cyc
            cell = next((c for c in ins["cells"] if c[0] == cyc), None)
            cellinfo = (f"\ncycle {cyc}: {_GLYPH_STAGE.get(cell[1], cell[1])}"
                        if cell else "")
            self.setToolTip(
                f"n={ins['n']}  {ins['pipe']}  {ins['pc']:#010x}  {ins['mnem']}\n"
                f"cycles {ins['c0']}..{ins['c1']}  (commit @ {ins['c1']}, "
                f"{ins['c1'] - ins['c0'] + 1} cyc){cellinfo}\n"
                f"click: pin regs · shift-click: set Δ-measure anchor")

    def mousePressEvent(self, ev):
        y = (ev.position().y() if hasattr(ev, "position") else ev.y())
        r = int(y // ROW_H)
        if not (0 <= r < len(self.insns)):
            return
        cyc = self.insns[r]["c1"]
        if ev.modifiers() & Qt.ShiftModifier:
            # second marker: measure the cycle range to the current playhead.
            self.anchor = None if self.anchor == cyc else cyc
            self.update()
            return
        self.sel_row = r
        self.sel_pc = self.insns[r]["pc"]
        self.playhead = cyc
        self.update()
        self.rowClicked.emit(int(self.insns[r]["n"]))


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
            self.plot.sel_row = r
            self.plot.sel_pc = self.plot.insns[r]["pc"]
            self.plot.update(); self.update()
            self.plot.rowClicked.emit(int(self.plot.insns[r]["n"]))

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
                p.setPen(QColor(C_STALL))
                p.drawText(QRect(GUTTER_W - bw - 6, y, bw, ROW_H),
                           Qt.AlignVCenter | Qt.AlignRight, f"{span}c")
            # split-colour: a NEUTRAL-grey mnemonic (same for every op) + the
            # operand(s) (a branch's target, a load's address) in the class accent,
            # so only the target is coloured (a branch's 'jne' is grey, not orange).
            parts = it["mnem"].split(" ", 1)
            mn = parts[0]; ops = parts[1] if len(parts) > 1 else ""
            _, icol = disasm.insn_class(mn)
            p.setPen(QColor("#939ba6"))
            p.drawText(QRect(118, y, mnem_w, ROW_H), Qt.AlignVCenter | Qt.AlignLeft, mn)
            mw = fm.horizontalAdvance(mn + " ")
            if ops and mw < mnem_w:
                p.setPen(QColor(icol))
                p.drawText(QRect(118 + mw, y, mnem_w - mw, ROW_H),
                           Qt.AlignVCenter | Qt.AlignLeft,
                           fm.elidedText(ops, Qt.ElideRight, mnem_w - mw - 2))
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
        c = base + ((10 - base % 10) % 10)
        while c <= maxc + 10:
            x = GUTTER_W + (c - base) * CELL_W - hoff
            if x > self.width():
                break
            if x >= GUTTER_W:
                p.setPen(QColor("#586069"))
                p.drawText(QRect(x - 16, 0, 32, HDR_H), Qt.AlignCenter, str(c))
            c += 10
        p.end()


class Konata(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(2, 2, 2, 2); v.setSpacing(2)
        title = QLabel("Pipeline view  (gem5/Konata — instruction × cycle)")
        title.setStyleSheet("font-weight:bold;")
        v.addWidget(title)
        # legend on its OWN line so it can't clip off the right edge
        lw = self._legend_widget()
        lh = QHBoxLayout(); lh.setContentsMargins(0, 0, 0, 0)
        lh.addWidget(lw); lh.addStretch(1)
        v.addLayout(lh)

        self.scroll = QScrollArea()
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
        self.scroll.horizontalScrollBar().setSingleStep(CELL_W)
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

    def _on_vscroll(self, val):
        self.gutter.update()
        if not self._adjusting:
            self._stick_v = val >= self.scroll.verticalScrollBar().maximum() - ROW_H

    def _on_hscroll(self, val):
        self.header.update()
        if not self._adjusting:
            self._stick_h = val >= self.scroll.horizontalScrollBar().maximum() - CELL_W

    def _legend_widget(self):
        # Each swatch is tightly coupled to ITS label (3px), with a clear gap
        # between entries (14px) so the swatch->label pairing is unambiguous.
        w = QWidget(); h = QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0); h.setSpacing(14)
        items = [("F fetch", C_STG_FETCH), ("L fill", C_STG_FILL), ("D dec", C_STG_DEC),
                 ("M mem", C_STG_MEM), ("X exec", C_STG_EXEC), ("W wb", C_STG_WB),
                 ("= stall", C_STG_STALL), ("! flush", C_MISPRED), ("FP", C_FP),
                 ("walk", C_WALK)]
        for txt, col in items:
            it = QWidget(); ih = QHBoxLayout(it); ih.setContentsMargins(0, 0, 0, 0); ih.setSpacing(3)
            sw = QLabel(); sw.setStyleSheet(f"background:{col}; border:1px solid #30363d;")
            sw.setFixedSize(12, 12)
            lab = QLabel(txt); lab.setStyleSheet("color:#9aa3ad; font-size:9px;")
            ih.addWidget(sw); ih.addWidget(lab)
            h.addWidget(it)
        return w

    def reset(self, backend, bits):
        self.plot.reset(backend, bits)
        self._last_cyc = 0
        self._stick_v = True
        self._stick_h = True
        self.gutter.update(); self.header.update()

    def set_bits(self, bits):
        self.plot.bits = bits

    def stats(self):
        return self.plot.stat

    def highlight_cycle(self, cyc):
        self.plot.playhead = cyc
        row = self.plot._cyc_row.get(cyc)
        if row is None:
            self.plot.update(); return
        self.plot.sel_row = row
        self.scroll.ensureVisible(self.plot._x(cyc), row * ROW_H + ROW_H // 2, 40, 60)
        self.plot.update(); self.gutter.update()

    def clear_playhead(self):
        self.plot.playhead = None
        self.plot.anchor = None
        self.plot.update()

    def update_from(self, backend):
        total = backend.cycle_count()
        if total <= self._last_cyc:
            return
        self._last_cyc = self.plot.ingest(backend, self._last_cyc + 1)
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
        self.setMouseTracking(True)
        self._hover_x = -1
        self.setCursor(Qt.PointingHandCursor)

    def reset(self, backend):
        self.backend = backend
        self._last_cyc = 0
        self.ret = []; self.ev = []
        self.update()

    def ingest(self):
        if self.backend is None:
            return
        for c in self.backend.get_cycles(self._last_cyc + 1, 8192):
            self.ret.append((1 if c.retU else 0) + (1 if c.retV else 0))
            name = self.backend.state_name(c.state)
            if c.mispred_bubbles > 0:
                e = "m"
            elif name == "S_WALK":
                e = "w"
            elif name == "S_PF":
                e = "f"
            elif c.stall_cnt > 0 or c.pending_mem_pen > 0:
                e = "s"
            else:
                e = ""
            self.ev.append(e)
            self._last_cyc = c.cyc
        if len(self.ret) > self.CAP:
            self.ret = self.ret[-self.CAP:]; self.ev = self.ev[-self.CAP:]
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
            p.drawText(QRect(labelw, ipc_y0, plotw, ipc_h), Qt.AlignCenter,
                       "IPC / stall sparkline — click to seek")
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
        p.end()

    def next_event(self, from_cyc, direction, cls="any"):
        """Cycle of the next (direction +1) / previous (-1) event — a mispredict
        'm', stall 's', I-fill 'f' or page-walk 'w' (or 'any') — scanning outward
        from from_cyc. Returns the cycle, or None if there's no further event."""
        n = len(self.ev)
        if n == 0:
            return None
        i = (n - 1 - (self._last_cyc - int(from_cyc))) + direction
        i = max(0, min(i, n - 1))    # a from_cyc outside the strip starts at an edge
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
        start = max(0, n - plotw)
        shown = n - start
        bw = plotw / shown                          # must match paintEvent's scale
        i = start + int((int(x) - self._LABELW) / bw)
        return self._last_cyc - (n - 1 - i) if 0 <= i < n else None

    def mousePressEvent(self, ev):
        cyc = self._cyc_at(ev.position().x() if hasattr(ev, "position") else ev.x())
        if cyc is not None:
            self.cycleClicked.emit(int(cyc))     # seek the Konata playhead here

    def leaveEvent(self, _ev):
        self._hover_x = -1
        self.update()

    def mouseMoveEvent(self, ev):
        x = int(ev.position().x() if hasattr(ev, "position") else ev.x())
        self._hover_x = x
        cyc = self._cyc_at(x)
        if cyc is not None:
            i = len(self.ev) - 1 - (self._last_cyc - cyc)
            ev_name = {"m": "mispredict", "s": "stall", "f": "I-fill", "w": "page-walk"}.get(self.ev[i], "")
            self.setToolTip(f"cyc {cyc}: {self.ret[i]} retired"
                            + (f", {ev_name}" if ev_name else "") + "  ·  click to seek")
        self.update()


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

    def clear_playhead(self):
        self.konata.clear_playhead()

    def update_from(self, backend, state):
        bits = 32 if state.cs_d else 16
        self.konata.plot.bits = bits
        self.konata.plot.cs_base = state.cs_base
        self.board.set_state(state, backend, bits)
        self.spark.ingest()
        self.konata.update_from(backend)
