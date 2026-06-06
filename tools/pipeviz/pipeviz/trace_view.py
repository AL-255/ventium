# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Assembly trace panel — one row per retired instruction, with its raw bytes,
the issuing pipe (U/V), and a capstone disassembly. Appends incrementally."""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QTableWidget,
                               QTableWidgetItem, QHeaderView, QAbstractItemView,
                               QLabel, QStyledItemDelegate, QStyle)
from PySide6.QtGui import QColor, QFont, QBrush, QFontMetrics
from PySide6.QtCore import Qt, QRect, Signal

from . import disasm
from .disasm import C_PIPE, C_FP, FIELD_COLOR

_COLS = ["n", "cyc", "Δ", "pipe", "PC", "bytes", "instruction"]
_BYTES_COL = 5
_MAX_ROWS = 6000   # rolling cap on displayed rows
_BYTES_ROLE = Qt.UserRole + 1
_CYC_ROLE = Qt.UserRole + 2
_U_COL = "#79c0ff"   # U pipe (blue)
_V_COL = "#e3b341"   # V pipe (amber)


class BytesDelegate(QStyledItemDelegate):
    """Paints the instruction bytes coloured by x86 field: light-gray prefix,
    blue opcode, green ModRM, purple SIB, yellow displacement, red immediate."""
    def __init__(self, font, parent=None):
        super().__init__(parent)
        self.font = font

    def paint(self, painter, option, index):
        if option.state & QStyle.State_Selected:
            painter.fillRect(option.rect, option.palette.highlight())
        fields = index.data(_BYTES_ROLE)
        if not fields:
            return
        painter.save()
        painter.setFont(self.font)
        fm = QFontMetrics(self.font)
        adv = fm.horizontalAdvance("00 ")
        x = option.rect.x() + 4
        for b, fld in fields:
            painter.setPen(QColor(FIELD_COLOR.get(fld, "#c9d1d9")))
            painter.drawText(QRect(x, option.rect.y(), adv, option.rect.height()),
                             Qt.AlignVCenter | Qt.AlignLeft, f"{b:02x}")
            x += adv
        painter.restore()


class TraceView(QWidget):
    rowSelected = Signal(int)     # emits the retire cycle of the selected row

    def __init__(self, parent=None):
        super().__init__(parent)
        self._last_cyc = None
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        self.title = QLabel("Retired-instruction trace")
        self.title.setStyleSheet("font-weight:bold;")
        lay.addWidget(self.title)
        self.tbl = QTableWidget(0, len(_COLS))
        self.tbl.setHorizontalHeaderLabels(_COLS)
        self.tbl.verticalHeader().setVisible(False)
        self.tbl.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tbl.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.tbl.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tbl.setShowGrid(False)
        self.tbl.setAlternatingRowColors(True)     # zebra striping
        mono = QFont("monospace"); mono.setStyleHint(QFont.Monospace); mono.setPointSize(9)
        self.tbl.setFont(mono)
        hh = self.tbl.horizontalHeader()
        for i, w in enumerate((56, 58, 42, 40, 76, 232)):
            self.tbl.setColumnWidth(i, w)
        hh.setSectionResizeMode(len(_COLS) - 1, QHeaderView.Stretch)
        self.tbl.setItemDelegateForColumn(_BYTES_COL, BytesDelegate(mono, self.tbl))
        self.tbl.currentCellChanged.connect(self._on_row)
        lay.addWidget(self.tbl)
        # field-colour legend
        leg = QHBoxLayout(); leg.setSpacing(10)
        leg.addWidget(self._k("bytes:"))
        for name, lab in [("prefix", "prefix"), ("opcode", "opcode"), ("modrm", "ModRM"),
                          ("sib", "SIB"), ("disp", "offset"), ("imm", "immediate")]:
            sw = QLabel("  "); sw.setFixedSize(11, 11)
            sw.setStyleSheet(f"background:{FIELD_COLOR[name]};border:1px solid #30363d;")
            t = QLabel(lab); t.setStyleSheet("color:#8b949e;font-size:8px;")
            leg.addWidget(sw); leg.addWidget(t)
        leg.addStretch(1)
        lay.addLayout(leg)
        self._seen = 0      # next retire n to fetch
        self._bits = 32

    def _k(self, t):
        l = QLabel(t); l.setStyleSheet("color:#8b949e;font-size:8px;")
        return l

    def set_bits(self, bits):
        self._bits = bits

    def _on_row(self, row, col, prow, pcol):
        if row < 0:
            return
        it = self.tbl.item(row, 0)
        if it is not None:
            cyc = it.data(_CYC_ROLE)
            if cyc is not None:
                self.rowSelected.emit(int(cyc))

    def reset(self):
        self.tbl.setRowCount(0)
        self._seen = 0
        self._last_cyc = None

    def update_from(self, backend):
        total = backend.retire_count()
        if total <= self._seen:
            return
        # pull only the new retirements
        want = total - self._seen
        recs = backend.get_retires(self._seen, min(want, _MAX_ROWS))
        if not recs:
            self._seen = total
            return
        sb = self.tbl.verticalScrollBar()
        at_bottom = sb.value() >= sb.maximum() - 2
        for r in recs:
            bs = bytes(r.bytes[:r.nbytes])
            bits = 32 if r.d32 else 16
            sz, mn, ops, _ = disasm.disasm_one(bs, r.pc, bits)
            txt = f"{mn} {ops}".strip()
            shown = bs[:sz] if sz else bs[:1]
            fields = disasm.byte_fields(bs, r.pc, bits)
            _, icol = disasm.insn_class(mn)
            # delta cycles since the previous retirement (surfaces stalls); a
            # paired V retires in the same cycle as its U (delta 0).
            dcyc = "" if self._last_cyc is None else str(int(r.cyc) - self._last_cyc)
            stall = (self._last_cyc is not None and int(r.cyc) - self._last_cyc > 1)
            self._last_cyc = int(r.cyc)
            row = self.tbl.rowCount()
            self.tbl.insertRow(row)
            pipe = "U" if r.pipe == 0 else ("V" if r.pipe == 1 else "-")
            vals = [str(r.n), str(r.cyc), dcyc, pipe, f"{r.pc:08x}",
                    " ".join(f"{b:02x}" for b in shown), txt]
            for c, v in enumerate(vals):
                it = QTableWidgetItem(v)
                if c in (0, 1, 4):
                    it.setForeground(QBrush(QColor("#8b949e")))
                if c == 0:
                    it.setData(_CYC_ROLE, int(r.cyc))   # for click-to-link
                if c == 2:                              # delta cyc
                    it.setTextAlignment(Qt.AlignCenter)
                    it.setForeground(QBrush(QColor("#d2a24c" if stall else "#586069")))
                if c == 3:                              # pipe (U=blue, V=amber)
                    it.setTextAlignment(Qt.AlignCenter)
                    it.setForeground(QBrush(QColor(_V_COL if r.pipe == 1 else _U_COL)))
                if c == _BYTES_COL:
                    it.setData(_BYTES_ROLE, fields)     # painted by BytesDelegate
                if c == 6:
                    it.setForeground(QBrush(QColor(icol)))
                self.tbl.setItem(row, c, it)
        self._seen = total
        # rolling cap
        excess = self.tbl.rowCount() - _MAX_ROWS
        if excess > 0:
            for _ in range(excess):
                self.tbl.removeRow(0)
        if at_bottom:
            self.tbl.scrollToBottom()
