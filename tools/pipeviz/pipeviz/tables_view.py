# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Memory-subsystem tables panel — what is resident in the I-cache (code cache),
D-cache, the split I/D TLB, and the slow-path prefetch buffer. Each is a table,
refreshed in full each frame (all are small: <=256 lines / 32 TLB entries)."""
import re
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QTabWidget,
                               QTableWidget, QTableWidgetItem, QHeaderView,
                               QAbstractItemView, QLabel, QGridLayout, QSizePolicy,
                               QLineEdit, QPushButton, QCheckBox,
                               QStyledItemDelegate, QStyle)
from PySide6.QtGui import (QFont, QColor, QBrush, QPainter, QFontMetrics,
                           QPalette, QKeySequence, QRegularExpressionValidator,
                           QShortcut)
from PySide6.QtCore import Qt, QRect, Signal, QRegularExpression

from .backend import DC_SETS, WAYS, LINE

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
    lineHovered = Signal(int, int)
    hoverCleared = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.cells = [(False, False)] * 256   # (valid, is_mru) by idx = set*2+way
        self._line_details = {}
        self._hovered_cell = None
        self.n_valid = 0
        self._base_accessible_description = (
            "No cache lines are resident; all 128 sets and both ways are empty.")
        self.setAccessibleDescription(self._base_accessible_description)
        self.setToolTip("Hover a set/way cell to identify its cache-table row")
        self.setMouseTracking(True)
        self.setFixedHeight(self.TOP + 2 * self.WAYH + self.BOT)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def set_lines(self, lines):
        cells = [(False, False)] * 256
        details = {}
        for l in lines:
            cells[l.set * 2 + l.way] = (True, l.lru == l.way)
            details[(int(l.set), int(l.way))] = (
                int(l.tag), (int(l.tag) << 12) | (int(l.set) << 5),
                int(l.lru) == int(l.way))
        self.cells = cells
        self._line_details = details
        self.n_valid = len(lines)
        occupied = []
        for cache_set in range(self.SETS):
            ways = []
            for way in range(2):
                valid, mru = cells[cache_set * 2 + way]
                if valid:
                    ways.append(
                        f"way {way}{' MRU' if mru else ' resident'}")
            if ways:
                occupied.append(
                    f"set {cache_set}: {', '.join(ways)}")
        if occupied:
            self._base_accessible_description = (
                f"{self.n_valid} of 256 cache line slots resident across "
                f"{len(occupied)} of 128 sets. " + "; ".join(occupied) + ".")
        else:
            self._base_accessible_description = (
                "No cache lines are resident; all 128 sets and both ways are empty.")
        self.setAccessibleDescription(self._base_accessible_description)
        if self._hovered_cell is not None:
            # A live cache refresh can replace the row under a stationary
            # pointer. Clear the transient link rather than retaining stale
            # tag/address text and selection until the mouse moves again.
            self._clear_hover()
        self.update()

    def _cell_at(self, point):
        plot_width = self.width() - self.LX - 4
        if plot_width <= 0 or not (
                self.LX <= point.x() < self.LX + plot_width
                and self.TOP <= point.y() < self.TOP + 2 * self.WAYH):
            return None
        cache_set = min(
            self.SETS - 1,
            int((point.x() - self.LX) * self.SETS / plot_width))
        way = min(1, int((point.y() - self.TOP) / self.WAYH))
        return cache_set, way

    def mouseMoveEvent(self, event):
        cell = self._cell_at(event.position().toPoint())
        if cell is None:
            self._clear_hover()
            return
        cache_set, way = cell
        self._hovered_cell = cell
        detail = self._line_details.get(cell)
        if detail is None:
            text = f"set {cache_set} · way {way} · empty"
        else:
            tag, address, mru = detail
            text = (
                f"set {cache_set} · way {way} · "
                f"{'MRU' if mru else 'resident'} · tag 0x{tag:05x} · "
                f"line 0x{address:08x}")
        self.setToolTip(text)
        self.setAccessibleDescription(
            f"{self._base_accessible_description} Hovered {text}.")
        self.lineHovered.emit(cache_set, way)
        event.accept()

    def _clear_hover(self):
        self._hovered_cell = None
        self.setToolTip("Hover a set/way cell to identify its cache-table row")
        self.setAccessibleDescription(self._base_accessible_description)
        self.hoverCleared.emit()

    def leaveEvent(self, event):
        self._clear_hover()
        super().leaveEvent(event)

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


class _HintTable(QTableWidget):
    """A QTableWidget that paints a centered, muted explanatory hint over its body
    when it has ZERO rows — so an empty cache / TLB / branch table reads as 'no
    activity yet' instead of a blank panel that looks broken or stuck. Mirrors the
    Konata view's existing 'step the core to fill the pipeline view' empty-state.
    The hint is a child label of the viewport, raised + transparent to clicks, so
    it never interferes with row selection once data arrives."""
    def __init__(self, rows, cols, hint=""):
        super().__init__(rows, cols)
        self._hint = QLabel(hint, self.viewport())
        self._hint.setAccessibleName("Empty analysis table explanation")
        self._hint.setAlignment(Qt.AlignCenter)
        self._hint.setWordWrap(True)
        self._hint.setAttribute(Qt.WA_TransparentForMouseEvents)
        self._hint.setStyleSheet("color:#586069; font-style:italic; background:transparent;")
        self._hint.hide()

    def set_hint(self, text):
        self._hint.setText(text)
        self.sync_hint()

    def sync_hint(self):
        if self.rowCount() == 0 and self._hint.text():
            self._hint.setGeometry(0, 0, self.viewport().width(), self.viewport().height())
            self._hint.show(); self._hint.raise_()
            self.setAccessibleDescription(
                f"Empty table. {self._hint.text()}")
        else:
            self._hint.hide()
            self.setAccessibleDescription(
                f"{self.rowCount()} populated "
                f"row{'s' if self.rowCount() != 1 else ''}.")

    def resizeEvent(self, ev):
        super().resizeEvent(ev)
        self._hint.setGeometry(0, 0, self.viewport().width(), self.viewport().height())


def _mk_table(cols, widths=None, hint=""):
    t = _HintTable(0, len(cols), hint)
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
    # The table is born empty.  Do not wait for the first backend refresh to
    # explain that state; this is especially important on the startup screen.
    t.sync_hint()
    return t


def _fill(table, rows, dim_cols=(), right_cols=()):
    table.setRowCount(len(rows))
    for r, row in enumerate(rows):
        for c, v in enumerate(row):
            it = QTableWidgetItem(str(v))
            if c in dim_cols:
                it.setForeground(QBrush(QColor("#8b949e")))
            if c in right_cols:
                # numeric columns right-align so digit places line up for
                # at-a-glance magnitude scanning (the whole job of a profiler table)
                it.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
            table.setItem(r, c, it)
    if isinstance(table, _HintTable):
        table.sync_hint()


_LINE_SHIFT = LINE.bit_length() - 1          # 32B line -> 5
_SET_MASK = DC_SETS - 1                       # 128 sets -> 0x7f


def _dcache_seed_sets(lines=()):
    """Convert session-start resident lines into sets ordered MRU -> LRU.

    ``vv_get_dcache`` returns only valid ways and repeats the set's MRU-way
    index in each record's ``lru`` field.  Keeping that replacement order is
    important after a snapshot restore: starting replay empty would mislabel
    every already-resident line as a cold miss.
    """
    sets = [[] for _ in range(DC_SETS)]
    grouped = {}
    for line in lines:
        if isinstance(line, tuple):
            s, way, tag, mru_way = map(int, line)
        else:
            s, way, tag, mru_way = (
                int(line.set), int(line.way), int(line.tag), int(line.lru))
        if 0 <= s < DC_SETS and 0 <= way < WAYS:
            grouped.setdefault(s, []).append((way, tag, mru_way))
    for s, resident in grouped.items():
        mru_way = resident[0][2]
        resident.sort(key=lambda item: item[0] != mru_way)
        for _way, tag, _mru in resident[:WAYS]:
            if tag not in sets[s]:
                sets[s].append(tag)
    return sets


def _dcache_replay(accs, seed=()):
    """Replay the resolved load/store address stream through a client-side model of
    the real D-cache geometry (DC_SETS sets × WAYS-way × LINE-byte, LRU) and tally
    hit / cold-miss / conflict-evict per access. The hardware (rtl/mem/dcache_timing)
    is exactly this 2-way-LRU model, so the miss-rate is faithful — and it answers a
    question the geometric STRIDE can't: dmiss strides +0x20 = the line size (100%
    miss) while test386 strides +0x2 < the line size (~92% HIT), yet both read
    'stride (100%)'. ``seed`` is session-start residency/LRU, notably from a
    restored snapshot. Returns (accesses, hits, misses, cold, conflict)."""
    sets = _dcache_seed_sets(seed)             # each set: tags, MRU first
    hits = cold = conflict = 0
    for a in accs:
        line = a[2] >> _LINE_SHIFT
        s = line & _SET_MASK
        tag = line >> (_SET_MASK.bit_length())
        ways = sets[s]
        if tag in ways:
            ways.remove(tag); ways.insert(0, tag); hits += 1
        else:
            if len(ways) < WAYS:
                cold += 1
            else:
                conflict += 1; ways.pop()     # evict the LRU way
            ways.insert(0, tag)
    return len(accs), hits, cold + conflict, cold, conflict


def _dcache_per_pc(accs, seed=()):
    """Per-PC (accesses, misses) from the SAME LRU replay, attributing each miss to
    the access's own PC (carried in the tuple, so it's robust to the Konata insns
    rolling window) — so the Hotspots profile can name WHICH load/store PC misses
    (dmiss's `mov eax,[esi]` = 14/14, vs test386's `[eax*4]` 3/17 while `[eax*4+2]`
    0/17), not just how many cycles each PC burned."""
    sets = _dcache_seed_sets(seed)
    stat = {}
    for a in accs:
        line = a[2] >> _LINE_SHIFT
        s = line & _SET_MASK
        tag = line >> (_SET_MASK.bit_length())
        ways = sets[s]
        if tag in ways:
            ways.remove(tag); ways.insert(0, tag); miss = False
        else:
            if len(ways) >= WAYS:
                ways.pop()
            ways.insert(0, tag); miss = True
        e = stat.setdefault(a[5], [0, 0])    # a[5] = the access's own PC
        e[0] += 1; e[1] += 1 if miss else 0
    return stat


def _align_headers(table, cols, align):
    """Align the given header labels so a header caption never sits visually
    divorced from its data: numeric columns right-align (digits line up), glyph-bar
    columns (cost/bias/bar) left-align so the caption sits over its left-pinned bar
    instead of floating centered in the stretched column's empty right half."""
    for c in cols:
        hi = table.horizontalHeaderItem(c)
        if hi is not None:
            hi.setTextAlignment(align | Qt.AlignVCenter)


