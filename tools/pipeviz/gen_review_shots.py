# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate a consistent set of GUI screenshots for the self-improving visual
loop's adversarial review agents. Renders the GUI offscreen across several
representative workloads and writes full-window PNGs + panel crops to a dir.

usage: python3 gen_review_shots.py [outdir]
"""
import os
import sys
import subprocess
import datetime
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PySide6.QtWidgets import QApplication
from pipeviz.main import MainWindow, _apply_dark
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pipeviz_review"
os.makedirs(OUT, exist_ok=True)

# Build stamp drawn onto every screenshot so a reviewer can PROVE which build
# they are looking at (and the loop can detect stale images).
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
try:
    _SHA = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                   cwd=_ROOT).decode().strip()
    # mark when the working tree (what's actually rendered) is ahead of HEAD
    if subprocess.check_output(["git", "status", "--porcelain", "tools/pipeviz"],
                               cwd=_ROOT).decode().strip():
        _SHA += "+dirty"
except Exception:
    _SHA = "nogit"
_STAMP = f"pipeviz build {_SHA}  {datetime.datetime.now().strftime('%H:%M:%S')}"


def _watermark(path, tag):
    im = Image.open(path).convert("RGB")
    d = ImageDraw.Draw(im)
    txt = f"{_STAMP}  |  {tag}"
    d.rectangle((0, 0, 8 + 7 * len(txt), 14), fill=(20, 24, 31))
    d.text((4, 2), txt, fill=(240, 200, 80))
    im.save(path)

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
    _watermark(full, tag)
    # panel crops for closer inspection (layout: toolbar ~85px; left splitter
    # pipeline:trace ~ [430,540]; right splitter tables:regs)
    im = Image.open(full)
    for sub, box in [("pipeline", (0, 86, 1010, 516)), ("trace", (0, 516, 1010, 980)),
                     ("tables", (1010, 86, 1640, 560)), ("regs", (1010, 560, 1640, 980))]:
        cp = os.path.join(OUT, f"{tag}_{sub}.png")
        im.crop(box).save(cp)
        _watermark(cp, f"{tag} · {sub}")
    s = win.backend.state()
    print(f"{tag:9s} ret={win.backend.retire_count():6d} "
          f"state={win.backend.state_name(s.state):9s} -> {full}")

win.backend.close()
print("OK", OUT)
