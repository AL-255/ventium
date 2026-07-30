# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Assembly trace panel — one row per retired instruction, with its raw bytes,
the issuing pipe (U/V), and a capstone disassembly. Appends incrementally."""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QTableWidget,
                               QTableWidgetItem, QHeaderView, QAbstractItemView,
                               QLabel, QStyledItemDelegate, QStyle, QLineEdit,
                               QToolButton)
from PySide6.QtGui import QColor, QFont, QBrush, QFontMetrics
from PySide6.QtCore import Qt, QRect, Signal

from . import disasm
from .disasm import C_PIPE, C_FP, FIELD_COLOR
from .regs_view import floatx80_to_float

_COLS = ["n", "cyc", "Δ", "pipe", "PC", "bytes", "instruction", "effect (writes)"]
_BYTES_COL = 5
_INSN_COL = 6
_EFFECT_COL = 7

# architectural-effect decoding: diff a retirement's committed GPRs/EFLAGS against
# the previous retirement's, so each row shows what the instruction actually WROTE.
_GPR = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]
_FLAGBITS = [(0, "CF"), (2, "PF"), (4, "AF"), (6, "ZF"), (7, "SF"),
             (11, "OF"), (10, "DF"), (9, "IF")]
_FSW_EXC = [(0, "IE"), (1, "DE"), (2, "ZE"), (3, "OE"), (4, "UE"), (5, "PE")]


def _effect(written_gprs, flags_written, gpr, eflags, prev_eflags,
            x87_valid=False, fstat=0, prev_fstat=None, fp_write=None, mem_ea=None):
    """Compact 'what this instruction WROTE' string (e.g. 'ecx=000003f2  ZF1 SF0').
    GPR writes are decoded from capstone (`written_gprs`) and shown with their
    committed value, so a dual-issue pair's writes land on the right rows (the
    per-cycle snapshot can't separate them). Flag changes are diffed vs the
    previous retirement's EFLAGS, but only surfaced when the op writes flags.
    `fp_write` (e.g. 'st0=86') is the pre-formatted x87 top-of-stack result so an
    FP op no longer reads as a no-op in the column literally headed 'writes'.
    `mem_ea` (e.g. '@08049180') is the resolved effective address a load/store
    touched, so a cache-missing load's access stride is visible in the trace."""
    parts = [f"{_GPR[k]}={gpr[k] & 0xffffffff:08x}" for k in written_gprs]
    if flags_written and prev_eflags is not None and eflags != prev_eflags:
        fl = [f"{nm}{(eflags >> bit) & 1}" for bit, nm in _FLAGBITS
              if ((eflags >> bit) & 1) != ((prev_eflags >> bit) & 1)]
        if fl:
            parts.append(" ".join(fl))
    if fp_write:                               # x87 ST(0) result write (e.g. 'st0=86')
        parts.append(fp_write)
    # x87 exception flags NEWLY raised this retirement (FSW IE/DE/ZE/OE/UE/PE) —
    # diffed (the FSW bits are sticky) so only the op that raised one shows it.
    if x87_valid and prev_fstat is not None and fstat != prev_fstat:
        exc = [nm for bit, nm in _FSW_EXC
               if ((fstat >> bit) & 1) and not ((prev_fstat >> bit) & 1)]
        if exc:
            parts.append("FP:" + " ".join(exc))
    if mem_ea:                                 # resolved load/store address (e.g. '@08049180')
        parts.append(mem_ea)
    return "   ".join(parts)
_MAX_ROWS = 6000   # rolling cap on displayed rows
_BYTES_ROLE = Qt.UserRole + 1
_CYC_ROLE = Qt.UserRole + 2
_FILT_ROLE = Qt.UserRole + 3   # (haystack, n, pc, cyc, pipe, stall) for filtering
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


_MNEM_GREY = "#828c99"   # all mnemonics share one neutral grey — dim enough that
                         # even a neutral (off-white) operand reads as the brighter,
                         # accented token, not just-barely-distinguishable from it