def _right_align_headers(table, cols):
    _align_headers(table, cols, Qt.AlignRight)


class InsnCellDelegate(QStyledItemDelegate):
    """Field-colours a disassembly table cell (e.g. the Hotspots 'instruction'
    column) so it speaks the SAME palette as the trace + Konata gutter: a neutral
    grey mnemonic, then operands class-coloured — immediate=salmon, displacement
    (inside [..])=gold, branch-target=orange, registers neutral. Reads the cell's
    display text directly ('mnem ops'), so it drops onto any plain-text column."""
    def __init__(self, font, parent=None):
        super().__init__(parent)
        self.font = font

    def paint(self, painter, option, index):
        if option.state & QStyle.State_Selected:
            painter.fillRect(option.rect, option.palette.highlight())
        text = index.data(Qt.DisplayRole) or ""
        if not text:
            return
        parts = text.split(" ", 1)
        mn = parts[0]; ops = parts[1] if len(parts) > 1 else ""
        _, icol = disasm.insn_class(mn)
        painter.save()
        painter.setClipRect(option.rect)
        painter.setFont(self.font)
        fm = QFontMetrics(self.font)
        r = option.rect
        x = r.x() + 4
        painter.setPen(QColor("#828c99"))          # neutral mnemonic (trace _MNEM_GREY)
        painter.drawText(QRect(x, r.y(), r.width() - 8, r.height()),
                         Qt.AlignVCenter | Qt.AlignLeft, mn)
        if ops:
            mw = fm.horizontalAdvance(mn + " ")
            ox, limit = x + mw, r.right() - 4
            is_br = (icol == disasm.CC_BRANCH)
            for txt, col in disasm.operand_segments(ops, is_br, icol):
                if ox >= limit:
                    break
                painter.setPen(QColor(col))
                painter.drawText(QRect(ox, r.y(), limit - ox, r.height()),
                                 Qt.AlignVCenter | Qt.AlignLeft, txt)
                ox += fm.horizontalAdvance(txt)
        painter.restore()


