# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Architectural register panel — GPRs, EFLAGS (decoded), segments, control
registers, and the x87 stack (logical ST(0..7) with decoded floatx80 values)."""
from PySide6.QtWidgets import (QWidget, QHBoxLayout, QVBoxLayout, QGridLayout,
                               QLabel, QGroupBox, QTabWidget, QSizePolicy,
                               QToolButton)
from PySide6.QtGui import QFont
from PySide6.QtCore import Qt, QSize, Signal

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


def _set_explanation(widget, text):
    """Keep pointer and assistive explanations synchronized across time points."""
    widget.setToolTip(text)
    widget.setAccessibleDescription(text)


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


class _StateBanner(QLabel):
    """Choose the clearest complete time-point phrase that fits its pane."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._full_text = ""
        self._variants = ()
        # The outer splitter is allowed to make Registers very narrow. Its
        # truth-critical LIVE/PINNED marker must yield layout width rather than
        # force the application wider, then choose a deliberate compact phrase
        # instead of letting QLabel crop arbitrary trailing words.
        self.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Fixed)
        self.setMinimumWidth(0)

    def set_state(self, full_text, variants, description):
        self._full_text = str(full_text)
        self._variants = tuple(str(text) for text in variants)
        self.setToolTip(description)
        self.setAccessibleDescription(description)
        self._sync_text()

    def fullText(self):
        return self._full_text

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._sync_text()

    def _sync_text(self):
        width = max(0, self.contentsRect().width())
        candidates = (self._full_text, *self._variants)
        chosen = next(
            (text for text in candidates
             if self.fontMetrics().horizontalAdvance(text) <= width),
            None)
        if chosen is None:
            shortest = candidates[-1] if candidates else ""
            chosen = self.fontMetrics().elidedText(
                shortest, Qt.ElideRight, width)
        QLabel.setText(self, chosen)