class InsnDelegate(QStyledItemDelegate):
    """Paints the disassembly with a neutral-grey mnemonic (the SAME grey for every
    instruction) and the operand(s) in the class accent — so the operand/target is
    the only coloured token. A branch's mnemonic is grey like every other op; only
    its rel target carries the orange, instead of the whole 'jne …' going orange."""
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
        painter.setPen(QColor(_MNEM_GREY))
        painter.drawText(QRect(x, r.y(), avail, r.height()),
                         Qt.AlignVCenter | Qt.AlignLeft, mn)
        if ops:
            mw = fm.horizontalAdvance(mn + " ")
            ox, limit = x + mw, r.right() - 4
            is_br = (icol == disasm.CC_BRANCH)
            ell = fm.horizontalAdvance("…")
            for txt, col in disasm.operand_segments(ops, is_br, icol):
                # if the next segment won't fully fit, stop with an ellipsis instead of
                # hard-clipping a glyph mid-immediate — the bytes column already does
                # this; without it a long imm (ppage's `mov [ebx+0x14], 0xcf90000`)
                # truncated to `0xcf9` with NO `…`, silently dropping the value.
                if ox + fm.horizontalAdvance(txt) > limit:
                    painter.setPen(QColor("#6e7681"))
                    painter.drawText(QRect(min(ox, limit - ell), r.y(), ell + 6, r.height()),
                                     Qt.AlignVCenter | Qt.AlignLeft, "…")
                    break
                painter.setPen(QColor(col))
                painter.drawText(QRect(ox, r.y(), limit - ox, r.height()),
                                 Qt.AlignVCenter | Qt.AlignLeft, txt)
                ox += fm.horizontalAdvance(txt)
        painter.restore()


class EffectDelegate(QStyledItemDelegate):
    """Colour-codes the effect column's write kinds so they don't read as one flat
    blob: GPR writes (`eax=…`) blue, integer flag changes (`ZF1 SF0`) teal, x87 ST(0)
    result writes (`st0=…`) purple, x87 exception groups (`FP:ZE`) amber, and the
    resolved memory-access address (`@08049180`) gold. Groups are the 3-space-
    separated parts that `_effect()` emits."""
    def __init__(self, font, parent=None):
        super().__init__(parent)
        self.font = font

    def paint(self, painter, option, index):
        if option.state & QStyle.State_Selected:
            painter.fillRect(option.rect, option.palette.highlight())
        txt = index.data(Qt.DisplayRole)
        if not txt:
            return
        painter.save()
        painter.setClipRect(option.rect)
        painter.setFont(self.font)
        fm = QFontMetrics(self.font)
        r = option.rect
        x = r.x() + 4
        for part in txt.split("   "):
            if not part:
                continue
            if part.startswith("FP:"):
                col = "#d29922"          # x87 exception (amber)
            elif part.startswith("@"):
                col = "#e3b341"          # resolved memory-access address (gold, like a disp)
            elif part.startswith("st") and "=" in part:
                col = "#c89bff"          # x87 ST(0) result write (purple, the FP accent)
            elif "=" in part:
                col = "#79c0ff"          # register write (blue)
            else:
                col = "#39c5cf"          # integer flag changes (teal)
            painter.setPen(QColor(col))
            painter.drawText(QRect(x, r.y(), r.right() - x, r.height()),
                             Qt.AlignVCenter | Qt.AlignLeft, part)
            x += fm.horizontalAdvance(part + "   ")
        painter.restore()


class _TraceFilter(QLineEdit):
    """Search field with local result-navigation keys.

    Handling these in the focused editor is more reliable than a window shortcut
    after a modal dialog and avoids F3 being consumed by platform text controls.
    """
    navigate = Signal(int)

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_F3:
            self.navigate.emit(-1 if event.modifiers() & Qt.ShiftModifier else 1)
            event.accept()
            return
        if event.key() == Qt.Key_Escape:
            self.clear()
            event.accept()
            return
        super().keyPressEvent(event)