class CycleBreakdown(QWidget):
    """perf/VTune-style attribution of WHERE the cycles go: every cycle is
    classified by the core FSM state into a category (retire / issue-stall /
    mispredict / I-fill / front-end / slow-path / page-walk / x87 / system /
    halt), tallied incrementally, and drawn as %-bars sorted biggest-first.
    Answers 'why is IPC low?' at a glance — the tall bar is the bottleneck."""
    CATS = [("retire", "#3fb950"), ("issue-stall", "#7a828d"),
            ("mispredict", "#f85149"), ("I-fill", "#e0a72e"),
            ("front end", "#39c5cf"), ("slow path", "#f0883e"),
            ("page-walk", "#f778ba"), ("x87 FP", "#bc8cff"),
            ("system", "#e3b341"), ("halt", "#8b949e")]

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setToolTip(
            "Every captured clock is classified once. Front end combines "
            "S_FETCH/S_DECODE; slow path combines integer execute, load/store, "
            "string, and I/O micro-operations.")
        self.backend = None
        self.session_active = False
        self._zero()
        self._sync_accessible_description()

    def set_session_active(self, active):
        self.session_active = bool(active)
        self._sync_accessible_description()
        self.update()

    def _zero(self):
        self._last_cyc = 0
        self.counts = {k: 0 for k, _ in self.CATS}
        self.total_ret = 0

    def reset(self, backend=None):
        self.backend = backend
        self._zero()
        if backend is not None:
            # Restored snapshots retain an absolute clock but no earlier cycle
            # records; attribution intentionally begins after the restore.
            self._last_cyc = int(backend.cycle_count())
        self._sync_accessible_description()
        self.update()

    def _sync_accessible_description(self):
        total = sum(self.counts.values())
        if not total:
            self.setAccessibleDescription(
                "Step the core to attribute cycles."
                if self.session_active else
                "No program loaded; open a program to attribute cycles.")
            return
        ipc = self.total_ret / total
        categories = sorted(
            ((name, count) for name, count in self.counts.items() if count),
            key=lambda item: -item[1])
        detail = "; ".join(
            f"{name} {count} clocks, {100.0 * count / total:.1f} percent"
            for name, count in categories)
        self.setAccessibleDescription(
            f"{total} captured clocks, {self.total_ret} retired, "
            f"IPC {ipc:.3f}. {detail}.")

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
            return "front end"
        if name in (
                "S_LOAD", "S_LOAD2", "S_STORE", "S_EXEC", "S_USEQ",
                "S_ENTER", "S_IO", "S_INS"):
            return "slow path"
        if name == "S_WALK":
            return "page-walk"
        if name in (
                "S_FLOAD", "S_FEXEC", "S_FEXEC_EX", "S_FSTORE",
                "S_FP_BUSY", "S_TRSC_BUSY", "S_FPREM_BUSY",
                "S_FENV_ST", "S_FENV_LD"):
            return "x87 FP"
        if name in ("S_HALT", "S_HLTWAIT", "S_F00F_HANG"):
            return "halt"
        return "system"

    def ingest(self, backend):
        self.backend = backend
        total = backend.cycle_count()
        if total < self._last_cyc:          # backend was reset under us
            self._zero()
        if total <= self._last_cyc:
            return
        while self._last_cyc < total:
            new = backend.get_cycles(self._last_cyc + 1, 8192)
            if not new:
                break
            for c in new:
                self.counts[self._classify(backend.state_name(c.state), c)] += 1
                self.total_ret += (1 if c.retU else 0) + (1 if c.retV else 0)
                self._last_cyc = c.cyc
        self._sync_accessible_description()
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
            message = ("step the core to attribute cycles" if self.session_active else
                       "no program loaded — open a program to attribute cycles")
            p.drawText(self.rect(), Qt.AlignCenter, message)
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
    pcClicked = Signal(int)     # a Hotspots/Branches PC row clicked -> drill to trace

    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        self.tabs = QTabWidget()
        self.tabs.setAccessibleName("Analysis views")
        self.tabs.tabBar().setAccessibleName("Analysis view tabs")
        lay.addWidget(self.tabs)

        # --- I-cache (code). 'way' shows '*' for the MRU way (LRU dropped). ---
        self.ic_lbl = QLabel()
        self.ic_map = CacheMap()
        self.ic = _mk_table(["set", "way *=MRU", "tag", "line addr", "32 line bytes"],
                            [46, 74, 60, 86, 9999],
                            hint="I-cache empty — step the core to fetch code into it")
        self.ic.setAccessibleName("Instruction cache lines")
        self.ic_map.setAccessibleName("Instruction cache occupancy map")
        self.ic_map.lineHovered.connect(
            lambda cache_set, way:
            self._highlight_cache_row(self.ic, cache_set, way))
        self.ic_map.hoverCleared.connect(
            lambda: self._clear_cache_hover(self.ic))
        self.ic.setWordWrap(True)
        self.tabs.addTab(self._wrap(self.ic_lbl, self.ic, self.ic_map), "Code$")
        self.tabs.setTabToolTip(0, "Instruction cache (I$): resident lines and set/way map")

        # --- D-cache (data, timing-only) ---
        self.dc_lbl = QLabel(); self.dc_lbl.setWordWrap(True)
        self.dc_map = CacheMap()
        self.dc = _mk_table(["set", "way *=MRU", "tag", "line addr"],
                            [56, 74, 90, 9999],
                            hint="D-cache empty — this workload has issued no data "
                                 "loads/stores yet")
        self.dc.setAccessibleName("Data cache lines")
        self.dc_map.setAccessibleName("Data cache occupancy map")
        self.dc_map.lineHovered.connect(
            lambda cache_set, way:
            self._highlight_cache_row(self.dc, cache_set, way))
        self.dc_map.hoverCleared.connect(
            lambda: self._clear_cache_hover(self.dc))
        self.tabs.addTab(self._wrap(self.dc_lbl, self.dc, self.dc_map), "Data$")
        self.tabs.setTabToolTip(1, "Data cache (D$): residency and replayed miss rate")

        # --- TLB (I + D) ---
        self.tlb_lbl = QLabel()
        self.tlb = _mk_table(
            ["side", "idx", "V", "page (4K/4M)", "vpn->pfn", "perm U/W/P", "big", "D"],
            [44, 40, 30, 110, 150, 90, 40, 9999],
            hint="TLB empty — paging is off or no translations have been resolved yet")
        self.tlb.setAccessibleName("Translation lookaside buffer entries")
        self.tabs.addTab(self._wrap(self.tlb_lbl, self.tlb), "TLB")
        self.tabs.setTabToolTip(2, "Instruction and data translation lookaside buffers")

        # --- Prefetch buffer (ibuf) ---
        self.pf = _PrefetchView()
        self.pf.setAccessibleName("Prefetch and decode state")
        self.tabs.addTab(self.pf, "Prefetch")
        self.tabs.setTabToolTip(3, "Prefetch buffer, fetch window, and live decode")

        # --- Hotspots (per-PC cycle-cost profile, perf/VTune-style) ---
        self.hot_lbl = QLabel()
        self.hot = _mk_table(
            ["PC", "hits", "Σ lat", "share", "D$ miss/access", "Σlat bar",
             "instruction"],
                             [76, 50, 64, 50, 86, 100, 9999],
                             hint="no instructions retired yet — step the core")
        self.hot.setAccessibleName("Instruction hotspots")
        self.hot.horizontalHeaderItem(2).setToolTip(
            "Sum of each dynamic instruction's fetch-to-retire latency at this PC; "
            "a held instruction may be waiting on an older operation")
        self.hot.horizontalHeaderItem(3).setToolTip(
            "Share of all summed instruction latency (overlapping instructions count separately)")
        self.hot.horizontalHeaderItem(4).setToolTip(
            "Replay-estimated D-cache misses / explicit memory accesses "
            "attributed to this instruction PC")
        self.hot.horizontalHeaderItem(5).setToolTip(
            "Visual bar normalized to the largest Σ latency among visible PCs")
        # field-colour the instruction column to match the trace / Konata gutter
        self.hot.setItemDelegateForColumn(6, InsnCellDelegate(_mono(), self.hot))
        _right_align_headers(self.hot, (1, 2, 3, 4))  # hits/cycles/cyc%/D$miss match data
        _align_headers(
            self.hot, (5,), Qt.AlignLeft)  # caption sits over its left-pinned bar
        self.tabs.addTab(self._wrap(self.hot_lbl, self.hot), "Hotspots")
        self.tabs.setTabToolTip(
            4, "Per-PC summed latency and attributed D-cache misses")

        # --- Branches (per-branch-PC observed taken/not-taken profile) ---
        self.br_lbl = QLabel()
        self.br = _mk_table(
            ["PC", "branch", "target", "hits", "taken/resolved", "taken %",
             "bias bar"],
                            [70, 64, 76, 46, 100, 64, 9999],
                            hint="no branches retired yet — step the core through a "
                                 "jump/call/loop")
        self.br.setAccessibleName("Branch behavior")
        self.br.horizontalHeaderItem(4).setToolTip(
            "Taken outcomes / resolved outcomes; capture-tail hits may be unresolved")
        self.br.horizontalHeaderItem(5).setToolTip(
            "100 × taken / resolved outcomes; unresolved capture-tail hits "
            "are excluded")
        self.br.horizontalHeaderItem(6).setToolTip(
            "Ten-slot taken-rate bar: each T represents one taken decile")
        _right_align_headers(self.br, (3, 4, 5))     # hits / T-resolved / T% match data
        _align_headers(
            self.br, (6,), Qt.AlignLeft)  # caption sits over its left-pinned bar
        self.tabs.addTab(self._wrap(self.br_lbl, self.br), "Branches")
        self.tabs.setTabToolTip(
            5, "Per-branch target, hit count, resolved taken rate, and bias")

        # --- Instruction mix (class histogram + U/V issue-port split) ---
        self.mix_lbl = QLabel()
        self.mix = _mk_table(
            ["class", "count", "%", "bar"], [88, 60, 56, 9999],
            hint="no instructions retired yet — step the core")
        self.mix.setAccessibleName("Instruction mix")
        _align_headers(self.mix, (3,), Qt.AlignLeft)  # 'bar' sits over its left-pinned bar
        self.tabs.addTab(self._wrap(self.mix_lbl, self.mix), "Mix")
        self.tabs.setTabToolTip(6, "Instruction-class mix and U/V issue split")

        # --- Cycle attribution (where the cycles go / why IPC is low) ---
        self.cyc = CycleBreakdown()
        self.cyc.setAccessibleName("Cycle attribution")
        self.tabs.addTab(self.cyc, "Cycles")
        self.tabs.setTabToolTip(7, "Cycle attribution: retire, stalls, fills, walks, and system")

        # --- Memory hex/ASCII inspector (follow EIP/ESP) ---
        self.mem = MemoryView()
        self.mem.setAccessibleName("Physical memory inspector")
        self.tabs.addTab(self.mem, "Memory")
        self.tabs.setTabToolTip(8, "Hex/ASCII memory inspector with EIP, ESP, and access following")

        # --- Memory-access map (address-vs-sequence scatter / access pattern) ---
        self.accmap = AccessMap()
        amw = QWidget(); amv = QVBoxLayout(amw); amv.setContentsMargins(4, 4, 4, 4)
        self.accmap_lbl = QLabel(
            "explicit memory operands — effective offset vs retire order")
        self.accmap_lbl.setStyleSheet("color:#8b949e;")
        amv.addWidget(self.accmap_lbl); amv.addWidget(self.accmap, 1)
        self.tabs.addTab(amw, "Mem map")
        self.tabs.setTabToolTip(9, "Load/store address versus retirement-order scatter")
        # a Mem-map point click also pins the Memory tab to that access's bytes (no
        # forced tab switch — switch to Memory to see exactly what the load/store hit).
        self.accmap.accessClicked.connect(self.mem.goto_access)
        self.accmap.accessUnavailable.connect(self.mem.clear_clicked_access)
        # drill-down: clicking a Hotspots / Branches row jumps the trace to that PC.
        self.hot.cellClicked.connect(lambda r, _c: self._emit_pc(self.hot, r))
        self.br.cellClicked.connect(lambda r, _c: self._emit_pc(self.br, r))
        # QTableWidget emits cellActivated for Enter/Return and double-click.
        # Keep the single-click path above, while making drill-down keyboard
        # accessible for users navigating rows with the arrow keys.
        self.hot.cellActivated.connect(lambda r, _c: self._emit_pc(self.hot, r))
        self.br.cellActivated.connect(lambda r, _c: self._emit_pc(self.br, r))
        self._bits = 32
        self._activity_hints = {
            self.ic: "I-cache empty — step the core to fetch code into it",
            self.dc: "D-cache empty — this workload has issued no data loads/stores yet",
            self.tlb: "TLB empty — paging is off or no translations have been resolved yet",
            self.hot: "no instructions retired yet — step the core",
            self.br: "no branches retired yet — step the core through a jump/call/loop",
            self.mix: "no instructions retired yet — step the core",
        }
        self._session_active = False
        self._dcache_seed = []
        self.set_session_active(False)

    def set_session_active(self, active):
        """Distinguish 'nothing loaded' from a real, currently empty structure."""
        self._session_active = bool(active)
        if active:
            for table, hint in self._activity_hints.items():
                table.set_hint(hint)
        else:
            message = "no program loaded — use File → Open example or Ctrl+O"
            for table in self._activity_hints:
                table.set_hint(message)
            for label in (self.ic_lbl, self.dc_lbl, self.tlb_lbl,
                          self.hot_lbl, self.br_lbl, self.mix_lbl):
                label.setText("No program loaded")
        self.pf.set_session_active(active)
        self.cyc.set_session_active(active)
        self.mem.set_session_active(active)
        self.accmap.set_session_active(active)

    def start_session(self, backend):
        """Reset every analysis accumulator before exposing a fresh model.

        Comparing clock numbers is insufficient for snapshots: a newly restored
        model can start at a larger clock than the previous session.
        """
        self.set_session_active(True)
        # A reset starts empty, while a restored snapshot may already contain
        # valid tags. Freeze primitive metadata at the visible-session boundary
        # so later live-cache updates cannot move replay's starting point.
        self._dcache_seed = [
            (int(line.set), int(line.way), int(line.tag), int(line.lru))
            for line in backend.dcache()
        ]
        self.cyc.reset(backend)
        self.mem.start_session()
        self.accmap.set_accesses([])

    def _emit_pc(self, table, row):
        it = table.item(row, 0)   # the PC column holds an 8-hex-digit address
        if it is not None:
            try:
                self.pcClicked.emit(int(it.text(), 16))
            except ValueError:
                pass

    def clear_linked_selection(self):
        """Clear historical drill-down cues while retaining analysis data."""
        self.accmap.clear_selection()
        self.mem.clear_clicked_access()

    _CLS_COLOR = {"branch": disasm.CC_BRANCH, "fp": disasm.CC_FP, "mem": disasm.CC_MEM,
                  "alu": disasm.CC_ALU, "sys": disasm.CC_SYS, "other": disasm.CC_OTHER}

    def set_instr_mix(self, insns):
        """Histogram of retired instructions by class (branch/fp/mem/alu/sys) with
        %-bars, plus the U/V issue-port split (a proxy for realised dual-issue)."""
        cls, pipe = {}, {"U": 0, "V": 0}
        for it in insns:
            name = disasm.insn_class(it["mnem"].split(" ")[0])[0]
            cls[name] = cls.get(name, 0) + 1
            if it["pipe"] in pipe:
                pipe[it["pipe"]] += 1
        total = sum(cls.values())
        self.mix.setRowCount(0)
        if total == 0:
            self.mix_lbl.setText("no instructions yet")
            self.mix.sync_hint()
            return
        maxc = max(cls.values())
        order = sorted(cls.items(), key=lambda kv: -kv[1])
        self.mix.setRowCount(len(order))
        self.mix.sync_hint()
        for r, (name, n) in enumerate(order):
            bar = "█" * max(1, round(14 * n / maxc))
            for c, v in enumerate([name, str(n), f"{100 * n / total:.1f}%", bar]):
                it = QTableWidgetItem(v)
                if c == 0:
                    it.setForeground(QBrush(QColor(self._CLS_COLOR.get(name, "#c9d1d9"))))
                elif c == 1:
                    it.setForeground(QBrush(QColor("#8b949e")))
                elif c == 3:
                    it.setForeground(QBrush(QColor("#d2a24c")))
                self.mix.setItem(r, c, it)
        u, v = pipe["U"], pipe["V"]
        self.mix_lbl.setText(
            f"{total} retired   ·   U-port {u}   V-port {v}   ·   "
            f"{100 * v / total:.0f}% via the V-port (realised dual-issue)")

    def set_branches(self, insns):
        """Per-branch-PC profile: identify branch instructions and infer taken vs
        not-taken from whether the NEXT retired instruction landed on the parsed
        branch target (direct) or fell through. Indirect/ret count as taken.
        A branch at the capture tail has no next retired PC yet, so its hit is
        visible but deliberately excluded from the outcome denominator."""
        agg = {}
        n = len(insns)
        for i, it in enumerate(insns):
            mn = it["mnem"]
            cls, _ = disasm.insn_class(mn.split(" ")[0])
            if cls != "branch":
                continue
            e = agg.get(it["pc"])
            if e is None:
                e = {"mn": mn.split(" ")[0], "tgt": "", "hits": 0,
                     "resolved": 0, "taken": 0}
                agg[it["pc"]] = e
            e["hits"] += 1
            m = re.search(r"0x([0-9a-fA-F]+)", mn)
            tgt = int(m.group(1), 16) if m else None
            if tgt is not None:
                e["tgt"] = f"{tgt:08x}"
            if i + 1 < n:
                e["resolved"] += 1
                nxt = insns[i + 1]["pc"]
                taken = (nxt == tgt) if tgt is not None else (nxt != it["pc"])
                if taken:
                    e["taken"] += 1
        ranked = sorted(agg.items(), key=lambda kv: -kv[1]["hits"])[:300]
        hits = sum(e["hits"] for e in agg.values())
        resolved = sum(e["resolved"] for e in agg.values())
        self.br_lbl.setText(
            f"{len(agg)} branch site{'' if len(agg) == 1 else 's'} · "
            f"{resolved}/{hits} outcomes resolved from the next retired PC "
            f"— an unresolved capture-tail branch is excluded from T%")
        rows = []
        for pc, e in ranked:
            pct = (100.0 * e["taken"] / e["resolved"]) if e["resolved"] else 0.0
            nb = max(0, min(10, round(pct / 10)))
            bias = "T" * nb + "·" * (10 - nb)
            rows.append([f"{pc:08x}", e["mn"], e["tgt"] or "—", e["hits"],
                         f"{e['taken']}/{e['resolved']}", f"{pct:.0f}", bias])
        _fill(self.br, rows, dim_cols=(0, 2, 3), right_cols=(3, 4, 5))
        for r in range(self.br.rowCount()):
            it = self.br.item(r, 6)
            if it is not None:
                it.setForeground(QBrush(QColor("#e3b341")))

    def set_bits(self, bits):
        self._bits = bits

    def set_hotspots(self, insns, accesses=(), captured_span=None):
        """Per-PC cycle-cost profile (perf-style): aggregate the reconstructed
        instruction lifecycles by PC -> hit count + total cycles occupied; the
        top consumers (often stalled loads/branches) bubble to the top. The
        'D$ miss' column attributes the replayed D-cache misses to each PC (red when
        a load/store PC misses heavily) so the missing load is named, not just costly."""
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
        miss_by_pc = (
            _dcache_per_pc(accesses, self._dcache_seed) if accesses else {})
        retired_span = (
            max(it["c1"] for it in insns) - min(it["c0"] for it in insns) + 1
            if insns else 0)
        captured_span = max(0, int(captured_span or retired_span))
        self.hot_lbl.setText(
            f"{len(agg)} distinct PC{'' if len(agg) == 1 else 's'} · "
            f"Σ latency {total} instruction-cycles · retired span "
            f"{retired_span}/{captured_span} captured cycles "
            f"— overlap counts separately")
        self.hot_lbl.setToolTip(
            "Σ latency sums fetch-to-retire time for retired instructions. "
            f"Their visible lifecycle span covers {retired_span} of "
            f"{captured_span} captured cycles; an in-flight tail is not yet "
            "attributed. Overlapping instructions count separately, and stalls "
            "inflate their held latency.")
        rows = []
        maxc = ranked[0][1][1] if ranked else 1
        for pc, (hits, cyc, mnem) in ranked:
            pct = (100.0 * cyc / total) if total else 0.0
            bar = "█" * max(1, int(round(12 * cyc / maxc))) if cyc else ""
            ma = miss_by_pc.get(pc)
            miss = f"{ma[1]}/{ma[0]}" if ma else ""    # D$ misses / accesses for a mem PC
            rows.append([f"{pc:08x}", hits, cyc, f"{pct:.1f}%", miss, bar, mnem])
        _fill(self.hot, rows, dim_cols=(0, 1), right_cols=(1, 2, 3, 4))
        for r, (pc, _e) in enumerate(ranked):
            cb = self.hot.item(r, 5)                   # cost bar -> amber
            if cb is not None:
                cb.setForeground(QBrush(QColor("#d2a24c")))
            ma = miss_by_pc.get(pc)                     # D$ miss -> colour by miss-rate
            mi = self.hot.item(r, 4)
            if ma and ma[0] and mi is not None:
                rate = ma[1] / ma[0]
                mi.setForeground(QBrush(QColor(
                    "#f85149" if rate >= 0.5 else ("#d29922" if rate > 0 else "#3fb950"))))

    def _wrap(self, label, table, cmap=None):
        w = QWidget(); v = QVBoxLayout(w); v.setContentsMargins(4, 4, 4, 4)
        label.setStyleSheet("color:#8b949e;")
        v.addWidget(label)
        if cmap is not None:
            v.addWidget(cmap)
        v.addWidget(table)
        return w

    @staticmethod
    def _highlight_cache_row(table, cache_set, way):
        for row in range(table.rowCount()):
            set_item = table.item(row, 0)
            way_item = table.item(row, 1)
            if set_item is None or way_item is None:
                continue
            if (set_item.text() == str(cache_set)
                    and way_item.text().rstrip("*") == str(way)):
                table.setCurrentCell(row, 0)
                table.selectRow(row)
                table.scrollToItem(
                    set_item, QAbstractItemView.PositionAtCenter)
                return
        TablesView._clear_cache_hover(table)

    @staticmethod
    def _clear_cache_hover(table):
        table.clearSelection()
        table.setCurrentCell(-1, -1)

    def update_from(self, backend, state):
        if not self._session_active:
            self.set_session_active(True)
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
            f"{len(dc)}/256 lines ({100*len(dc)//256}%) · "
            "8 KB, 2-way × 32 B · timing only")
        self.dc_lbl.setToolTip(
            "Resident D-cache tags and replacement state. The RTL model has "
            "no data array; inspect bytes in Memory.")
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

    def set_dcache_replay(self, accs):
        """Append the replayed D-cache miss-rate (the resolved access stream run
        through the real 2-way-LRU geometry) to the Data$ header — the hit/miss
        OUTCOME that the resident-line snapshot and the Mem-map geometric stride
        never report. Re-appends each frame onto the residency text update_from just
        set, so it never accumulates."""
        n, _hits, miss, cold, conflict = _dcache_replay(
            accs, self._dcache_seed)
        if n:
            origin = f"seed {len(self._dcache_seed)}" if self._dcache_seed else "empty"
            origin_detail = (
                f"Replay began from {len(self._dcache_seed)} resident "
                "session-start lines and their MRU order."
                if self._dcache_seed
                else "Replay began from an empty session-start cache.")
            self.dc_lbl.setText(
                self.dc_lbl.text() +
                f" · replay [{origin}] {round(100 * miss / n)}% miss ({miss}/{n})")
            self.dc_lbl.setToolTip(
                self.dc_lbl.toolTip() + "\n"
                f"{n} replayed accesses: {_hits} hits, {cold} cold fills, "
                f"{conflict} conflict evictions. {origin_detail}")


