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

from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QToolBar, QLabel,
                               QLineEdit, QPushButton, QCheckBox, QSpinBox, QSplitter,
                               QFileDialog, QMessageBox, QStyle)
from PySide6.QtGui import QAction, QFont, QPalette, QColor, QKeySequence
from PySide6.QtCore import Qt, QTimer

from .backend import Backend
from .pipeline_view import PipelineView
from .tables_view import TablesView
from .trace_view import TraceView
from .regs_view import RegsView

DEF_ENTRY = 0x08048000
DEF_ESP = 0x40c34910


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
        "QTabBar::tab{background:#161b22;color:#8b949e;padding:4px 10px;border:1px solid #30363d;}"
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

        self._build_toolbar()
        self._build_central()

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._on_run_tick)
        self._running = False
        self._refresh_status()

    # ---- UI construction ----
    def _build_toolbar(self):
        tb = QToolBar("main"); tb.setMovable(False)
        self.addToolBar(tb)

        openbtn = QPushButton(" Open image…")
        openbtn.setIcon(self.style().standardIcon(QStyle.SP_DirOpenIcon))
        openbtn.clicked.connect(self.on_open)
        tb.addWidget(openbtn)

        tb.addWidget(QLabel("  entry "))
        self.entry_e = _hex_edit(DEF_ENTRY); tb.addWidget(self.entry_e)
        tb.addWidget(QLabel(" load "))
        self.load_e = _hex_edit(DEF_ENTRY); tb.addWidget(self.load_e)
        tb.addWidget(QLabel(" esp "))
        self.esp_e = _hex_edit(DEF_ESP); tb.addWidget(self.esp_e)
        tb.addSeparator()   # file/load | config

        self.cyc_cb = QCheckBox("cycle (dual-issue)"); self.cyc_cb.setChecked(True)
        tb.addWidget(self.cyc_cb)
        self.sys_cb = QCheckBox("system"); tb.addWidget(self.sys_cb)
        self.soc_cb = QCheckBox("SoC")
        self.soc_cb.setToolTip("Run the full ventium_soc (internal port-I/O / PIC / "
                               "PIT) — needed for bare-metal images like test386. "
                               "Requires build.sh --soc.")
        tb.addWidget(self.soc_cb)
        tb.addSeparator()

        self.reset_btn = QPushButton(" Reset")
        self.reset_btn.setIcon(self.style().standardIcon(QStyle.SP_BrowserReload))
        self.reset_btn.clicked.connect(self.on_reset)
        tb.addWidget(self.reset_btn)

        self.step1_btn = QPushButton("Step clk")
        self.step1_btn.clicked.connect(lambda: self.do_step(1, False))
        tb.addWidget(self.step1_btn)
        self.stepi_btn = QPushButton("Step insn")
        self.stepi_btn.clicked.connect(lambda: self.do_step(200000, True))
        tb.addWidget(self.stepi_btn)

        tb.addWidget(QLabel(" N "))
        self.stepn = QSpinBox(); self.stepn.setRange(1, 1000000); self.stepn.setValue(100)
        self.stepn.setFixedWidth(90); tb.addWidget(self.stepn)
        self.stepn_btn = QPushButton("Step N")
        self.stepn_btn.clicked.connect(lambda: self.do_step(self.stepn.value(), False))
        tb.addWidget(self.stepn_btn)

        self.run_btn = QPushButton(" Run")
        self.run_btn.setIcon(self.style().standardIcon(QStyle.SP_MediaPlay))
        self.run_btn.clicked.connect(self.on_run_toggle)
        self.run_btn.setStyleSheet(
            "QPushButton{background:#238636;color:#ffffff;font-weight:bold;border:1px "
            "solid #2ea043;padding:3px 12px;} QPushButton:hover{background:#2ea043;}")
        tb.addWidget(self.run_btn)
        tb.addWidget(QLabel(" speed "))
        self.speed = QSpinBox(); self.speed.setRange(1, 20000); self.speed.setValue(200)
        self.speed.setSuffix(" clk/tick"); self.speed.setFixedWidth(110)
        tb.addWidget(self.speed)

        # status toolbar (second row)
        self.addToolBarBreak()
        sb = QToolBar("status"); sb.setMovable(False); self.addToolBar(sb)
        self.status_lbl = QLabel("  no image loaded  ")
        f = QFont("monospace"); f.setStyleHint(QFont.Monospace); self.status_lbl.setFont(f)
        sb.addWidget(self.status_lbl)

        # shortcuts
        for key, fn in [(Qt.Key_Period, lambda: self.do_step(1, False)),
                        (Qt.Key_Space, lambda: self.do_step(200000, True)),
                        (Qt.Key_F5, self.on_run_toggle)]:
            a = QAction(self); a.setShortcut(QKeySequence(key)); a.triggered.connect(fn)
            self.addAction(a)

    def _build_central(self):
        outer = QSplitter(Qt.Horizontal)
        left = QSplitter(Qt.Vertical)
        self.pipeline = PipelineView()
        self.trace = TraceView()
        left.addWidget(self.pipeline)
        left.addWidget(self.trace)
        left.setStretchFactor(0, 3); left.setStretchFactor(1, 2)
        left.setSizes([500, 470])
        right = QSplitter(Qt.Vertical)
        self.tables = TablesView()
        self.regs = RegsView()
        right.addWidget(self.tables)
        right.addWidget(self.regs)
        right.setStretchFactor(0, 3); right.setStretchFactor(1, 1)
        outer.addWidget(left); outer.addWidget(right)
        outer.setStretchFactor(0, 3); outer.setStretchFactor(1, 2)
        for sp in (outer, left, right):
            sp.setHandleWidth(4)
        self.setCentralWidget(outer)
        # two-way link: trace row <-> Konata instruction row
        self.trace.rowSelected.connect(self.pipeline.highlight_cycle)
        self.pipeline.konata.plot.rowClicked.connect(self.trace.select_n)

    # ---- image loading ----
    def on_open(self):
        start = os.path.join(os.getcwd(), "build")
        if not os.path.isdir(start):
            start = os.getcwd()
        path, _ = QFileDialog.getOpenFileName(
            self, "Open flat image", start,
            "Flat images (*.flat *.bin *.img);;All files (*)")
        if path:
            self.load_image(path)

    def load_image(self, path):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            QMessageBox.critical(self, "Open failed", str(e)); return
        # honour a sibling manifest.json (load_addr / entry) if present
        man = os.path.join(os.path.dirname(path), "manifest.json")
        entry = DEF_ENTRY; load = DEF_ENTRY
        if os.path.exists(man):
            try:
                m = json.load(open(man))
                if "entry" in m: entry = int(m["entry"], 0)
                if "load_addr" in m: load = int(m["load_addr"], 0)
            except Exception:
                pass
        self.image_path = path
        self.image_bytes = data
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
        self.setWindowTitle(f"Ventium pipeline visualizer — {os.path.basename(path)}")
        self.on_reset()

    # ---- driving ----
    def _fresh_backend(self, soc=False):
        try:
            self.backend.close()
        except Exception:
            pass
        try:
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
        if self.image_bytes is None:
            return
        soc = self.soc_cb.isChecked()
        system = self.sys_cb.isChecked() or soc      # SoC always boots system mode
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
            load = _parse_hex(self.load_e, DEF_ENTRY)
            entry = _parse_hex(self.entry_e, DEF_ENTRY)
            esp = _parse_hex(self.esp_e, DEF_ESP)
            self.backend.load_bytes(self.image_bytes, load)
            self.backend.reset(entry, esp, cycle_mode=self.cyc_cb.isChecked(), system=0)
        bits = 16 if system else 32
        for v in (self.pipeline, self.trace, self.tables):
            if hasattr(v, "set_bits"):
                v.set_bits(bits)
        self.pipeline.reset(self.backend)
        self.trace.reset()
        self._refresh_all()

    def do_step(self, n, stop_on_retire):
        if self.image_bytes is None:
            return
        self.backend.step(n, stop_on_retire)
        self._refresh_all()
        if self.backend.is_done():
            self.stop_run()

    def on_run_toggle(self):
        if self._running:
            self.stop_run()
        elif self.image_bytes is not None:
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
        if self.image_bytes is None or self.backend.is_done():
            self.stop_run(); self._refresh_all(); return
        self.backend.step(self.speed.value(), False)
        self._refresh_all()
        if self.backend.is_done():
            self.stop_run()

    # ---- refresh ----
    def _refresh_all(self):
        s = self.backend.state()
        self.pipeline.update_from(self.backend, s)
        self.tables.update_from(self.backend, s)
        self.tables.set_hotspots(self.pipeline.konata.plot.insns)
        self.tables.set_branches(self.pipeline.konata.plot.insns)
        self.tables.mem.set_state(self.backend, s)
        self.regs.update_from(s)
        self.trace.update_from(self.backend)
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
        groups = [
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
    ap.add_argument("image", nargs="?", help="flat image to load on startup")
    ap.add_argument("--entry", type=lambda x: int(x, 0), default=None)
    ap.add_argument("--esp", type=lambda x: int(x, 0), default=DEF_ESP)
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
    if img is None:
        for cand in ("build/m2/mb_brloop.flat", "build/m2/mb_fpindep.flat",
                     "build/m2/smoke.flat"):
            if os.path.exists(cand):
                img = cand; break
    if img and os.path.exists(img):
        if args.entry is not None:
            win.entry_e.setText(f"0x{args.entry:08x}")
            win.load_e.setText(f"0x{args.entry:08x}")
        win.esp_e.setText(f"0x{args.esp:08x}")
        win.load_image(img)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
