# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The main pipeline panel.

Two complementary views of the Ventium core's three pipelines (U / V / FP):

  * StageBoard  — a LIVE snapshot. The classic P5 in-order stages
    (PF -> D1 -> D2 -> EX -> WB, plus the FP X1/X2/WF/ER stages) drawn as a
    grid of U / V / FP lanes, with the cell(s) the core is working in THIS clock
    lit and labelled with the occupying instruction. Derived from the FSM
    `state` (rtl/core/core.sv) via disasm.STATE_STAGE.

  * Timeline    — a SCROLLING cycle history (Konata/gem5-pipeview style). One
    column per core clock: a top band coloured by FSM state (fills, walks, FP,
    interrupts), thin bubble markers (AGI / mispredict / D-miss / FP-occupancy),
    and U / V lanes where each retired instruction is placed at its retire cycle
    with its mnemonic. This is where dual issue, stalls, and cache-fill gaps are
    visible over time.
"""
from PySide6.QtWidgets import QWidget, QVBoxLayout, QLabel, QScrollArea, QSizePolicy, QHBoxLayout
from PySide6.QtGui import QPainter, QColor, QFont, QPen, QBrush, QFontMetrics
from PySide6.QtCore import Qt, QRect, QSize

from . import disasm

INT_STAGES = ["PF", "D1", "D2", "EX", "WB"]
FP_STAGES = ["X1", "X2", "WF", "ER"]
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
        # value = (list_of_lit_stage_indices, text)
        return {"U": ([], ""), "V": ([], ""), "FP": ([], "")}

    def set_state(self, s, backend, bits):
        name = backend.state_name(s.state)
        lane, stage, color, desc = disasm.stage_of(name)
        self._statecol = color
        cells = self._blank()

        def dis(addr):
            t, sz = disasm.text(backend.mem_read(addr, 16), addr, bits)
            return t

        issuing = (name == "S_PIPE" and s.stall_cnt == 0 and s.mispred_bubbles == 0
                   and s.pending_mem_pen == 0)
        if name == "S_PIPE":
            if s.ud_is_fp:
                cells["FP"] = ([0, 1, 3], dis(s.eip))      # FP issue (whole pipe)
            elif issuing:
                cells["U"] = ([3, 4], dis(s.eip))          # EX + WB
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
        self._status = (f"{name}  ({desc})   eip=0x{s.eip:08x}   cyc={s.core_cyc}{pair}{hz}")
        self.update()

    def reset(self):
        self._cells = self._blank(); self._status = "reset"; self._statecol = _DIM
        self.update()

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(_BG))
        p.setRenderHint(QPainter.Antialiasing, False)
        W = self.width()
        lane_h = 34
        top = 26
        lane_label_w = 38
        # integer block occupies left ~62%, FP block the rest
        int_w = int((W - lane_label_w - 16) * 0.62)
        fp_x0 = lane_label_w + int_w + 16

        p.setFont(_mono(9, True))
        p.setPen(QColor(_MUT))
        p.drawText(QRect(0, 4, W, 18), Qt.AlignLeft, "  Integer pipeline (U / V)")
        p.drawText(QRect(fp_x0, 4, W - fp_x0, 18), Qt.AlignLeft, "FP pipeline")

        # stage headers
        icw = int_w / len(INT_STAGES)
        fcw = (W - fp_x0 - 6) / len(FP_STAGES)
        p.setFont(_mono(8))
        p.setPen(QColor(_MUT))
        for i, st in enumerate(INT_STAGES):
            x = lane_label_w + i * icw
            p.drawText(QRect(int(x), top - 14, int(icw), 12), Qt.AlignCenter, st)
        for i, st in enumerate(FP_STAGES):
            x = fp_x0 + i * fcw
            p.drawText(QRect(int(x), top - 14, int(fcw), 12), Qt.AlignCenter, st)

        lanes = [("U", "U", INT_STAGES, lane_label_w, icw, int_w),
                 ("V", "V", INT_STAGES, lane_label_w, icw, int_w),
                 ("FP", "FP", FP_STAGES, fp_x0, fcw, W - fp_x0 - 6)]
        # U and V share the integer block; FP is its own row but we stack all 3
        for r, (key, label, stages, x0, cw, blockw) in enumerate(lanes):
            y = top + r * lane_h
            p.setFont(_mono(9, True)); p.setPen(QColor(_MUT))
            p.drawText(QRect(2, y, lane_label_w - 4, lane_h), Qt.AlignVCenter | Qt.AlignRight, label)
            lit_idxs, text = self._cells.get(key, ([], ""))
            for i, st in enumerate(stages):
                cx = x0 + i * cw
                cell = QRect(int(cx) + 1, y + 2, int(cw) - 2, lane_h - 6)
                lit = (i in lit_idxs)
                col = QColor(self._statecol) if lit else QColor(_DIM)
                p.fillRect(cell, col)
                p.setPen(QColor(_GRID)); p.drawRect(cell)
            # draw the instruction text spanning the lit cells (one label per lane)
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

        # status line
        p.setFont(_mono(9))
        p.setPen(QColor(_TXT))
        p.drawText(QRect(4, top + 3 * lane_h + 4, W - 8, 18), Qt.AlignLeft, self._status)
        p.end()


# ===========================================================================
# Scrolling cycle timeline
# ===========================================================================
class _TimelineCanvas(QWidget):
    COL_W = 13
    STATE_H = 22
    BUB_H = 8
    LANE_H = 20

    def __init__(self, parent=None):
        super().__init__(parent)
        self.samples = []            # list of dicts (lightweight copies)
        self._pc_text = {}           # pc -> mnemonic cache
        self.bits = 32
        self.backend = None
        self._total_h = self.STATE_H + self.BUB_H + 2 * self.LANE_H + 24
        self.setMinimumHeight(self._total_h)
        self.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self.setMouseTracking(True)
        self._hover = -1

    def reset(self, backend, bits):
        self.samples = []
        self._pc_text = {}
        self.backend = backend
        self.bits = bits
        self._resize()

    def _mnemonic(self, pc):
        t = self._pc_text.get(pc)
        if t is None and self.backend is not None:
            sz, mn, ops, _ = disasm.disasm_one(self.backend.mem_read(pc, 16), pc, self.bits)
            t = mn
            self._pc_text[pc] = t
        return t or "?"

    def ingest(self, backend, since_cyc):
        new = backend.get_cycles(since_cyc, 8192)
        for c in new:
            self.samples.append({
                "cyc": c.cyc, "state": c.state,
                "name": backend.state_name(c.state),
                "stall": (c.stall_cnt > 0 or c.mispred_bubbles > 0 or c.pending_mem_pen > 0),
                "mispred": c.mispred_bubbles > 0,
                "fp": c.fp_occ_pending > 0,
                "retU": c.retU, "retV": c.retV,
                "nU": c.nU, "nV": c.nV, "pcU": c.pcU, "pcV": c.pcV,
            })
        # rolling cap
        if len(self.samples) > 40000:
            self.samples = self.samples[-40000:]
        self._resize()
        return self.samples[-1]["cyc"] if self.samples else since_cyc

    def _resize(self):
        w = max(self.parent().width() if self.parent() else 600,
                len(self.samples) * self.COL_W + 4)
        self.setFixedSize(w, self._total_h)

    def sizeHint(self):
        return QSize(len(self.samples) * self.COL_W + 4, self._total_h)

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(_BG))
        if not self.samples:
            p.setPen(QColor(_MUT)); p.setFont(_mono(10))
            p.drawText(self.rect(), Qt.AlignCenter, "step the core to populate the timeline")
            p.end(); return

        cw = self.COL_W
        y_state = 2
        y_bub = y_state + self.STATE_H
        y_u = y_bub + self.BUB_H
        y_v = y_u + self.LANE_H
        base_cyc = self.samples[0]["cyc"]

        # only paint visible columns
        vis = ev.rect()
        i0 = max(0, vis.left() // cw - 1)
        i1 = min(len(self.samples), vis.right() // cw + 2)

        p.setFont(_mono(8))
        for i in range(i0, i1):
            s = self.samples[i]
            x = i * cw
            col = QColor(disasm.STATE_STAGE.get(s["name"], ("", "", "#8b949e", ""))[2])
            # state band
            r = QRect(x, y_state, cw - 1, self.STATE_H)
            p.fillRect(r, col)
            if s["stall"]:
                # hatch the stalled clocks darker so bubbles read even within S_PIPE
                p.fillRect(QRect(x, y_state, cw - 1, self.STATE_H),
                           QColor(0, 0, 0, 90))
            # bubble marker row
            if s["mispred"]:
                p.fillRect(QRect(x, y_bub, cw - 1, self.BUB_H), QColor(disasm.C_WALK))
            elif s["stall"]:
                p.fillRect(QRect(x, y_bub, cw - 1, self.BUB_H), QColor("#6e7681"))
            elif s["fp"]:
                p.fillRect(QRect(x, y_bub, cw - 1, self.BUB_H), QColor(disasm.C_FP))
            # U / V retire blocks
            if s["retU"]:
                rr = QRect(x, y_u, cw - 1, self.LANE_H - 1)
                p.fillRect(rr, QColor(disasm.C_PIPE))
                p.setPen(QColor("#0d1117"))
                p.drawText(rr, Qt.AlignCenter, self._mnemonic(s["pcU"])[:4])
            if s["retV"]:
                rr = QRect(x, y_v, cw - 1, self.LANE_H - 1)
                p.fillRect(rr, QColor(disasm.C_PIPE))
                p.setPen(QColor("#0d1117"))
                p.drawText(rr, Qt.AlignCenter, self._mnemonic(s["pcV"])[:4])

            # cycle tick every 10
            if s["cyc"] % 10 == 0:
                p.setPen(QColor(_GRID))
                p.drawLine(x, 0, x, self._total_h)
                p.setPen(QColor(_MUT))
                p.drawText(QRect(x + 1, y_v + self.LANE_H, 40, 12), Qt.AlignLeft, str(s["cyc"]))

        # hover highlight + tooltip handled in mouseMove
        p.end()

    def mouseMoveEvent(self, ev):
        i = ev.position().x() // self.COL_W if hasattr(ev, "position") else ev.x() // self.COL_W
        i = int(i)
        if 0 <= i < len(self.samples):
            s = self.samples[i]
            tip = f"cyc {s['cyc']}  {s['name']}"
            if s["retU"]:
                tip += f"\nU: n={s['nU']} {self._mnemonic(s['pcU'])} @{s['pcU']:#x}"
            if s["retV"]:
                tip += f"\nV: n={s['nV']} {self._mnemonic(s['pcV'])} @{s['pcV']:#x}"
            if s["stall"]:
                tip += "\n(stall / bubble)"
            self.setToolTip(tip)


class Timeline(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(2, 2, 2, 2); v.setSpacing(2)
        head = QHBoxLayout()
        title = QLabel("Cycle timeline"); title.setStyleSheet("font-weight:bold;")
        head.addWidget(title)
        head.addStretch(1)
        self.legend = QLabel(); self.legend.setFont(_mono(8))
        head.addWidget(self._legend_widget())
        v.addLayout(head)
        # row labels overlaying the scroll area
        body = QHBoxLayout(); body.setSpacing(0)
        labels = QVBoxLayout(); labels.setContentsMargins(0, 2, 0, 0); labels.setSpacing(0)
        for txt, h in [("state", 22), ("bub", 8), ("U", 20), ("V", 20)]:
            l = QLabel(txt); l.setFixedHeight(h); l.setFixedWidth(34)
            l.setStyleSheet("color:#8b949e; font-size:8px;")
            l.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
            labels.addWidget(l)
        labels.addStretch(1)
        lw = QWidget(); lw.setLayout(labels); lw.setFixedWidth(34)
        body.addWidget(lw)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(False)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOn)
        self.scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.canvas = _TimelineCanvas(self.scroll)
        self.scroll.setWidget(self.canvas)
        self.scroll.setFixedHeight(self.canvas._total_h + 20)
        lw.setFixedHeight(self.canvas._total_h + 20)
        body.addWidget(self.scroll, 1)
        v.addLayout(body, 0)
        v.addStretch(1)
        self._last_cyc = 0
        self._follow = True

    def _legend_widget(self):
        w = QWidget(); h = QHBoxLayout(w); h.setContentsMargins(0, 0, 0, 0); h.setSpacing(8)
        for txt, col in disasm.LEGEND:
            sw = QLabel("  "); sw.setStyleSheet(
                f"background:{col}; border:1px solid #30363d;")
            sw.setFixedSize(12, 12)
            lab = QLabel(txt); lab.setStyleSheet("color:#8b949e; font-size:8px;")
            h.addWidget(sw); h.addWidget(lab)
        return w

    def reset(self, backend, bits):
        self.canvas.reset(backend, bits)
        self._last_cyc = 0

    def update_from(self, backend):
        total = backend.cycle_count()
        if total <= self._last_cyc:
            return
        sb = self.scroll.horizontalScrollBar()
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
        self.timeline = Timeline()
        v.addWidget(self.timeline, 1)
        self._bits = 32

    def set_bits(self, bits):
        self._bits = bits

    def reset(self, backend):
        self.board.reset()
        self.timeline.reset(backend, self._bits)

    def update_from(self, backend, state):
        self.board.set_state(state, backend, self._bits)
        self.timeline.update_from(backend)