class _PrefetchView(QWidget):
    """The slow-path 16-byte prefetch buffer (ibuf) + the fast-path fetch window
    (flin / eip). Shows the raw bytes and a tentative decode."""
    def __init__(self, parent=None):
        super().__init__(parent)
        # QTabWidget pages do not inherit the application's QPalette.Window brush
        # reliably on every Qt platform/style.  An unpainted page consequently used
        # the Fusion default medium grey while every custom Pipeviz canvas is nearly
        # black.  Give this page an explicit, palette-aware canvas (rather than a
        # descendant-wide stylesheet that would also flatten the byte-cell colours).
        palette = self.palette()
        palette.setColor(QPalette.Window, QColor("#0d1117"))
        self.setPalette(palette)
        self.setAutoFillBackground(True)
        v = QVBoxLayout(self); v.setContentsMargins(8, 8, 8, 8)
        self.info = QLabel(); self.info.setStyleSheet("color:#8b949e;")
        self.info.setAccessibleName("Prefetch address state")
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
            b.setAccessibleName(f"Prefetch buffer byte {i}")
            b.setStyleSheet("background:#161b22; border:1px solid #30363d; padding:4px;")
            grid.addWidget(b, 1, i)
            self.byte_lbls.append(b)
        v.addWidget(gw)
        self.decode = QLabel(); self.decode.setFont(_mono(10))
        self.decode.setAccessibleName("Prefetch buffer decode")
        self.decode.setWordWrap(True)
        v.addWidget(self.decode)
        v.addStretch(1)
        self.set_session_active(False)

    def set_session_active(self, active):
        if active:
            return
        self.info.setText("No program loaded")
        for byte in self.byte_lbls:
            byte.setText("—")
            byte.setStyleSheet(
                "color:#586069;background:#161b22;border:1px solid #30363d;padding:4px;")
        self.decode.setText(
            "<i>Open a program to inspect its slow-path prefetch buffer.</i>")
        self.decode.setStyleSheet("color:#586069;")
        self.setAccessibleDescription(
            "No program loaded. Open a program to inspect its slow-path "
            "prefetch buffer.")

    def update_from(self, s, bits):
        self.info.setText(
            f"flin (linear fetch addr) = 0x{s.flin:08x}    eip = 0x{s.eip:08x}    "
            f"fetch_word = {s.fetch_word}")
        ib = bytes(s.ibuf[i] for i in range(16))
        for i in range(16):
            self.byte_lbls[i].setText(f"{ib[i]:02x}")
            self.byte_lbls[i].setStyleSheet(
                "background:#161b22;border:1px solid #30363d;padding:4px;")
        if not any(ib):
            # An all-zero ibuf is the IDLE slow-path buffer — the core is on the fast
            # dual-issue path, fetching straight from the I-cache, so the slow-path
            # decoder is not engaged. Decoding the zeros would render the classic
            # `00 00` -> `add byte ptr [eax], al` artifact and falsely label it
            # '@ eip', contradicting the real instruction at eip (shown in Memory).
            self.decode.setText(
                "<i>ibuf idle — fast-path fetch from the I-cache; "
                "slow-path decoder not engaged</i>")
            self.decode.setStyleSheet("color:#6e7681;")
            decode_state = (
                "Buffer idle; fast-path fetch from the instruction cache, "
                "slow-path decoder not engaged.")
        else:
            txt, sz = disasm.text(ib, s.eip, bits)
            self.decode.setText(f"ibuf decode @ eip:  <b>{txt}</b>  ({sz} bytes)")
            self.decode.setStyleSheet("color:#c9d1d9;")
            decode_state = (
                f"Buffer decodes at EIP as {txt}, {sz} "
                f"byte{'s' if sz != 1 else ''}.")
        self.setAccessibleDescription(
            f"Linear fetch address 0x{int(s.flin):08x}; "
            f"EIP 0x{int(s.eip):08x}; fetch word {int(s.fetch_word)}. "
            f"Sixteen buffer bytes: {' '.join(f'{byte:02x}' for byte in ib)}. "
            f"{decode_state}")


