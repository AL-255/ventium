# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Memory-subsystem tables panel — what is resident in the I-cache (code cache),
D-cache, the split I/D TLB, and the slow-path prefetch buffer. Each is a table,
refreshed in full each frame (all are small: <=256 lines / 32 TLB entries)."""
import re
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QTabWidget,
                               QTableWidget, QTableWidgetItem, QHeaderView,
                               QAbstractItemView, QLabel, QGridLayout, QSizePolicy,
                               QLineEdit, QPushButton, QCheckBox)
from PySide6.QtGui import QFont, QColor, QBrush, QPainter
from PySide6.QtCore import Qt, QRect

from . import disasm


class CacheMap(QWidget):
    """Occupancy heatmap of a 2-way / 128-set L1 cache laid out as a real 2D
    grid: 128 columns (sets, X) x 2 rows (ways, Y). Empty = dark, resident =
    green, the MRU way of a set is brightened. Axis ticks + a legend make the
    geometry self-evident."""
    SETS = 128
    LX = 34          # left margin for "way 0 / way 1" labels
    TOP = 13         # top band for the title/legend
    WAYH = 13        # height of each way row
    BOT = 12         # bottom band for set ticks

    def __init__(self, parent=None):
        super().__init__(parent)
        self.cells = [(False, False)] * 256   # (valid, is_mru) by idx = set*2+way
        self.n_valid = 0
        self.setFixedHeight(self.TOP + 2 * self.WAYH + self.BOT)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def set_lines(self, lines):
        cells = [(False, False)] * 256
        for l in lines:
            cells[l.set * 2 + l.way] = (True, l.lru == l.way)
        self.cells = cells
        self.n_valid = len(lines)
        self.update()

    def paintEvent(self, ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0d1117"))
        f = QFont("monospace"); f.setStyleHint(QFont.Monospace); f.setPointSize(7)
        p.setFont(f)
        plot_w = self.width() - self.LX - 4
        cw = plot_w / self.SETS
        # title + legend (right-aligned swatches)
        p.setPen(QColor("#8b949e"))
        p.drawText(QRect(0, 0, self.LX + 80, self.TOP - 1), Qt.AlignVCenter | Qt.AlignLeft,
                   f" {self.n_valid}/256")
        lx = self.width() - 4
        for lab, col in (("MRU", "#56d364"), ("resident", "#1f7a36"), ("empty", "#161b22")):
            tw = 6 + 7 * len(lab)
            lx -= tw
            p.fillRect(QRect(lx, 3, 7, 7), QColor(col))
            p.setPen(QColor("#6e7681"))
            p.drawText(QRect(lx + 9, 0, tw, self.TOP - 1), Qt.AlignVCenter | Qt.AlignLeft, lab)
            lx -= 6
        # way labels + cells
        for way in range(2):
            y = self.TOP + way * self.WAYH
            p.setPen(QColor("#6e7681"))
            p.drawText(QRect(0, y, self.LX - 4, self.WAYH), Qt.AlignVCenter | Qt.AlignRight,
                       f"way{way}")
            for s in range(self.SETS):
                valid, mru = self.cells[s * 2 + way]
                x = self.LX + s * cw
                cell = QRect(int(x), y + 1, max(1, int(cw) - 0), self.WAYH - 2)
                p.fillRect(cell, QColor("#56d364" if (valid and mru)
                                        else "#1f7a36" if valid else "#161b22"))
        # set axis ticks every 16 (0..112; 128 would clip the right edge)
        p.setPen(QColor("#586069"))
        ty = self.TOP + 2 * self.WAYH
        for s in range(0, self.SETS, 16):
            x = int(self.LX + s * cw)
            p.drawText(QRect(x - 8, ty, 20, self.BOT), Qt.AlignHCenter | Qt.AlignTop, str(s))
        p.drawText(QRect(self.LX, ty, plot_w, self.BOT), Qt.AlignRight | Qt.AlignTop, "set →")
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


class CycleBreakdown(QWidget):
    """perf/VTune-style attribution of WHERE the cycles go: every cycle is
    classified by the core FSM state into a category (retire / issue-stall /
    mispredict / I-fill / decode / load-store / page-walk / x87 / system /
    halt), tallied incrementally, and drawn as %-bars sorted biggest-first.
    Answers 'why is IPC low?' at a glance — the tall bar is the bottleneck."""
    CATS = [("retire", "#3fb950"), ("issue-stall", "#7a828d"),
            ("mispredict", "#f85149"), ("I-fill", "#e0a72e"), ("decode", "#39c5cf"),
            ("load/store", "#f0883e"), ("page-walk", "#f778ba"), ("x87 FP", "#bc8cff"),
            ("system", "#e3b341"), ("halt", "#8b949e")]

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.backend = None
        self._zero()

    def _zero(self):
        self._last_cyc = 0
        self.counts = {k: 0 for k, _ in self.CATS}
        self.total_ret = 0

    def reset(self, backend=None):
        self.backend = backend
        self._zero()
        self.update()

    @staticmethod
    def _classify(name, c):
        if name == "S_PIPE":
            if c.mispred_bubbles > 0:
                return "mispredict"
            if c.retU or c.retV:
                return "retire"
            return "issue-stall"
        if name == "S_PF":
            return "I-fill"
        if name in ("S_FETCH", "S_DECODE"):
            return "decode"
        if name in ("S_LOAD", "S_LOAD2", "S_STORE", "S_EXEC", "S_USEQ", "S_IO", "S_INS"):
            return "load/store"
        if name == "S_WALK":
            return "page-walk"
        if name in ("S_FLOAD", "S_FEXEC", "S_FSTORE", "S_FENV_ST", "S_FENV_LD"):
            return "x87 FP"
        if name in ("S_HALT", "S_F00F_HANG"):
            return "halt"
        return "system"

    def ingest(self, backend):
        self.backend = backend
        total = backend.cycle_count()
        if total < self._last_cyc:          # backend was reset under us
            self._zero()
        if total <= self._last_cyc:
            return
        for c in backend.get_cycles(self._last_cyc + 1, 8192):
            self.counts[self._classify(backend.state_name(c.state), c)] += 1
            self.total_ret += (1 if c.retU else 0) + (1 if c.retV else 0)
            self._last_cyc = c.cyc
        self.update()

    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0d1117"))
        W, H = self.width(), self.height()
        total = sum(self.counts.values())
        f = QFont("monospace"); f.setStyleHint(QFont.Monospace); f.setPointSize(9)
        fb = QFont(f); fb.setBold(True)
        ipc = (self.total_ret / total) if total else 0.0
        p.setFont(fb); p.setPen(QColor("#c9d1d9"))
        p.drawText(QRect(8, 6, W - 16, 16), Qt.AlignLeft,
                   f"cycle attribution — {total} cyc · {self.total_ret} retired · IPC {ipc:.3f}")
        if total == 0:
            p.setPen(QColor("#8b949e")); p.setFont(f)
            p.drawText(self.rect(), Qt.AlignCenter, "step the core to attribute cycles")
            p.end(); return
        colmap = dict(self.CATS)
        rows = sorted(((k, v) for k, v in self.counts.items() if v),
                      key=lambda kv: -kv[1])
        p.setFont(f)
        y, rowh, labelw = 30, 22, 92
        barx = 8 + labelw + 54
        barw = max(40, W - barx - 60)
        for k, v in rows:
            pct = v / total
            p.setPen(QColor("#adbac7"))
            p.drawText(QRect(8, y, labelw, rowh), Qt.AlignVCenter | Qt.AlignLeft, k)
            p.setPen(QColor("#8b949e"))
            p.drawText(QRect(8 + labelw, y, 50, rowh), Qt.AlignVCenter | Qt.AlignRight, str(v))
            p.fillRect(QRect(barx, y + 4, barw, rowh - 8), QColor("#161b22"))
            p.fillRect(QRect(barx, y + 4, int(barw * pct), rowh - 8), QColor(colmap[k]))
            p.setPen(QColor("#c9d1d9"))
            p.drawText(QRect(barx + barw + 6, y, 52, rowh), Qt.AlignVCenter | Qt.AlignLeft,
                       f"{pct * 100:.1f}%")
            y += rowh
            if y > H - rowh:
                break
        p.end()


class TablesView(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        self.tabs = QTabWidget()
        lay.addWidget(self.tabs)

        # --- I-cache (code). 'way' shows '*' for the MRU way (LRU dropped). ---
        self.ic_lbl = QLabel()
        self.ic_map = CacheMap()
        self.ic = _mk_table(["set", "way *=MRU", "tag", "line addr", "32 line bytes"],
                            [46, 74, 60, 86, 9999])
        self.ic.setWordWrap(True)
        self.tabs.addTab(self._wrap(self.ic_lbl, self.ic, self.ic_map), "Code $ (I)")

        # --- D-cache (data, timing-only) ---
        self.dc_lbl = QLabel()
        self.dc_map = CacheMap()
        self.dc = _mk_table(["set", "way *=MRU", "tag", "line addr"],
                            [56, 74, 90, 9999])
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

        # --- Hotspots (per-PC cycle-cost profile, perf/VTune-style) ---
        self.hot_lbl = QLabel()
        self.hot = _mk_table(["PC", "hits", "cycles", "cyc%", "cost", "instruction"],
                             [76, 50, 64, 50, 120, 9999])
        self.tabs.addTab(self._wrap(self.hot_lbl, self.hot), "Hotspots")

        # --- Branches (per-branch-PC taken/not-taken profile) ---
        self.br_lbl = QLabel()
        self.br = _mk_table(["PC", "branch", "target", "hits", "taken", "T%", "bias"],
                            [70, 64, 76, 46, 46, 46, 9999])
        self.tabs.addTab(self._wrap(self.br_lbl, self.br), "Branches")

        # --- Cycle attribution (where the cycles go / why IPC is low) ---
        self.cyc = CycleBreakdown()
        self.tabs.addTab(self.cyc, "Cycles")

        # --- Memory hex/ASCII inspector (follow EIP/ESP) ---
        self.mem = MemoryView()
        self.tabs.addTab(self.mem, "Memory")
        self._bits = 32

    def set_branches(self, insns):
        """Per-branch-PC profile: identify branch instructions and infer taken vs
        not-taken from whether the NEXT retired instruction landed on the parsed
        branch target (direct) or fell through. Indirect/ret count as taken."""
        agg = {}
        n = len(insns)
        for i, it in enumerate(insns):
            mn = it["mnem"]
            cls, _ = disasm.insn_class(mn.split(" ")[0])
            if cls != "branch":
                continue
            e = agg.get(it["pc"])
            if e is None:
                e = {"mn": mn.split(" ")[0], "tgt": "", "hits": 0, "taken": 0}
                agg[it["pc"]] = e
            e["hits"] += 1
            m = re.search(r"0x([0-9a-fA-F]+)", mn)
            tgt = int(m.group(1), 16) if m else None
            if tgt is not None:
                e["tgt"] = f"{tgt:08x}"
            if i + 1 < n:
                nxt = insns[i + 1]["pc"]
                taken = (nxt == tgt) if tgt is not None else (nxt != it["pc"])
                if taken:
                    e["taken"] += 1
        ranked = sorted(agg.items(), key=lambda kv: -kv[1]["hits"])[:300]
        self.br_lbl.setText(f"{len(agg)} branch sites — taken inferred from the next "
                            f"retired PC (direct: == target; indirect/ret: transferred)")
        rows = []
        for pc, e in ranked:
            pct = (100.0 * e["taken"] / e["hits"]) if e["hits"] else 0.0
            nb = max(0, min(10, round(pct / 10)))
            bias = "T" * nb + "·" * (10 - nb)
            rows.append([f"{pc:08x}", e["mn"], e["tgt"] or "—", e["hits"],
                         e["taken"], f"{pct:.0f}", bias])
        _fill(self.br, rows, dim_cols=(0, 2, 3))
        for r in range(self.br.rowCount()):
            it = self.br.item(r, 6)
            if it is not None:
                it.setForeground(QBrush(QColor("#e3b341")))

    def set_bits(self, bits):
        self._bits = bits

    def set_hotspots(self, insns):
        """Per-PC cycle-cost profile (perf-style): aggregate the reconstructed
        instruction lifecycles by PC -> hit count + total cycles occupied; the
        top consumers (often stalled loads/branches) bubble to the top."""
        agg = {}
        total = 0
        for it in insns:
            span = it["c1"] - it["c0"] + 1
            total += span
            e = agg.get(it["pc"])
            if e is None:
                agg[it["pc"]] = [1, span, it["mnem"]]
            else:
                e[0] += 1; e[1] += span
        ranked = sorted(agg.items(), key=lambda kv: -kv[1][1])[:300]
        self.hot_lbl.setText(
            f"{len(agg)} distinct PCs, {total} cycles total — top consumers first "
            f"(cycles = total clocks each PC occupied; stalls inflate it)")
        rows = []
        maxc = ranked[0][1][1] if ranked else 1
        for pc, (hits, cyc, mnem) in ranked:
            pct = (100.0 * cyc / total) if total else 0.0
            bar = "█" * max(1, int(round(12 * cyc / maxc))) if cyc else ""
            rows.append([f"{pc:08x}", hits, cyc, f"{pct:.1f}", bar, mnem])
        _fill(self.hot, rows, dim_cols=(0, 1))
        # colour the cost bar amber
        for r in range(self.hot.rowCount()):
            it = self.hot.item(r, 4)
            if it is not None:
                it.setForeground(QBrush(QColor("#d2a24c")))

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
        self.cyc.ingest(backend)        # accumulate the cycle-attribution breakdown
        # I-cache
        ic = backend.icache()
        self.ic_map.set_lines(ic)
        self.ic_lbl.setText(
            f"{len(ic)} / 256 lines resident ({100*len(ic)//256}% full)  "
            f"— 8 KB, 2-way, 32-byte line, 128 sets")
        rows = []
        for l in ic:
            base = (l.tag << 12) | (l.set << 5)
            # 32 line bytes on two 16-byte rows so nothing is ellipsis-truncated.
            b = [f"{l.data[i]:02x}" for i in range(32)]
            data = " ".join(b[:16]) + "\n" + " ".join(b[16:])
            way = f"{l.way}{'*' if l.lru == l.way else ''}"
            rows.append([l.set, way, f"{l.tag:05x}", f"{base:08x}", data])
        _fill(self.ic, rows, dim_cols=(0, 2, 3))
        self.ic.resizeRowsToContents()

        # D-cache
        dc = backend.dcache()
        self.dc_map.set_lines(dc)
        self.dc_lbl.setText(
            f"{len(dc)} / 256 lines resident ({100*len(dc)//256}% full)  "
            f"— 8 KB, 2-way, 32-byte line, timing model (no data array)")
        rows = []
        for l in dc:
            base = (l.tag << 12) | (l.set << 5)
            way = f"{l.way}{'*' if l.lru == l.way else ''}"
            rows.append([l.set, way, f"{l.tag:05x}", f"{base:08x}"])
        _fill(self.dc, rows, dim_cols=(0, 2))

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


class _HexDump(QWidget):
    """Classic 16-bytes-per-row hex + ASCII dump, painted; highlights the bytes
    at EIP (cyan) and ESP (amber) when they fall in the viewed window."""
    ROW_H = 15

    def __init__(self, parent=None):
        super().__init__(parent)
        self.data = b""
        self.base = 0
        self.eip = 0
        self.esp = 0
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

    def set(self, backend, base, eip, esp):
        rows = max(8, self.height() // self.ROW_H)
        self.base = base & 0xFFFFFFFF
        self.data = backend.mem_read(self.base, rows * 16)
        self.eip = eip
        self.esp = esp
        self.update()

    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0b0f14"))
        p.setFont(_mono(9))
        from PySide6.QtGui import QFontMetrics
        fm = QFontMetrics(p.font())
        cw = fm.horizontalAdvance("0")
        ax = 4
        hx = ax + 9 * cw                    # hex column start
        asc = hx + (16 * 3 + 1) * cw + cw   # ascii column start
        rows = len(self.data) // 16
        for r in range(rows):
            y = r * self.ROW_H
            a = self.base + r * 16
            p.setPen(QColor("#586069"))
            p.drawText(QRect(ax, y, 9 * cw, self.ROW_H), Qt.AlignVCenter | Qt.AlignLeft, f"{a:08x}")
            for c in range(16):
                b = self.data[r * 16 + c]
                addr = a + c
                gap = 1 if c >= 8 else 0
                x = hx + (c * 3 + gap) * cw
                if addr == self.eip or (self.eip <= addr < self.eip + 1):
                    pass
                if self.eip <= addr < self.eip + 4:
                    p.fillRect(QRect(x - 1, y + 1, 2 * cw + 1, self.ROW_H - 2), QColor(40, 70, 90))
                elif self.esp <= addr < self.esp + 4:
                    p.fillRect(QRect(x - 1, y + 1, 2 * cw + 1, self.ROW_H - 2), QColor(80, 64, 24))
                p.setPen(QColor("#c9d1d9" if b else "#3d444d"))
                p.drawText(QRect(x, y, 2 * cw, self.ROW_H), Qt.AlignVCenter | Qt.AlignLeft, f"{b:02x}")
                ch = chr(b) if 32 <= b < 127 else "."
                p.setPen(QColor("#79c0ff" if 32 <= b < 127 else "#3d444d"))
                p.drawText(QRect(asc + c * cw, y, cw, self.ROW_H), Qt.AlignVCenter | Qt.AlignLeft, ch)
        p.end()


class MemoryView(QWidget):
    """Arbitrary-memory hex/ASCII inspector: type an address, or follow EIP/ESP."""
    def __init__(self, parent=None):
        super().__init__(parent)
        self.backend = None
        self.addr = 0x08048000
        self.follow = None        # None | 'eip' | 'esp'
        v = QVBoxLayout(self); v.setContentsMargins(4, 4, 4, 4); v.setSpacing(4)
        bar = QHBoxLayout(); bar.setSpacing(5)
        bar.addWidget(QLabel("addr"))
        self.addr_e = QLineEdit("0x08048000"); self.addr_e.setFixedWidth(96)
        self.addr_e.setFont(_mono(9))
        self.addr_e.returnPressed.connect(self._go)
        bar.addWidget(self.addr_e)
        go = QPushButton("Go"); go.clicked.connect(self._go); bar.addWidget(go)
        be = QPushButton("→EIP"); be.clicked.connect(lambda: self._set_follow("eip")); bar.addWidget(be)
        bs = QPushButton("→ESP"); bs.clicked.connect(lambda: self._set_follow("esp")); bar.addWidget(bs)
        for d, lab in ((-256, "◀"), (256, "▶")):
            b = QPushButton(lab); b.setFixedWidth(28)
            b.clicked.connect(lambda _=0, dd=d: self._page(dd)); bar.addWidget(b)
        self.follow_lbl = QLabel(""); self.follow_lbl.setStyleSheet("color:#8b949e;font-size:8px;")
        bar.addWidget(self.follow_lbl); bar.addStretch(1)
        v.addLayout(bar)
        self.dump = _HexDump()
        v.addWidget(self.dump, 1)

    def _go(self):
        try:
            self.addr = int(self.addr_e.text(), 0) & 0xFFFFFFF0
        except ValueError:
            return
        self.follow = None
        self._refresh()

    def _set_follow(self, which):
        self.follow = which
        if which == "eip":
            self.addr = getattr(self, "_eip", self.addr) & 0xFFFFFFF0
        elif which == "esp":
            self.addr = getattr(self, "_esp", self.addr) & 0xFFFFFFF0
        self._refresh()

    def _page(self, delta):
        self.follow = None
        self.addr = (self.addr + delta) & 0xFFFFFFF0
        self._refresh()

    def set_state(self, backend, state):
        self.backend = backend
        self._eip = state.eip
        self._esp = state.gpr[4]
        if self.follow == "eip":
            self.addr = self._eip & 0xFFFFFFF0
        elif self.follow == "esp":
            self.addr = self._esp & 0xFFFFFFF0
        self._refresh()

    def _refresh(self):
        if self.backend is None:
            return
        self.addr_e.setText(f"0x{self.addr:08x}")
        self.follow_lbl.setText(f"following {self.follow.upper()}" if self.follow else
                                "cyan=EIP  amber=ESP")
        self.dump.set(self.backend, self.addr, getattr(self, "_eip", 0), getattr(self, "_esp", 0))
