# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Offscreen end-to-end smoke: construct the GUI, load an image, step, screenshot.
import os, sys
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PySide6.QtWidgets import QApplication
from PySide6.QtCore import QCoreApplication
from pipeviz.main import MainWindow, _apply_dark

img = sys.argv[1] if len(sys.argv) > 1 else "build/m2/mb_brloop.flat"
entry = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x08048000
clocks = int(sys.argv[3]) if len(sys.argv) > 3 else 220
out = sys.argv[4] if len(sys.argv) > 4 else "/tmp/pipeviz_shot.png"

app = QApplication(sys.argv)
_apply_dark(app)
win = MainWindow()
win.resize(1640, 980)
win.entry_e.setText(f"0x{entry:08x}")
win.load_e.setText(f"0x{entry:08x}")
win.load_image(img)            # resets + loads
win.show()
app.processEvents()
win.do_step(clocks, False)     # step + refresh all panels
app.processEvents()

s = win.backend.state()
print(f"image={img} stepped={clocks} core_cyc={s.core_cyc} state={win.backend.state_name(s.state)} "
      f"retired={win.backend.retire_count()} icache_lines={len(win.backend.icache())} "
      f"timeline_samples={len(win.pipeline.timeline.canvas.samples)} trace_rows={win.trace.tbl.rowCount()}")

# force layout then grab
win.repaint(); app.processEvents()
pix = win.grab()
pix.save(out)
print("screenshot:", out, pix.width(), "x", pix.height())
win.backend.close()
print("OK")
