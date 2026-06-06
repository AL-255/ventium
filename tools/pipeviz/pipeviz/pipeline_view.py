# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The main pipeline panel.

  * StageBoard — a LIVE snapshot of the classic P5 in-order stages
    (PF -> D1 -> D2 -> EX -> WB, plus the FP X1/X2/WF/ER stages) as U / V / FP
    lanes, the cell(s) the core works in THIS clock lit + labelled with the
    occupying instruction. Derived from the FSM `state` (rtl/core/core.sv).

  * Waterfall — the cycle history as a pipeline waterfall: **Y axis = time**
    (cycles flowing downward), **X axis = stages**, laid out as three side-by-side
    groups U | V | FP. Each cycle is a row; the stage cell(s) a lane occupies that
    cycle are filled and labelled. A slow (multi-cycle) instruction streaks
    diagonally down-and-right through PF->D1->D2->EX->WB; the fast path lights
    EX+WB in a single row; the FP pipe streaks through X1/X2/ER. Cache fills,
    stalls, mispredicts and page walks read directly off the colours.
"""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QLabel, QScrollArea,
                               QSizePolicy, QHBoxLayout)
from PySide6.QtGui import QPainter, QColor, QFont, QFontMetrics
from PySide6.QtCore import Qt, QRect, QSize

from . import disasm
from .disasm import (C_PIPE, C_FILL, C_SLOW, C_FP, C_WALK, C_SYS, C_HALT)

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
        self.setMinimumHeight(190)
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
        hz = ("   ⚠ " + ", ".join(haz)) if haz else ""
        pair = "  ⇄ paired" if (name == "S_PIPE" and s.pipe_pair) else ""
        self._status = f"{name}  ({desc})   eip=0x{s.eip:08x}   cyc={s.core_cyc}{pair}{hz}"
        self.update()

    def reset(self):
        self._cells = self._blank(); self._status = "reset"; self._statecol = _DIM
        self.update()

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(_BG))
        W = self.width()
        lane_h = 34
        top = 26
        lane_label_w = 38
        int_w = int((W - lane_label_w - 16) * 0.62)
        fp_x0 = lane_label_w + int_w + 16

        p.setFont(_mono(9, True)); p.setPen(QColor(_MUT))
        p.drawText(QRect(0, 4, W, 18), Qt.AlignLeft, "  Integer pipeline (U / V)")
        p.drawText(QRect(fp_x0, 4, W - fp_x0, 18), Qt.AlignLeft, "FP pipeline")

        icw = int_w / len(INT_STAGES)
        fcw = (W - fp_x0 - 6) / len(FP_STAGES)
        p.setFont(_mono(8)); p.setPen(QColor(_MUT))
        for i, st in enumerate(INT_STAGES):
            p.drawText(QRect(int(lane_label_w + i * icw), top - 14, int(icw), 12),
                       Qt.AlignCenter, st)
        for i, st in enumerate(FP_STAGES):
            p.drawText(QRect(int(fp_x0 + i * fcw), top - 14, int(fcw), 12),
                       Qt.AlignCenter, st)

        lanes = [("U", "U", INT_STAGES, lane_label_w, icw),
                 ("V", "V", INT_STAGES, lane_label_w, icw),
                 ("FP", "FP", FP_STAGES, fp_x0, fcw)]
        for r, (key, label, stages, x0, cw) in enumerate(lanes):
            y = top + r * lane_h
            p.setFont(_mono(9, True)); p.setPen(QColor(_MUT))
            p.drawText(QRect(2, y, lane_label_w - 4, lane_h),
                       Qt.AlignVCenter | Qt.AlignRight, label)
            lit_idxs, text = self._cells.get(key, ([], ""))
            for i, st in enumerate(stages):
                cx = x0 + i * cw
                cell = QRect(int(cx) + 1, y + 2, int(cw) - 2, lane_h - 6)
                col = QColor(self._statecol) if (i in lit_idxs) else QColor(_DIM)
                p.fillRect(cell, col)
                p.setPen(QColor(_GRID)); p.drawRect(cell)
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
# Waterfall geometry (shared by the header bar + canvas)
# ===========================================================================
GUTTER = 58          # cycle number + state swatch
STAGE_W = 42
GAP = 14
ROW_H = 16


def group_x0(gi):
    x = GUTTER
    for i in range(gi):
        x += len(GROUPS[i][1]) * STAGE_W + GAP
    return x


def total_width():
    last = len(GROUPS) - 1
    return group_x0(last) + len(GROUPS[last][1]) * STAGE_W + 8


def stage_rect_x(gi, lo, hi):
    x0 = group_x0(gi) + lo * STAGE_W
    return x0, (hi - lo + 1) * STAGE_W


# ===========================================================================
# Waterfall header bar (sticky column labels above the scrolling canvas)
# ===========================================================================
class _WaterfallHeader(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(30)
        self.setFixedWidth(total_width())

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#161b22"))
        p.setPen(QColor(_MUT)); p.setFont(_mono(8, True))
        p.drawText(QRect(0, 0, GUTTER, 30), Qt.AlignCenter, "cyc")
        for gi, (gname, stages, gcol) in enumerate(GROUPS):
            gx = group_x0(gi)
            gw = len(stages) * STAGE_W
            p.setPen(QColor(gcol)); p.setFont(_mono(9, True))
            p.drawText(QRect(gx, 0, gw, 14), Qt.AlignCenter, gname)
            p.setPen(QColor(_MUT)); p.setFont(_mono(7))
            for i, st in enumerate(stages):
                p.drawText(QRect(gx + i * STAGE_W, 15, STAGE_W, 13), Qt.AlignCenter, st)
        p.end()


# ===========================================================================
# Waterfall canvas — Y = time (down), X = stages grouped U | V | FP
# ===========================================================================
class _WaterfallCanvas(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.rows = []           # per-cycle dicts
        self._pc_text = {}
        self.bits = 32
        self.cs_base = 0
        self.backend = None
        self.setFixedWidth(total_width())
        self.setMouseTracking(True)
        # live stats
        self.stat = dict(uret=0, vret=0, fill=0, stall=0, mispred=0, walk=0, sysm=0)

    def reset(self, backend, bits):
        self.rows = []; self._pc_text = {}; self.backend = backend; self.bits = bits
        self.stat = dict(uret=0, vret=0, fill=0, stall=0, mispred=0, walk=0, sysm=0)
        self.setFixedHeight(ROW_H + 2)

    def _mn(self, pc):
        key = (pc, self.cs_base, self.bits)
        t = self._pc_text.get(key)
        if t is None and self.backend is not None:
            _, mn, _, _ = disasm.disasm_one(
                self.backend.mem_read(self.cs_base + pc, 16), pc, self.bits)
            t = mn; self._pc_text[key] = t
        return t or "?"

    def ingest(self, backend, since_cyc):
        new = backend.get_cycles(since_cyc, 8192)
        for c in new:
            name = backend.state_name(c.state)
            d = {"cyc": c.cyc, "name": name, "eip": c.eip, "pf_word": c.pf_word,
                 "retU": c.retU, "retV": c.retV, "pcU": c.pcU, "pcV": c.pcV,
                 "stall": (c.stall_cnt > 0 or c.pending_mem_pen > 0),
                 "mispred": c.mispred_bubbles > 0, "fp": c.fp_occ_pending > 0}
            self.rows.append(d)
            # stats
            if c.retU: self.stat["uret"] += 1
            if c.retV: self.stat["vret"] += 1
            if name == "S_PF": self.stat["fill"] += 1
            if d["mispred"]: self.stat["mispred"] += 1
            if name == "S_WALK": self.stat["walk"] += 1
            if d["stall"] and name == "S_PIPE": self.stat["stall"] += 1
        if len(self.rows) > 24000:
            self.rows = self.rows[-24000:]
        self.setFixedHeight(max(ROW_H + 2, len(self.rows) * ROW_H + 2))
        return self.rows[-1]["cyc"] if self.rows else since_cyc

    def _cells_for(self, s):
        """Return list of (group_index, lo_stage, hi_stage, text, colour)."""
        gi = {"U": 0, "V": 1, "FP": 2}
        name = s["name"]
        out = []
        if name == "S_PIPE":
            any_ret = False
            if s["retU"]:
                t = self._mn(s["pcU"])
                if t[:1] == "f":
                    out.append((gi["FP"], 0, 3, t, C_FP))
                else:
                    out.append((gi["U"], 3, 4, t, C_PIPE))
                any_ret = True
            if s["retV"]:
                out.append((gi["V"], 3, 4, self._mn(s["pcV"]), C_PIPE))
                any_ret = True
            if not any_ret:
                col = C_WALK if s["mispred"] else "#6e7681"
                lbl = "flush" if s["mispred"] else ("stall" if s["stall"] else "·")
                out.append((gi["U"], 3, 3, lbl, col))
        elif name == "S_PF":
            out.append((gi["U"], 0, 0, f"fill{s['pf_word']}", C_FILL))
        elif name == "S_FETCH":
            out.append((gi["U"], 0, 0, self._mn(s["eip"]), C_SLOW))
        elif name == "S_DECODE":
            out.append((gi["U"], 1, 2, self._mn(s["eip"]), C_SLOW))
        elif name in ("S_LOAD", "S_LOAD2"):
            out.append((gi["U"], 3, 3, "ld", C_SLOW))
        elif name == "S_EXEC":
            out.append((gi["U"], 3, 3, self._mn(s["eip"]), C_SLOW))
        elif name in ("S_STORE", "S_USEQ", "S_IO", "S_INS"):
            out.append((gi["U"], 4, 4, "st", C_SLOW))
        elif name == "S_FLOAD":
            out.append((gi["FP"], 0, 0, "ld", C_FP))
        elif name == "S_FEXEC":
            out.append((gi["FP"], 0, 1, self._mn(s["eip"]), C_FP))
        elif name in ("S_FSTORE", "S_FENV_ST", "S_FENV_LD"):
            out.append((gi["FP"], 3, 3, "st", C_FP))
        elif name == "S_WALK":
            out.append((gi["U"], 0, 4, "page-walk", C_WALK))
        elif name in ("S_HALT", "S_F00F_HANG"):
            out.append((gi["U"], 0, 0, "halt", C_HALT))
        else:
            # system / interrupt / task / SMM microcode — span the U group
            out.append((gi["U"], 0, 4, name.replace("S_", "").lower(), C_SYS))
        return out

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(ev.rect(), QColor(_BG))
        if not self.rows:
            p.setPen(QColor(_MUT)); p.setFont(_mono(10))
            p.drawText(self.rect(), Qt.AlignTop | Qt.AlignHCenter, "\n step the core to fill the waterfall")
            p.end(); return

        # faint group separators (vertical)
        p.setPen(QColor(_GRID))
        for gi in range(len(GROUPS)):
            x = group_x0(gi)
            p.drawLine(x - GAP // 2, ev.rect().top(), x - GAP // 2, ev.rect().bottom())

        base = self.rows[0]["cyc"]
        r0 = max(0, ev.rect().top() // ROW_H - 1)
        r1 = min(len(self.rows), ev.rect().bottom() // ROW_H + 2)
        fm8 = QFontMetrics(_mono(8, True))
        for r in range(r0, r1):
            s = self.rows[r]
            y = r * ROW_H
            statecol = disasm.STATE_STAGE.get(s["name"], ("", "", _MUT, ""))[2]
            # gutter: cycle number + state swatch
            if s["cyc"] % 5 == 0:
                p.setPen(QColor(_MUT)); p.setFont(_mono(7))
                p.drawText(QRect(2, y, GUTTER - 14, ROW_H), Qt.AlignVCenter | Qt.AlignRight,
                           str(s["cyc"]))
            p.fillRect(QRect(GUTTER - 10, y + 1, 8, ROW_H - 2), QColor(statecol))
            # lit stage cells
            for gidx, lo, hi, text, col in self._cells_for(s):
                x0, w = stage_rect_x(gidx, lo, hi)
                cell = QRect(int(x0) + 1, y + 1, int(w) - 2, ROW_H - 2)
                p.fillRect(cell, QColor(col))
                if text:
                    p.setPen(QColor("#0d1117") if QColor(col).lightness() > 140 else QColor(_TXT))
                    p.setFont(_mono(8, True))
                    p.drawText(cell, Qt.AlignVCenter | Qt.AlignHCenter,
                               fm8.elidedText(text, Qt.ElideRight, cell.width() - 2))
        p.end()

    def mouseMoveEvent(self, ev):
        r = int((ev.position().y() if hasattr(ev, "position") else ev.y()) // ROW_H)
        if 0 <= r < len(self.rows):
            s = self.rows[r]
            tip = f"cyc {s['cyc']}  {s['name']}"
            if s["retU"]:
                tip += f"\nU: {self._mn(s['pcU'])} @{s['pcU']:#x}"
            if s["retV"]:
                tip += f"\nV: {self._mn(s['pcV'])} @{s['pcV']:#x}"
            self.setToolTip(tip)


class Waterfall(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(2, 2, 2, 2); v.setSpacing(2)
        head = QHBoxLayout()
        title = QLabel("Pipeline waterfall  (time ↓,  stages →  U | V | FP)")
        title.setStyleSheet("font-weight:bold;")
        head.addWidget(title); head.addStretch(1)
        head.addWidget(self._legend_widget())
        v.addLayout(head)

        self.header = _WaterfallHeader()
        hb = QHBoxLayout(); hb.setContentsMargins(0, 0, 0, 0)
        hb.addWidget(self.header); hb.addStretch(1)
        v.addLayout(hb)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(False)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        self.scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        self.canvas = _WaterfallCanvas(self.scroll)
        self.scroll.setWidget(self.canvas)
        v.addWidget(self.scroll, 1)
        self._last_cyc = 0

    def _legend_widget(self):
        w = QWidget(); h = QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0); h.setSpacing(8)
        for txt, col in disasm.LEGEND:
            sw = QLabel(); sw.setStyleSheet(f"background:{col}; border:1px solid #30363d;")
            sw.setFixedSize(12, 12)
            lab = QLabel(txt); lab.setStyleSheet("color:#8b949e; font-size:8px;")
            h.addWidget(sw); h.addWidget(lab)
        return w

    def reset(self, backend, bits):
        self.canvas.reset(backend, bits)
        self._last_cyc = 0

    def set_bits(self, bits):
        self.canvas.bits = bits

    def stats(self):
        return self.canvas.stat

    def update_from(self, backend):
        total = backend.cycle_count()
        if total <= self._last_cyc:
            return
        sb = self.scroll.verticalScrollBar()
        following = sb.value() >= sb.maximum() - 4
        self._last_cyc = self.canvas.ingest(backend, self._last_cyc + 1)
        self.canvas.update()
        if following:
            sb.setValue(sb.maximum())


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
        self.waterfall = Waterfall()
        v.addWidget(self.waterfall, 1)
        self._bits = 32

    def set_bits(self, bits):
        self._bits = bits
        self.waterfall.set_bits(bits)

    def reset(self, backend):
        self.board.reset()
        self.waterfall.reset(backend, self._bits)

    def update_from(self, backend, state):
        bits = 32 if state.cs_d else 16
        self.waterfall.canvas.bits = bits
        self.waterfall.canvas.cs_base = state.cs_base
        self.board.set_state(state, backend, bits)
        self.waterfall.update_from(backend)
