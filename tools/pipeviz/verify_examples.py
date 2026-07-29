#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Offscreen regressions for the user-guide workloads.

Run from any directory.  Each case uses MainWindow rather than a backend-only
probe so this verifies loading, reset mode selection, trace/timeline population,
and the evidence called out in docs/user-guide.md.
"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

from PySide6.QtWidgets import QApplication
from pipeviz.main import MainWindow, _apply_dark


CASES = (
    ("branch dual-issue", "build/verify/mb_brloop.cycle.flat", 120,
     lambda b: b.retire_count() >= 150 and len(b.icache()) >= 1),
    ("D-cache pressure", "build/verify/mb_dmiss.cycle.flat", 160,
     lambda b: b.retire_count() >= 40 and len(b.dcache()) >= 8),
    ("x87 overlap", "build/verify/mb_fpindep.cycle.flat", 420,
     lambda b: b.retire_count() >= 200 and len(b.icache()) >= 8),
    ("system paging", "verif/sys/tests/ppage/ppage.bin", 240,
     lambda b: b.retire_count() >= 20 and len(b.icache()) >= 3 and len(b.dcache()) >= 1),
)


def main():
    app = QApplication(sys.argv)
    _apply_dark(app)
    for label, relative, clocks, evidence in CASES:
        image = os.path.join(ROOT, relative)
        if not os.path.isfile(image):
            raise AssertionError(f"{label}: missing guide image {image}")
        win = MainWindow()
        try:
            win.resize(1280, 800)
            win.load_image(image)
            win.show()
            app.processEvents()
            win.do_step(clocks, False)
            app.processEvents()
            backend = win.backend
            retired = backend.retire_count()
            rows = win.trace.tbl.rowCount()
            timeline = len(win.pipeline.konata.plot.insns)
            assert rows == retired == timeline, (
                f"{label}: GUI trace mismatch: retired={retired}, rows={rows}, timeline={timeline}")
            assert evidence(backend), f"{label}: expected workload evidence was absent"
            print(f"OK {label}: clocks={clocks} retired={retired} "
                  f"I$={len(backend.icache())} D$={len(backend.dcache())}")
        finally:
            win.backend.close()
            win.close()
    print("All documented examples passed")


if __name__ == "__main__":
    main()
