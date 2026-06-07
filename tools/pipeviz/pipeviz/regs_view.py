# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Architectural register panel — GPRs, EFLAGS (decoded), segments, control
registers, and the x87 stack (logical ST(0..7) with decoded floatx80 values)."""
from PySide6.QtWidgets import (QWidget, QHBoxLayout, QVBoxLayout, QGridLayout,
                               QLabel, QGroupBox)
from PySide6.QtGui import QFont
from PySide6.QtCore import Qt

from .backend import GPR_NAMES, SEG_NAMES

_FLAGS = [(0, "CF"), (2, "PF"), (4, "AF"), (6, "ZF"), (7, "SF"),
          (8, "TF"), (9, "IF"), (10, "DF"), (11, "OF")]


def _mono(pt=10, bold=False):
    f = QFont("monospace"); f.setStyleHint(QFont.Monospace); f.setPointSize(pt)
    f.setBold(bold)
    return f


def _fmt80(hexs: str) -> str:
    """Split a 20-hex-char big-endian floatx80 into its sign/exponent word and
    64-bit mantissa (`c001 8000000000000000`) so the fields are readable."""
    return hexs[:4] + " " + hexs[4:]


def floatx80_to_float(b10: bytes):
    """Decode a 10-byte little-endian floatx80 to a Python float for display."""
    if len(b10) < 10:
        return 0.0
    mant = int.from_bytes(b10[0:8], "little")
    se = int.from_bytes(b10[8:10], "little")
    sign = -1.0 if (se >> 15) & 1 else 1.0
    exp = se & 0x7fff
    try:
        if exp == 0x7fff:
            if mant == (1 << 63):
                return sign * float("inf")
            return float("nan")
        if exp == 0:
            if mant == 0:
                return sign * 0.0
            return sign * (mant / 2.0 ** 63) * 2.0 ** (-16382)
        return sign * (mant / 2.0 ** 63) * 2.0 ** (exp - 16383)
    except OverflowError:
        return sign * float("inf")


class RegsView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        root = QHBoxLayout(self); root.setContentsMargins(4, 4, 4, 4); root.setSpacing(8)

        # --- integer column ---
        col1 = QVBoxLayout(); root.addLayout(col1, 1)
        gp = QGroupBox("Integer / flags")
        g = QGridLayout(gp); g.setSpacing(2)
        self.gpr_lbls = {}
        for i, name in enumerate(GPR_NAMES):
            g.addWidget(self._k(name), i, 0)
            v = QLabel("00000000"); v.setFont(_mono())
            self.gpr_lbls[name] = v
            g.addWidget(v, i, 1)
        g.addWidget(self._k("EIP"), len(GPR_NAMES), 0)
        self.eip_lbl = QLabel("00000000"); self.eip_lbl.setFont(_mono())
        g.addWidget(self.eip_lbl, len(GPR_NAMES), 1)
        g.addWidget(self._k("EFL"), len(GPR_NAMES) + 1, 0)
        self.efl_lbl = QLabel("00000000"); self.efl_lbl.setFont(_mono())
        g.addWidget(self.efl_lbl, len(GPR_NAMES) + 1, 1)
        self.flags_lbl = QLabel(""); self.flags_lbl.setFont(_mono(9))
        # span the flag row across 3 columns and let the 3rd absorb the panel's
        # slack, so the name (col 0) + hex value (col 1) pack tightly on the left
        # instead of the value drifting to the far right of a stretched column.
        g.addWidget(self.flags_lbl, len(GPR_NAMES) + 2, 0, 1, 3)
        g.setColumnStretch(2, 1)
        col1.addWidget(gp)

        # --- segment + control column ---
        col2 = QVBoxLayout(); root.addLayout(col2, 1)
        sg = QGroupBox("Segments")
        g2 = QGridLayout(sg); g2.setSpacing(2)
        g2.addWidget(self._k("sel"), 0, 1); g2.addWidget(self._k("base"), 0, 2)
        g2.addWidget(self._k("limit"), 0, 3)
        self.seg_lbls = {}
        for i, name in enumerate(SEG_NAMES):
            g2.addWidget(self._k(name), i + 1, 0)
            sel = QLabel("0000"); sel.setFont(_mono(9))
            base = QLabel("00000000"); base.setFont(_mono(9))
            lim = QLabel("00000000"); lim.setFont(_mono(9))
            self.seg_lbls[name] = (sel, base, lim)
            g2.addWidget(sel, i + 1, 1); g2.addWidget(base, i + 1, 2); g2.addWidget(lim, i + 1, 3)
        g2.addWidget(QWidget(), 0, 4); g2.setColumnStretch(4, 1)   # absorb slack on the right
        col2.addWidget(sg)
        cr = QGroupBox("Control / mode")
        g3 = QGridLayout(cr); g3.setSpacing(2)
        self.cr_lbls = {}
        for i, name in enumerate(["CR0", "CR2", "CR3", "CR4"]):
            g3.addWidget(self._k(name), i, 0)
            v = QLabel("00000000"); v.setFont(_mono(9)); self.cr_lbls[name] = v
            g3.addWidget(v, i, 1)
        self.mode_lbl = QLabel(""); self.mode_lbl.setFont(_mono(9))
        g3.addWidget(self.mode_lbl, 4, 0, 1, 3)         # span the absorber column too
        g3.setColumnStretch(2, 1)                       # pack CR name+value on the left
        col2.addWidget(cr)

        # --- x87 column ---
        col3 = QVBoxLayout(); root.addLayout(col3, 1)
        fp = QGroupBox("x87 FPU")
        g4 = QGridLayout(fp); g4.setSpacing(2)
        self.fphdr = QLabel(""); self.fphdr.setFont(_mono(9))
        self.fphdr.setWordWrap(True)   # guard the header against width overrun
        g4.addWidget(self.fphdr, 0, 0, 1, 4)
        # col 2 is a fixed-width spacer so the decoded value never fuses with the
        # 20-hex-digit 80-bit mantissa; the value column (3) is right-aligned.
        g4.setColumnMinimumWidth(2, 12); g4.setColumnStretch(2, 1)
        g4.addWidget(self._k("reg"), 1, 0); g4.addWidget(self._k("80-bit"), 1, 1)
        g4.addWidget(self._k("value"), 1, 3, alignment=Qt.AlignRight)
        self.st_lbls = []
        for i in range(8):
            tag = QLabel(f"ST{i}"); tag.setFont(_mono(9))
            hexv = QLabel("0" * 20); hexv.setFont(_mono(9))
            val = QLabel("0.0"); val.setFont(_mono(9))
            self.st_lbls.append((tag, hexv, val))
            g4.addWidget(tag, i + 2, 0); g4.addWidget(hexv, i + 2, 1)
            g4.addWidget(val, i + 2, 3, alignment=Qt.AlignRight)
        col3.addWidget(fp)

        # trailing stretch on every column so the group boxes size to their CONTENT
        # (compact rows) and the spare panel height collects below them, instead of
        # stretching each register row to ~2x its text height (the "wasted gaps").
        for _c in (col1, col2, col3):
            _c.addStretch(1)

    def _k(self, t):
        l = QLabel(t); l.setStyleSheet("color:#8b949e;"); l.setFont(_mono(9, True))
        return l

    def update_from(self, s):
        prev = getattr(self, "_prev", None)
        chg = "color:#e3b341;font-weight:bold;"   # changed since last step (amber)
        same = "color:#c9d1d9;"
        for i, name in enumerate(GPR_NAMES):
            changed = prev is not None and prev["gpr"][i] != s.gpr[i]
            self.gpr_lbls[name].setText(f"{s.gpr[i]:08x}")
            self.gpr_lbls[name].setStyleSheet(chg if changed else same)
        eip_chg = prev is not None and prev["eip"] != s.eip
        self.eip_lbl.setText(f"{s.eip:08x}")
        self.eip_lbl.setStyleSheet(chg if eip_chg else same)
        efl_chg = prev is not None and prev["eflags"] != s.eflags
        self.efl_lbl.setText(f"{s.eflags:08x}")
        self.efl_lbl.setStyleSheet(chg if efl_chg else same)
        # full named-bit grid: every flag shown (set = amber, clear = dim); a bit
        # that changed since the previous step is underlined.
        prev_efl = prev["eflags"] if prev is not None else None
        parts = []
        for bit, nm in _FLAGS:
            f_on = (s.eflags >> bit) & 1
            f_chg = prev_efl is not None and ((prev_efl >> bit) & 1) != f_on
            col = "#e3b341" if f_on else "#4b535d"
            style = f"color:{col}" + (";text-decoration:underline" if f_chg else "")
            parts.append(f"<span style='{style}'>{nm}{f_on}</span>")
        self.flags_lbl.setText("&nbsp;".join(parts))
        self._prev = {"gpr": list(s.gpr), "eip": s.eip, "eflags": s.eflags}
        for i, name in enumerate(SEG_NAMES):
            sel, base, lim = self.seg_lbls[name]
            sel.setText(f"{s.seg_sel[i]:04x}")
            base.setText(f"{s.seg_base[i]:08x}"); base.setStyleSheet("")   # clear pinned n/a
            lim.setText(f"{s.seg_limit[i]:08x}"); lim.setStyleSheet("")
        for k, val in (("CR0", s.cr0), ("CR2", s.cr2), ("CR3", s.cr3), ("CR4", s.cr4)):
            self.cr_lbls[k].setText(f"{val:08x}"); self.cr_lbls[k].setStyleSheet("")
        self.mode_lbl.setText(
            f"{'SYS' if s.sys_mode else 'USER'}  CPL={s.cpl}"
            f"{'  SMM' if s.smm_active else ''}")
        # x87 — logical ST(i) = physical fpr[(ftop+i)&7]
        self.fphdr.setText(f"TOP={s.ftop}  ctrl={s.fctrl:04x}  stat={s.fstat:04x}  tag={s.fptag:02x}")
        for i in range(8):
            phys = (s.ftop + i) & 7
            b10 = bytes(s.fpr[phys][k] for k in range(10))
            hexs = b10[::-1].hex()
            empty = bool((s.fptag >> phys) & 1)   # fptag bit i: 1 = empty
            tag, hexv, val = self.st_lbls[i]
            tag.setText(f"ST{i}" + ("·" if empty else ""))
            hexv.setText(_fmt80(hexs))
            hexv.setStyleSheet("color:#4b535d;" if empty else "color:#c9d1d9;")
            fv = floatx80_to_float(b10)
            val.setText("—" if empty else f"{fv:.6g}")

    def show_retire(self, rec, prev):
        """Pin the panel to a retired instruction's post-commit architectural
        state (from the retire record), highlighting what changed vs the previous
        retirement. Segment bases/limits + CRs aren't in the record (shown dim)."""
        chg = "color:#e3b341;font-weight:bold;"
        same = "color:#c9d1d9;"
        for i, name in enumerate(GPR_NAMES):
            changed = prev is not None and prev.gpr[i] != rec.gpr[i]
            self.gpr_lbls[name].setText(f"{rec.gpr[i]:08x}")
            self.gpr_lbls[name].setStyleSheet(chg if changed else same)
        self.eip_lbl.setText(f"{rec.pc:08x}"); self.eip_lbl.setStyleSheet(same)
        efl_chg = prev is not None and prev.eflags != rec.eflags
        self.efl_lbl.setText(f"{rec.eflags:08x}")
        self.efl_lbl.setStyleSheet(chg if efl_chg else same)
        prev_efl = prev.eflags if prev is not None else None
        parts = []
        for bit, nm in _FLAGS:
            f_on = (rec.eflags >> bit) & 1
            f_chg = prev_efl is not None and ((prev_efl >> bit) & 1) != f_on
            col = "#e3b341" if f_on else "#4b535d"
            style = f"color:{col}" + (";text-decoration:underline" if f_chg else "")
            parts.append(f"<span style='{style}'>{nm}{f_on}</span>")
        self.flags_lbl.setText("&nbsp;".join(parts))
        # base/limit + CRs aren't in the retire record: dim italic "n/a" reads as
        # "not captured" rather than a bright dot-run that looks like real data.
        na = "color:#4b535d;font-style:italic;"
        for i, name in enumerate(SEG_NAMES):
            sel, base, lim = self.seg_lbls[name]
            sel.setText(f"{rec.seg[i]:04x}")
            base.setText("n/a"); base.setStyleSheet(na)
            lim.setText("n/a"); lim.setStyleSheet(na)
        for k in ("CR0", "CR2", "CR3", "CR4"):
            self.cr_lbls[k].setText("n/a"); self.cr_lbls[k].setStyleSheet(na)
        self.mode_lbl.setText(f"PINNED n={rec.n} cyc={rec.cyc}")
        self.mode_lbl.setStyleSheet("color:#e3b341;")
        if rec.x87_valid:
            # tight single-space header (the "PINNED" banner already flags the
            # mode) so the 4-digit tag value never clips off the panel's right edge.
            self.fphdr.setText(f"pin ctrl={rec.fctrl:04x} stat={rec.fstat:04x} tag={rec.ftag:04x}")
            for i in range(8):
                b10 = bytes(rec.st[i][k] for k in range(10))   # logical ST(i) in the record
                empty = (b10 == b"\x00" * 10)
                tag, hexv, val = self.st_lbls[i]
                tag.setText(f"ST{i}")
                hexv.setText(_fmt80(b10[::-1].hex()))
                hexv.setStyleSheet("color:#4b535d;" if empty else "color:#c9d1d9;")
                val.setText("—" if empty else f"{floatx80_to_float(b10):.6g}")
        self._prev = None   # next live refresh re-highlights from scratch

    def unpin(self):
        self.mode_lbl.setStyleSheet("color:#8b949e;")
