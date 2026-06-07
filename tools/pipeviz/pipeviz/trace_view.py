# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Assembly trace panel — one row per retired instruction, with its raw bytes,
the issuing pipe (U/V), and a capstone disassembly. Appends incrementally."""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QTableWidget,
                               QTableWidgetItem, QHeaderView, QAbstractItemView,
                               QLabel, QStyledItemDelegate, QStyle, QLineEdit)
from PySide6.QtGui import QColor, QFont, QBrush, QFontMetrics
from PySide6.QtCore import Qt, QRect, Signal

from . import disasm
from .disasm import C_PIPE, C_FP, FIELD_COLOR

_COLS = ["n", "cyc", "Δ", "pipe", "PC", "bytes", "instruction", "effect (writes)"]
_BYTES_COL = 5
_INSN_COL = 6
_EFFECT_COL = 7

# architectural-effect decoding: diff a retirement's committed GPRs/EFLAGS against
# the previous retirement's, so each row shows what the instruction actually WROTE.
_GPR = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]
_FLAGBITS = [(0, "CF"), (2, "PF"), (4, "AF"), (6, "ZF"), (7, "SF"),
             (11, "OF"), (10, "DF"), (9, "IF")]


def _effect(written_gprs, flags_written, gpr, eflags, prev_eflags):
    """Compact 'what this instruction WROTE' string (e.g. 'ecx=000003f2  ZF1 SF0').
    GPR writes are decoded from capstone (`written_gprs`) and shown with their
    committed value, so a dual-issue pair's writes land on the right rows (the
    per-cycle snapshot can't separate them). Flag changes are diffed vs the
    previous retirement's EFLAGS, but only surfaced when the op writes flags."""
    parts = [f"{_GPR[k]}={gpr[k] & 0xffffffff:08x}" for k in written_gprs]
    if flags_written and prev_eflags is not None and eflags != prev_eflags:
        fl = [f"{nm}{(eflags >> bit) & 1}" for bit, nm in _FLAGBITS
              if ((eflags >> bit) & 1) != ((prev_eflags >> bit) & 1)]
        if fl:
            parts.append(" ".join(fl))
    return "   ".join(parts)
_MAX_ROWS = 6000   # rolling cap on displayed rows
_BYTES_ROLE = Qt.UserRole + 1
_CYC_ROLE = Qt.UserRole + 2
_FILT_ROLE = Qt.UserRole + 3   # (haystack, cyc, pipe, stall) for the filter box
_INSN_ROLE = Qt.UserRole + 4   # (mnemonic, operands, class-colour) for split paint
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
        painter.setClipRect(option.rect)            # never paint into the disasm column
        painter.setFont(self.font)
        fm = QFontMetrics(self.font)
        adv = fm.horizontalAdvance("00 ")
        x0 = option.rect.x() + 4
        limit = option.rect.right() - 8             # keep a hard right margin
        x = x0
        for i, (b, fld) in enumerate(fields):
            if x + adv > limit and i < len(fields):
                painter.setPen(QColor("#6e7681"))
                painter.drawText(QRect(x, option.rect.y(), adv + 4, option.rect.height()),
                                 Qt.AlignVCenter | Qt.AlignLeft, "…")
                break
            painter.setPen(QColor(FIELD_COLOR.get(fld, "#c9d1d9")))
            painter.drawText(QRect(x, option.rect.y(), adv, option.rect.height()),
                             Qt.AlignVCenter | Qt.AlignLeft, f"{b:02x}")
            x += adv
        painter.restore()


class InsnDelegate(QStyledItemDelegate):
    """Paints the disassembly with a DIMMED class-coloured mnemonic and the
    operand(s) in the full class accent — so a branch's target (or a load's
    address) is what pops, not the whole instruction painted one flat colour."""
    def __init__(self, font, parent=None):
        super().__init__(parent)
        self.font = font

    def paint(self, painter, option, index):
        if option.state & QStyle.State_Selected:
            painter.fillRect(option.rect, option.palette.highlight())
        data = index.data(_INSN_ROLE)
        if not data:
            return
        mn, ops, icol = data
        painter.save()
        painter.setClipRect(option.rect)
        painter.setFont(self.font)
        fm = QFontMetrics(self.font)
        r = option.rect
        x = r.x() + 4
        avail = r.width() - 8
        painter.setPen(QColor(icol).darker(150))
        painter.drawText(QRect(x, r.y(), avail, r.height()),
                         Qt.AlignVCenter | Qt.AlignLeft, mn)
        if ops:
            mw = fm.horizontalAdvance(mn + " ")
            if mw < avail:
                painter.setPen(QColor(icol))
                painter.drawText(QRect(x + mw, r.y(), avail - mw, r.height()),
                                 Qt.AlignVCenter | Qt.AlignLeft,
                                 fm.elidedText(ops, Qt.ElideRight, avail - mw))
        painter.restore()


