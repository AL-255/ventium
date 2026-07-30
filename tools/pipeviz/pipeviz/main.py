# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Ventium pipeline visualizer — application window.

Drives the verilated core (backend.Backend over libventium_viz.so) and wires the
pipeline / tables / trace / register panels together with a step+run toolbar.
"""
import os
import sys
import json
import argparse
import struct

from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QToolBar, QLabel,
                               QLineEdit, QPushButton, QCheckBox, QSpinBox, QSplitter,
                               QFileDialog, QMessageBox, QStyle)
from PySide6.QtGui import QAction, QFont, QPalette, QColor, QKeySequence, QShortcut
from PySide6.QtCore import Qt, QTimer

from .backend import Backend
from .pipeline_view import PipelineView
from .tables_view import TablesView
from .trace_view import TraceView
from .regs_view import RegsView
from .help_view import UserGuideDialog

DEF_ENTRY = 0x08048000
DEF_ESP = 0x40c34910


def _read_program(path):
    """Return ``(segments, entry, kind)`` for a raw image or a little-endian ELF.

    A raw image is deliberately kept as the simple one-segment case.  ELF support
    matters here because normal compiler/linker output has discontiguous PT_LOAD
    sections; treating it as a flat blob silently puts code at the wrong address.
    Only the bytes which should exist in memory are returned -- a fresh backend is
    already zero-filled, which supplies ELF .bss (p_memsz - p_filesz).
    """
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF":
        return [(DEF_ENTRY, data)], DEF_ENTRY, "flat image"
    if len(data) < 16 or data[5] != 1:
        raise ValueError("only little-endian ELF files are supported")
    cls = data[4]
    if cls == 1:
        if len(data) < 52:
            raise ValueError("truncated ELF32 header")
        # e_machine / e_entry / e_phoff / e_phentsize / e_phnum; the explicit
        # offsets make this work for ELF files that have no section table.
        machine = struct.unpack_from("<H", data, 18)[0]
        entry = struct.unpack_from("<I", data, 24)[0]
        phoff = struct.unpack_from("<I", data, 28)[0]
        phentsz = struct.unpack_from("<H", data, 42)[0]
        phnum = struct.unpack_from("<H", data, 44)[0]
        want_machine, min_ph = 3, 32
        fmt = "<IIIIIIII"
    elif cls == 2:
        if len(data) < 64:
            raise ValueError("truncated ELF64 header")
        machine = struct.unpack_from("<H", data, 18)[0]
        entry = struct.unpack_from("<Q", data, 24)[0]
        phoff = struct.unpack_from("<Q", data, 32)[0]
        phentsz = struct.unpack_from("<H", data, 54)[0]
        phnum = struct.unpack_from("<H", data, 56)[0]
        want_machine, min_ph = 3, 56
        fmt = "<IIQQQQQQ"
    else:
        raise ValueError(f"unsupported ELF class {cls}")
    if machine != want_machine:
        raise ValueError(f"ELF machine {machine} is not x86 (EM_386)")
    if phentsz < min_ph or phoff + phentsz * phnum > len(data):
        raise ValueError("invalid or truncated ELF program-header table")
    segments = []
    for i in range(phnum):
        fields = struct.unpack_from(fmt, data, phoff + i * phentsz)
        if cls == 1:
            p_type, p_offset, p_vaddr, _paddr, p_filesz, _p_memsz, _flags, _align = fields
        else:
            p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, _p_memsz, _align = fields
        if p_type != 1 or not p_filesz:
            continue
        if p_vaddr > 0xffffffff or p_offset + p_filesz > len(data):
            raise ValueError("ELF load segment lies outside the file or 32-bit address space")
        segments.append((int(p_vaddr), data[p_offset:p_offset + p_filesz]))
    if not segments:
        raise ValueError("ELF contains no loadable program segments")
    if entry > 0xffffffff:
        raise ValueError("64-bit ELF entry point cannot run on this 32-bit core")
    return segments, int(entry), "ELF"


def _apply_dark(app):
    app.setStyle("Fusion")
    p = QPalette()
    p.setColor(QPalette.Window, QColor("#0d1117"))
    p.setColor(QPalette.WindowText, QColor("#c9d1d9"))
    p.setColor(QPalette.Base, QColor("#0d1117"))
    p.setColor(QPalette.AlternateBase, QColor("#161b22"))
    p.setColor(QPalette.Text, QColor("#c9d1d9"))
    p.setColor(QPalette.Button, QColor("#21262d"))
    p.setColor(QPalette.ButtonText, QColor("#c9d1d9"))
    p.setColor(QPalette.Highlight, QColor("#1f6feb"))
    p.setColor(QPalette.HighlightedText, QColor("#ffffff"))
    p.setColor(QPalette.ToolTipBase, QColor("#161b22"))
    p.setColor(QPalette.ToolTipText, QColor("#c9d1d9"))
    app.setPalette(p)
    app.setStyleSheet(
        "QToolBar{background:#161b22;border-bottom:1px solid #30363d;spacing:4px;padding:3px;}"
        "QGroupBox{border:1px solid #30363d;margin-top:8px;font-weight:bold;}"
        "QGroupBox::title{subcontrol-origin:margin;left:6px;padding:0 3px;color:#8b949e;}"
        "QTableWidget{background:#0d1117;alternate-background-color:#161b22;gridline-color:#21262d;}"
        "QHeaderView::section{background:#161b22;color:#8b949e;border:0;border-right:1px solid #30363d;padding:2px;}"
        "QTabBar::tab{background:#161b22;color:#8b949e;padding:4px 6px;border:1px solid #30363d;}"
        "QTabBar::tab:selected{background:#0d1117;color:#c9d1d9;border-bottom:2px solid #1f6feb;}"
        "QLineEdit{background:#0d1117;border:1px solid #30363d;padding:2px;}"
        "QPushButton{background:#21262d;border:1px solid #30363d;padding:3px 8px;}"
        "QPushButton:hover{background:#30363d;}"
        "QPushButton:disabled{color:#6e7681;}"
        "QSplitter::handle{background:#30363d;}"
        "QSplitter::handle:hover{background:#484f58;}"
        "QToolBar QLabel{color:#8b949e;}")


def _hex_edit(val, width=92):
    e = QLineEdit(f"0x{val:08x}")
    e.setFixedWidth(width)
    f = QFont("monospace"); f.setStyleHint(QFont.Monospace); e.setFont(f)
    return e


def _parse_hex(e, default):
    try:
        return int(e.text(), 0) & 0xFFFFFFFF
    except ValueError:
        return default


class MainWindow(QMainWindow):
    def __init__(self, libpath=None):
        super().__init__()
        self.setWindowTitle("Ventium pipeline visualizer — verilated RTL backend")
        self.resize(1640, 980)
        self.backend = Backend(libpath)
        self._libpath = libpath
        self.image_path = None
        self.image_bytes = None
        self.image_segments = []
        self.image_kind = None
        self.snapshot_prefix = None
        self.setAcceptDrops(True)

        self._build_toolbar()
        self._build_central()
        self._build_menus()

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._on_run_tick)
        self.notice_timer = QTimer(self)
        self.notice_timer.setSingleShot(True)
        self.notice_timer.timeout.connect(lambda: self.action_hint.setText(""))
        self._running = False
        self._set_transport_enabled(False)
        self._refresh_status()

    def _build_menus(self):
        file_menu = self.menuBar().addMenu("&File")
        open_action = QAction("Open program…", self)
        open_action.setShortcut(QKeySequence("Ctrl+O"))
        open_action.triggered.connect(self.on_open)
        file_menu.addAction(open_action)
        snapshot_action = QAction("Open snapshot…", self)
        snapshot_action.setShortcut(QKeySequence("Ctrl+Shift+O"))
        snapshot_action.triggered.connect(self.on_open_snapshot)
        file_menu.addAction(snapshot_action)
        file_menu.addSeparator()
        quit_action = QAction("Quit", self)
        quit_action.setShortcut(QKeySequence("Ctrl+Q"))
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)
        self._file_menu = file_menu

        view_menu = self.menuBar().addMenu("&View")
        reset_layout = QAction("Reset panel layout", self)
        reset_layout.setShortcut(QKeySequence("Ctrl+0"))
        reset_layout.triggered.connect(self._reset_layout)
        view_menu.addAction(reset_layout)
        view_menu.addSeparator()
        for toolbar in (self.session_toolbar, self.transport_toolbar, self.status_toolbar):
            action = toolbar.toggleViewAction()
            action.setText(f"Show {toolbar.windowTitle()} toolbar")
            view_menu.addAction(action)
        self._view_menu = view_menu

        menu = self.menuBar().addMenu("&Help")
        guide = QAction("User Guide", self)
        guide.setShortcut(QKeySequence(Qt.Key_F1))
        guide.triggered.connect(lambda: self._show_guide("Getting started"))
        menu.addAction(guide)
        pipeline = QAction("How to read the Pipeline View", self)
        pipeline.triggered.connect(lambda: self._show_guide("Reading the Pipeline View"))
        menu.addAction(pipeline)
        shortcuts = QAction("Keyboard and mouse shortcuts", self)
        shortcuts.triggered.connect(self._show_shortcuts)
        menu.addAction(shortcuts)
        self._help_menu = menu
        self._guide_dialog = None

    def _reset_layout(self):
        self.outer_split.setSizes([900, 740])
        self.left_split.setSizes([500, 470])
        self.right_split.setSizes([600, 300])
        self._notice("Panel layout reset")

    def _show_guide(self, topic="Getting started"):
        if self._guide_dialog is None:
            self._guide_dialog = UserGuideDialog(self)
        self._guide_dialog.show_page(topic)
        self._guide_dialog.show()
        self._guide_dialog.raise_()
        self._guide_dialog.activateWindow()

    # ---- UI construction ----
    def _build_toolbar(self):
        tb = QToolBar("session"); tb.setMovable(False)
        self.addToolBar(tb)
        self.session_toolbar = tb

        openbtn = QPushButton(" Open…")
        openbtn.setMinimumWidth(92)
        openbtn.setIcon(self.style().standardIcon(QStyle.SP_DirOpenIcon))
        openbtn.clicked.connect(self.on_open)
        openbtn.setToolTip("Open a flat binary or x86 ELF executable (you can also drag a file here)")
        tb.addWidget(openbtn)

        snapbtn = QPushButton(" Snapshot…")
        snapbtn.setMinimumWidth(104)
        snapbtn.setToolTip("Resume a host-testbench --save-state checkpoint (.aux + .vlt pair)")
        snapbtn.clicked.connect(self.on_open_snapshot)
        tb.addWidget(snapbtn)

        tb.addWidget(QLabel("  entry "))
        self.entry_e = _hex_edit(DEF_ENTRY); tb.addWidget(self.entry_e)
        tb.addWidget(QLabel(" load "))
        self.load_e = _hex_edit(DEF_ENTRY); tb.addWidget(self.load_e)
        tb.addWidget(QLabel(" esp "))
        self.esp_e = _hex_edit(DEF_ESP); tb.addWidget(self.esp_e)
        tb.addSeparator()   # file/load | config

        self.cyc_cb = QCheckBox("cycle"); self.cyc_cb.setChecked(True)
        self.cyc_cb.setToolTip("Cycle mode: show both integer issue lanes (dual issue)")
        tb.addWidget(self.cyc_cb)
        self.sys_cb = QCheckBox("system"); tb.addWidget(self.sys_cb)
        self.soc_cb = QCheckBox("SoC")
        self.soc_cb.setToolTip("Run the full ventium_soc (internal port-I/O / PIC / "
                               "PIT) — needed for bare-metal images like test386. "
                               "Requires build.sh --soc.")
        tb.addWidget(self.soc_cb)

        # Transport gets its own row. Keeping file/config and execution controls
        # separate avoids QToolBar's overflow chevron on 1280px displays.
        self.addToolBarBreak()
        ctl = QToolBar("transport"); ctl.setMovable(False)
        self.addToolBar(ctl)
        self.transport_toolbar = ctl

        self.reset_btn = QPushButton(" Reset")
        self.reset_btn.setIcon(self.style().standardIcon(QStyle.SP_BrowserReload))
        self.reset_btn.clicked.connect(self.on_reset)
        self.reset_btn.setToolTip("Reset the loaded program (R)")
        ctl.addWidget(self.reset_btn)

        self.step1_btn = QPushButton("Clock")
        self.step1_btn.clicked.connect(lambda: self.do_step(1, False))
        self.step1_btn.setToolTip("Advance one clock (.)")
        ctl.addWidget(self.step1_btn)
        self.stepi_btn = QPushButton("Insn")
        self.stepi_btn.clicked.connect(lambda: self.do_step(200000, True))
        self.stepi_btn.setToolTip("Advance to the next retired instruction (I or Space)")
        ctl.addWidget(self.stepi_btn)

        ctl.addWidget(QLabel(" N "))
        self.stepn = QSpinBox(); self.stepn.setRange(1, 1000000); self.stepn.setValue(100)
        self.stepn.setFixedWidth(90); ctl.addWidget(self.stepn)
        self.stepn_btn = QPushButton("Step N")
        self.stepn_btn.clicked.connect(lambda: self.do_step(self.stepn.value(), False))
        self.stepn_btn.setToolTip("Advance the selected number of clocks")
        ctl.addWidget(self.stepn_btn)

        self.run_btn = QPushButton(" Run")
        self.run_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPlay))
        self.run_btn.clicked.connect(self.on_run_toggle)
        self.run_btn.setStyleSheet(
            "QPushButton{background:#238636;color:#ffffff;font-weight:bold;border:1px "
            "solid #2ea043;padding:3px 12px;} QPushButton:hover{background:#2ea043;}"
            "QPushButton:disabled{background:#21262d;color:#6e7681;"
            "border-color:#30363d;}")
        ctl.addWidget(self.run_btn)
        self.run_btn.setToolTip("Run or pause continuous execution (F5)")
        ctl.addWidget(QLabel(" speed "))
        self.speed = QSpinBox(); self.speed.setRange(1, 20000); self.speed.setValue(200)
        self.speed.setSuffix(" clk/tick"); self.speed.setFixedWidth(110)
        ctl.addWidget(self.speed)

        ctl.addSeparator()   # transport | event-jump
        ctl.addWidget(QLabel(" event "))
        self.evprev_btn = QPushButton("◀")
        self.evprev_btn.setToolTip("Jump the playhead to the PREVIOUS pipeline event "
                                   "(mispredict / stall / I-fill / page-walk)")
        self.evprev_btn.clicked.connect(lambda: self._jump_event(-1))
        ctl.addWidget(self.evprev_btn)
        self.evnext_btn = QPushButton("▶")
        self.evnext_btn.setToolTip("Jump the playhead to the NEXT pipeline event "
                                   "(mispredict / stall / I-fill / page-walk)")
        self.evnext_btn.clicked.connect(lambda: self._jump_event(1))
        ctl.addWidget(self.evnext_btn)

        # status toolbar (third row)
        self.addToolBarBreak()
        sb = QToolBar("status"); sb.setMovable(False); self.addToolBar(sb)
        self.status_toolbar = sb
        self.status_lbl = QLabel("  no image loaded  ")
        f = QFont("monospace"); f.setStyleHint(QFont.Monospace); self.status_lbl.setFont(f)
        sb.addWidget(self.status_lbl)
        self.action_hint = QLabel("")
        self.action_hint.setStyleSheet("color:#8b949e;padding-left:12px;")
        sb.addWidget(self.action_hint)

        # shortcuts
        for key, fn in [(Qt.Key_Period, lambda: self.do_step(1, False)),
                        (Qt.Key_Space, lambda: self.do_step(200000, True)),
                        (Qt.Key_F5, self.on_run_toggle),
                        (Qt.Key_R, self.on_reset)]:
            a = QAction(self); a.setShortcut(QKeySequence(key)); a.triggered.connect(fn)
            self.addAction(a)

    def _has_session(self):
        return self.image_bytes is not None or self.snapshot_prefix is not None

    def _set_transport_enabled(self, enabled):
        """Keep controls honest: a fresh window cannot accidentally look runnable."""
        for w in (self.reset_btn, self.step1_btn, self.stepi_btn, self.stepn,
                  self.stepn_btn, self.run_btn, self.speed,
                  self.evprev_btn, self.evnext_btn):
            w.setEnabled(enabled)

    def _notice(self, text, ms=3500):
        self.action_hint.setText(text)
        self.notice_timer.start(ms)

    def _show_shortcuts(self):
        self._show_guide("Shortcuts")

    def _build_central(self):
        outer = QSplitter(Qt.Horizontal)
        left = QSplitter(Qt.Vertical)
        self.outer_split = outer
        self.left_split = left
        self.pipeline = PipelineView()
        self.trace = TraceView()
        left.addWidget(self.pipeline)
        left.addWidget(self.trace)
        left.setMinimumWidth(700)
        left.setStretchFactor(0, 3); left.setStretchFactor(1, 2)
        left.setSizes([500, 470])
        right = QSplitter(Qt.Vertical)
        self.right_split = right
        self.tables = TablesView()
        self.regs = RegsView()
        right.addWidget(self.tables)
        right.addWidget(self.regs)
        # give the register/FPU panel real vertical room (was a crammed 25% bottom
        # strip) and shrink the cache-table area's dead void when it's sparse.
        right.setStretchFactor(0, 3); right.setStretchFactor(1, 2)
        # the register panel sizes to its (now-compact) content ~300px; give the
        # rest to the cache/tables panel which benefits from more visible rows.
        right.setSizes([600, 300])
        outer.addWidget(left); outer.addWidget(right)
        outer.setStretchFactor(0, 3); outer.setStretchFactor(1, 2)
        # Give the linked trace/timeline enough room at compact window sizes.
        # Relying only on stretch factors makes QSplitter shrink the left side
        # all the way to its minimum while preserving excess width on the right.
        # An explicit 55:45 starting allocation keeps trace operands/effects
        # readable and also gives the ten analysis tabs enough room at 1640px.
        outer.setSizes([900, 740])
        for sp in (outer, left, right):
            sp.setHandleWidth(4)
        self.setCentralWidget(outer)
        # two-way link: trace row <-> Konata instruction row
        self.trace.rowSelected.connect(self.pipeline.highlight_cycle)
        self.pipeline.konata.plot.rowClicked.connect(self.trace.select_n)
        # selecting an instruction (either side) PINS the register panel to its
        # post-commit architectural state + drops a playhead at its cycle.
        self.trace.instSelected.connect(self._pin_to)
        self.pipeline.konata.plot.rowClicked.connect(self._pin_to)
        # drill-down: click a Hotspots / Branches PC row -> jump the trace to it
        self.tables.pcClicked.connect(self.trace.select_pc)
        # drill-down: click a Mem-map access point -> jump the trace to that retire n
        # (+ pin regs), so an outlier/stripe in the scatter is one click from its row.
        self.tables.accmap.pointSelected.connect(self.trace.select_n)
        self.tables.accmap.pointSelected.connect(self._pin_to)

        # keyboard-driven stepping / navigation (a debugger should be drivable from
        # the keyboard): . = step 1 clk, i = step 1 instruction, ] / [ = jump to the
        # next / previous pipeline event (mispredict / stall / I-fill / page-walk).
        # `.` is an QAction in the toolbar shortcut set above. Keep it out of
        # this QShortcut group: registering both lets Qt dispatch a single key
        # press twice on some platform styles, advancing two clocks unexpectedly.
        for keys, fn in [("i", lambda: self.do_step(1, True)),
                         ("]", lambda: self._jump_event(1)),
                         ("[", lambda: self._jump_event(-1))]:
            QShortcut(QKeySequence(keys), self).activated.connect(fn)

    # ---- image loading ----
    def on_open(self):
        start = os.path.join(os.getcwd(), "build")
        if not os.path.isdir(start):
            start = os.getcwd()
        path, _ = QFileDialog.getOpenFileName(
            self, "Open flat image", start,
            "Programs (*.flat *.bin *.img *.elf *.exe);;All files (*)")
        if path:
            self.load_image(path)

    def load_image(self, path):
        try:
            segments, entry, kind = _read_program(path)
            data = b"".join(chunk for _, chunk in segments)
        except (OSError, ValueError, struct.error) as e:
            QMessageBox.critical(self, "Open failed", str(e)); return
        # honour a sibling manifest.json (load_addr / entry) if present
        man = os.path.join(os.path.dirname(path), "manifest.json")
        load = min(addr for addr, _ in segments)
        if os.path.exists(man):
            try:
                with open(man, encoding="utf-8") as mf:
                    m = json.load(mf)
                if "entry" in m: entry = int(m["entry"], 0)
                if "load_addr" in m: load = int(m["load_addr"], 0)
            except (OSError, ValueError, TypeError, json.JSONDecodeError) as e:
                QMessageBox.warning(self, "Manifest ignored",
                                    f"Could not read {man}: {e}\nLoading the program metadata instead.")
        # A manifest's load address is a flat-image convention.  ELF carries
        # individual virtual addresses in PT_LOAD and must retain those.
        if kind == "flat image":
            segments = [(load, data)]
        self.image_path = path
        self.image_bytes = data
        self.image_segments = segments
        self.image_kind = kind
        self.snapshot_prefix = None
        self.reset_btn.setText(" Reset")
        self.reset_btn.setToolTip("Re-cold-reset the loaded program on a fresh model")
        # heuristic: bare-metal/system images (.bin under sys/, ~64 KiB) boot in
        # system mode (real-mode reset at F000:FFF0). Auto-tick `system` so they
        # "just work"; the user can override.
        looks_system = (("/sys/tests/" in path or path.endswith(".bin"))
                        and len(data) >= 0x8000)
        # test386 / external CPU tests drive the SoC's port-I/O (POST codes),
        # so they need the full ventium_soc — auto-tick SoC for those.
        looks_soc = any(k in path for k in ("test386", "09-external", "/soc/"))
        self.sys_cb.setChecked(looks_system or looks_soc)
        self.soc_cb.setChecked(looks_soc)
        self.entry_e.setText(f"0x{entry:08x}")
        self.load_e.setText(f"0x{load:08x}")
        is_flat = kind == "flat image"
        self.load_e.setEnabled(is_flat)
        self.load_e.setToolTip("Load address for a flat image" if is_flat else
                               "ELF segment addresses come from its PT_LOAD headers")
        self.setWindowTitle(f"Ventium pipeline visualizer — {os.path.basename(path)} ({kind})")
        self.on_reset()
        self._notice(f"Loaded {kind}: {os.path.basename(path)}")

    def dragEnterEvent(self, event):
        urls = event.mimeData().urls()
        if len(urls) == 1 and urls[0].isLocalFile():
            event.acceptProposedAction()

    def dropEvent(self, event):
        urls = event.mimeData().urls()
        if len(urls) == 1 and urls[0].isLocalFile():
            path = urls[0].toLocalFile()
            if path.endswith((".aux", ".vlt")):
                self.load_snapshot(path)
            else:
                self.load_image(path)
            event.acceptProposedAction()

    def on_open_snapshot(self):
        start = os.getcwd()
        path, _ = QFileDialog.getOpenFileName(
            self, "Open host snapshot", start,
            "Ventium snapshots (*.aux *.vlt);;All files (*)")
        if path:
            self.load_snapshot(path)

    @staticmethod
    def _snapshot_prefix(path):
        return path[:-4] if path.endswith((".aux", ".vlt")) else path

    def load_snapshot(self, path):
        """Restore the host TB's paired <prefix>.{vlt,aux} state checkpoint.
        Build/restore failures leave the currently running backend untouched."""
        self.stop_run()
        prefix = self._snapshot_prefix(path)
        candidate = None
        try:
            candidate = Backend(self._libpath, soc=False)
            candidate.load_snapshot(prefix)
        except (FileNotFoundError, OSError, RuntimeError) as e:
            if candidate is not None:
                candidate.close()
            QMessageBox.critical(self, "Snapshot restore failed", str(e))
            return
        old = self.backend
        self.backend = candidate
        old.close()
        self.image_path = None
        self.image_bytes = None
        self.image_segments = []
        self.image_kind = "snapshot"
        self.snapshot_prefix = prefix
        self.sys_cb.setChecked(False)
        self.soc_cb.setChecked(False)
        self.reset_btn.setText(" Restore snapshot")
        self.reset_btn.setToolTip("Discard continued execution and restore this snapshot again")
        self.setWindowTitle(f"Ventium pipeline visualizer — snapshot {os.path.basename(prefix)}")
        s = self.backend.state()
        bits = 32 if s.cs_d else 16
        for v in (self.pipeline, self.trace, self.tables):
            if hasattr(v, "set_bits"):
                v.set_bits(bits)
        self.pipeline.reset(self.backend)
        self.trace.reset()
        self.tables.mem.reset()
        self._unpin()
        self._refresh_all()
        self._set_transport_enabled(True)
        self._notice(f"Restored snapshot at clock {s.clk}")

    # ---- driving ----
    def _fresh_backend(self, soc=False):
        try:
            self.backend.close()
        except Exception:
            pass
        try:
            if soc and not Backend.supports_snapshot(self._libpath, soc=True):
                raise FileNotFoundError(
                    "libventium_viz_soc.so is stale or unreadable "
                    "(missing the current replay ABI)")
            self.backend = Backend(self._libpath, soc=soc)
        except FileNotFoundError as e:
            if soc:
                QMessageBox.warning(self, "SoC model missing",
                                    f"{e}\n\nFalling back to ventium_top. Run "
                                    "`tools/pipeviz/build.sh --soc` to build it.")
                self.soc_cb.setChecked(False)
                self.backend = Backend(self._libpath, soc=False)
            else:
                raise

    def on_reset(self):
        self.stop_run()
        if self.snapshot_prefix:
            self.load_snapshot(self.snapshot_prefix)
            return
        if self.image_bytes is None:
            return
        soc = self.soc_cb.isChecked()
        system = self.sys_cb.isChecked() or soc      # SoC always boots system mode
        if system and self.image_kind == "ELF":
            QMessageBox.warning(self, "ELF is a user-mode program",
                                "System/SoC boot expects a raw BIOS image. Untick system "
                                "and SoC to run this ELF at its entry point.")
            return
        # fresh model => clean memory
        self._fresh_backend(soc=soc)
        soc = self.backend.soc                        # may have fallen back
        if system:
            # -bios placement: the image's LAST byte sits at 0x000FFFFF so the
            # reset vector F000:FFF0 -> 0x000FFFF0 lands in it (matches tb_main /
            # qemu-system -bios). entry/esp are seeded by boot_mode in the core.
            load = (0x00100000 - len(self.image_bytes)) & 0xFFFFFFFF
            self.load_e.setText(f"0x{load:08x}")
            self.backend.load_bytes(self.image_bytes, load)
            self.backend.reset(0, 0, cycle_mode=self.cyc_cb.isChecked(), system=1)
        else:
            entry = _parse_hex(self.entry_e, DEF_ENTRY)
            esp = _parse_hex(self.esp_e, DEF_ESP)
            # ELF images can have several non-contiguous PT_LOAD segments.  A
            # flat image remains one segment, so this also keeps the old workflow.
            if self.image_kind == "flat image":
                segments = [(_parse_hex(self.load_e, DEF_ENTRY), self.image_bytes)]
            else:
                segments = self.image_segments
            for address, chunk in segments:
                self.backend.load_bytes(chunk, address)
            self.backend.reset(entry, esp, cycle_mode=self.cyc_cb.isChecked(), system=0)
        bits = 16 if system else 32
        for v in (self.pipeline, self.trace, self.tables):
            if hasattr(v, "set_bits"):
                v.set_bits(bits)
        self.pipeline.reset(self.backend)
        self.trace.reset()
        self.tables.mem.reset()        # drop any stale Mem-map-click pin from the old image
        self._unpin()
        self._refresh_all()
        self._set_transport_enabled(True)

    # ---- register pinning (AS-OF a retired instruction) + playhead ----
    def _pin_to(self, n):
        recs = self.backend.get_retires(max(0, n - 1), 2)
        rec = next((r for r in recs if r.n == n), None)
        if rec is None:
            return
        prev = next((r for r in recs if r.n == n - 1), None)
        self._pinned_n = n
        self.regs.show_retire(rec, prev)

    def _unpin(self):
        if getattr(self, "_pinned_n", None) is not None:
            self._pinned_n = None
            self.regs.unpin()
            self.pipeline.clear_playhead()

    def _jump_event(self, direction):
        """Move the Konata playhead to the next/prev pipeline event (mispredict /
        stall / I-fill / page-walk) — fast navigation to where the action is."""
        plot = self.pipeline.konata.plot
        cur = plot.playhead
        if cur is None:                         # no playhead yet: start at an edge
            cur = plot.base_cyc - 1 if direction > 0 else plot.max_cyc + 1
        cyc = self.pipeline.spark.next_event(cur, direction)
        if cyc is not None:
            self.pipeline.highlight_cycle(cyc)
        else:
            self._notice("No pipeline event in the captured timeline")

    def do_step(self, n, stop_on_retire):
        if not self._has_session():
            return
        self._unpin()
        stepped = self.backend.step(n, stop_on_retire)
        self._refresh_all()
        unit = "instruction boundary" if stop_on_retire else "clock" + ("s" if stepped != 1 else "")
        self._notice(f"Advanced {stepped} {unit}")
        if self.backend.is_done():
            self.stop_run()

    def on_run_toggle(self):
        if self._running:
            self.stop_run()
        elif self._has_session():
            self._running = True
            self.run_btn.setText(" Pause")
            self.run_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPause))
            self.timer.start(30)

    def stop_run(self):
        self._running = False
        self.timer.stop()
        self.run_btn.setText(" Run")
        self.run_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPlay))

    def _on_run_tick(self):
        if not self._has_session() or self.backend.is_done():
            self.stop_run(); self._refresh_all(); return
        self._unpin()
        self.backend.step(self.speed.value(), False)
        self._refresh_all()
        if self.backend.is_done():
            self.stop_run()

    # ---- refresh ----
    def _refresh_all(self):
        s = self.backend.state()
        self.pipeline.update_from(self.backend, s)
        self.trace.update_from(self.backend)   # FIRST: refreshes the access stream the
        #   Hotspots D$-miss column + Mem map + →access all read this same frame
        self.tables.update_from(self.backend, s)
        self.tables.set_hotspots(self.pipeline.konata.plot.insns, self.trace.accesses)
        self.tables.set_branches(self.pipeline.konata.plot.insns)
        self.tables.set_instr_mix(self.pipeline.konata.plot.insns)
        self.tables.mem.set_state(self.backend, s, self.trace.last_access)
        self.tables.accmap.set_accesses(self.trace.accesses)
        self.tables.set_dcache_replay(self.trace.accesses)   # append D$ miss-rate to Data$ header
        if getattr(self, "_pinned_n", None) is None:
            self.regs.update_from(s)   # else keep the pinned AS-OF display
        self._refresh_status(s)

    def _refresh_status(self, s=None):
        if s is None:
            self.status_lbl.setText("  no image loaded — Open an image (e.g. build/m2/mb_brloop.flat)  ")
            return
        name = self.backend.state_name(s.state)
        ret = self.backend.retire_count()
        cyc = max(1, s.core_cyc)
        st = self.pipeline.waterfall.stats()
        ipc = ret / cyc
        prate = (2 * st["vret"] / ret * 100) if ret else 0.0   # % of insns that paired
        icn = sum(1 for v, _ in self.tables.ic_map.cells if v)
        dcn = sum(1 for v, _ in self.tables.dc_map.cells if v)
        mode = "SYS" if s.sys_mode else "USR"

        def chip(lab, val, alert=False):
            col = "#e3b341" if alert else "#e6edf3"
            return (f"<span style='color:#6e7681'>{lab}</span>"
                    f"<span style='color:{col}'>&nbsp;{val}</span>")
        sep = " <span style='color:#30363d'>&#9474;</span> "
        if self.snapshot_prefix:
            image = f"snapshot: {os.path.basename(self.snapshot_prefix)}"
        else:
            image = (f"{self.image_kind}: {os.path.basename(self.image_path)}"
                     if self.image_path else "no image")
        groups = [
            f"<span style='color:#8b949e'>{image}</span>",
            chip("cyc", s.core_cyc),
            f"<span style='color:#79c0ff'>{name}</span> <span style='color:#6e7681'>{mode}</span>",
            chip("ret", ret) + "&nbsp;&nbsp;" + chip("IPC", f"{ipc:.2f}")
                + "&nbsp;&nbsp;" + chip("pair", f"{prate:.0f}%")
                + "&nbsp;&nbsp;" + chip("mispred", st["mispred"], st["mispred"] > 0),
            chip("I$", f"{icn}/256") + "&nbsp;&nbsp;" + chip("D$", f"{dcn}/256")
                + "&nbsp;&nbsp;" + chip("fills", st["fill"])
                + "&nbsp;&nbsp;" + chip("walks", st["walk"], st["walk"] > 0),
            chip("eip", f"0x{s.eip:08x}"),
        ]
        html = "&nbsp;" + sep.join(groups)
        if self.backend.is_done():
            html += " <span style='color:#3fb950;font-weight:bold'>[DONE]</span>"
        if s.cpu_hung:
            html += " <span style='color:#f85149;font-weight:bold'>[HUNG]</span>"
        self.status_lbl.setText(html)


def main():
    ap = argparse.ArgumentParser(description="Ventium pipeline visualizer")
    ap.add_argument("image", nargs="?", help="flat image or x86 ELF to load on startup")
    ap.add_argument("--entry", type=lambda x: int(x, 0), default=None)
    ap.add_argument("--load", type=lambda x: int(x, 0), default=None,
                    help="load address override for a flat image")
    ap.add_argument("--esp", type=lambda x: int(x, 0), default=DEF_ESP)
    ap.add_argument("--system", action="store_true", help="boot a raw BIOS/system image")
    ap.add_argument("--soc", action="store_true", help="use the full SoC backend (implies --system)")
    ap.add_argument("--snapshot", "--restore-state", dest="snapshot", default=None,
                    help="resume a host-TB --save-state prefix (.aux + .vlt)")
    ap.add_argument("--lib", default=None, help="path to libventium_viz.so")
    args = ap.parse_args()

    app = QApplication(sys.argv)
    _apply_dark(app)
    try:
        win = MainWindow(libpath=args.lib)
    except FileNotFoundError as e:
        QMessageBox.critical(None, "Backend missing", str(e))
        return 1
    # auto-load: CLI image, else a default demo image if present
    img = args.image
    if args.snapshot:
        win.load_snapshot(args.snapshot)
        img = None
    if img is None:
        for cand in ("build/m2/mb_brloop.flat", "build/m2/mb_fpindep.flat",
                     "build/m2/smoke.flat"):
            if os.path.exists(cand):
                img = cand; break
    if img and os.path.exists(img):
        win.load_image(img)
        # Apply command-line choices *after* program metadata.  Previously
        # load_image() overwrote --entry, making the documented flag ineffective.
        if args.entry is not None:
            win.entry_e.setText(f"0x{args.entry:08x}")
        if args.load is not None:
            win.load_e.setText(f"0x{args.load:08x}")
            if win.image_kind == "flat image":
                win.image_segments = [(args.load, win.image_bytes)]
        win.esp_e.setText(f"0x{args.esp:08x}")
        if args.system or args.soc:
            win.sys_cb.setChecked(True)
            win.soc_cb.setChecked(args.soc)
        if args.entry is not None or args.load is not None or args.system or args.soc or args.esp != DEF_ESP:
            win.on_reset()
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
