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
from pathlib import Path

from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QToolBar, QLabel,
                               QLineEdit, QPushButton, QCheckBox, QSpinBox, QSplitter,
                               QFileDialog, QMessageBox, QStyle, QSizePolicy,
                               QComboBox, QTabWidget)
from PySide6.QtGui import (QAction, QFont, QPalette, QColor, QKeySequence,
                           QShortcut, QRegularExpressionValidator)
from PySide6.QtCore import Qt, QTimer, QRegularExpression

from .backend import Backend
from .pipeline_view import PipelineView
from .tables_view import TablesView
from .trace_view import TraceView
from .regs_view import RegsView
from .help_view import UserGuideDialog
from .source_view import AssemblyView, CView

DEF_ENTRY = 0x08048000
DEF_ESP = 0x40c34910
_TOOL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_REPO_ROOT = os.path.dirname(os.path.dirname(_TOOL_DIR))
_PROGRAM_FILTER = (
    "Programs (*.flat *.bin *.img *.rom *.elf);;"
    "ELF executables (*.elf);;Raw images (*.flat *.bin *.img *.rom);;"
    "All files (*)")
_EXAMPLES = (
    ("Dual issue and branches",
     ("build/m2/mb_brloop.flat", "build/verify/mb_brloop.cycle.flat")),
    ("D-cache pressure",
     ("build/m2/mb_dmiss.flat", "build/verify/mb_dmiss.cycle.flat")),
    ("x87 overlap",
     ("build/m2/mb_fpindep.flat", "build/verify/mb_fpindep.cycle.flat")),
    ("System paging", ("verif/sys/tests/ppage/ppage.bin",)),
)


def _first_repo_file(candidates):
    return next((os.path.join(_REPO_ROOT, relative) for relative in candidates
                 if os.path.isfile(os.path.join(_REPO_ROOT, relative))), None)


def _load_startup_target(window, image=None, snapshot=None):
    """Load exactly one startup target.

    Explicit targets never fall through to a demo: a snapshot must remain the
    restored session, and a misspelled image path must reach ``load_image``'s
    visible error instead of being silently ignored.
    """
    if snapshot is not None:
        window.load_snapshot(snapshot)
        return "snapshot"
    if image is not None:
        window.load_image(image)
        return "image"
    for candidates in (entry[1] for entry in _EXAMPLES[:3]):
        candidate = _first_repo_file(candidates)
        if candidate:
            window.load_image(candidate)
            return "demo"
    smoke = os.path.join(_REPO_ROOT, "build", "m2", "smoke.flat")
    if os.path.exists(smoke):
        window.load_image(smoke)
        return "demo"
    return None


def _manifest_address(value, field):
    """Normalize a JSON address written as either a number or ``"0x…"`` text."""
    if isinstance(value, bool):
        raise TypeError(f"{field} must be an integer or hexadecimal string")
    if isinstance(value, int):
        address = value
    elif isinstance(value, str):
        address = int(value, 0)
    else:
        raise TypeError(f"{field} must be an integer or hexadecimal string")
    if not 0 <= address <= 0xFFFFFFFF:
        raise ValueError(f"{field} lies outside the 32-bit address space")
    return address


def _manifest_bool(value, field):
    """Require an actual JSON boolean for launch-mode manifest fields."""
    if not isinstance(value, bool):
        raise TypeError(f"{field} must be true or false")
    return value


def _validate_segments(segments):
    """Reject any byte range that cannot be represented by the 32-bit core."""
    for address, chunk in segments:
        end = address + len(chunk)
        if address < 0 or address > 0xFFFFFFFF or end > 0x1_0000_0000:
            raise ValueError(
                f"segment at 0x{address:x} ({len(chunk)} bytes) crosses "
                "the 32-bit address-space limit")


def _system_load_address(size):
    if not 0 < size <= 0x00100000:
        raise ValueError(
            "a BIOS/system image must be between 1 byte and 1 MiB so it can "
            "be top-aligned below the reset vector")
    return 0x00100000 - size


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
    if not data:
        raise ValueError("program file is empty")
    if data[:4] != b"\x7fELF":
        if data[:2] == b"MZ" and str(path).lower().endswith((".exe", ".dll")):
            raise ValueError(
                "DOS/PE executables are not supported; use a raw image "
                "(.flat/.bin/.img/.rom) or a little-endian x86 ELF")
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
            p_type, p_offset, p_vaddr, _paddr, p_filesz, p_memsz, _flags, _align = fields
        else:
            p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, p_memsz, _align = fields
        if p_type != 1 or not p_filesz:
            continue
        if (p_filesz > p_memsz or p_vaddr > 0xffffffff or
                p_vaddr + p_memsz > 0x1_0000_0000 or
                p_offset + p_filesz > len(data)):
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
    p.setColor(QPalette.PlaceholderText, QColor("#6e7681"))
    p.setColor(QPalette.ToolTipBase, QColor("#161b22"))
    p.setColor(QPalette.ToolTipText, QColor("#c9d1d9"))
    for role in (QPalette.WindowText, QPalette.Text, QPalette.ButtonText):
        p.setColor(QPalette.Disabled, role, QColor("#586069"))
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
        "QLineEdit:disabled{color:#484f58;background:#0b0f14;border-color:#21262d;}"
        "QPushButton{background:#21262d;border:1px solid #30363d;padding:3px 8px;}"
        "QPushButton:hover{background:#30363d;}"
        "QPushButton:disabled{color:#6e7681;}"
        "QCheckBox:disabled{color:#586069;}"
        "QSplitter::handle{background:#30363d;}"
        "QSplitter::handle:hover{background:#484f58;}"
        "QToolBar QLabel{color:#8b949e;}"
        "QToolBar QLabel:disabled{color:#484f58;}")


def _hex_edit(val, width=92):
    e = QLineEdit(f"0x{val:08x}")
    e.setFixedWidth(width)
    e.setValidator(QRegularExpressionValidator(
        QRegularExpression(r"0[xX][0-9a-fA-F]{1,8}"), e))
    f = QFont("monospace"); f.setStyleHint(QFont.Monospace); e.setFont(f)
    return e


def _parse_hex(e):
    try:
        value = int(e.text(), 0)
        if not 0 <= value <= 0xFFFFFFFF:
            raise ValueError
        e.setStyleSheet("")
        return value
    except ValueError:
        e.setStyleSheet("border:1px solid #f85149;")
        return None


