# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate a consistent set of GUI screenshots for the self-improving visual
loop's adversarial review agents. Renders the GUI offscreen across several
representative workloads and writes full-window PNGs + panel crops to a dir.

usage: python3 gen_review_shots.py [outdir]
"""
import os
import sys
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PySide6.QtWidgets import QApplication
from pipeviz.main import MainWindow, _apply_dark
from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pipeviz_review"
os.makedirs(OUT, exist_ok=True)

# (tag, image, steps, soc) — representative workloads
SHOTS = [
    ("dmiss",   "build/m2/mb_dmiss.flat",                                     160,  False),
    ("brloop",  "build/m2/mb_brloop.flat",                                    120,  False),
    ("fp",      "build/m2/mb_fpindep.flat",                                   420,  False),
    ("test386", "ventium-refs/09-external-cpu-tests/test386.asm/test386.bin", 3000, True),
    ("ppage",   "verif/sys/tests/ppage/ppage.bin",                           240,  False),
]

app = QApplication(sys.argv)
_apply_dark(app)
win = MainWindow()
win.resize(1640, 980)
win.show()

for tag, img, steps, soc in SHOTS:
    if not os.path.exists(img):
        print(f"skip {tag}: {img} missing"); continue
    win.load_image(img)
    app.processEvents()
    win.do_step(steps, False)
    app.processEvents()
    win.repaint(); app.processEvents()
    full = os.path.join(OUT, f"{tag}_full.png")
    win.grab().save(full)
    # panel crops for closer inspection
    im = Image.open(full)
    im.crop((0, 88, 1010, 470)).save(os.path.join(OUT, f"{tag}_pipeline.png"))
    im.crop((0, 560, 1010, 980)).save(os.path.join(OUT, f"{tag}_trace.png"))
    im.crop((1010, 88, 1640, 560)).save(os.path.join(OUT, f"{tag}_tables.png"))
    im.crop((1010, 560, 1640, 980)).save(os.path.join(OUT, f"{tag}_regs.png"))
    s = win.backend.state()
    print(f"{tag:9s} ret={win.backend.retire_count():6d} "
          f"state={win.backend.state_name(s.state):9s} -> {full}")

win.backend.close()
print("OK", OUT)
