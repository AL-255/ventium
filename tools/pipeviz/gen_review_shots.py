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
_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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


def _panels(win):
    return (win.pipeline, win.trace, win.tables, win.regs)


def _settle(win, app, tries=12):
    """Spin the event loop until every panel reports an IN-WINDOW geometry. The
    QSplitter can take an extra pass to constrain a panel after a content change;
    if we crop while a panel still holds its unconstrained size hint we frame the
    WRONG region (e.g. a 2000x400 'trace' crop that actually shows the pipeline).
    """
    for _ in range(tries):
        W, H = win.width(), win.height()
        if all(50 <= w.rect().width() <= W and 50 <= w.rect().height() <= H
               for w in _panels(win)):
            return
        app.processEvents()


def _box(win, widget):
    """The on-screen (left, top, right, bottom) of a panel within the window —
    so panel crops always frame the real widget, regardless of splitter sizes.
    Clamped to the window as a final guard against any unsettled geometry."""
    W, H = win.width(), win.height()
    tl = widget.mapTo(win, widget.rect().topLeft())
    br = widget.mapTo(win, widget.rect().bottomRight())
    x0 = max(0, min(tl.x(), W)); y0 = max(0, min(tl.y(), H))
    x1 = max(x0 + 1, min(br.x(), W)); y1 = max(y0 + 1, min(br.y(), H))
    return (x0, y0, x1, y1)


def _watermark(path, tag):
    # Stamp the build into a DEDICATED 15px band ABOVE the screenshot rather than
    # painting over the top-left corner (which obscured the toolbar in full-window
    # shots and a panel title in the crops). The band overlaps no UI, and the
    # stamp stays top-left + findable for the anti-staleness check.
    im = Image.open(path).convert("RGB")
    w, h = im.size
    band = 15
    canvas = Image.new("RGB", (w, h + band), (20, 24, 31))
    canvas.paste(im, (0, band))
    d = ImageDraw.Draw(canvas)
    d.text((4, 2), f"{_STAMP}  |  {tag}", fill=(240, 200, 80))
    canvas.save(path)

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
    _settle(win, app)          # ensure splitter geometry is constrained before cropping
    full = os.path.join(OUT, f"{tag}_full.png")
    win.grab().save(full)
    # crop the RAW grab first (crop boxes assume the un-banded coords), THEN band
    # the full image — so the 15px watermark band never shifts the crop regions.
    # Boxes are computed from LIVE widget geometry (not hardcoded): the outer
    # splitter is 3:2 so the right column starts at ~x=922, NOT 1010 — hardcoded
    # boxes were slicing ~88px off the left of the tables/regs panels, which is
    # what made critics keep "seeing" clipped register names every round.
    im = Image.open(full)
    for sub, widget in [("pipeline", win.pipeline), ("trace", win.trace),
                        ("tables", win.tables), ("regs", win.regs)]:
        cp = os.path.join(OUT, f"{tag}_{sub}.png")
        im.crop(_box(win, widget)).save(cp)
        _watermark(cp, f"{tag} · {sub}")
    _watermark(full, tag)
    # also capture the register panel PINNED to a mid-trace instruction, so the
    # review covers the "pin regs AS-OF a retired insn" feature (live shots can't
    # show it). dmiss exercises GPR deltas, fp the x87 stack.
    if tag in ("dmiss", "fp"):
        nret = win.backend.retire_count()
        if nret > 6:
            npin = nret - 4
            win._pin_to(npin)
            app.processEvents(); win.repaint(); app.processEvents()
            pfull = os.path.join(OUT, f"{tag}_pinned_full.png")
            win.grab().save(pfull)
            pf = os.path.join(OUT, f"{tag}_regs_pinned.png")
            Image.open(pfull).crop(_box(win, win.regs)).save(pf)
            _watermark(pf, f"{tag} · regs pinned n={npin}")
            win._unpin(); app.processEvents()
    s = win.backend.state()
    print(f"{tag:9s} ret={win.backend.retire_count():6d} "
          f"state={win.backend.state_name(s.state):9s} -> {full}")

win.backend.close()
print("OK", OUT)