class RegsView(QWidget):
    unpinRequested = Signal()
    COMPACT_WIDTH = 744

    def __init__(self, parent=None):
        super().__init__(parent)
        # The full three-column register bank needs roughly 740px.  Let the outer
        # splitter shrink below that and switch to indexed pages rather than
        # forcing the entire application wider or silently clipping x87 values.
        self.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        root = QVBoxLayout(self)
        root.setContentsMargins(4, 4, 4, 4)
        root.setSpacing(0)
        self._session_active = False
        self.state_bar = QWidget()
        self.state_bar.setFixedHeight(20)
        state_row = QHBoxLayout(self.state_bar)
        state_row.setContentsMargins(0, 0, 0, 0)
        state_row.setSpacing(0)
        self.state_banner = _StateBanner()
        self.state_banner.setAccessibleName("Register state time point")
        self.state_banner.setFont(_mono(9, True))
        self.state_banner.setFixedHeight(20)
        self.state_banner.setStyleSheet(
            "color:#8b949e;background:#0d1117;border:1px solid #30363d;"
            "padding:1px 5px;")
        self.state_banner.set_state(
            "LIVE · current architectural state",
            ("LIVE · current state", "LIVE"),
            "Live architectural state after the most recent model clock")
        state_row.addWidget(self.state_banner, 1)
        self.unpin_btn = QToolButton()
        self.unpin_btn.setText("× Unpin")
        self.unpin_btn.setAccessibleName("Unpin registers")
        self.unpin_btn.setFixedHeight(20)
        self.unpin_btn.setToolTip(
            "Return Registers to current live state without advancing the model "
            "(or focus Pipeline and press Escape with an empty Trace filter)")
        self.unpin_btn.setStyleSheet(
            "QToolButton{color:#e3b341;background:#211a08;"
            "border:1px solid #6e5420;padding:1px 6px;}"
            "QToolButton:hover{background:#3a2d0c;color:#f0c95c;}")
        self.unpin_btn.clicked.connect(self.unpinRequested.emit)
        self.unpin_btn.hide()
        state_row.addWidget(self.unpin_btn)
        root.addWidget(self.state_bar)
        self._session_hint = QLabel(
            "No program loaded\n\nUse Open… for a file, its arrow for an "
            "example, or Snapshot… to inspect architectural state.")
        self._session_hint.setAlignment(Qt.AlignCenter)
        self._session_hint.setWordWrap(True)
        self._session_hint.setStyleSheet(
            "color:#7d8590;font-style:italic;padding:20px;")
        root.addWidget(self._session_hint, 1)

        # --- integer column ---
        self.int_pane = QWidget()
        col1 = QVBoxLayout(self.int_pane)
        col1.setContentsMargins(0, 0, 0, 0)
        gp = QGroupBox("Integer / flags")
        g = QGridLayout(gp); g.setSpacing(2)
        self.gpr_lbls = {}
        for i, name in enumerate(GPR_NAMES):
            g.addWidget(self._k(name), i, 0)
            v = QLabel("00000000"); v.setFont(_mono())
            self.gpr_lbls[name] = v
            g.addWidget(v, i, 1)
        self.eip_name_lbl = self._k("EIP")
        g.addWidget(self.eip_name_lbl, len(GPR_NAMES), 0)
        self.eip_lbl = QLabel("00000000"); self.eip_lbl.setFont(_mono())
        g.addWidget(self.eip_lbl, len(GPR_NAMES), 1)
        g.addWidget(self._k("EFL"), len(GPR_NAMES) + 1, 0)
        self.efl_lbl = QLabel("00000000"); self.efl_lbl.setFont(_mono())
        g.addWidget(self.efl_lbl, len(GPR_NAMES) + 1, 1)
        self.flags_lbl = QLabel("")
        self.flags_lbl.setFont(_mono(9))
        self.flags_lbl.setWordWrap(True)
        self.flags_lbl.setAccessibleName("Decoded EFLAGS")
        self._flag_parts = ()
        self._flags_side = False
        # In normal widths, span the flag footer across all 3 columns and let
        # the 3rd absorb slack. At the true minimum _sync_flag_layout reuses
        # that absorber as a five-row side grid, preserving every indicator.
        g.addWidget(self.flags_lbl, len(GPR_NAMES) + 2, 0, 1, 3)
        self._int_grid = g
        g.setColumnStretch(2, 1)
        col1.addWidget(gp)

        # --- segment + control column ---
        self.seg_pane = QWidget()
        col2 = QVBoxLayout(self.seg_pane)
        col2.setContentsMargins(0, 0, 0, 0)
        sg = QGroupBox("Segments")
        self.seg_group = sg
        g2 = QGridLayout(sg)
        g2.setVerticalSpacing(2)
        g2.setHorizontalSpacing(5)
        g2.addWidget(self._k("sel"), 0, 1)
        self.seg_base_hdr = self._k("base")
        g2.addWidget(self.seg_base_hdr, 0, 2)
        g2.addWidget(self._k("limit"), 0, 3)
        self.seg_lbls = {}
        for i, name in enumerate(SEG_NAMES):
            g2.addWidget(self._k(name), i + 1, 0)
            sel = QLabel("0000"); sel.setFont(_mono(9))
            base = QLabel("00000000"); base.setFont(_mono(9))
            lim = QLabel("00000000"); lim.setFont(_mono(9))
            sel.setAccessibleName(f"{name} selector")
            base.setAccessibleName(f"{name} segment base")
            lim.setAccessibleName(f"{name} segment limit")
            self.seg_lbls[name] = (sel, base, lim)
            g2.addWidget(sel, i + 1, 1); g2.addWidget(base, i + 1, 2); g2.addWidget(lim, i + 1, 3)
        g2.addWidget(QWidget(), 0, 4); g2.setColumnStretch(4, 1)   # absorb slack on the right
        col2.addWidget(sg)
        self.seg_compact_group = QGroupBox("Segments + control")
        self.seg_compact_group.setAccessibleName(
            "Segments and control registers")
        self.seg_compact_group.setToolTip(
            "Compact register table: each segment row is selector, base, "
            "then limit; control rows show CR0/CR2/CR3/CR4 and mode")
        self.seg_compact_group.setAccessibleDescription(
            self.seg_compact_group.toolTip())
        seg_compact_layout = QVBoxLayout(self.seg_compact_group)
        seg_compact_layout.setContentsMargins(6, 4, 4, 4)
        self.seg_compact_lbl = QLabel()
        self.seg_compact_lbl.setFont(_mono(7))
        self.seg_compact_lbl.setAccessibleName("Compact segment register table")
        self.seg_compact_lbl.setToolTip(
            "One row per segment: selector, base, then limit")
        seg_compact_layout.addWidget(self.seg_compact_lbl)
        self.seg_compact_group.hide()
        col2.addWidget(self.seg_compact_group)
        cr = QGroupBox("Control / mode")
        self.control_group = cr
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
        self.fp_pane = QWidget()
        col3 = QVBoxLayout(self.fp_pane)
        col3.setContentsMargins(0, 0, 0, 0)
        fp = QGroupBox("x87 FPU")
        g4 = QGridLayout(fp); g4.setSpacing(2)
        self._fp_grid = g4
        self._fp_grid_margins = g4.getContentsMargins()
        self.fphdr = QLabel(""); self.fphdr.setFont(_mono(9))
        self.fphdr.setWordWrap(True)   # guard the header against width overrun
        g4.addWidget(self.fphdr, 0, 0, 1, 4)
        # col 0 (the ST label) gets a fixed min width so the exponent hex never butts
        # against the label: the live path padded col 0 only incidentally, via the
        # empty-slot '·', so a full stack (or the pinned path, which dropped the '·')
        # rendered 'ST13fff' with no gap. A fixed width pads it in EVERY mode/state.
        g4.setColumnMinimumWidth(0, 30)
        # col 2 is a fixed-width spacer so the decoded value never fuses with the
        # 20-hex-digit 80-bit mantissa; the value column (3) is right-aligned.
        g4.setColumnMinimumWidth(2, 12); g4.setColumnStretch(2, 1)
        self.fp_reg_hdr = self._k("reg")
        self.fp_hex_hdr = self._k("80-bit")
        self.fp_value_hdr = self._k("value")
        g4.addWidget(self.fp_reg_hdr, 1, 0)
        g4.addWidget(self.fp_hex_hdr, 1, 1)
        g4.addWidget(self.fp_value_hdr, 1, 3, alignment=Qt.AlignRight)
        self.st_lbls = []
        for i in range(8):
            tag = QLabel(f"ST{i}"); tag.setFont(_mono(9))
            hexv = QLabel("0" * 20); hexv.setFont(_mono(9))
            val = QLabel("0.0"); val.setFont(_mono(9))
            hexv.setAccessibleName(f"ST{i} raw 80-bit value")
            val.setAccessibleName(f"ST{i} decoded value")
            self.st_lbls.append((tag, hexv, val))
            g4.addWidget(tag, i + 2, 0); g4.addWidget(hexv, i + 2, 1)
            g4.addWidget(val, i + 2, 3, alignment=Qt.AlignRight)
        col3.addWidget(fp)

        # trailing stretch on every column so the group boxes size to their CONTENT
        # (compact rows) and the spare panel height collects below them, instead of
        # stretching each register row to ~2x its text height (the "wasted gaps").
        for _c in (col1, col2, col3):
            _c.addStretch(1)

        self._panes = (
            (self.int_pane, "Integer", "General registers and decoded EFLAGS"),
            (self.seg_pane, "Segments", "Segments, control registers, and CPU mode"),
            (self.fp_pane, "x87", "Logical x87 stack, control, status, and tags"),
        )
        self._wide_host = QWidget()
        self._wide_layout = QHBoxLayout(self._wide_host)
        self._wide_layout.setContentsMargins(0, 0, 0, 0)
        self._wide_layout.setSpacing(4)
        self._compact_tabs = QTabWidget()
        self._compact_tabs.setDocumentMode(True)
        self._compact_tabs.setAccessibleName("Register groups")
        self._compact_tabs.setAccessibleDescription(
            "Choose the Integer, Segments, or x87 architectural register page.")
        self._compact_tabs.tabBar().setUsesScrollButtons(False)
        self._compact_tabs.tabBar().setAccessibleName("Register group tabs")
        self._compact_tabs.tabBar().setAccessibleDescription(
            "Choose the Integer, Segments, or x87 architectural register page.")
        self._compact_tabs.tabBar().setToolTip(
            "Register pages: Integer, Segments/control, and x87")
        root.addWidget(self._wide_host)
        root.addWidget(self._compact_tabs)
        self._wide_host.hide()
        self._compact = False
        # Start compact: it gives QSplitter an honest small minimum before the
        # final window width is known. resizeEvent promotes it when room exists.
        self._set_compact(True)
        self.set_session_active(False)

    def minimumSizeHint(self):
        return QSize(340, 220)

    def _set_compact(self, compact):
        if compact == self._compact:
            self._sync_session_visibility()
            return
        if compact:
            self._wide_host.hide()
            for pane, label, tip in self._panes:
                self._wide_layout.removeWidget(pane)
                self._compact_tabs.addTab(pane, label)
                self._compact_tabs.setTabToolTip(
                    self._compact_tabs.indexOf(pane), tip)
            self._compact_tabs.setCurrentIndex(
                min(getattr(self, "_compact_index", 0),
                    self._compact_tabs.count() - 1))
            self._compact_tabs.show()
        else:
            self._compact_index = max(0, self._compact_tabs.currentIndex())
            self._compact_tabs.hide()
            for pane, _label, _tip in self._panes:
                idx = self._compact_tabs.indexOf(pane)
                if idx >= 0:
                    self._compact_tabs.removeTab(idx)
                pane.setParent(self._wide_host)
            # Equal stretch distributes any spare room; each pane's measured
            # content hint still protects its labels at the wide-mode threshold.
            for pane, _label, _tip in self._panes:
                # x87 carries a 20-hex-digit value plus decoded text and a
                # longer metadata header. Allocate it proportionally more of
                # the wide bank; Integer and Segments remain comfortably above
                # their measured content widths.
                self._wide_layout.addWidget(
                    pane, 3 if pane is self.fp_pane else 2)
                # Non-current QTabWidget pages are hidden; reparenting alone
                # preserves that state, so explicitly reveal every wide column.
                pane.show()
            self._wide_host.show()
        self._compact = compact
        self._sync_session_visibility()

    def _sync_session_visibility(self):
        self.state_bar.setVisible(self._session_active)
        self._session_hint.setVisible(not self._session_active)
        self._compact_tabs.setVisible(
            self._session_active and self._compact)
        self._wide_host.setVisible(
            self._session_active and not self._compact)

    def set_session_active(self, active):
        self._session_active = bool(active)
        self._sync_session_visibility()

    def start_session(self):
        """Expose the bank for a fresh model without comparing to stale values."""
        self._prev = None
        self._show_live_banner()
        self.set_session_active(True)

    def _show_live_banner(self):
        self.state_banner.setStyleSheet(
            "color:#8b949e;background:#0d1117;border:1px solid #30363d;"
            "padding:1px 5px;")
        self.state_banner.set_state(
            "LIVE · current architectural state",
            ("LIVE · current state", "LIVE"),
            "Live architectural state after the most recent model clock")
        self.unpin_btn.hide()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        narrow = event.size().width() < 260
        if narrow and self.unpin_btn.text() != "×":
            self.unpin_btn.setText("×")
            self.unpin_btn.setFixedWidth(24)
        elif not narrow and self.unpin_btn.text() != "× Unpin":
            self.unpin_btn.setMinimumWidth(0)
            self.unpin_btn.setMaximumWidth(16777215)
            self.unpin_btn.setText("× Unpin")
        self._sync_narrow_registers(narrow)
        self._sync_flag_layout(narrow)
        self._set_compact(event.size().width() < self.COMPACT_WIDTH)

    def _k(self, t):
        l = QLabel(t); l.setStyleSheet("color:#8b949e;"); l.setFont(_mono(9, True))
        return l

    def _sync_narrow_registers(self, narrow):
        """Preserve every segment/x87 hex digit in the 196 px register pane."""
        self.seg_group.setVisible(not narrow)
        self.control_group.setVisible(not narrow)
        self.seg_compact_group.setVisible(narrow)
        self._sync_segment_compact()

        # A decoded x87 float and its 21-character raw value cannot coexist in
        # 164 px. Keep the complete architectural 80-bit value on-canvas and
        # expose the decoded value through its tooltip/accessibility metadata.
        self._fp_grid.setHorizontalSpacing(1 if narrow else 2)
        self._fp_grid.setVerticalSpacing(0 if narrow else 2)
        left, top, right, bottom = self._fp_grid_margins
        self._fp_grid.setContentsMargins(
            6 if narrow else left, top,
            6 if narrow else right, bottom)
        self._fp_grid.setColumnMinimumWidth(0, 22 if narrow else 30)
        self._fp_grid.setColumnMinimumWidth(2, 0 if narrow else 12)
        self.fphdr.setMinimumHeight(
            2 * self.fphdr.fontMetrics().height()
            if narrow else self.fphdr.fontMetrics().height())
        self.fp_reg_hdr.setVisible(not narrow)
        self.fp_hex_hdr.setVisible(not narrow)
        self.fp_value_hdr.setVisible(not narrow)
        for tag, raw, decoded in self.st_lbls:
            tag.setFont(_mono(7 if narrow else 9))
            raw.setFont(_mono(7 if narrow else 9))
            decoded.setVisible(not narrow)

    def _sync_segment_compact(self):
        rows = []
        descriptions = []
        for name in SEG_NAMES:
            selector, base, limit = self.seg_lbls[name]
            rows.append(
                f"{name} {selector.text()} {base.text()} {limit.text()}")
            descriptions.append(
                f"{name}: selector {selector.text()}, base {base.text()}, "
                f"limit {limit.text()}")
        for name in ("CR0", "CR2", "CR3", "CR4"):
            value = self.cr_lbls[name].text()
            rows.append(f"{name} {value}")
            descriptions.append(f"{name}: {value}")
        rows.append(self.mode_lbl.text())
        descriptions.append(f"mode: {self.mode_lbl.text()}")
        self.seg_compact_lbl.setText("\n".join(rows))
        self.seg_compact_lbl.setAccessibleDescription(
            "Compact segment and control registers. "
            + "; ".join(descriptions) + ".")

    def _show_flags(self, eflags, previous=None):
        """Render all named EFLAGS, wrapping only between complete indicators."""
        parts = []
        values = []
        changed_names = []
        for bit, name in _FLAGS:
            enabled = (eflags >> bit) & 1
            changed = (
                previous is not None
                and ((previous >> bit) & 1) != enabled)
            color = "#e3b341" if enabled else "#7d8590"
            style = (
                f"color:{color}"
                + (";text-decoration:underline" if changed else ""))
            parts.append(
                f"<span style='{style}'>{name}{enabled}</span>")
            values.append(f"{name}={enabled}")
            if changed:
                changed_names.append(name)
        self._flag_parts = tuple(parts)
        self._sync_flag_layout(self.width() < 260)
        comparison = (
            " Changed since the prior time point: "
            + ", ".join(changed_names) + "."
            if changed_names else
            " No named flag changed since the prior time point."
            if previous is not None else
            " No prior time point is available for change comparison.")
        self.flags_lbl.setAccessibleDescription(
            "Decoded EFLAGS: " + ", ".join(values) + "." + comparison)

    def _sync_flag_layout(self, narrow):
        if not self._flag_parts:
            return
        if narrow != self._flags_side:
            self._int_grid.removeWidget(self.flags_lbl)
            if narrow:
                # Use the otherwise-empty absorber column beside the upper GPR
                # rows. Five pair rows need no extra vertical space and fit the
                # 164 px content width without shrinking the hex values.
                self._int_grid.addWidget(
                    self.flags_lbl, 0, 2, 5, 1,
                    alignment=Qt.AlignLeft | Qt.AlignTop)
            else:
                self._int_grid.addWidget(
                    self.flags_lbl, len(GPR_NAMES) + 2, 0, 1, 3)
            self._flags_side = narrow
        if narrow:
            rows = [
                " ".join(self._flag_parts[index:index + 2])
                for index in range(0, len(self._flag_parts), 2)]
            text = "<br>".join(rows)
            self.flags_lbl.setMinimumHeight(
                len(rows) * self.flags_lbl.fontMetrics().height())
        else:
            text = " ".join(self._flag_parts)
            self.flags_lbl.setMinimumHeight(
                self.flags_lbl.fontMetrics().height())
        self.flags_lbl.setText(text)

    def update_from(self, s):
        self._show_live_banner()
        self.eip_name_lbl.setText("EIP")
        _set_explanation(self.eip_name_lbl, "")
        self.seg_base_hdr.setText("base")
        _set_explanation(self.seg_base_hdr, "")
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
        # Full named-bit grid: every flag shown (set = amber, clear = dim); a bit
        # that changed since the previous step is underlined.
        prev_efl = prev["eflags"] if prev is not None else None
        self._show_flags(s.eflags, prev_efl)
        self._prev = {"gpr": list(s.gpr), "eip": s.eip, "eflags": s.eflags}
        for i, name in enumerate(SEG_NAMES):
            sel, base, lim = self.seg_lbls[name]
            sel.setText(f"{s.seg_sel[i]:04x}")
            base.setText(f"{s.seg_base[i]:08x}"); base.setStyleSheet("")   # clear pinned n/a
            lim.setText(f"{s.seg_limit[i]:08x}"); lim.setStyleSheet("")
            _set_explanation(base, "")
            _set_explanation(lim, "")
        for k, val in (("CR0", s.cr0), ("CR2", s.cr2), ("CR3", s.cr3), ("CR4", s.cr4)):
            self.cr_lbls[k].setText(f"{val:08x}"); self.cr_lbls[k].setStyleSheet("")
            _set_explanation(self.cr_lbls[k], "")
        self.mode_lbl.setText(
            f"{'SYS' if s.sys_mode else 'USER'}  CPL={s.cpl}"
            f"{'  SMM' if s.smm_active else ''}")
        _set_explanation(self.mode_lbl, "")
        self._sync_segment_compact()
        # x87 — logical ST(i) = physical fpr[(ftop+i)&7]
        logical_tag = sum(
            ((s.fptag >> ((s.ftop + i) & 7)) & 1) << i
            for i in range(8))
        self.fphdr.setText(
            f"TOP={s.ftop}  ctrl={s.fctrl:04x}  stat={s.fstat:04x}  "
            f"empty={logical_tag:02x}")
        self.fphdr.setToolTip(
            "Live x87 stack: TOP selects the physical stack head; empty mask "
            "bit i = 1 means logical ST(i) is empty")
        for i in range(8):
            phys = (s.ftop + i) & 7
            b10 = bytes(s.fpr[phys][k] for k in range(10))
            hexs = b10[::-1].hex()
            empty = bool((s.fptag >> phys) & 1)   # fptag bit i: 1 = empty
            tag, hexv, val = self.st_lbls[i]
            tag.setText(f"ST{i}" + ("·" if empty else ""))
            tag.setStyleSheet("")
            tag.setToolTip(
                f"Logical ST({i}) is {'empty' if empty else 'occupied'}")
            raw_text = _fmt80(hexs)
            hexv.setText(raw_text)
            hexv.setStyleSheet("color:#7d8590;" if empty else "color:#c9d1d9;")
            fv = floatx80_to_float(b10)
            decoded_text = "—" if empty else f"{fv:.6g}"
            val.setText(decoded_text)
            val.setStyleSheet("color:#7d8590;" if empty else "color:#c9d1d9;")
            detail = (
                f"Logical ST({i}), physical register {phys}: "
                f"{'empty' if empty else 'occupied'}; raw 80-bit value "
                f"{raw_text}; decoded value "
                f"{'unavailable while empty' if empty else decoded_text}.")
            hexv.setToolTip(detail)
            hexv.setAccessibleDescription(detail)
            val.setToolTip(detail)
            val.setAccessibleDescription(detail)

    def show_retire(self, rec, prev):
        """Pin the panel to a retired instruction's post-commit architectural
        state (from the retire record), highlighting what changed vs the previous
        retirement. Translation bases and CR0/3/4 are the record's pre-execution
        context; limits and CR2 remain unavailable."""
        chg = "color:#e3b341;font-weight:bold;"
        same = "color:#c9d1d9;"
        self.state_banner.setStyleSheet(
            "color:#e3b341;background:#211a08;border:1px solid #6e5420;"
            "border-right:0;padding:1px 5px;")
        self.state_banner.set_state(
            f"PINNED n={rec.n} · retire cyc={rec.cyc}",
            (f"PIN n={rec.n} · c={rec.cyc}", f"PIN n={rec.n}"),
            f"Pinned retirement n={rec.n} at retirement cycle {rec.cyc}: "
            "architectural values are post-commit; "
            "starred instruction/translation context is pre-execution")
        self.unpin_btn.show()
        for i, name in enumerate(GPR_NAMES):
            changed = prev is not None and prev.gpr[i] != rec.gpr[i]
            self.gpr_lbls[name].setText(f"{rec.gpr[i]:08x}")
            self.gpr_lbls[name].setStyleSheet(chg if changed else same)
        # The record stores the retiring instruction's source PC, not the
        # post-commit next EIP. Do not give that different time point an EIP
        # label merely because the live register bank uses one.
        self.eip_name_lbl.setText("PC*")
        _set_explanation(
            self.eip_name_lbl,
            "* retiring instruction PC; post-commit next EIP is not captured")
        self.eip_lbl.setText(f"{rec.pc:08x}"); self.eip_lbl.setStyleSheet(same)
        efl_chg = prev is not None and prev.eflags != rec.eflags
        self.efl_lbl.setText(f"{rec.eflags:08x}")
        self.efl_lbl.setStyleSheet(chg if efl_chg else same)
        prev_efl = prev.eflags if prev is not None else None
        self._show_flags(rec.eflags, prev_efl)
        # Selectors are architectural post-state. Bases and CR0/3/4 are captured
        # pre-execution for exact address translation, so mark the header and
        # explain the time point instead of presenting them as post-state.
        na = "color:#7d8590;font-style:italic;"
        self.seg_base_hdr.setText("base*")
        _set_explanation(
            self.seg_base_hdr,
            "* pre-execution segment base used for address translation")
        for i, name in enumerate(SEG_NAMES):
            sel, base, lim = self.seg_lbls[name]
            sel.setText(f"{rec.seg[i]:04x}")
            base.setText(f"{rec.seg_base[i]:08x}"); base.setStyleSheet("")
            _set_explanation(
                base, "Pre-execution base captured for this retirement")
            lim.setText("n/a"); lim.setStyleSheet(na)
            _set_explanation(
                lim, "Segment limit is not captured per retirement")
        for k, value in (("CR0", rec.cr0), ("CR3", rec.cr3), ("CR4", rec.cr4)):
            self.cr_lbls[k].setText(f"{value:08x}")
            self.cr_lbls[k].setStyleSheet("")
            _set_explanation(
                self.cr_lbls[k],
                "Pre-execution control register used for address translation")
        self.cr_lbls["CR2"].setText("n/a")
        self.cr_lbls["CR2"].setStyleSheet(na)
        _set_explanation(
            self.cr_lbls["CR2"], "CR2 is not captured per retirement")
        self.mode_lbl.setText(
            f"{'SYS' if rec.sys_mode else 'USER'}  CPL={rec.cpl}"
            f"{'  SMM' if rec.smm_active else ''}")
        self.mode_lbl.setStyleSheet(same)
        _set_explanation(
            self.mode_lbl,
            "Execution mode sampled before this retirement; GPRs/selectors are "
            "post-commit; PC*, base*, and CR0/CR3/CR4 are pre-execution context")
        self._sync_segment_compact()
        if rec.x87_valid:
            # Values are already rotated into logical ST(0..7), so label that
            # useful fact instead of repeating the global PINNED banner.
            self.fphdr.setText(
                f"logical ctrl={rec.fctrl:04x} stat={rec.fstat:04x} "
                f"empty={rec.ftag & 0xff:02x}")
            self.fphdr.setToolTip(
                "Pinned post-commit logical ST(0..7); empty mask bit i = 1 "
                "means ST(i) is empty (values are already rotated, so TOP is "
                "not needed)")
            for i in range(8):
                b10 = bytes(rec.st[i][k] for k in range(10))   # logical ST(i) in the record
                empty = bool((rec.ftag >> i) & 1)
                tag, hexv, val = self.st_lbls[i]
                tag.setText(f"ST{i}" + ("·" if empty else ""))   # match the live empty marker
                tag.setStyleSheet("")
                tag.setToolTip(
                    f"Pinned logical ST({i}) is "
                    f"{'empty' if empty else 'occupied'}")
                raw_text = _fmt80(b10[::-1].hex())
                hexv.setText(raw_text)
                hexv.setStyleSheet("color:#7d8590;" if empty else "color:#c9d1d9;")
                decoded_text = (
                    "—" if empty else f"{floatx80_to_float(b10):.6g}")
                val.setText(decoded_text)
                val.setStyleSheet(
                    "color:#7d8590;" if empty else "color:#c9d1d9;")
                detail = (
                    f"Pinned logical ST({i}): "
                    f"{'empty' if empty else 'occupied'}; raw 80-bit value "
                    f"{raw_text}; decoded value "
                    f"{'unavailable while empty' if empty else decoded_text}.")
                hexv.setToolTip(detail)
                hexv.setAccessibleDescription(detail)
                val.setToolTip(detail)
                val.setAccessibleDescription(detail)
        else:
            # A partial/legacy backend record may not carry an x87 snapshot.
            # Never leave the last live or pinned values under a new pin.
            self.fphdr.setText("x87 n/a · not captured for this retirement")
            self.fphdr.setToolTip(
                "This retirement did not capture x87 post-commit state; use a "
                "complete backend record or return to LIVE")
            for i, (tag, hexv, val) in enumerate(self.st_lbls):
                tag.setText(f"ST{i}")
                tag.setStyleSheet(na)
                tag.setToolTip(
                    f"ST({i}) is unavailable for this retirement")
                hexv.setText("n/a")
                hexv.setStyleSheet(na)
                hexv.setToolTip(
                    "Raw 80-bit value was not captured for this retirement")
                hexv.setAccessibleDescription(
                    f"Pinned logical ST({i}) raw 80-bit value unavailable.")
                val.setText("—")
                val.setStyleSheet(na)
                val.setToolTip(
                    "Decoded value was not captured for this retirement")
                val.setAccessibleDescription(
                    f"Pinned logical ST({i}) decoded value unavailable.")
        self._prev = None   # next live refresh re-highlights from scratch

    def unpin(self):
        self._show_live_banner()
        self.mode_lbl.setStyleSheet("color:#8b949e;")