class _HexDump(QWidget):
    """Classic 16-bytes-per-row hex + ASCII dump, painted; highlights the bytes
    at EIP (cyan fill) and ESP (amber fill), and the most-recent load/store ACCESS
    (gold outline + its exact byte span) when they fall in the viewed window."""
    ROW_H = 15

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAccessibleName("Physical memory hex and ASCII dump")
        self.data = b""
        self.base = 0
        self.eip = 0
        self.esp = 0
        self.acc_addr = None     # (start) of the most-recent memory access
        self.acc_size = 0
        self.message = ""
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

    def clear(self, message=""):
        self.data = b""
        self.message = message
        self.setAccessibleDescription(
            message or "No physical memory bytes are displayed.")
        self.update()

    def set(self, backend, base, eip, esp, access=None):
        rows = max(8, self.height() // self.ROW_H)
        self.base = base & 0xFFFFFFFF
        self.data = backend.mem_read(self.base, rows * 16)
        self.eip = eip
        self.esp = esp
        self.acc_addr, self.acc_size = access if access else (None, 0)
        self.message = ""
        end = (self.base + max(0, len(self.data) - 1)) & 0xFFFFFFFF
        parts = [
            f"Physical memory bytes 0x{self.base:08x} through 0x{end:08x}."]
        visible_end = self.base + len(self.data)
        if self.base <= self.eip < visible_end:
            parts.append(f"EIP marker at 0x{self.eip:08x}.")
        if self.base <= self.esp < visible_end:
            parts.append(f"ESP marker at 0x{self.esp:08x}.")
        if (self.acc_addr is not None
                and self.base <= self.acc_addr < visible_end):
            parts.append(
                f"Access marker at 0x{self.acc_addr:08x}, "
                f"{self.acc_size} byte{'s' if self.acc_size != 1 else ''}.")
        for offset in range(0, len(self.data), 16):
            row = self.data[offset:offset + 16]
            address = (self.base + offset) & 0xFFFFFFFF
            hex_bytes = " ".join(f"{byte:02x}" for byte in row)
            ascii_bytes = "".join(
                chr(byte) if 32 <= byte < 127 else "." for byte in row)
            parts.append(
                f"0x{address:08x}: {hex_bytes}; ASCII {ascii_bytes}.")
        self.setAccessibleDescription(" ".join(parts))
        self.update()

    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0b0f14"))
        p.setFont(_mono(9))
        if not self.data and self.message:
            p.setPen(QColor("#586069"))
            p.drawText(self.rect(), Qt.AlignCenter, self.message)
            p.end()
            return
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
                if self.eip <= addr < self.eip + 4:
                    p.fillRect(QRect(x - 1, y + 1, 2 * cw + 1, self.ROW_H - 2), QColor(40, 70, 90))
                elif self.esp <= addr < self.esp + 4:
                    p.fillRect(QRect(x - 1, y + 1, 2 * cw + 1, self.ROW_H - 2), QColor(80, 64, 24))
                # the most-recent memory ACCESS: a gold outline over its exact byte
                # span (the load/store the program just made), distinct from the EIP/
                # ESP fills so the three never read as the same marker.
                if self.acc_addr is not None and self.acc_addr <= addr < self.acc_addr + self.acc_size:
                    p.setPen(QColor("#e3b341"))
                    p.drawRect(QRect(x - 1, y + 1, 2 * cw, self.ROW_H - 3))
                p.setPen(QColor("#c9d1d9" if b else "#3d444d"))
                p.drawText(QRect(x, y, 2 * cw, self.ROW_H), Qt.AlignVCenter | Qt.AlignLeft, f"{b:02x}")
                ch = chr(b) if 32 <= b < 127 else "."
                p.setPen(QColor("#79c0ff" if 32 <= b < 127 else "#3d444d"))
                p.drawText(QRect(asc + c * cw, y, cw, self.ROW_H), Qt.AlignVCenter | Qt.AlignLeft, ch)
        p.end()


class AccessMap(QWidget):
    """Address-vs-sequence SCATTER of the program's memory accesses — one point per
    retired load/store (X = retire order n, Y = effective address with low at the
    bottom), loads blue / stores gold. Reveals the ACCESS PATTERN as a SHAPE that the
    per-row trace address list can't: a strided walk is a straight diagonal, a hot
    location is a horizontal band, random access scatters. CLICKING a point reads out
    its n/cyc/address/kind and emits `pointSelected(n)` to jump the trace to that
    instruction — so an outlier or a stripe is one click from its source row. Pure
    client-side from the trace's already-resolved effective addresses."""
    pointSelected = Signal(int)     # retire-n of the clicked access -> drill to trace
    accessClicked = Signal(int, int)  # (addr, size) of the clicked access -> Memory tab
    accessUnavailable = Signal()    # selected access has no physical translation

    def __init__(self, parent=None):
        super().__init__(parent)
        # (n, cyc, effective offset, is_store, size, pc, linear, physical)
        self.accesses = []
        self.sel_n = None           # retire-n of the clicked access (a STABLE identity,
                                    # so the selection survives the trace's rolling cap
                                    # dropping older accesses off the front of the list)
        self._pts = []              # cached [(px, py, idx)] from the last paint, for hit-test
        self.session_active = False
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.NoFocus)
        self.setAccessibleName("Memory access map")
        self.setAccessibleDescription(
            "Address versus retirement scatter. Use Left and Right to traverse "
            "accesses; Enter opens the selected retirement and physical bytes.")
        self.setToolTip(
            "Click a point or use ←/→, Page Up/Down, Home/End to select an "
            "access. Enter/Space reopens its Trace row and physical Memory bytes.")
        self._sync_accessible_description()

    def set_session_active(self, active):
        self.session_active = bool(active)
        self._sync_accessible_description()
        self.update()

    def set_accesses(self, accs):
        if accs is not self.accesses:
            self.sel_n = None        # a fresh stream invalidates the selection
        self.accesses = accs
        # Keep an empty scatter out of the Tab order. It becomes a keyboard
        # control as soon as there is a point arrows can actually traverse.
        self.setFocusPolicy(Qt.StrongFocus if accs else Qt.NoFocus)
        self._sync_accessible_description()
        self.update()

    def clear_selection(self):
        self.sel_n = None
        self._sync_accessible_description()
        self.update()

    def _sync_accessible_description(self):
        navigation = (
            "Use Left and Right or Up and Down, Page Up and Page Down, Home "
            "and End to select an access; Enter opens its retirement and "
            "physical bytes.")
        if not self.accesses:
            state = (
                "No memory accesses captured."
                if self.session_active else "No program loaded.")
            self.setAccessibleDescription(f"{state} {navigation}")
            return
        loads = sum(1 for access in self.accesses if not access[3])
        stores = len(self.accesses) - loads
        selected = self._sel_idx()
        context = (
            f"{len(self.accesses)} accesses: {loads} loads and {stores} stores.")
        if selected is not None:
            access = self.accesses[selected]
            physical = access[7] if len(access) > 7 else access[2]
            context += (
                f" Selected retirement n={int(access[0])}, cycle "
                f"{int(access[1])}, {'store' if access[3] else 'load'}, "
                f"effective address 0x{int(access[2]):08x}")
            context += (
                ", untranslated."
                if physical is None else
                f", physical address 0x{int(physical):08x}.")
        self.setAccessibleDescription(f"{context} {navigation}")

    def focusInEvent(self, event):
        super().focusInEvent(event)
        self.update()

    def focusOutEvent(self, event):
        super().focusOutEvent(event)
        self.update()

    def _sel_idx(self):
        """Current index of the selected access (by its stable retire-n), or None if
        it's been dropped off the front by the rolling cap / never set."""
        if self.sel_n is None:
            return None
        for i, a in enumerate(self.accesses):
            if a[0] == self.sel_n:
                return i
        return None

    def paintEvent(self, _ev):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0b0f14"))
        W, H = self.width(), self.height()
        accs = self.accesses
        self._pts = []
        if not accs:
            p.setPen(QColor("#586069")); p.setFont(_mono(10))
            message = ("no memory accesses yet — step a workload that loads/stores"
                       if self.session_active else
                       "no program loaded — open a program to inspect memory accesses")
            p.drawText(self.rect(), Qt.AlignCenter, message)
            if self.hasFocus():
                p.setPen(QColor("#1f6feb"))
                p.drawRect(self.rect().adjusted(0, 0, -1, -1))
            p.end(); return
        ns = [a[0] for a in accs]; addrs = [a[2] for a in accs]
        n0, n1 = min(ns), max(ns); a0, a1 = min(addrs), max(addrs)
        nspan = max(1, n1 - n0); aspan = max(1, a1 - a0)
        nloads = sum(1 for a in accs if not a[3]); nstores = len(accs) - nloads
        # dominant access STRIDE (mode of the consecutive-access deltas) — surfaces a
        # strided walk numerically, which the scatter's slope shows only as a shape;
        # e.g. dmiss strides +0x20 = exactly the 32-byte cache line, so every access
        # misses. Shown only when one delta clearly dominates, else "irregular".
        stride_str = ""
        if len(addrs) >= 2:
            deltas = [addrs[i + 1] - addrs[i] for i in range(len(addrs) - 1)]
            freq = {}
            for d in deltas:
                freq[d] = freq.get(d, 0) + 1
            mode = max(freq, key=freq.get); pct = round(100 * freq[mode] / len(deltas))
            stride_str = (f" · stride {'+' if mode >= 0 else '-'}0x{abs(mode):x} ({pct}%)"
                          if pct >= 40 else " · irregular stride")
        si = self._sel_idx()         # resolve the stable sel_n to a current index
        hf = _mono(8); hf.setBold(True)
        p.setPen(QColor("#8b949e")); p.setFont(hf)
        if si is not None:
            sn, scy, sa, sst = accs[si][:4]
            physical = accs[si][7] if len(accs[si]) > 7 else sa
            mapped = (
                " · untranslated"
                if physical is None else
                f" → phys {physical:08x}" if physical != sa else "")
            p.setPen(QColor("#e3b341" if sst else "#79c0ff"))
            p.drawText(QRect(4, 1, W - 8, 15), Qt.AlignVCenter | Qt.AlignLeft,
                       f"selected  n={sn} cyc={scy} @{sa:08x} {'store' if sst else 'load'}"
                       f"{mapped}   ·   {len(accs)} accesses · "
                       f"0x{a0:x}..0x{a1:x}{stride_str}")
        else:
            p.drawText(QRect(4, 1, W - 8, 15), Qt.AlignVCenter | Qt.AlignLeft,
                       f"{len(accs)} accesses · 0x{a0:x}..0x{a1:x}{stride_str} · "
                       f"loads={nloads} stores={nstores}   [blue=load · gold=store · click]")
        L, R, T, B = 76, 8, 20, 16
        pw, ph = max(1, W - L - R), max(1, H - T - B)
        def yof(addr): return T + ph - int((addr - a0) * ph / aspan)
        def xof(n): return L + int((n - n0) * pw / nspan)
        p.setFont(_mono(7))
        for k in range(5):
            av = a0 + aspan * k // 4
            y = yof(av)
            p.setPen(QColor("#1c232b")); p.drawLine(L, y, W - R, y)
            p.setPen(QColor("#6e7681"))
            # the bottom-most label, centred on its gridline, would drop INTO the x-tick
            # row and collide with the leftmost 'n' tick at the origin — sit it just ABOVE
            # its gridline instead (the others keep their centred placement).
            ly = (y - 12) if k == 0 else (y - 6)
            p.drawText(QRect(0, ly, L - 4, 12), Qt.AlignVCenter | Qt.AlignRight, f"{av:08x}")
        for k in range(5):
            nv = n0 + nspan * k // 4
            x = xof(nv)
            p.setPen(QColor("#6e7681"))
            # left-align the leftmost tick from the axis (not centred on it) so 'n0' clears
            # the y-axis label gutter / origin point instead of overlapping them.
            if k == 0:
                p.drawText(QRect(x + 2, H - B + 1, 48, 12), Qt.AlignLeft | Qt.AlignTop, f"n{nv}")
            else:
                p.drawText(QRect(x - 24, H - B + 1, 48, 12), Qt.AlignHCenter | Qt.AlignTop, f"n{nv}")
        # Keep ordinary traces individually legible without turning long,
        # dense captures into a solid ribbon. The pointer hit radius below is
        # deliberately larger than either painted footprint.
        point_radius = 2 if len(accs) <= 256 else 1
        for i, a in enumerate(accs):
            n, addr, st = a[0], a[2], a[3]
            px, py = xof(n), yof(addr)
            self._pts.append((px, py, i))
            p.fillRect(
                QRect(px - point_radius, py - point_radius,
                      2 * point_radius + 1, 2 * point_radius + 1),
                QColor("#e3b341") if st else QColor("#79c0ff"))
        # selection crosshair ring on top
        if si is not None:
            sa = accs[si]
            px, py = xof(sa[0]), yof(sa[2])
            p.setPen(QColor("#f0f0f0"))
            p.drawLine(L, py, W - R, py); p.drawLine(px, T, px, T + ph)
            p.drawEllipse(px - 4, py - 4, 8, 8)
        if self.hasFocus():
            p.setPen(QColor("#1f6feb"))
            p.drawRect(self.rect().adjusted(0, 0, -1, -1))
        p.end()

    def _activate_index(self, index):
        if not 0 <= index < len(self.accesses):
            return
        a = self.accesses[index]
        self.sel_n = int(a[0])
        self._sync_accessible_description()
        self.update()
        self.pointSelected.emit(int(a[0]))
        physical = a[7] if len(a) > 7 else a[2]
        if physical is not None:
            self.accessClicked.emit(int(physical), int(a[4]))
        else:
            self.accessUnavailable.emit()

    def mousePressEvent(self, ev):
        self.setFocus(Qt.MouseFocusReason)
        if not self._pts:
            return
        cx = ev.position().x() if hasattr(ev, "position") else ev.x()
        cy = ev.position().y() if hasattr(ev, "position") else ev.y()
        # nearest point within a small radius
        best, bd = None, 1e9
        for (px, py, i) in self._pts:
            d = (px - cx) ** 2 + (py - cy) ** 2
            if d < bd:
                bd, best = d, i
        if best is not None and bd <= 18 * 18:
            self._activate_index(best)

    def keyPressEvent(self, ev):
        key = ev.key()
        navigation = {
            Qt.Key_Left: -1, Qt.Key_Up: -1,
            Qt.Key_Right: 1, Qt.Key_Down: 1,
            Qt.Key_PageUp: -10, Qt.Key_PageDown: 10,
        }
        if not self.accesses:
            super().keyPressEvent(ev)
            return
        current = self._sel_idx()
        if key == Qt.Key_Home:
            target = 0
        elif key == Qt.Key_End:
            target = len(self.accesses) - 1
        elif key in navigation:
            if current is None:
                target = 0 if navigation[key] > 0 else len(self.accesses) - 1
            else:
                target = max(
                    0, min(len(self.accesses) - 1,
                           current + navigation[key]))
        elif key in (Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space):
            self._activate_index(current if current is not None else 0)
            ev.accept()
            return
        else:
            super().keyPressEvent(ev)
            return
        self._activate_index(target)
        ev.accept()


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
        self.addr_e.setAccessibleName("Physical memory address")
        self.addr_e.setValidator(QRegularExpressionValidator(
            QRegularExpression(r"0[xX][0-9a-fA-F]{1,8}"), self.addr_e))
        self.addr_e.setToolTip("32-bit physical address in the backend memory image")
        self.addr_e.setFont(_mono(9))
        self.addr_e.returnPressed.connect(self._go)
        bar.addWidget(self.addr_e)
        go = QPushButton("Go")
        go.setAccessibleName("Open physical memory address")
        go.setToolTip("Open the typed physical address (Enter)")
        go.clicked.connect(self._go); bar.addWidget(go)
        be = QPushButton("→EIP")
        be.setAccessibleName("Follow instruction pointer in physical memory")
        be.setToolTip("Follow current CS:EIP after segmentation and paging")
        be.clicked.connect(lambda: self._set_follow("eip")); bar.addWidget(be)
        bs = QPushButton("→ESP")
        bs.setAccessibleName("Follow stack pointer in physical memory")
        bs.setToolTip("Follow current SS:ESP after segmentation and paging")
        bs.clicked.connect(lambda: self._set_follow("esp")); bar.addWidget(bs)
        ba = QPushButton("→access")
        ba.setAccessibleName("Follow latest data access in physical memory")
        ba.setToolTip(
            "Follow the most-recent explicit load/store at its translated physical address")
        ba.clicked.connect(lambda: self._set_follow("access")); bar.addWidget(ba)
        self.eip_btn, self.esp_btn = be, bs
        self.access_btn = ba
        self._access = None       # (addr, size) of the newest memory access
        self._click_hl = None     # (addr, size) pinned by a Mem-map point click
        self.page_buttons = []
        for d, lab, tip in (
                (-256, "◀", "Previous 256 physical bytes (Page Up)"),
                (256, "▶", "Next 256 physical bytes (Page Down)")):
            b = QPushButton(lab); b.setFixedWidth(28); b.setToolTip(tip)
            b.setAccessibleName(
                "Previous physical memory page"
                if d < 0 else "Next physical memory page")
            b.clicked.connect(lambda _=0, dd=d: self._page(dd)); bar.addWidget(b)
            self.page_buttons.append(b)
        self.follow_lbl = QLabel(""); self.follow_lbl.setStyleSheet("color:#8b949e;font-size:8px;")
        self.follow_lbl.setAccessibleName("Physical memory navigation state")
        bar.addWidget(self.follow_lbl); bar.addStretch(1)
        v.addLayout(bar)
        self.dump = _HexDump()
        v.addWidget(self.dump, 1)
        self._session_controls = (
            self.addr_e, go, be, bs, *self.page_buttons)
        for key, delta in (("PgUp", -256), ("PgDown", 256)):
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.setContext(Qt.WidgetWithChildrenShortcut)
            shortcut.activated.connect(
                lambda step=delta: self._page(step))
        self.set_session_active(False)

    def set_session_active(self, active):
        for control in self._session_controls:
            control.setEnabled(active)
        self.access_btn.setEnabled(active and self._access is not None)
        if not active:
            self.backend = None
            self.follow_lbl.setText("No program loaded")
            self.follow_lbl.setAccessibleDescription("No program loaded")
            self.dump.clear("Open a program to inspect memory.")

    def reset(self):
        """Clear the transient Mem-map-click pin on a new image load, so the panel
        never shows a stale 'showing clicked access' highlight from the old program."""
        self._click_hl = None

    def start_session(self):
        """Start a program/snapshot at its instruction pointer, not stale memory."""
        self.set_session_active(False)
        self.follow = "eip"
        self.addr = 0x08048000
        self._access = None
        self._click_hl = None

    def goto_access(self, addr, size):
        """Jump to (and gold-highlight) a SPECIFIC access — a Mem-map point click
        navigates here without forcing a tab switch, so switching to this tab shows
        the translated physical bytes that load/store touched. The pinned highlight
        clears the moment the user navigates away (Go / a follow button / paging)."""
        self.follow = None
        self.addr = addr & 0xFFFFFFF0
        self._click_hl = (addr, size)
        self._refresh()

    def clear_clicked_access(self):
        """Drop only the Mem-map selection highlight, not the chosen address."""
        self._click_hl = None
        if self.backend is not None:
            self._refresh()

    def _go(self):
        try:
            value = int(self.addr_e.text(), 0)
            if not 0 <= value <= 0xFFFFFFFF:
                raise ValueError
        except ValueError:
            self.addr_e.setStyleSheet("border:1px solid #f85149;")
            self.follow_lbl.setText("invalid 32-bit address")
            self.follow_lbl.setAccessibleDescription(
                "Invalid 32-bit physical memory address")
            self.follow_lbl.setStyleSheet("color:#f85149;font-size:8px;")
            self.addr_e.selectAll()
            return
        self.addr = value & 0xFFFFFFF0
        self.follow = None
        self._click_hl = None
        self._refresh()

    def _set_follow(self, which):
        self.follow = which
        self._click_hl = None
        if which == "eip":
            physical = getattr(self, "_eip", None)
            if physical is not None:
                self.addr = physical & 0xFFFFFFF0
        elif which == "esp":
            physical = getattr(self, "_esp", None)
            if physical is not None:
                self.addr = physical & 0xFFFFFFF0
        elif which == "access" and self._access is not None:
            self.addr = self._access[0] & 0xFFFFFFF0
        self._refresh()

    def _page(self, delta):
        if self.backend is None:
            return
        self.follow = None
        self._click_hl = None
        self.addr = (self.addr + delta) & 0xFFFFFFF0
        self._refresh()

    def set_state(self, backend, state, access=None):
        self.backend = backend
        self._eip_offset = int(state.eip)
        self._esp_offset = int(state.gpr[4])
        self._eip_linear = (
            int(state.cs_base) + self._eip_offset) & 0xFFFFFFFF
        self._esp_linear = (
            int(state.seg_base[1]) + self._esp_offset) & 0xFFFFFFFF
        self._eip = backend.translate_linear(
            self._eip_linear, state.cr0, state.cr3, state.cr4)
        self._esp = backend.translate_linear(
            self._esp_linear, state.cr0, state.cr3, state.cr4)
        self._access = access
        for control in self._session_controls:
            control.setEnabled(True)
        self.eip_btn.setEnabled(self._eip is not None)
        self.esp_btn.setEnabled(self._esp is not None)
        self.access_btn.setEnabled(access is not None)
        if self.follow == "eip" and self._eip is not None:
            self.addr = self._eip & 0xFFFFFFF0
        elif self.follow == "esp" and self._esp is not None:
            self.addr = self._esp & 0xFFFFFFF0
        elif self.follow == "access" and access is not None:
            self.addr = access[0] & 0xFFFFFFF0
        self._refresh()

    def _refresh(self):
        if self.backend is None:
            return
        hl = self._click_hl or self._access      # a clicked access pins over the live one
        self.addr_e.setStyleSheet("")
        self.follow_lbl.setStyleSheet("color:#8b949e;font-size:8px;")
        self.addr_e.setText(f"0x{self.addr:08x}")
        if self._click_hl:
            follow_text = "showing clicked access (physical)"
        elif self.follow in ("eip", "esp"):
            physical = self._eip if self.follow == "eip" else self._esp
            linear = (
                self._eip_linear if self.follow == "eip" else self._esp_linear)
            offset = (
                self._eip_offset if self.follow == "eip" else self._esp_offset)
            follow_text = (
                f"{self.follow.upper()} translation unavailable"
                if physical is None else
                f"{self.follow.upper()} lin {linear:08x} → phys {physical:08x}"
                if physical != linear else
                f"{self.follow.upper()} off {offset:08x} → phys {physical:08x}"
                if linear != offset else
                f"following {self.follow.upper()}")
        elif self.follow == "access":
            follow_text = "following ACCESS (physical)"
        else:
            follow_text = "cyan=EIP  amber=ESP  gold=access · physical view"
        self.follow_lbl.setText(follow_text)
        self.follow_lbl.setAccessibleDescription(follow_text)
        self.follow_lbl.setToolTip(
            "Memory displays physical backend bytes. EIP and ESP are translated "
            "from their segment-relative offsets; access follows the translation "
            "captured for that retirement.")
        eip = getattr(self, "_eip", None)
        esp = getattr(self, "_esp", None)
        self.dump.set(
            self.backend, self.addr,
            eip if eip is not None else -8,
            esp if esp is not None else -8, hl)
