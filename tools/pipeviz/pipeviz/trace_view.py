# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Assembly trace panel — one row per retired instruction, with its raw bytes,
the issuing pipe (U/V), and a capstone disassembly. Appends incrementally."""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QTableWidget, QTableWidgetItem,
                               QHeaderView, QAbstractItemView, QLabel)
from PySide6.QtGui import QColor, QFont, QBrush
from PySide6.QtCore import Qt

from . import disasm
from .disasm import C_PIPE, C_FP

_COLS = ["n", "cyc", "pipe", "PC", "bytes", "instruction"]
_MAX_ROWS = 6000   # rolling cap on displayed rows


class TraceView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
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
        self.tbl.setShowGrid(False)
        mono = QFont("monospace"); mono.setStyleHint(QFont.Monospace); mono.setPointSize(9)
        self.tbl.setFont(mono)
        hh = self.tbl.horizontalHeader()
        for i, w in enumerate((70, 70, 44, 96, 150, 9999)):
            if i < len(_COLS) - 1:
                self.tbl.setColumnWidth(i, w)
        hh.setSectionResizeMode(len(_COLS) - 1, QHeaderView.Stretch)
        lay.addWidget(self.tbl)
        self._seen = 0      # next retire n to fetch
        self._bits = 32

    def set_bits(self, bits):
        self._bits = bits

    def reset(self):
        self.tbl.setRowCount(0)
        self._seen = 0

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
            txt, sz = disasm.text(bs, r.pc, self._bits)
            shown = bs[:sz] if sz else bs[:1]
            row = self.tbl.rowCount()
            self.tbl.insertRow(row)
            pipe = "U" if r.pipe == 0 else ("V" if r.pipe == 1 else "-")
            vals = [str(r.n), str(r.cyc), pipe, f"{r.pc:08x}",
                    " ".join(f"{b:02x}" for b in shown), txt]
            for c, v in enumerate(vals):
                it = QTableWidgetItem(v)
                if c in (0, 1, 3, 4):
                    it.setForeground(QBrush(QColor("#8b949e")))
                if c == 2:
                    it.setTextAlignment(Qt.AlignCenter)
                    if r.pipe == 1:
                        it.setForeground(QBrush(QColor(C_PIPE)))
                    elif r.x87_valid and ("f" == (txt[:1] or "")):
                        it.setForeground(QBrush(QColor(C_FP)))
                self.tbl.setItem(row, c, it)
        self._seen = total
        # rolling cap
        excess = self.tbl.rowCount() - _MAX_ROWS
        if excess > 0:
            for _ in range(excess):
                self.tbl.removeRow(0)
        if at_bottom:
            self.tbl.scrollToBottom()