class TraceView(QWidget):
    rowSelected = Signal(int)     # emits the retire cycle of the selected row
    instSelected = Signal(int)    # emits the retire n of the selected row (for pinning)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._last_cyc = None
        self._tokens = []
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        top = QHBoxLayout(); top.setSpacing(6)
        self.title = QLabel("Retired-instruction trace")
        self.title.setStyleSheet("font-weight:bold;")
        top.addWidget(self.title)
        self.filt = QLineEdit()
        self.filt.setPlaceholderText("filter:  mov   pc:08048   cyc>=133   pipe:V   stall")
        self.filt.setClearButtonEnabled(True)
        mfilt = QFont("monospace"); mfilt.setStyleHint(QFont.Monospace); mfilt.setPointSize(9)
        self.filt.setFont(mfilt)
        self.filt.textChanged.connect(self._on_filter)
        top.addWidget(self.filt, 1)
        self.match_lbl = QLabel(""); self.match_lbl.setStyleSheet("color:#8b949e;font-size:8px;")
        top.addWidget(self.match_lbl)
        lay.addLayout(top)
        self.tbl = QTableWidget(0, len(_COLS))
        self.tbl.setHorizontalHeaderLabels(_COLS)
        # left-align the headers whose data is left-aligned (n/cyc/PC/bytes/instr)
        # so a caption sits directly over its column's first glyph instead of
        # floating centred over the wide bytes/instruction gutter.
        for _c in (0, 1, 4, 5, 6, 7):
            _hi = self.tbl.horizontalHeaderItem(_c)
            if _hi is not None:
                _hi.setTextAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        self.tbl.verticalHeader().setVisible(False)
        self.tbl.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tbl.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.tbl.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tbl.setShowGrid(False)
        self.tbl.setAlternatingRowColors(True)     # zebra striping
        self.tbl.setVerticalScrollMode(QAbstractItemView.ScrollPerItem)  # whole-row snap
        mono = QFont("monospace"); mono.setStyleHint(QFont.Monospace); mono.setPointSize(9)
        self.tbl.setFont(mono)
        hh = self.tbl.horizontalHeader()
        for i, w in enumerate((52, 54, 40, 38, 74, 200, 246)):
            self.tbl.setColumnWidth(i, w)
        hh.setSectionResizeMode(_EFFECT_COL, QHeaderView.Stretch)   # effect fills the rest
        self.tbl.setItemDelegateForColumn(_BYTES_COL, BytesDelegate(mono, self.tbl))
        self.tbl.setItemDelegateForColumn(_INSN_COL, InsnDelegate(mono, self.tbl))
        self.tbl.currentCellChanged.connect(self._on_row)
        lay.addWidget(self.tbl)
        # field-colour legend — swatch tightly coupled to ITS label (no rotation)
        leg = QHBoxLayout(); leg.setSpacing(12)
        leg.addWidget(self._k("bytes:"))
        for name, lab in [("prefix", "prefix"), ("opcode", "opcode"), ("modrm", "ModRM"),
                          ("sib", "SIB"), ("disp", "offset"), ("imm", "immediate"),
                          ("rel", "branch")]:
            it = QWidget(); ih = QHBoxLayout(it); ih.setContentsMargins(0, 0, 0, 0); ih.setSpacing(3)
            sw = QLabel(); sw.setFixedSize(11, 11)
            sw.setStyleSheet(f"background:{FIELD_COLOR[name]};border:1px solid #30363d;")
            t = QLabel(lab); t.setStyleSheet("color:#8b949e;font-size:8px;")
            ih.addWidget(sw); ih.addWidget(t)
            leg.addWidget(it)
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
            try:
                self.instSelected.emit(int(it.text()))
            except ValueError:
                pass

    def select_n(self, n):
        """Select + scroll to the trace row for retire `n` (linked from a click
        in the Konata pipeline view)."""
        target = str(int(n))
        for row in range(self.tbl.rowCount()):
            it = self.tbl.item(row, 0)
            if it is not None and it.text() == target:
                self.tbl.setCurrentCell(row, 0)
                self.tbl.scrollToItem(it, QAbstractItemView.PositionAtCenter)
                return

    def reset(self):
        self.tbl.setRowCount(0)
        self._seen = 0
        self._last_cyc = None
        self._prev_eff = None

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
            # architectural effect: which GPR/flags THIS instruction wrote (capstone
            # attribution) shown with their committed values
            wgpr, wflags = disasm.written_regs(bs, r.pc, bits)
            efl = int(r.eflags)
            eff = _effect(wgpr, wflags, list(r.gpr), efl, getattr(self, "_prev_eff", None))
            self._prev_eff = efl
            # delta cycles since the previous retirement (surfaces stalls); a
            # paired V retires in the same cycle as its U (delta 0).
            stall = (self._last_cyc is not None and int(r.cyc) - self._last_cyc > 1)
            # only surface Δ on a stall gap (+N) — the steady-state 0/1 is noise
            dcyc = f"+{int(r.cyc) - self._last_cyc}" if stall else ""
            self._last_cyc = int(r.cyc)
            row = self.tbl.rowCount()
            self.tbl.insertRow(row)
            pipe = "U" if r.pipe == 0 else ("V" if r.pipe == 1 else "-")
            vals = [str(r.n), str(r.cyc), dcyc, pipe, f"{r.pc:08x}",
                    " ".join(f"{b:02x}" for b in shown), txt, eff]
            hay = f"{r.pc:08x} {vals[5]} {txt} {eff}".lower()
            for c, v in enumerate(vals):
                it = QTableWidgetItem(v)
                if c in (0, 1, 4):
                    it.setForeground(QBrush(QColor("#8b949e")))
                if c == 0:
                    it.setData(_CYC_ROLE, int(r.cyc))   # for click-to-link
                    it.setData(_FILT_ROLE, (hay, int(r.cyc), pipe, stall))
                if c == 2:                              # delta cyc
                    it.setTextAlignment(Qt.AlignCenter)
                    it.setForeground(QBrush(QColor("#d2a24c" if stall else "#586069")))
                if c == 3:                              # pipe (U=blue, V=amber)
                    it.setTextAlignment(Qt.AlignCenter)
                    it.setForeground(QBrush(QColor(_V_COL if r.pipe == 1 else _U_COL)))
                if c == _BYTES_COL:
                    it.setData(_BYTES_ROLE, fields)     # painted by BytesDelegate
                    it.setToolTip(v)                    # full bytes — never lost to the … clip
                if c == _INSN_COL:                      # painted by InsnDelegate
                    parts = txt.split(" ", 1)
                    it.setData(_INSN_ROLE,
                               (parts[0], parts[1] if len(parts) > 1 else "", icol))
                    it.setToolTip(txt)                  # full disasm (col is now fixed-width)
                if c == _EFFECT_COL:                    # register/flag writes
                    it.setForeground(QBrush(QColor("#79c0ff")))
                    if v:
                        it.setToolTip(v)
                self.tbl.setItem(row, c, it)
        self._seen = total
        # rolling cap
        excess = self.tbl.rowCount() - _MAX_ROWS
        if excess > 0:
            for _ in range(excess):
                self.tbl.removeRow(0)
        if self._tokens:
            self._apply_filter()
        if at_bottom and not self._tokens:
            self.tbl.scrollToBottom()

    # ---- filter box ----
    def _on_filter(self, text):
        self._tokens = [t for t in text.strip().lower().split() if t]
        self._apply_filter()

    @staticmethod
    def _match(filt, tokens):
        hay, cyc, pipe, stall = filt
        for tok in tokens:
            try:
                if tok.startswith("pipe:"):
                    if pipe.lower() != tok[5:]:
                        return False
                elif tok.startswith("cyc>="):
                    if cyc < int(tok[5:], 0):
                        return False
                elif tok.startswith("cyc<="):
                    if cyc > int(tok[5:], 0):
                        return False
                elif tok.startswith("cyc="):
                    if cyc != int(tok[4:], 0):
                        return False
                elif tok.startswith("pc:"):
                    if tok[3:] not in hay:
                        return False
                elif tok == "stall":
                    if not stall:
                        return False
                elif tok not in hay:
                    return False
            except ValueError:
                if tok not in hay:
                    return False
        return True

    def _apply_filter(self):
        toks = self._tokens
        n = self.tbl.rowCount()
        shown = 0
        for row in range(n):
            it = self.tbl.item(row, 0)
            filt = it.data(_FILT_ROLE) if it is not None else None
            ok = (not toks) or (filt is not None and self._match(filt, toks))
            self.tbl.setRowHidden(row, not ok)
            shown += ok
        self.match_lbl.setText("" if not toks else f"{shown}/{n} match")
