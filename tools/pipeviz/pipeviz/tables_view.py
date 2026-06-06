# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Memory-subsystem tables panel — what is resident in the I-cache (code cache),
D-cache, the split I/D TLB, and the slow-path prefetch buffer. Each is a table,
refreshed in full each frame (all are small: <=256 lines / 32 TLB entries)."""
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QTabWidget,
                               QTableWidget, QTableWidgetItem, QHeaderView,
                               QAbstractItemView, QLabel, QGridLayout, QSizePolicy)
from PySide6.QtGui import QFont, QColor, QBrush, QPainter
from PySide6.QtCore import Qt, QRect

from . import disasm


class CacheMap(QWidget):
    """A 256-cell occupancy heatmap of a 2-way / 128-set L1 cache (one cell per
    (set, way); empty = dark, resident = green, MRU way brightened). Gives an
    instant picture of how full the cache is."""
    COLS = 64

    def __init__(self, parent=None):
        super().__init__(parent)
        self.cells = [(False, False)] * 256   # (valid, is_mru) by idx = set*2+way
        self.setFixedHeight(64)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def set_lines(self, lines):
        cells = [(False, False)] * 256
        for l in lines:
            idx = l.set * 2 + l.way
            cells[idx] = (True, l.lru == l.way)
        self.cells = cells
        self.update()

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0d1117"))
        rows = 256 // self.COLS
        cw = self.width() / self.COLS
        ch = self.height() / rows
        for idx, (valid, mru) in enumerate(self.cells):
            c = idx % self.COLS
            r = idx // self.COLS
            cell = QRect(int(c * cw) + 1, int(r * ch) + 1, int(cw) - 1, int(ch) - 1)
            if valid:
                p.fillRect(cell, QColor("#3fb950" if mru else "#1f7a36"))
            else:
                p.fillRect(cell, QColor("#161b22"))
        p.end()


def _mono(pt=9):
    f = QFont("monospace"); f.setStyleHint(QFont.Monospace); f.setPointSize(pt)
    return f


def _mk_table(cols, widths=None):
    t = QTableWidget(0, len(cols))
    t.setHorizontalHeaderLabels(cols)
    t.verticalHeader().setVisible(False)
    t.setEditTriggers(QAbstractItemView.NoEditTriggers)
    t.setSelectionBehavior(QAbstractItemView.SelectRows)
    t.setShowGrid(False)
    t.setFont(_mono())
    if widths:
        for i, w in enumerate(widths):
            t.setColumnWidth(i, w)
        t.horizontalHeader().setSectionResizeMode(len(cols) - 1, QHeaderView.Stretch)
    return t


def _fill(table, rows, dim_cols=()):
    table.setRowCount(len(rows))
    for r, row in enumerate(rows):
        for c, v in enumerate(row):
            it = QTableWidgetItem(str(v))
            if c in dim_cols:
                it.setForeground(QBrush(QColor("#8b949e")))
            table.setItem(r, c, it)


class TablesView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        self.tabs = QTabWidget()
        lay.addWidget(self.tabs)

        # --- I-cache (code) ---
        self.ic_lbl = QLabel()
        self.ic_map = CacheMap()
        self.ic = _mk_table(["set", "way", "LRU", "tag", "line addr", "32 line bytes"],
                            [44, 40, 40, 70, 90, 9999])
        self.tabs.addTab(self._wrap(self.ic_lbl, self.ic, self.ic_map), "Code $ (I)")

        # --- D-cache (data, timing-only) ---
        self.dc_lbl = QLabel()
        self.dc_map = CacheMap()
        self.dc = _mk_table(["set", "way", "LRU", "tag", "line addr"],
                            [50, 50, 50, 90, 9999])
        self.tabs.addTab(self._wrap(self.dc_lbl, self.dc, self.dc_map), "Data $ (D)")

        # --- TLB (I + D) ---
        self.tlb_lbl = QLabel()
        self.tlb = _mk_table(
            ["side", "idx", "V", "page (4K/4M)", "vpn->pfn", "perm U/W/P", "big", "D"],
            [44, 40, 30, 110, 150, 90, 40, 9999])
        self.tabs.addTab(self._wrap(self.tlb_lbl, self.tlb), "TLB (I/D)")

        # --- Prefetch buffer (ibuf) ---
        self.pf = _PrefetchView()
        self.tabs.addTab(self.pf, "Prefetch")
        self._bits = 32

    def set_bits(self, bits):
        self._bits = bits

    def _wrap(self, label, table, cmap=None):
        w = QWidget(); v = QVBoxLayout(w); v.setContentsMargins(4, 4, 4, 4)
        label.setStyleSheet("color:#8b949e;")
        v.addWidget(label)
        if cmap is not None:
            v.addWidget(cmap)
        v.addWidget(table)
        return w

    def update_from(self, backend, state):
        self._bits = 32 if state.cs_d else 16
        # I-cache
        ic = backend.icache()
        self.ic_map.set_lines(ic)
        self.ic_lbl.setText(
            f"{len(ic)} / 256 lines resident ({100*len(ic)//256}% full)  "
            f"— 8 KB, 2-way, 32-byte line, 128 sets")
        rows = []
        for l in ic:
            base = (l.tag << 12) | (l.set << 5)
            data = " ".join(f"{l.data[b]:02x}" for b in range(32))
            mru = "*" if l.lru == l.way else " "
            rows.append([l.set, l.way, mru, f"{l.tag:05x}", f"{base:08x}", data])
        _fill(self.ic, rows, dim_cols=(0, 1, 3, 4))

        # D-cache
        dc = backend.dcache()
        self.dc_map.set_lines(dc)
        self.dc_lbl.setText(
            f"{len(dc)} / 256 lines resident ({100*len(dc)//256}% full)  "
            f"— 8 KB, 2-way, 32-byte line, timing model (no data array)")
        rows = []
        for l in dc:
            base = (l.tag << 12) | (l.set << 5)
            mru = "*" if l.lru == l.way else " "
            rows.append([l.set, l.way, mru, f"{l.tag:05x}", f"{base:08x}"])
        _fill(self.dc, rows, dim_cols=(0, 1, 3))

        # TLB (both sides, valid entries only)
        rows = []
        nv = 0
        for side, is_d in (("I", 0), ("D", 1)):
            ents = backend.tlb(is_d)
            for i, e in enumerate(ents):
                if not e.valid:
                    continue
                nv += 1
                pg = "4M" if e.big else "4K"
                vaddr = e.vpn << 12
                paddr = e.pfn << 12
                perm = f"{(e.perm>>2)&1}/{(e.perm>>1)&1}/{e.perm&1}"
                rows.append([side, i, "1", f"{pg} {vaddr:08x}",
                             f"{e.vpn:05x}->{e.pfn:05x}", perm,
                             "Y" if e.big else "", "Y" if e.dirty else ""])
        self.tlb_lbl.setText(f"{nv} valid entries  (16-entry direct-mapped, split I/D; index = lin[15:12])")
        _fill(self.tlb, rows, dim_cols=(1, 3, 4))

        # Prefetch buffer
        self.pf.update_from(state, self._bits)


class _PrefetchView(QWidget):
    """The slow-path 16-byte prefetch buffer (ibuf) + the fast-path fetch window
    (flin / eip). Shows the raw bytes and a tentative decode."""
    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self); v.setContentsMargins(8, 8, 8, 8)
        self.info = QLabel(); self.info.setStyleSheet("color:#8b949e;")
        v.addWidget(self.info)
        grid = QGridLayout(); grid.setSpacing(3)
        self.byte_lbls = []
        hdr = QLabel("ibuf[0..15] (slow-path fetch buffer):")
        hdr.setStyleSheet("font-weight:bold;")
        v.addWidget(hdr)
        gw = QWidget(); gw.setLayout(grid)
        for i in range(16):
            idx = QLabel(f"{i:02d}"); idx.setAlignment(Qt.AlignCenter)
            idx.setStyleSheet("color:#6e7681; font-size:8px;")
            grid.addWidget(idx, 0, i)
            b = QLabel("00"); b.setAlignment(Qt.AlignCenter); b.setFont(_mono(11))
            b.setStyleSheet("background:#161b22; border:1px solid #30363d; padding:4px;")
            grid.addWidget(b, 1, i)
            self.byte_lbls.append(b)
        v.addWidget(gw)
        self.decode = QLabel(); self.decode.setFont(_mono(10))
        self.decode.setWordWrap(True)
        v.addWidget(self.decode)
        v.addStretch(1)

    def update_from(self, s, bits):
        self.info.setText(
            f"flin (linear fetch addr) = 0x{s.flin:08x}    eip = 0x{s.eip:08x}    "
            f"fetch_word = {s.fetch_word}")
        ib = bytes(s.ibuf[i] for i in range(16))
        for i in range(16):
            self.byte_lbls[i].setText(f"{ib[i]:02x}")
        txt, sz = disasm.text(ib, s.eip, bits)
        self.decode.setText(f"ibuf decode @ eip:  <b>{txt}</b>  ({sz} bytes)")