def _session_progress(raw_ret, core_cyc, start_cyc, first_visible_n=None,
                      snapshot=False):
    """Return (visible retirements, elapsed session clocks, IPC).

    Snapshot-capable libraries before the retirement-epoch bridge fix expose a
    large first retirement ID. Subtract it only for a restored session; normal
    programs retain lifetime totals even if their GUI row ring has rolled.
    """
    retired = (
        max(0, int(raw_ret) - int(first_visible_n))
        if snapshot and first_visible_n is not None else int(raw_ret))
    elapsed = max(0, int(core_cyc) - int(start_cyc) + 1)
    return retired, elapsed, retired / max(1, elapsed)


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
        self._applied_reset_config = None
        self._session_start_cyc = 1
        self._assembly_source_map = {}
        self._assembly_link_line = None
        self._pinned_n = None
        self._source_workspace_active = False
        self._visual_toolbar_visibility = None
        verify_dir = os.path.join(_REPO_ROOT, "build", "verify")
        self._last_program_dir = verify_dir if os.path.isdir(verify_dir) else os.getcwd()
        self._last_snapshot_dir = os.getcwd()
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
        self._sync_config_enabled()
        self._refresh_status()

    def _build_menus(self):
        file_menu = self.menuBar().addMenu("&File")
        self.open_action = QAction("Open program…", self)
        self.open_action.setShortcut(QKeySequence("Ctrl+O"))
        self.open_action.triggered.connect(self.on_open)
        file_menu.addAction(self.open_action)
        self.save_source_action = QAction("Save source", self)
        self.save_source_action.setShortcut(QKeySequence("Ctrl+S"))
        self.save_source_action.setEnabled(False)
        self.save_source_action.triggered.connect(self._save_active_source)
        file_menu.addAction(self.save_source_action)
        snapshot_action = QAction("Open snapshot…", self)
        snapshot_action.setShortcut(QKeySequence("Ctrl+Shift+O"))
        snapshot_action.triggered.connect(self.on_open_snapshot)
        file_menu.addAction(snapshot_action)
        self.reload_action = QAction("Reload program from disk", self)
        self.reload_action.setShortcut(QKeySequence("Ctrl+Shift+R"))
        self.reload_action.setToolTip(
            "Re-read the current program after rebuilding it")
        self.reload_action.triggered.connect(self.reload_program)
        self.reload_action.setEnabled(False)
        file_menu.addAction(self.reload_action)
        examples_menu = file_menu.addMenu("Open example")
        self._example_actions = []
        for label, candidates in _EXAMPLES:
            action = QAction(label, self)
            action.triggered.connect(
                lambda _checked=False, example_candidates=candidates:
                self._open_example(example_candidates))
            examples_menu.addAction(action)
            self._example_actions.append((action, candidates))
        examples_menu.aboutToShow.connect(self._refresh_example_actions)
        self._refresh_example_actions()
        self._examples_menu = examples_menu
        file_menu.addSeparator()
        quit_action = QAction("Quit", self)
        quit_action.setShortcut(QKeySequence("Ctrl+Q"))
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)
        self._file_menu = file_menu

        # Alt+V is the documented Visualizer workspace shortcut. Giving the
        # menu the same mnemonic makes QAction dispatch ambiguous on Qt/X11,
        # so retain keyboard menu access on Alt+W instead.
        view_menu = self.menuBar().addMenu("Vie&w")
        workspace_menu = view_menu.addMenu("Workspace")
        self._workspace_actions = []
        for label, key, index in (
                ("Visualizer", "Alt+V", 0),
                ("Assembly", "Alt+A", 1),
                ("C source", "Alt+C", 2)):
            action = QAction(label, self)
            action.setShortcut(QKeySequence(key))
            action.triggered.connect(
                lambda _checked=False, tab_index=index:
                self._select_workspace(tab_index))
            workspace_menu.addAction(action)
            self._workspace_actions.append(action)
        self._workspace_menu = workspace_menu
        view_menu.addSeparator()
        reset_layout = QAction("Reset panel layout", self)
        reset_layout.setShortcut(QKeySequence("Ctrl+0"))
        reset_layout.triggered.connect(self._reset_layout)
        view_menu.addAction(reset_layout)
        view_menu.addSeparator()
        self._toolbar_visibility_actions = []
        for toolbar in (self.session_toolbar, self.transport_toolbar, self.status_toolbar):
            action = toolbar.toggleViewAction()
            action.setText(f"Show {toolbar.windowTitle()} toolbar")
            action.setEnabled(self.workspace.currentIndex() == 0)
            view_menu.addAction(action)
            self._toolbar_visibility_actions.append(action)
        analysis_menu = view_menu.addMenu("Analysis tab")
        self._analysis_actions = []
        for index in range(self.tables.tabs.count()):
            label = self.tables.tabs.tabText(index)
            key = (index + 1) % 10
            action = QAction(label, self)
            action.setShortcut(QKeySequence(f"Alt+{key}"))
            action.triggered.connect(
                lambda _checked=False, tab_index=index:
                self._select_analysis_tab(tab_index))
            analysis_menu.addAction(action)
            self._analysis_actions.append(action)
        self._analysis_menu = analysis_menu
        self._view_menu = view_menu

        menu = self.menuBar().addMenu("&Help")
        guide = QAction("User Guide", self)
        guide.setShortcut(QKeySequence(Qt.Key_F1))
        guide.triggered.connect(lambda: self._show_guide("Getting started"))
        menu.addAction(guide)
        pipeline = QAction("How to read the Pipeline View", self)
        pipeline.triggered.connect(lambda: self._show_guide("Reading the Pipeline View"))
        menu.addAction(pipeline)
        authoring = QAction("Assembly and C workbenches", self)
        authoring.triggered.connect(
            lambda: self._show_guide("Assembly and C workbenches"))
        menu.addAction(authoring)
        shortcuts = QAction("Keyboard and mouse shortcuts", self)
        shortcuts.triggered.connect(self._show_shortcuts)
        menu.addAction(shortcuts)
        self._help_menu = menu
        self._guide_dialog = None
        self._sync_workspace_file_actions()

    def _refresh_example_actions(self):
        """Discover builds lazily so examples compiled after launch appear."""
        for action, candidates in self._example_actions:
            path = _first_repo_file(candidates)
            action.setToolTip(
                os.path.relpath(path, _REPO_ROOT) if path else
                "Not built; expected " + " or ".join(candidates))
            action.setEnabled(path is not None)

    def _open_example(self, candidates):
        path = _first_repo_file(candidates)
        if path is not None:
            self.load_image(path)
        else:
            self._refresh_example_actions()
            self._notice("Example is not built yet")

    def _reset_layout(self):
        self.outer_split.setSizes([880, 760])
        self.left_split.setSizes([500, 470])
        self.right_split.setSizes([600, 300])
        self._notice("Panel layout reset")

    def _select_analysis_tab(self, index):
        if 0 <= index < self.tables.tabs.count():
            # Analysis lives in the Visualizer. Complete the documented
            # navigation even when Alt+1…Alt+0 starts in Assembly or C; changing
            # a hidden tab with no visible outcome makes the shortcut appear
            # broken.
            if self.workspace.currentWidget() is not self.visualizer_tab:
                self.workspace.setCurrentWidget(self.visualizer_tab)
            self.tables.tabs.setCurrentIndex(index)
            self._notice(f"Analysis: {self.tables.tabs.tabText(index)}")
            QTimer.singleShot(
                0, lambda selected=index:
                self._focus_analysis_content(selected))

    def _focus_analysis_content(self, index):
        if (self.workspace.currentIndex() != 0
                or self.tables.tabs.currentIndex() != index):
            return
        targets = (
            self.tables.ic, self.tables.dc, self.tables.tlb, None,
            self.tables.hot, self.tables.br, self.tables.mix, None,
            self.tables.mem.addr_e, self.tables.accmap,
        )
        target = targets[index] if 0 <= index < len(targets) else None
        if (target is None or not target.isEnabled()
                or target.focusPolicy() == Qt.NoFocus):
            target = self.tables.tabs.tabBar()
        if hasattr(target, "rowCount") and target.rowCount():
            if target.currentRow() < 0:
                target.setCurrentCell(0, 0)
        if target.isVisible():
            target.setFocus(Qt.ShortcutFocusReason)

    def _show_guide(self, topic="Getting started"):
        if self._guide_dialog is None:
            self._guide_dialog = UserGuideDialog(self)
        self._guide_dialog.show_page(topic)
        self._guide_dialog.show()
        self._guide_dialog.raise_()
        self._guide_dialog.activateWindow()
        # The guide is explicitly indexed; make that index the deterministic
        # keyboard entry point on first open and every topic-action reopen.
        QTimer.singleShot(
            0, lambda dialog=self._guide_dialog:
            dialog.index.setFocus(Qt.ShortcutFocusReason)
            if dialog.isVisible() else None)

    # ---- UI construction ----
    def _build_toolbar(self):
        tb = QToolBar("session"); tb.setMovable(False)
        self.addToolBar(tb)
        self.session_toolbar = tb

        openbtn = QPushButton(" Open…")
        openbtn.setMinimumWidth(92)
        openbtn.setIcon(self.style().standardIcon(QStyle.SP_DirOpenIcon))
        openbtn.clicked.connect(self.on_open)
        openbtn.setAccessibleName("Open program")
        openbtn.setToolTip("Open a flat binary or x86 ELF executable (you can also drag a file here)")
        tb.addWidget(openbtn)

        snapbtn = QPushButton(" Snapshot…")
        snapbtn.setMinimumWidth(104)
        snapbtn.setAccessibleName("Open snapshot")
        snapbtn.setToolTip("Resume a host-testbench --save-state checkpoint (.aux + .vlt pair)")
        snapbtn.clicked.connect(self.on_open_snapshot)
        tb.addWidget(snapbtn)

        self.entry_label = QLabel("  entry ")
        tb.addWidget(self.entry_label)
        self.entry_e = _hex_edit(DEF_ENTRY)
        self.entry_e.setAccessibleName("Program entry address")
        self.entry_e.setToolTip(
            "Initial instruction pointer (32-bit hex; applies on Reset)")
        tb.addWidget(self.entry_e)
        self.load_label = QLabel(" load ")
        tb.addWidget(self.load_label)
        self.load_e = _hex_edit(DEF_ENTRY)
        self.load_e.setAccessibleName("Flat-image load address")
        self.load_e.setToolTip(
            "Flat-image load address (32-bit hex; applies on Reset)")
        tb.addWidget(self.load_e)
        self.esp_label = QLabel(" esp ")
        tb.addWidget(self.esp_label)
        self.esp_e = _hex_edit(DEF_ESP)
        self.esp_e.setAccessibleName("Initial stack pointer")
        self.esp_e.setToolTip(
            "Initial stack pointer (32-bit hex; applies on Reset)")
        tb.addWidget(self.esp_e)
        tb.addSeparator()   # file/load | config

        self.cyc_cb = QCheckBox("U/V issue"); self.cyc_cb.setChecked(True)
        self.cyc_cb.setToolTip(
            "Enable Pentium-style U/V dual issue (applies on Reset); "
            "untick to compare single issue")
        tb.addWidget(self.cyc_cb)
        self.sys_cb = QCheckBox("system")
        self.sys_cb.setToolTip(
            "Boot a raw BIOS image at F000:FFF0 (applies on Reset)")
        tb.addWidget(self.sys_cb)
        self.soc_cb = QCheckBox("SoC")
        self.soc_cb.setToolTip("Run the full ventium_soc (internal port-I/O / PIC / "
                               "PIT) — needed for bare-metal images like test386. "
                               "Requires build.sh --soc; applies on Reset.")
        tb.addWidget(self.soc_cb)
        self._config_widgets = (
            self.entry_e, self.load_e, self.esp_e,
            self.cyc_cb, self.sys_cb, self.soc_cb,
        )
        for edit in (self.entry_e, self.load_e, self.esp_e):
            edit.textEdited.connect(self._mark_reset_required)
        self.cyc_cb.toggled.connect(self._mark_reset_required)
        self.sys_cb.toggled.connect(self._system_toggled)
        self.soc_cb.toggled.connect(self._soc_toggled)

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
        self.stepn.setAccessibleName("Step clock count")
        self.stepn.setToolTip("Number of clocks advanced by Step N")
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
        self.speed.setAccessibleName("Run clocks per timer tick")
        self.speed.setToolTip(
            "Clocks simulated per UI timer tick while Run is active")
        self.speed.setSuffix(" clk/tick"); self.speed.setFixedWidth(110)
        ctl.addWidget(self.speed)

        ctl.addSeparator()   # transport | event-jump
        ctl.addWidget(QLabel(" event "))
        self.event_kind = QComboBox()
        self.event_kind.addItem("any", "any")
        self.event_kind.addItem("mispredict", "m")
        self.event_kind.addItem("stall", "s")
        self.event_kind.addItem("I-fill", "f")
        self.event_kind.addItem("page-walk", "w")
        self.event_kind.setFixedWidth(112)
        self.event_kind.setAccessibleName("Pipeline event type")
        self.event_kind.setToolTip(
            "Choose which pipeline event [ and ] navigate")
        ctl.addWidget(self.event_kind)
        self.evprev_btn = QPushButton("◀")
        self.evprev_btn.setAccessibleName("Previous pipeline event")
        self.evprev_btn.setToolTip("Jump the playhead to the PREVIOUS pipeline event "
                                   "(mispredict / stall / I-fill / page-walk)")
        self.evprev_btn.clicked.connect(lambda: self._jump_event(-1))
        ctl.addWidget(self.evprev_btn)
        self.evnext_btn = QPushButton("▶")
        self.evnext_btn.setAccessibleName("Next pipeline event")
        self.evnext_btn.setToolTip("Jump the playhead to the NEXT pipeline event "
                                   "(mispredict / stall / I-fill / page-walk)")
        self.evnext_btn.clicked.connect(lambda: self._jump_event(1))
        ctl.addWidget(self.evnext_btn)

        # status toolbar (third row)
        self.addToolBarBreak()
        sb = QToolBar("status"); sb.setMovable(False); self.addToolBar(sb)
        self.status_toolbar = sb
        self.status_lbl = QLabel("  no image loaded  ")
        # Let the status consume the row's spare width while retaining the
        # high-value left-hand metrics. QToolBar can shrink this below its rich
        # text hint, so it no longer forces the whole window wider.
        self.status_lbl.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        self.status_lbl.setMinimumWidth(600)
        f = QFont("monospace"); f.setStyleHint(QFont.Monospace); self.status_lbl.setFont(f)
        sb.addWidget(self.status_lbl)
        self.action_hint = QLabel("")
        self.action_hint.setSizePolicy(QSizePolicy.Maximum, QSizePolicy.Preferred)
        self.action_hint.setStyleSheet("color:#8b949e;padding-left:12px;")
        sb.addWidget(self.action_hint)

        # shortcuts
        self._transport_shortcut_actions = []
        for key, fn in [(Qt.Key_Period, lambda: self.do_step(1, False)),
                        (Qt.Key_Space, lambda: self.do_step(200000, True)),
                        (Qt.Key_F5, self.on_run_toggle),
                        (Qt.Key_R, self.on_reset)]:
            a = QAction(self); a.setShortcut(QKeySequence(key)); a.triggered.connect(fn)
            self.addAction(a)
            self._transport_shortcut_actions.append(a)

    def _has_session(self):
        return self.image_bytes is not None or self.snapshot_prefix is not None

    def _mark_reset_required(self, *_args):
        if not self._has_session() or self.snapshot_prefix:
            return
        if self._current_reset_config() == self._applied_reset_config:
            self._clear_reset_required()
            self._notice("Setup matches running model · no reset needed")
            return
        self.reset_btn.setText(" Apply + Reset")
        self.reset_btn.setStyleSheet("border:1px solid #e3b341;")
        self.reset_btn.setToolTip(
            "Apply changed addresses/mode on a fresh model (R)")
        self._notice("Setup changed — Reset to apply")

    def _current_reset_config(self):
        """Return only launch fields consumed by Reset, normalized by value."""
        if self.image_bytes is None or self.snapshot_prefix:
            return None

        def hex_value(field):
            try:
                value = int(field.text(), 0)
                return value if 0 <= value <= 0xffffffff else None
            except ValueError:
                return None

        soc = self.soc_cb.isChecked()
        system = self.sys_cb.isChecked() or soc
        return (
            self.cyc_cb.isChecked(), system, soc,
            None if system else hex_value(self.entry_e),
            None if system else hex_value(self.esp_e),
            (hex_value(self.load_e)
             if not system and self.image_kind == "flat image" else None),
        )

    def _soc_toggled(self, checked):
        if checked and not self.sys_cb.isChecked():
            self.sys_cb.setChecked(True)
        self._sync_config_enabled()
        self._mark_reset_required()

    def _system_toggled(self, checked):
        if not checked and self.soc_cb.isChecked():
            self.soc_cb.setChecked(False)
        self._sync_config_enabled()
        self._mark_reset_required()

    def _sync_config_enabled(self):
        """Expose only reset fields that the selected launch mode will consume."""
        program = self.image_bytes is not None and self.snapshot_prefix is None
        system = self.sys_cb.isChecked() or self.soc_cb.isChecked()
        user = program and not system
        self.entry_e.setEnabled(user)
        self.esp_e.setEnabled(user)
        self.load_e.setEnabled(user and self.image_kind == "flat image")
        self.entry_label.setEnabled(user)
        self.esp_label.setEnabled(user)
        self.load_label.setEnabled(user and self.image_kind == "flat image")
        if not user:
            for field in (self.entry_e, self.load_e, self.esp_e):
                field.setStyleSheet("")
        elif self.image_kind != "flat image":
            self.load_e.setStyleSheet("")
        for widget in (self.cyc_cb, self.sys_cb, self.soc_cb):
            widget.setEnabled(program)
        if system:
            self.entry_e.setToolTip(
                "System boot starts at the architectural reset vector F000:FFF0")
            self.load_e.setToolTip(
                "The raw system image is top-aligned below 1 MiB automatically")
            self.esp_e.setToolTip(
                "System firmware establishes its own stack after reset")
        else:
            self.entry_e.setToolTip(
                "Initial instruction pointer (32-bit hex; applies on Reset)")
            self.load_e.setToolTip(
                "Load address for a flat image" if self.image_kind == "flat image"
                else "ELF segment addresses come from its PT_LOAD headers")
            self.esp_e.setToolTip(
                "Initial stack pointer (32-bit hex; applies on Reset)")

    def _clear_reset_required(self):
        self.reset_btn.setText(" Reset")
        self.reset_btn.setStyleSheet("")
        self.reset_btn.setToolTip("Re-cold-reset the loaded program on a fresh model (R)")

    def _set_transport_enabled(self, enabled):
        """Keep controls honest: a fresh window cannot accidentally look runnable."""
        self.reset_btn.setEnabled(enabled)
        for w in (self.evprev_btn, self.evnext_btn):
            w.setEnabled(enabled)
        self.event_kind.setEnabled(enabled)
        runnable = enabled and not self.backend.is_done()
        for w in (self.step1_btn, self.stepi_btn, self.stepn,
                  self.stepn_btn, self.run_btn, self.speed):
            w.setEnabled(runnable)

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
        self.regs.unpinRequested.connect(self._return_live)
        # Tables can scroll and the register bank becomes tabbed when its three
        # complete columns no longer fit.
        # Ignore their wide content hints so the outer splitter can truly honor
        # a 1280px application window.
        self.tables.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
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
        # Give the right side enough room for the content-weighted x87 column
        # (20 hex digits + decoded value + metadata) while retaining a wide
        # 850px linked Trace/timeline at the 1640px reference size.
        outer.setSizes([850, 790])
        for sp in (outer, left, right):
            sp.setHandleWidth(4)
        self.workspace = QTabWidget()
        self.workspace.setDocumentMode(True)
        self.workspace.setTabPosition(QTabWidget.North)
        self.workspace.setAccessibleName("Pipeviz workspace")
        self.workspace.tabBar().setAccessibleName("Workspace tabs")
        self.visualizer_tab = outer
        self.assembly = AssemblyView()
        self.c_source = CView()
        self.workspace.addTab(self.visualizer_tab, "Visualizer")
        self.workspace.addTab(self.assembly, "Assembly")
        self.workspace.addTab(self.c_source, "C")
        self.workspace.setTabToolTip(
            0, "Run programs and investigate pipeline behavior")
        self.workspace.setTabToolTip(
            1, "Edit, complete, assemble, and run 32-bit Intel-syntax assembly")
        self.workspace.setTabToolTip(
            2, "Compile a freestanding C experiment into editable assembly")
        self.setCentralWidget(self.workspace)
        self.assembly.runRequested.connect(self._run_assembly)
        self.assembly.statusChanged.connect(self._authoring_notice)
        self.assembly.dirtyChanged.connect(self._assembly_dirty_changed)
        self.c_source.assemblyGenerated.connect(self._accept_compiled_assembly)
        self.c_source.statusChanged.connect(self._authoring_notice)
        self.c_source.dirtyChanged.connect(self._c_dirty_changed)
        # two-way link: trace row <-> exact Konata retirement. A cycle-only
        # trace link is ambiguous whenever U and V retire together.
        self.trace.instSelected.connect(self.pipeline.select_n)
        self.pipeline.konata.plot.rowClicked.connect(
            self._select_retirement_origin)
        # selecting an instruction (either side) PINS the register panel to its
        # post-commit architectural state + drops a playhead at its cycle.
        self.trace.instSelected.connect(self._pin_to)
        self.pipeline.konata.plot.escapeRequested.connect(
            self._escape_visualizer)
        # The stage board represents the instructions that are live *now*, before
        # they necessarily have a retirement record. Link its occupied U/V/FP
        # cells directly by PC so authored source navigation works in-flight too.
        self.pipeline.board.instructionClicked.connect(
            self._live_instruction_clicked)
        self.pipeline.spark.cycleClicked.connect(self._cycle_seeked)
        # drill-down: click a Hotspots / Branches PC row -> jump the trace to it
        self.tables.pcClicked.connect(self._select_pc_origin)
        # drill-down: click a Mem-map access point -> jump the trace to that retire n
        # (+ pin regs), so an outlier/stripe in the scatter is one click from its row.
        self.tables.accmap.pointSelected.connect(
            self._select_retirement_origin)

        # keyboard-driven stepping / navigation (a debugger should be drivable from
        # the keyboard): . = step 1 clk, i = step 1 instruction, ] / [ = jump to the
        # next / previous pipeline event (mispredict / stall / I-fill / page-walk).
        # `.` is an QAction in the toolbar shortcut set above. Keep it out of
        # this QShortcut group: registering both lets Qt dispatch a single key
        # press twice on some platform styles, advancing two clocks unexpectedly.
        self._debug_shortcuts = []
        for keys, fn in [("i", lambda: self.do_step(1, True)),
                         ("]", lambda: self._jump_event(1)),
                         ("[", lambda: self._jump_event(-1))]:
            shortcut = QShortcut(QKeySequence(keys), self)
            shortcut.activated.connect(fn)
            self._debug_shortcuts.append(shortcut)
        # Search should be reachable from anywhere in the debugger, not only
        # after first clicking the trace table.
        search_shortcut = QShortcut(QKeySequence("/"), self)
        search_shortcut.activated.connect(self.trace.focus_filter)
        self._debug_shortcuts.append(search_shortcut)
        self.workspace.currentChanged.connect(self._workspace_changed)
        self._workspace_changed(self.workspace.currentIndex())

    def _escape_visualizer(self):
        """Resolve Escape from the narrowest transient context outward."""
        if self.trace.filt.text():
            self.trace.filt.clear()
        elif getattr(self, "_pinned_n", None) is not None:
            self._return_live()

    def _select_workspace(self, index):
        if 0 <= index < self.workspace.count():
            self.workspace.setCurrentIndex(index)
            self._notice(f"Workspace: {self.workspace.tabText(index)}")

    def _workspace_changed(self, index):
        """Plain debugger keys must remain ordinary text in source editors."""
        visualizer = index == 0
        for action in self._transport_shortcut_actions:
            action.setEnabled(visualizer)
        for shortcut in self._debug_shortcuts:
            shortcut.setEnabled(visualizer)
        for action in getattr(self, "_toolbar_visibility_actions", ()):
            # Source workspaces intentionally own the full height. Prevent the
            # View menu or toolbar context menu from reintroducing Visualizer
            # chrome over an editor while still preserving each user's chosen
            # visibility for the next Visualizer visit.
            action.setEnabled(visualizer)
        toolbars = (
            self.session_toolbar, self.transport_toolbar, self.status_toolbar)
        if not visualizer and not self._source_workspace_active:
            self._visual_toolbar_visibility = tuple(
                not toolbar.isHidden() for toolbar in toolbars)
            for toolbar in toolbars:
                toolbar.hide()
            self._source_workspace_active = True
        elif visualizer and self._source_workspace_active:
            visibility = self._visual_toolbar_visibility or (True, True, True)
            for toolbar, shown in zip(toolbars, visibility):
                toolbar.setVisible(shown)
            self._source_workspace_active = False
        self._sync_workspace_file_actions()
        # A workspace shortcut should complete the navigation, not strand
        # keyboard focus on a now-hidden tab. Defer until the tab switch event
        # finishes so mouse/shortcut dispatch cannot immediately steal it back.
        QTimer.singleShot(
            0, lambda selected=index:
            self._focus_workspace_content(selected))

    def _focus_workspace_content(self, index):
        if self.workspace.currentIndex() != index:
            return
        target = (
            self.pipeline.konata.plot if index == 0 else
            self.assembly.editor if index == 1 else
            self.c_source.editor if index == 2 else None)
        if target is not None and target.isVisible():
            target.setFocus(Qt.ShortcutFocusReason)

    def _sync_workspace_file_actions(self):
        if not hasattr(self, "open_action"):
            return
        index = self.workspace.currentIndex()
        labels = (
            ("Open program…", "Open a raw image or 32-bit x86 ELF"),
            ("Open assembly source…", "Open GNU Intel-syntax assembly"),
            ("Open C source…", "Open a freestanding C source file"),
        )
        label, tip = labels[index] if 0 <= index < len(labels) else labels[0]
        self.open_action.setText(label)
        self.open_action.setToolTip(f"{tip} (Ctrl+O)")
        self.save_source_action.setEnabled(index in (1, 2))
        self.save_source_action.setText(
            "Save assembly source" if index == 1 else
            "Save C source" if index == 2 else "Save source")
        # Reload means "re-read the already-built program", not "rebuild this
        # source editor." Keeping it active over Assembly/C makes Ctrl+Shift+R
        # run an older generated ELF and invalidate source links behind the
        # user's current text. Authoring has explicit Compile/Assemble actions.
        self.reload_action.setEnabled(index == 0 and self.image_path is not None)

    def _save_active_source(self):
        source = (
            self.assembly if self.workspace.currentIndex() == 1 else
            self.c_source if self.workspace.currentIndex() == 2 else None)
        if source is not None:
            source.save_source()

    def _clear_assembly_source_link(self):
        self._assembly_source_map = {}
        self._clear_assembly_marker()

    def _clear_assembly_marker(self, pc=None):
        """Clear only the selected line while retaining the live PC map."""
        self._assembly_link_line = None
        self.assembly.editor.mark_execution_line(None)
        if (pc is not None and self._assembly_source_map
                and self.assembly.mapping_current):
            self.assembly.status.setText(
                f"Selected PC 0x{int(pc):08x} is generated and has no editor source line")
            self.assembly.status.setStyleSheet("color:#8b949e;padding:2px;")
        self._update_assembly_tab()

    def _update_assembly_tab(self):
        dirty = self.assembly.editor.document().isModified()
        label = "Assembly *" if dirty else "Assembly"
        if self._assembly_link_line is not None and self.assembly.mapping_current:
            label += f" · L{self._assembly_link_line}"
        self.workspace.setTabText(1, label)
        if self._assembly_link_line is not None and self.assembly.mapping_current:
            tip = (
                f"Selected assembly line {self._assembly_link_line}"
                + (" · source has unsaved changes" if dirty else ""))
        elif dirty:
            tip = "Assembly has unsaved changes; Ctrl+S saves the source"
        else:
            tip = "Edit, complete, assemble, and run 32-bit Intel-syntax assembly"
        self.workspace.setTabToolTip(1, tip)

    def _assembly_dirty_changed(self, _dirty):
        self._update_assembly_tab()

    def _c_dirty_changed(self, dirty):
        self.workspace.setTabText(2, "C *" if dirty else "C")
        self.workspace.setTabToolTip(
            2,
            "C has unsaved changes; Ctrl+S saves the source"
            if dirty else
            "Compile a freestanding C experiment into editable assembly")

    def _authoring_notice(self, text):
        if text in ("Assembly source modified", "Assembly source replaced"):
            self._clear_assembly_source_link()
        self._notice(text)

    def _accept_compiled_assembly(self, source, optimization):
        if not self.assembly.set_source(
                source, f"C compiler ({optimization})"):
            self.c_source.status.setText(
                "C compiled · keeping unsaved Assembly (replacement cancelled)")
            self.c_source.status.setStyleSheet("color:#e3b341;padding:2px;")
            self._notice(
                "C compiled, but generated assembly was not opened")
            return
        self.workspace.setCurrentWidget(self.assembly)
        self._notice("C compiled — review or edit the generated assembly, then run")

    def _run_assembly(self, path, source_map):
        if self.load_image(path):
            self._assembly_source_map = dict(source_map)
            self._update_assembly_tab()
            self.workspace.setCurrentWidget(self.visualizer_tab)
            self._notice(
                f"Running authored assembly · {len(source_map)} source-linked instructions")

    # ---- image loading ----
    def on_open(self):
        if self.workspace.currentWidget() is self.assembly:
            self.assembly.open_source()
            return
        if self.workspace.currentWidget() is self.c_source:
            self.c_source.open_source()
            return
        path, _ = QFileDialog.getOpenFileName(
            self, "Open program", self._last_program_dir,
            _PROGRAM_FILTER)
        if path:
            self.load_image(path)

    def reload_program(self):
        if self.image_path:
            self.load_image(self.image_path, preserve_setup=True)

    def load_image(self, path, preserve_setup=False):
        previous = {
            "image_path": self.image_path,
            "image_bytes": self.image_bytes,
            "image_segments": self.image_segments,
            "image_kind": self.image_kind,
            "snapshot_prefix": self.snapshot_prefix,
            "last_program_dir": self._last_program_dir,
            "entry": self.entry_e.text(),
            "load": self.load_e.text(),
            "esp": self.esp_e.text(),
            "cycle": self.cyc_cb.isChecked(),
            "system": self.sys_cb.isChecked(),
            "soc": self.soc_cb.isChecked(),
            "reload_enabled": self.reload_action.isEnabled(),
            "title": self.windowTitle(),
            "reset_text": self.reset_btn.text(),
            "reset_tip": self.reset_btn.toolTip(),
            "reset_style": self.reset_btn.styleSheet(),
            "notice": self.action_hint.text(),
        }
        setup = None
        if preserve_setup:
            system = self.sys_cb.isChecked() or self.soc_cb.isChecked()
            if not system:
                address_fields = [
                    (self.entry_e, "entry"),
                    (self.esp_e, "esp"),
                ]
                if self.image_kind == "flat image":
                    address_fields.append((self.load_e, "load"))
                invalid = next(
                    ((widget, label) for widget, label in address_fields
                     if _parse_hex(widget) is None),
                    None)
                if invalid is not None:
                    widget, label = invalid
                    widget.setFocus()
                    QMessageBox.warning(
                        self, "Invalid address",
                        f"Cannot reload while {label} is invalid. Enter a 32-bit "
                        "hexadecimal address, then reload again.")
                    return False
            setup = {
                "kind": self.image_kind,
                "entry": self.entry_e.text(),
                "load": self.load_e.text(),
                "esp": self.esp_e.text(),
                "cycle": self.cyc_cb.isChecked(),
                "system": self.sys_cb.isChecked(),
                "soc": self.soc_cb.isChecked(),
            }
        try:
            segments, entry, kind = _read_program(path)
            data = b"".join(chunk for _, chunk in segments)
        except (OSError, ValueError, struct.error) as e:
            QMessageBox.critical(self, "Open failed", str(e)); return False
        # Honour a sibling manifest transactionally. A malformed later field
        # must not leave an earlier entry/load override partially applied.
        man = os.path.join(os.path.dirname(path), "manifest.json")
        load = min(addr for addr, _ in segments)
        manifest_esp = None
        manifest_uv = None
        manifest_system = None
        manifest_soc = None
        if os.path.exists(man):
            try:
                with open(man, encoding="utf-8") as mf:
                    m = json.load(mf)
                if not isinstance(m, dict):
                    raise TypeError("manifest root must be a JSON object")
                candidate_entry = (
                    _manifest_address(m["entry"], "entry")
                    if "entry" in m else entry)
                candidate_load = (
                    _manifest_address(m["load_addr"], "load_addr")
                    if "load_addr" in m and kind == "flat image" else load)
                candidate_esp = (
                    _manifest_address(m["esp"], "esp")
                    if "esp" in m else None)
                candidate_uv = (
                    _manifest_bool(m["uv_issue"], "uv_issue")
                    if "uv_issue" in m else None)
                candidate_system = (
                    _manifest_bool(m["system"], "system")
                    if "system" in m else None)
                candidate_soc = (
                    _manifest_bool(m["soc"], "soc")
                    if "soc" in m else None)
                if candidate_soc and candidate_system is False:
                    raise ValueError("soc=true conflicts with system=false")
                entry, load = candidate_entry, candidate_load
                manifest_esp = candidate_esp
                manifest_uv = candidate_uv
                manifest_system = candidate_system
                manifest_soc = candidate_soc
            except (OSError, ValueError, TypeError, json.JSONDecodeError) as e:
                QMessageBox.warning(self, "Manifest ignored",
                                    f"Could not read {man}: {e}\nLoading the program metadata instead.")
        # A manifest's load address is a flat-image convention.  ELF carries
        # individual virtual addresses in PT_LOAD and must retain those.
        if kind == "flat image":
            segments = [(load, data)]
        try:
            _validate_segments(segments)
        except ValueError as e:
            QMessageBox.critical(self, "Open failed", str(e))
            return False
        self.image_path = path
        self.image_bytes = data
        self.image_segments = segments
        self.image_kind = kind
        self.snapshot_prefix = None
        self._last_program_dir = os.path.dirname(os.path.abspath(path))
        self._sync_workspace_file_actions()
        self._clear_reset_required()
        # Known repository system tests boot at F000:FFF0. A generic large
        # `.bin` is not sufficient evidence: user flat binaries commonly use
        # that extension. External images can opt in via manifest `system`.
        normalized_path = path.replace("\\", "/")
        looks_system = "/sys/tests/" in normalized_path
        # test386 / external CPU tests drive the SoC's port-I/O (POST codes),
        # so they need the full ventium_soc — auto-tick SoC for those.
        looks_soc = any(
            k in normalized_path for k in ("test386", "09-external", "/soc/"))
        if manifest_system is not None or manifest_soc is not None:
            selected_soc = bool(manifest_soc)
            selected_system = bool(manifest_system) or selected_soc
        else:
            selected_soc = looks_soc
            selected_system = looks_system or looks_soc
        self.sys_cb.setChecked(selected_system)
        self.soc_cb.setChecked(selected_soc)
        self.entry_e.setText(f"0x{entry:08x}")
        self.load_e.setText(f"0x{load:08x}")
        # A new workload must not inherit the previous workload's private
        # stack choice. Reload below deliberately restores the current setup.
        self.esp_e.setText(
            f"0x{(manifest_esp if manifest_esp is not None else DEF_ESP):08x}")
        if manifest_uv is not None:
            self.cyc_cb.setChecked(manifest_uv)
        if setup is not None:
            # Reload is the edit/compile/debug loop: retain the user's reset
            # configuration while re-reading bytes and ELF segments from disk.
            if setup["kind"] == kind:
                self.entry_e.setText(setup["entry"])
                if kind == "flat image":
                    self.load_e.setText(setup["load"])
            self.esp_e.setText(setup["esp"])
            self.cyc_cb.setChecked(setup["cycle"])
            self.sys_cb.setChecked(setup["system"])
            self.soc_cb.setChecked(setup["soc"])
        for field in (self.entry_e, self.load_e, self.esp_e):
            field.setStyleSheet("")
        self._sync_config_enabled()
        self.setWindowTitle(f"Ventium pipeline visualizer — {os.path.basename(path)} ({kind})")
        if not self.on_reset():
            # Reset validates placement and constructs a replacement backend
            # transactionally. If it rejects the candidate, keep every visible
            # part of the still-live prior session coherent with that backend.
            self.image_path = previous["image_path"]
            self.image_bytes = previous["image_bytes"]
            self.image_segments = previous["image_segments"]
            self.image_kind = previous["image_kind"]
            self.snapshot_prefix = previous["snapshot_prefix"]
            self._last_program_dir = previous["last_program_dir"]
            controls = (
                (self.entry_e, previous["entry"]),
                (self.load_e, previous["load"]),
                (self.esp_e, previous["esp"]),
                (self.cyc_cb, previous["cycle"]),
                (self.sys_cb, previous["system"]),
                (self.soc_cb, previous["soc"]),
            )
            blocked = [(widget, widget.blockSignals(True))
                       for widget, _value in controls]
            for widget, value in controls:
                if isinstance(value, bool):
                    widget.setChecked(value)
                else:
                    widget.setText(value)
            for widget, old_blocked in blocked:
                widget.blockSignals(old_blocked)
            self.reload_action.setEnabled(previous["reload_enabled"])
            self.setWindowTitle(previous["title"])
            self.reset_btn.setText(previous["reset_text"])
            self.reset_btn.setToolTip(previous["reset_tip"])
            self.reset_btn.setStyleSheet(previous["reset_style"])
            self.action_hint.setText(previous["notice"])
            self._sync_config_enabled()
            self._sync_workspace_file_actions()
            return False
        if hasattr(self, "assembly"):
            self._clear_assembly_source_link()
        self._notice(
            f"{'Reloaded' if preserve_setup else 'Loaded'} {kind}: "
            f"{os.path.basename(path)}")
        return True

    def dragEnterEvent(self, event):
        urls = event.mimeData().urls()
        if len(urls) == 1 and urls[0].isLocalFile():
            event.acceptProposedAction()

    def dropEvent(self, event):
        urls = event.mimeData().urls()
        if len(urls) == 1 and urls[0].isLocalFile():
            path = urls[0].toLocalFile()
            self._load_dropped_path(path)
            event.acceptProposedAction()

    def _load_dropped_path(self, path):
        """Route dropped source, snapshot, and program files by their type."""
        suffix = Path(path).suffix.lower()
        if suffix in (".s", ".asm"):
            if self.assembly.load_source(path):
                self.workspace.setCurrentWidget(self.assembly)
                self._notice(f"Opened assembly source: {os.path.basename(path)}")
                return True
            return False
        if suffix in (".c", ".h"):
            if self.c_source.load_source(path):
                self.workspace.setCurrentWidget(self.c_source)
                self._notice(f"Opened C source: {os.path.basename(path)}")
                return True
            return False
        if suffix in (".aux", ".vlt"):
            return bool(self.load_snapshot(path))
        return bool(self.load_image(path))

    def closeEvent(self, event):
        # Closing while Run is active must not leave a timer dispatching into a
        # destroyed Verilator handle during Qt's deferred teardown.
        was_running = self._running
        self.stop_run()
        if not self.assembly.confirm_safe_to_discard("closing pipeviz"):
            if was_running:
                self.on_run_toggle()
            event.ignore()
            return
        if not self.c_source.confirm_safe_to_discard("closing pipeviz"):
            if was_running:
                self.on_run_toggle()
            event.ignore()
            return
        self.backend.close()
        super().closeEvent(event)

    def on_open_snapshot(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open host snapshot", self._last_snapshot_dir,
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
            return False
        old = self.backend
        self.backend = candidate
        old.close()
        self.image_path = None
        self.image_bytes = None
        self.image_segments = []
        self.image_kind = "snapshot"
        self.snapshot_prefix = prefix
        self._applied_reset_config = None
        self._clear_assembly_source_link()
        self._last_snapshot_dir = os.path.dirname(os.path.abspath(prefix))
        self._sync_workspace_file_actions()
        self.sys_cb.setChecked(False)
        self.soc_cb.setChecked(False)
        self.reset_btn.setText(" Restore snapshot")
        self.reset_btn.setToolTip("Discard continued execution and restore this snapshot again")
        self.reset_btn.setStyleSheet("")
        self._sync_config_enabled()
        self.setWindowTitle(f"Ventium pipeline visualizer — snapshot {os.path.basename(prefix)}")
        s = self.backend.state()
        self._session_start_cyc = int(self.backend.cycle_count()) + 1
        bits = 32 if s.cs_d else 16
        for v in (self.pipeline, self.trace, self.tables):
            if hasattr(v, "set_bits"):
                v.set_bits(bits)
        self.pipeline.reset(self.backend)
        self.trace.start_session()
        self.trace.reset()
        self.tables.start_session(self.backend)
        self.regs.start_session()
        self._clear_selection_for_advance()
        self._refresh_all()
        self._set_transport_enabled(True)
        self._notice(f"Restored snapshot at clock {s.clk}")
        return True

    # ---- driving ----
    def _fresh_backend(self, soc=False):
        candidate = None
        fell_back_to_core = False
        try:
            if soc and not Backend.supports_snapshot(self._libpath, soc=True):
                raise FileNotFoundError(
                    "libventium_viz_soc.so is stale or unreadable "
                    "(missing the current replay ABI)")
            candidate = Backend(self._libpath, soc=soc)
        except (FileNotFoundError, OSError, RuntimeError) as e:
            if soc:
                QMessageBox.warning(self, "SoC model missing",
                                    f"{e}\n\nFalling back to ventium_top. Run "
                                    "`tools/pipeviz/build.sh --soc` to build it.")
                fell_back_to_core = True
                try:
                    candidate = Backend(self._libpath, soc=False)
                except (FileNotFoundError, OSError, RuntimeError) as fallback_error:
                    QMessageBox.critical(
                        self, "Backend reset failed", str(fallback_error))
                    return False
            else:
                QMessageBox.critical(self, "Backend reset failed", str(e))
                return False
        old = self.backend
        self.backend = candidate
        old.close()
        # Only advertise the core fallback after its construction succeeded.
        # On a double failure the still-live old backend and visible requested
        # mode must remain coherent.
        if fell_back_to_core:
            self.soc_cb.setChecked(False)
        return True

    def on_reset(self):
        self.stop_run()
        if self.snapshot_prefix:
            return bool(self.load_snapshot(self.snapshot_prefix))
        if self.image_bytes is None:
            return False
        soc = self.soc_cb.isChecked()
        system = self.sys_cb.isChecked() or soc      # SoC always boots system mode
        if system and self.image_kind == "ELF":
            QMessageBox.warning(self, "ELF is a user-mode program",
                                "System/SoC boot expects a raw BIOS image. Untick system "
                                "and SoC to run this ELF at its entry point.")
            return False
        entry = esp = load = None
        if not system:
            entry = _parse_hex(self.entry_e)
            esp = _parse_hex(self.esp_e)
            if self.image_kind == "flat image":
                load = _parse_hex(self.load_e)
            invalid = next((
                (widget, label) for widget, label, value in (
                    (self.entry_e, "entry", entry),
                    (self.load_e, "load", load if self.image_kind == "flat image" else 0),
                    (self.esp_e, "esp", esp),
                ) if value is None), None)
            if invalid is not None:
                widget, label = invalid
                widget.setFocus()
                QMessageBox.warning(
                    self, "Invalid address",
                    f"{label} must be a 32-bit hexadecimal address "
                    "(for example 0x08048000).")
                return False
        # Validate placement while the current backend is still intact.
        if system:
            try:
                load = _system_load_address(len(self.image_bytes))
            except ValueError as e:
                QMessageBox.warning(self, "Invalid system image", str(e))
                return False
            segments = None
        else:
            # ELF images can have several non-contiguous PT_LOAD segments. A
            # flat image remains one segment, so this also keeps the old workflow.
            segments = ([(load, self.image_bytes)]
                        if self.image_kind == "flat image"
                        else self.image_segments)
            try:
                _validate_segments(segments)
            except ValueError as e:
                QMessageBox.warning(self, "Invalid program placement", str(e))
                return False
        # fresh model => clean memory
        if not self._fresh_backend(soc=soc):
            return False
        soc = self.backend.soc                        # may have fallen back
        if system:
            # -bios placement: the image's LAST byte sits at 0x000FFFFF so the
            # reset vector F000:FFF0 -> 0x000FFFF0 lands in it (matches tb_main /
            # qemu-system -bios). entry/esp are seeded by boot_mode in the core.
            self.load_e.setText(f"0x{load:08x}")
            self.backend.load_bytes(self.image_bytes, load)
            self.backend.reset(0, 0, cycle_mode=self.cyc_cb.isChecked(), system=1)
        else:
            for address, chunk in segments:
                self.backend.load_bytes(chunk, address)
            self.backend.reset(entry, esp, cycle_mode=self.cyc_cb.isChecked(), system=0)
        self._session_start_cyc = int(self.backend.cycle_count()) + 1
        bits = 16 if system else 32
        for v in (self.pipeline, self.trace, self.tables):
            if hasattr(v, "set_bits"):
                v.set_bits(bits)
        self.pipeline.reset(self.backend)
        self.trace.start_session()
        self.trace.reset()
        self.tables.start_session(self.backend)
        self.regs.start_session()
        self._clear_selection_for_advance()
        self._applied_reset_config = self._current_reset_config()
        self._clear_reset_required()
        self._refresh_all()
        self._set_transport_enabled(True)
        return True

    # ---- register pinning (AS-OF a retired instruction) + playhead ----
    def _select_retirement_origin(self, n):
        """Route non-Trace drill-down through one exact pin transaction.

        Trace's currentCellChanged signal already synchronizes Pipeline,
        Registers, and Assembly. Pipeline/Mem-map retain a longer history, so
        fall back to a direct pin only when their retirement is no longer in
        Trace's rolling table.
        """
        n = int(n)
        retained = self.trace.select_n(n)
        if not retained or getattr(self, "_pinned_n", None) != n:
            self._pin_to(n)

    def _select_pc_origin(self, pc):
        """Drill a summary PC into Trace, or its longer Pipeline fallback."""
        pc = int(pc)
        if self.trace.select_pc(pc):
            return
        plot = self.pipeline.konata.plot
        candidates = [
            row for row, insn in enumerate(plot.insns)
            if int(insn["pc"]) == pc
        ]
        if not candidates:
            self._notice(
                f"PC 0x{pc:08x} is outside the retained Trace/Pipeline windows")
            return
        row = (
            min(candidates, key=lambda candidate:
                abs(candidate - plot.sel_row))
            if plot.sel_row is not None else candidates[-1])
        selected = plot.insns[row]
        self.pipeline.select_n(int(selected["n"]))
        self._pin_to(int(selected["n"]))
        self._notice(
            f"PC 0x{pc:08x} is outside Trace · selected retained "
            f"Pipeline retirement n={int(selected['n'])}")

    def _highlight_assembly_pc(self, pc, context):
        """Highlight one live/retired PC without requiring a retirement record."""
        pc = int(pc)
        line = self._assembly_source_map.get(pc)
        if (line is not None
                and self.assembly.highlight_pc(pc, line, context)):
            self._assembly_link_line = line
            self._update_assembly_tab()
            self.workspace.setTabToolTip(
                1, f"{context} at PC 0x{pc:08x} maps to assembly line {line}"
                + (" · source has unsaved changes"
                   if self.assembly.editor.document().isModified() else ""))
            return line
        # A generated wrapper/fall-through instruction has no editor line.
        # Never leave the previously selected source line looking current.
        self._clear_assembly_marker(pc)
        return None

    def _live_instruction_clicked(self, pc, lane):
        context = f"In-flight {lane}-lane instruction"
        line = self._highlight_assembly_pc(pc, context)
        if line is None:
            self._notice(
                f"{context} at 0x{int(pc):08x} has no linked Assembly line")
        else:
            self._notice(
                f"{context} at 0x{int(pc):08x} → Assembly line {line} "
                "(Alt+A to inspect)")

    def _cycle_seeked(self, cyc):
        """Describe a playhead-only seek without implying an instruction pin."""
        pinned = self._pinned_n
        self._notice(
            f"Pipeline cycle {int(cyc)} selected · "
            + (f"retirement pin n={pinned} unchanged"
               if pinned is not None else "no instruction pinned"))

    def _pin_to(self, n):
        recs = self.backend.get_retires(max(0, n - 1), 2)
        rec = next((r for r in recs if r.n == n), None)
        if rec is None:
            self._notice(f"Retirement n={int(n)} is no longer available to pin")
            return
        prev = next((r for r in recs if r.n == n - 1), None)
        self._pinned_n = n
        self.regs.show_retire(rec, prev)
        line = self._highlight_assembly_pc(
            rec.pc, f"Retired instruction n={int(rec.n)}")
        lane = "U" if int(rec.pipe) == 0 else (
            "V" if int(rec.pipe) == 1 else "—")
        source = f" · Assembly L{line}" if line is not None else ""
        self._notice(
            f"Pinned retirement n={int(rec.n)} · cycle {int(rec.cyc)} · "
            f"{lane} · PC 0x{int(rec.pc):08x}{source}")

    def _unpin(self):
        if getattr(self, "_pinned_n", None) is not None:
            self._pinned_n = None
            self.regs.unpin()
            self.pipeline.clear_selection()
            self.trace.clear_selection()
            self.tables.clear_linked_selection()
            had_source_context = bool(
                self._assembly_source_map and self.assembly.mapping_current)
            self._clear_assembly_marker()
            if had_source_context:
                self.assembly.status.setText(
                    "Instruction selection cleared · source map remains active")
                self.assembly.status.setStyleSheet(
                    "color:#8b949e;padding:2px;")
            return True
        return False

    def _clear_selection_for_advance(self):
        """Clear any instruction-specific view before model state changes.

        Retired selections own a register pin and are handled atomically by
        `_unpin`.  A live U/V/FP click has no retirement to pin, but its source
        marker is equally transient: after the next clock that PC may no longer
        be in flight.  Keep the valid address-to-line map in either case.
        """
        if self._unpin():
            return True
        if self._assembly_link_line is None:
            return False
        had_source_context = bool(
            self._assembly_source_map and self.assembly.mapping_current)
        self._clear_assembly_marker()
        if had_source_context:
            self.assembly.status.setText(
                "Execution advanced · prior in-flight source marker cleared")
            self.assembly.status.setStyleSheet("color:#8b949e;padding:2px;")
        return True

    def _return_live(self):
        """Clear a historical selection without consuming a model clock."""
        if not self._unpin():
            return
        # `_unpin` changes selection state only. Refresh immediately so the
        # newly LIVE banner can never sit above stale retirement values.
        self._refresh_all()
        self._notice("Returned Registers to LIVE · linked selection cleared")

    def _jump_event(self, direction):
        """Move the Konata playhead to the next/prev pipeline event (mispredict /
        stall / I-fill / page-walk) — fast navigation to where the action is."""
        plot = self.pipeline.konata.plot
        cur = plot.playhead
        if cur is None:                         # no playhead yet: start at an edge
            cur = plot.base_cyc - 1 if direction > 0 else plot.max_cyc + 1
        event_code = self.event_kind.currentData()
        cyc = self.pipeline.spark.next_event(cur, direction, event_code)
        if cyc is not None:
            self.pipeline.highlight_cycle(cyc)
            label = self.event_kind.currentText()
            self._notice(
                f"{'Next' if direction > 0 else 'Previous'} {label} event "
                f"at cycle {cyc}")
        else:
            label = (
                "pipeline event"
                if event_code == "any" else self.event_kind.currentText())
            where = "later" if direction > 0 else "earlier"
            if not self.pipeline.spark.ev:
                self._notice("No captured cycle history yet")
            else:
                self._notice(
                    f"No {where} {label} in the captured timeline")

    def do_step(self, n, stop_on_retire):
        if not self._has_session():
            return
        self._clear_selection_for_advance()
        stepped = self.backend.step(n, stop_on_retire)
        self._refresh_all()
        unit = "instruction boundary" if stop_on_retire else "clock" + ("s" if stepped != 1 else "")
        self._notice(f"Advanced {stepped} {unit}")
        if self.backend.is_done():
            self.stop_run()

    def on_run_toggle(self):
        if self._running:
            self.stop_run()
        elif self._has_session() and not self.backend.is_done():
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
        self._clear_selection_for_advance()
        self.backend.step(self.speed.value(), False)
        self._refresh_all()
        if self.backend.is_done():
            self.stop_run()

    # ---- refresh ----
    def _refresh_all(self):
        s = self.backend.state()
        self.regs.set_session_active(True)
        self.pipeline.update_from(self.backend, s)
        self.trace.update_from(self.backend)   # FIRST: refreshes the access stream the
        #   Hotspots D$-miss column + Mem map + →access all read this same frame
        self.tables.update_from(self.backend, s)
        captured_span = max(
            0, int(s.core_cyc) - self.pipeline.konata.plot.history_start + 1)
        self.tables.set_hotspots(
            self.pipeline.konata.plot.insns, self.trace.accesses, captured_span)
        self.tables.set_branches(self.pipeline.konata.plot.insns)
        self.tables.set_instr_mix(self.pipeline.konata.plot.insns)
        self.tables.mem.set_state(self.backend, s, self.trace.last_access)
        self.tables.accmap.set_accesses(self.trace.accesses)
        self.tables.set_dcache_replay(self.trace.accesses)   # append D$ miss-rate to Data$ header
        if getattr(self, "_pinned_n", None) is None:
            self.regs.update_from(s)   # else keep the pinned AS-OF display
        self._refresh_status(s)
        self._set_transport_enabled(True)

    def _refresh_status(self, s=None):
        if s is None:
            self.status_lbl.setText(
                "  no image loaded — Open a program or choose File → Open example  ")
            return
        name = self.backend.state_name(s.state)
        raw_ret = self.backend.retire_count()
        first_n = getattr(self.trace, "_session_first_n", None)
        # Current bridges rebase post-snapshot retirement IDs to zero. Keep the
        # subtraction as compatibility for older snapshot-capable libraries
        # whose first visible row retained the RTL's large architectural ID.
        ret, _session_cyc, ipc = _session_progress(
            raw_ret, s.core_cyc, self._session_start_cyc, first_n,
            bool(self.snapshot_prefix))
        st = self.pipeline.waterfall.stats()
        captured_ret = st["uret"] + st["vret"]
        # Plot history can intentionally be bounded after a very large step.
        # Pairing must use that same captured denominator, never lifetime `ret`.
        prate = (2 * st["vret"] / captured_ret * 100
                 if captured_ret else 0.0)
        windowed = self.pipeline.konata._history_truncated
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
                + "&nbsp;&nbsp;" + chip("pair(win)" if windowed else "pair",
                                        f"{prate:.0f}%")
                + "&nbsp;&nbsp;" + chip("mispred(win)" if windowed else "mispred",
                                        st["mispred"], st["mispred"] > 0),
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
        self.status_lbl.setToolTip(
            "pair and mispredict cover the latest Pipeline cycle window; "
            "ret and IPC cover the current program/restore session"
            if windowed else
            "ret, IPC, pair, and mispredict cover the captured session")


def main():
    ap = argparse.ArgumentParser(description="Ventium pipeline visualizer")
    ap.add_argument("image", nargs="?", help="flat image or x86 ELF to load on startup")
    ap.add_argument("--entry", type=lambda x: int(x, 0), default=None)
    ap.add_argument("--load", type=lambda x: int(x, 0), default=None,
                    help="load address override for a flat image")
    ap.add_argument("--esp", type=lambda x: int(x, 0), default=None)
    ap.add_argument("--system", action="store_true", help="boot a raw BIOS/system image")
    ap.add_argument("--soc", action="store_true", help="use the full SoC backend (implies --system)")
    ap.add_argument("--snapshot", "--restore-state", dest="snapshot", default=None,
                    help="resume a host-TB --save-state prefix (.aux + .vlt)")
    ap.add_argument("--lib", default=None, help="path to libventium_viz.so")
    args = ap.parse_args()
    if args.snapshot and args.image:
        ap.error("an image and --snapshot are mutually exclusive startup targets")
    if args.snapshot and (
            args.entry is not None or args.load is not None or
            args.esp is not None or args.system or args.soc):
        ap.error("reset-address and mode overrides cannot be combined with --snapshot")

    app = QApplication(sys.argv)
    _apply_dark(app)
    try:
        win = MainWindow(libpath=args.lib)
    except FileNotFoundError as e:
        QMessageBox.critical(None, "Backend missing", str(e))
        return 1
    target_kind = _load_startup_target(
        win, image=args.image, snapshot=args.snapshot)
    if target_kind in ("image", "demo") and win.image_bytes is not None:
        # Apply command-line choices *after* program metadata.  Previously
        # load_image() overwrote --entry, making the documented flag ineffective.
        if args.entry is not None:
            win.entry_e.setText(f"0x{args.entry:08x}")
        if args.load is not None:
            win.load_e.setText(f"0x{args.load:08x}")
            if win.image_kind == "flat image":
                win.image_segments = [(args.load, win.image_bytes)]
        esp = args.esp if args.esp is not None else DEF_ESP
        win.esp_e.setText(f"0x{esp:08x}")
        if args.system or args.soc:
            win.sys_cb.setChecked(True)
            win.soc_cb.setChecked(args.soc)
        if (args.entry is not None or args.load is not None or args.system or
                args.soc or args.esp is not None):
            win.on_reset()
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
