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
from PySide6.QtCore import Qt, QRect, QSize

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
        self.setFixedHeight(150)
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
                cells["U"] = ([3], "· stall")
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
        lane_h = 30
        title_y = 2          # section titles band
        hdr_y = 20           # stage-label band (separated from titles -> no collision)
        top = 36             # cells start
        lane_label_w = 38
        int_w = int((W - lane_label_w - 16) * 0.62)
        fp_x0 = lane_label_w + int_w + 16

        fp_idle = not self._cells.get("FP", ([], ""))[0]
        p.setFont(_mono(9, True)); p.setPen(QColor(C_PIPE))
        p.drawText(QRect(lane_label_w, title_y, int_w, 14), Qt.AlignLeft,
                   "Integer pipeline  (U / V)")
        p.setPen(QColor(_MUT if fp_idle else C_FP))
        p.drawText(QRect(fp_x0, title_y, W - fp_x0, 14), Qt.AlignLeft,
                   "FP pipeline" + ("  (idle)" if fp_idle else ""))

        icw = int_w / len(INT_STAGES)
        fcw = (W - fp_x0 - 6) / len(FP_STAGES)
        p.setFont(_mono(8, True)); p.setPen(QColor("#7d8590"))
        for i, st in enumerate(INT_STAGES):
            p.drawText(QRect(int(lane_label_w + i * icw), hdr_y, int(icw), 12),
                       Qt.AlignCenter, st)
        for i, st in enumerate(FP_STAGES):
            p.drawText(QRect(int(fp_x0 + i * fcw), hdr_y, int(fcw), 12),
                       Qt.AlignCenter, st)

        lanes = [("U", "U", INT_STAGES, lane_label_w, icw, False),
                 ("V", "V", INT_STAGES, lane_label_w, icw, False),
                 ("FP", "FP", FP_STAGES, fp_x0, fcw, fp_idle)]
        for r, (key, label, stages, x0, cw, idle) in enumerate(lanes):
            y = top + r * lane_h
            p.setFont(_mono(9, True)); p.setPen(QColor("#5b6470" if idle else _MUT))
            p.drawText(QRect(2, y, lane_label_w - 4, lane_h),
                       Qt.AlignVCenter | Qt.AlignRight, label)
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
                lo, hi = min(lit_idxs), max(lit_idxs)
                span = QRect(int(x0 + lo * cw) + 2, y + 2,
                             int((hi - lo + 1) * cw) - 4, lane_h - 6)
                p.setPen(QColor("#0d1117") if QColor(self._statecol).lightness() > 140
                         else QColor(_TXT))
                p.setFont(_mono(8, True))
                fm = QFontMetrics(p.font())
                p.drawText(span, Qt.AlignVCenter | Qt.AlignHCenter,
                           fm.elidedText(text, Qt.ElideRight, span.width() - 4))
        p.setFont(_mono(9)); p.setPen(QColor(_TXT))
        p.drawText(QRect(4, top + 3 * lane_h + 4, W - 8, 18), Qt.AlignLeft, self._status)
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
ROW_H = 15
CELL_W = 14
GUTTER_W = 218
HDR_H = 18


def _recolor_fp(cells, mnem):
    """Cycle-mode x87 ops execute on the S_PIPE fast path (green X); recolour
    their execute cells to the FP purple when the mnemonic is an x87 op."""
    if not (mnem[:1] == "f" and mnem[:2] not in ("fs", "gs")):
        return list(cells)
    return [(cy, ch, C_FP if co == C_PIPE else co) for (cy, ch, co) in cells]