class _TraceTable(QTableWidget):
    focusFilter = Signal()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Slash and event.modifiers() == Qt.NoModifier:
            self.focusFilter.emit()
            event.accept()
            return
        super().keyPressEvent(event)


class TraceView(QWidget):
    rowSelected = Signal(int)     # emits the retire cycle of the selected row
    instSelected = Signal(int)    # emits the retire n of the selected row (for pinning)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._last_cyc = None
        self.last_access = None
        self.accesses = []        # [(retire_n, address, is_store)] for the access map
        self._tokens = []
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        top = QHBoxLayout(); top.setSpacing(6)
        self.title = QLabel("Retired-instruction trace")
        self.title.setStyleSheet("font-weight:bold;")
        top.addWidget(self.title)
        self.filt = _TraceFilter()
        self.filt.setPlaceholderText("filter:  mov   pc:08048   cyc>=133   pipe:V   stall   @  (mem)")
        self.filt.setClearButtonEnabled(True)
        self.filt.setToolTip(
            "Space-separated terms are ANDed.\n"
            "Examples: mov, pc:08048, n>=100, cyc<=200, pipe:U, stall, @.\n"
            "/ focuses search; Enter or F3 selects the next match; "
            "Shift+F3 selects the previous match; Esc clears.")
        mfilt = QFont("monospace"); mfilt.setStyleHint(QFont.Monospace); mfilt.setPointSize(9)
        self.filt.setFont(mfilt)
        self.filt.textChanged.connect(self._on_filter)
        self.filt.returnPressed.connect(lambda: self._select_match(1))
        self.filt.navigate.connect(self._select_match)
        top.addWidget(self.filt, 1)
        self.match_lbl = QLabel(""); self.match_lbl.setStyleSheet("color:#8b949e;font-size:8px;")
        top.addWidget(self.match_lbl)
        self.prev_match_btn = QToolButton()
        self.prev_match_btn.setText("↑")
        self.prev_match_btn.setToolTip("Previous matching retirement (Shift+F3)")
        self.prev_match_btn.clicked.connect(lambda: self._select_match(-1))
        self.next_match_btn = QToolButton()
        self.next_match_btn.setText("↓")
        self.next_match_btn.setToolTip("Next matching retirement (Enter or F3)")
        self.next_match_btn.clicked.connect(lambda: self._select_match(1))
        for button in (self.prev_match_btn, self.next_match_btn):
            button.setAutoRaise(True)
            button.setFixedSize(22, 20)
            button.hide()
            top.addWidget(button)
        lay.addLayout(top)
        self.tbl = _TraceTable(0, len(_COLS))
        self.tbl.focusFilter.connect(self.focus_filter)
        self.tbl.setHorizontalHeaderLabels(_COLS)
        # left-align the headers whose data is left-aligned (n/cyc/PC/bytes/instr)
        # so a caption sits directly over its column's first glyph instead of
        # floating centred over the wide bytes/instruction gutter.
        for _c in (0, 1, 4, 5, 6, 7):
            _hi = self.tbl.horizontalHeaderItem(_c)
            if _hi is not None:
                _hi.setTextAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        self.tbl.verticalHeader().setVisible(False)
        # A trace is read by scanning many adjacent retirements.  Qt's default
        # ~30px row wastes vertical space for this single-line data, so use a
        # fixed compact row while retaining enough height for the 9pt font.
        self.tbl.verticalHeader().setSectionResizeMode(QHeaderView.Fixed)
        self.tbl.verticalHeader().setMinimumSectionSize(19)
        self.tbl.verticalHeader().setDefaultSectionSize(22)
        self.tbl.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tbl.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.tbl.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tbl.setShowGrid(False)
        self.tbl.setAlternatingRowColors(True)     # zebra striping
        self.tbl.setVerticalScrollMode(QAbstractItemView.ScrollPerItem)  # whole-row snap
        mono = QFont("monospace"); mono.setStyleHint(QFont.Monospace); mono.setPointSize(9)
        self.tbl.setFont(mono)
        hh = self.tbl.horizontalHeader()
        for i, w in enumerate((52, 54, 40, 38, 74, 176)):          # n cyc Δ pipe PC bytes
            self.tbl.setColumnWidth(i, w)
        self.tbl.setColumnWidth(_EFFECT_COL, 192)                  # effect: fits 'reg=val + @addr'
        # the INSTRUCTION column stretches (full operands, no truncation while the
        # short effect column sat on a wide stretch) — effect is short and fixed.
        hh.setSectionResizeMode(_INSN_COL, QHeaderView.Stretch)
        self.tbl.setItemDelegateForColumn(_BYTES_COL, BytesDelegate(mono, self.tbl))
        self.tbl.setItemDelegateForColumn(_INSN_COL, InsnDelegate(mono, self.tbl))
        self.tbl.setItemDelegateForColumn(_EFFECT_COL, EffectDelegate(mono, self.tbl))
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

    def focus_filter(self):
        self.filt.setFocus()
        self.filt.selectAll()

    def _select_match(self, direction):
        """Select the next visible filtered row, wrapping at either edge."""
        rows = [row for row in range(self.tbl.rowCount())
                if not self.tbl.isRowHidden(row)]
        if not rows:
            return
        current = self.tbl.currentRow()
        if current not in rows:
            target = rows[0] if direction > 0 else rows[-1]
        else:
            target = rows[(rows.index(current) + direction) % len(rows)]
        item = self.tbl.item(target, 0)
        self.tbl.setCurrentCell(target, 0)
        if item is not None:
            self.tbl.scrollToItem(item, QAbstractItemView.PositionAtCenter)

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

    def select_pc(self, pc):
        """Select a context-preserving trace row at PC ``pc``.

        Hotspot/branch PCs often repeat thousands of times. Prefer the matching
        row nearest the current investigation, or the newest match when nothing
        is selected. If the active query hides every match, clear that query so
        drill-down never lands on an invisible row.
        """
        target = f"{int(pc):08x}"
        matches = [
            row for row in range(self.tbl.rowCount())
            if (self.tbl.item(row, 4) is not None
                and self.tbl.item(row, 4).text() == target)
        ]
        if not matches:
            return
        visible = [row for row in matches if not self.tbl.isRowHidden(row)]
        if not visible and self._tokens:
            self.filt.clear()
            visible = matches
        candidates = visible or matches
        current = self.tbl.currentRow()
        row = (min(candidates, key=lambda candidate: abs(candidate - current))
               if current >= 0 else candidates[-1])
        item = self.tbl.item(row, 0)
        self.tbl.setCurrentCell(row, 0)
        if item is not None:
            self.tbl.scrollToItem(item, QAbstractItemView.PositionAtCenter)

    def reset(self):
        self.tbl.setRowCount(0)
        self._seen = 0
        self._last_cyc = None
        self._prev_eff = None
        self._prev_fstat = None
        self._prev_st0 = None
        self._prev_gpr = None     # prior retirement's committed GPRs (pre-state for EA)
        self.last_access = None   # newest resolved load/store address (Memory '→access')
        self.accesses = []        # access stream for the access map
        self._apply_filter()

    def start_session(self):
        """Clear search state which would otherwise silently hide a new program."""
        self.filt.clear()

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
            xv = bool(r.x87_valid); fsw = int(r.fstat)
            # x87 ST(0) result: FP ops aren't in the GPR/flag/exception channels, so a
            # non-faulting fadd/fld/fmul reads as a no-op. Diff the (logical) ST(0) vs
            # the previous retirement; for an FP op that CHANGED it, surface 'st0=<v>'.
            fp_write = None
            if xv:
                st0 = bytes(r.st[0][k] for k in range(10))
                if mn.startswith("f") and st0 != getattr(self, "_prev_st0", None):
                    fp_write = f"st0={floatx80_to_float(st0):.6g}"
                self._prev_st0 = st0
            # resolved memory-access address: a load/store's effective address =
            # base + index*scale + disp evaluated on the PRE-instruction register file
            # (the prior retirement's committed GPRs — exact for a U-pipe op, which is
            # always the senior of its dual-issue pair, so its inputs are the prior
            # commit). Surfaced as '@<ea>' so a cache-missing load's stride is visible.
            mem_ea = None
            mo = disasm.mem_operand(bs, r.pc, bits)
            if mo is not None:
                base, index, scale, disp, _store, size = mo
                needs_reg = base >= 0 or index >= 0
                pre = getattr(self, "_prev_gpr", None)
                if not needs_reg or (r.pipe == 0 and pre is not None):
                    g = pre if pre is not None else [0] * 8
                    ea = ((g[base] if base >= 0 else 0)
                          + (g[index] if index >= 0 else 0) * scale + disp)
                    mask = 0xffffffff if bits == 32 else 0xffff
                    ea &= mask
                    mem_ea = (f"@{ea:08x}" if bits == 32 else f"@{ea:04x}")
                    self.last_access = (ea, size)   # newest access -> Memory '→access'
                    # accumulate the (retire-n, cyc, address, is_store, size, pc) access
                    # stream for the access-pattern map + the per-PC D$-miss attribution.
                    # pc is carried HERE so the attribution doesn't depend on the Konata
                    # insns rolling window (which can drop a PC the access stream still
                    # holds for a long, sparse-memory run). Capped, rolling.
                    self.accesses.append((int(r.n), int(r.cyc), ea, _store, size, int(r.pc)))
                    if len(self.accesses) > 4000:
                        del self.accesses[:len(self.accesses) - 4000]
            eff = _effect(wgpr, wflags, list(r.gpr), efl, getattr(self, "_prev_eff", None),
                          xv, fsw, getattr(self, "_prev_fstat", None), fp_write, mem_ea)
            self._prev_eff = efl
            self._prev_gpr = list(r.gpr)
            if xv:
                self._prev_fstat = fsw
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
                    it.setData(_FILT_ROLE, (
                        hay, int(r.n), int(r.pc), int(r.cyc), pipe, stall))
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
                if c == _EFFECT_COL:                    # painted by EffectDelegate
                    if v:                               # (reg=blue / flags=teal / FP=amber)
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
        hay, retire_n, pc, cyc, pipe, stall = filt
        for tok in tokens:
            try:
                if tok.startswith("pipe:"):
                    query = tok[5:]
                    if not query or pipe.lower() != query:
                        return False
                elif tok.startswith("n>="):
                    if retire_n < int(tok[3:], 0):
                        return False
                elif tok.startswith("n<="):
                    if retire_n > int(tok[3:], 0):
                        return False
                elif tok.startswith("n="):
                    if retire_n != int(tok[2:], 0):
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
                    query = tok[3:].removeprefix("0x")
                    if not query or query not in f"{pc:08x}":
                        return False
                elif tok == "stall":
                    if not stall:
                        return False
                elif tok not in hay:
                    return False
            except ValueError:
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
        active = bool(toks)
        self.match_lbl.setText("" if not active else f"{shown}/{n} match")
        self.match_lbl.setStyleSheet(
            "color:#f85149;font-size:8px;" if active and shown == 0
            else "color:#8b949e;font-size:8px;")
        self.filt.setStyleSheet(
            "border:1px solid #f85149;" if active and shown == 0 else "")
        for button in (self.prev_match_btn, self.next_match_btn):
            button.setVisible(active)
            button.setEnabled(shown > 0)