def _stage_cell(name, ret, stall, mispred):
    """Map one cycle's FSM state to a (letter, colour) lifecycle cell."""
    if name == "S_PIPE":
        if mispred:
            return ("!", C_MISPRED)
        if ret:
            return ("X", C_PIPE)        # issue + execute + writeback (fast path)
        return ("=", C_STALL)           # materialised stall / bubble
    if name == "S_PF":
        return ("F", C_FILL)            # I-cache line fill
    if name == "S_FETCH":
        return ("F", C_SLOW)
    if name == "S_DECODE":
        return ("D", C_SLOW)
    if name in ("S_LOAD", "S_LOAD2"):
        return ("M", C_SLOW)
    if name == "S_EXEC":
        return ("X", C_SLOW)
    if name in ("S_STORE", "S_USEQ", "S_IO", "S_INS"):
        return ("W", C_SLOW)
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
                cells = _recolor_fp(self._pending, mn)
                self.insns.append(dict(n=c.nU, pc=c.pcU, pipe="U", mnem=mn,
                                       cells=cells, c0=cells[0][0], c1=c.cyc))
                self._cyc_row[c.cyc] = len(self.insns) - 1
                self.stat["uret"] += 1
                self._pending = []
            if c.retV:
                mn = self._mn(c.pcV)
                vch = "X"
                vcol = C_FP if (mn[:1] == "f" and mn[:2] not in ("fs", "gs")) else C_PIPE
                self.insns.append(dict(n=c.nV, pc=c.pcV, pipe="V", mnem=mn,
                                       cells=[(c.cyc, vch, vcol)], c0=c.cyc, c1=c.cyc))
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
        h = max(1, len(self.insns) * ROW_H)
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
        r0 = max(0, vis.top() // ROW_H - 1)
        r1 = min(len(self.insns), vis.bottom() // ROW_H + 2)
        xlo, xhi = vis.left() - CELL_W, vis.right() + CELL_W
        p.setFont(_mono(8, True))
        for r in range(r0, r1):
            ins = self.insns[r]
            y = r * ROW_H
            if r % 2:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#0f141b"))
            if r == self.sel_row:
                p.fillRect(QRect(0, y, self.width(), ROW_H), QColor("#1c2531"))
            for (cyc, ch, col) in ins["cells"]:
                x = self._x(cyc)
                if x < xlo or x > xhi:
                    continue
                cell = QRect(x, y + 1, CELL_W - 1, ROW_H - 2)
                p.fillRect(cell, QColor(col))
                p.setPen(QColor("#0d1117") if QColor(col).lightness() > 130 else QColor(_TXT))
                p.drawText(cell, Qt.AlignCenter, ch)
        p.end()

    def mouseMoveEvent(self, ev):
        x = (ev.position().x() if hasattr(ev, "position") else ev.x())
        y = (ev.position().y() if hasattr(ev, "position") else ev.y())
        r = int(y // ROW_H)
        if 0 <= r < len(self.insns):
            ins = self.insns[r]
            self.setToolTip(
                f"n={ins['n']}  {ins['pipe']}  {ins['pc']:#010x}  {ins['mnem']}\n"
                f"cycles {ins['c0']}..{ins['c1']}  (commit @ {ins['c1']}, "
                f"{ins['c1'] - ins['c0'] + 1} cyc)")


class _KonataGutter(QWidget):
    """Frozen left column: instruction labels (n / pipe / PC / mnemonic),
    vertically synced to the plot's scroll offset."""
    def __init__(self, plot, scroll, parent=None):
        super().__init__(parent)
        self.plot = plot
        self.scroll = scroll
        self.setFixedWidth(GUTTER_W)

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
            p.setPen(QColor("#586069"))
            p.drawText(QRect(2, y, 46, ROW_H), Qt.AlignVCenter | Qt.AlignRight, str(it["n"]))
            p.setPen(QColor("#79c0ff" if it["pipe"] == "U" else "#e3b341"))
            p.drawText(QRect(52, y, 12, ROW_H), Qt.AlignVCenter | Qt.AlignHCenter, it["pipe"])
            p.setPen(QColor("#6e7681"))
            p.drawText(QRect(66, y, 60, ROW_H), Qt.AlignVCenter | Qt.AlignLeft, f"{it['pc']:08x}")
            _, icol = disasm.insn_class(it["mnem"].split(" ")[0])
            p.setPen(QColor(icol))
            p.drawText(QRect(128, y, GUTTER_W - 130, ROW_H), Qt.AlignVCenter | Qt.AlignLeft,
                       fm.elidedText(it["mnem"], Qt.ElideRight, GUTTER_W - 132))
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
        head = QHBoxLayout()
        title = QLabel("Pipeline view  (gem5/Konata — instruction × cycle)")
        title.setStyleSheet("font-weight:bold;")
        head.addWidget(title); head.addStretch(1)
        head.addWidget(self._legend_widget())
        v.addLayout(head)

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

        self.scroll.verticalScrollBar().valueChanged.connect(self.gutter.update)
        self.scroll.horizontalScrollBar().valueChanged.connect(self.header.update)
        self._last_cyc = 0

    def _legend_widget(self):
        w = QWidget(); h = QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0); h.setSpacing(7)
        items = [("F fetch/fill", C_FILL), ("D decode", C_SLOW), ("X exec", C_PIPE),
                 ("W wb", C_SLOW), ("= stall", C_STALL), ("! flush", C_MISPRED),
                 ("FP", C_FP), ("walk", C_WALK)]
        for txt, col in items:
            sw = QLabel(); sw.setStyleSheet(f"background:{col}; border:1px solid #30363d;")
            sw.setFixedSize(11, 11)
            lab = QLabel(txt); lab.setStyleSheet("color:#8b949e; font-size:8px;")
            h.addWidget(sw); h.addWidget(lab)
        return w

    def reset(self, backend, bits):
        self.plot.reset(backend, bits)
        self._last_cyc = 0
        self.gutter.update(); self.header.update()

    def set_bits(self, bits):
        self.plot.bits = bits

    def stats(self):
        return self.plot.stat

    def highlight_cycle(self, cyc):
        row = self.plot._cyc_row.get(cyc)
        if row is None:
            return
        self.plot.sel_row = row
        self.scroll.ensureVisible(self.plot._x(cyc), row * ROW_H + ROW_H // 2, 40, 60)
        self.plot.update(); self.gutter.update()

    def update_from(self, backend):
        total = backend.cycle_count()
        if total <= self._last_cyc:
            return
        vb = self.scroll.verticalScrollBar(); hb = self.scroll.horizontalScrollBar()
        follow_v = vb.value() >= vb.maximum() - 4
        follow_h = hb.value() >= hb.maximum() - 4
        self._last_cyc = self.plot.ingest(backend, self._last_cyc + 1)
        self.plot.update(); self.gutter.update(); self.header.update()
        if follow_v:
            vb.setValue(vb.maximum())
        if follow_h:
            hb.setValue(hb.maximum())


# ===========================================================================
# Composite panel
# ===========================================================================
class PipelineView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(2, 2, 2, 2); v.setSpacing(4)
        bt = QLabel("Pipelines — U / V (integer dual-issue) + FP (x87)")
        bt.setStyleSheet("font-weight:bold;")
        v.addWidget(bt)
        self.board = StageBoard()
        v.addWidget(self.board)
        self.konata = Konata()
        v.addWidget(self.konata, 1)
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
        self.konata.reset(backend, self._bits)

    def stats(self):
        return self.konata.stats()

    def highlight_cycle(self, cyc):
        self.konata.highlight_cycle(cyc)

    def update_from(self, backend, state):
        bits = 32 if state.cs_d else 16
        self.konata.plot.bits = bits
        self.konata.plot.cs_base = state.cs_base
        self.board.set_state(state, backend, bits)
        self.konata.update_from(backend)
