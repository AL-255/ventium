#!/usr/bin/env python3
# Vivado ROUTER congestion CONCENTRATION map from `report_design_analysis -congestion`.
# Each congested row reports a coarse parent window + finer sub-windows, each at a
# LEVEL (5/6/..). We use the SUB-windows (finest) when present and accumulate a
# level-weighted overlap score per INT tile: score += (level-4) for every covering
# window. Bright = many high-level windows stack = the true routing hotspot.
#   python3 render_congestion_levels.py <congestion.rpt> <out.png> ["title"]
import sys, re
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

rpt, out = sys.argv[1], sys.argv[2]
title = sys.argv[3] if len(sys.argv) > 3 else "Router congestion concentration"
text = open(rpt).read()
RE = re.compile(r'X(\d+)Y(\d+)\s*,\s*[A-Z0-9_]+?_X(\d+)Y(\d+)')

rows = []   # (level, [rects])  using sub-windows when present
for line in text.splitlines():
    if not line.startswith("|"): continue
    cols = [c.strip() for c in line.split("|")]
    if len(cols) < 4 or not cols[3].isdigit(): continue
    lvl = int(cols[3])
    pairs = [tuple(map(int, m)) for m in RE.findall(line)]
    if not pairs: continue
    use = pairs[1:] if len(pairs) > 1 else pairs    # prefer the finer sub-windows
    rows.append((lvl, use))

maxx = max(max(x1,x2) for _,ps in rows for x1,y1,x2,y2 in ps)
maxy = max(max(y1,y2) for _,ps in rows for x1,y1,x2,y2 in ps)
grid = np.zeros((maxy+1, maxx+1))
for lvl, ps in rows:
    for x1,y1,x2,y2 in ps:
        xa,xb = sorted((x1,x2)); ya,yb = sorted((y1,y2))
        grid[ya:yb+1, xa:xb+1] += (lvl - 4)

fig, ax = plt.subplots(figsize=(8, 11))
im = ax.imshow(grid, origin="lower", aspect="auto", cmap="inferno",
               extent=[0, maxx+1, 0, maxy+1], interpolation="nearest")
cb = fig.colorbar(im, ax=ax, shrink=0.82)
cb.set_label("router-congestion score  (Σ level-weighted overlapping windows)")
ax.set_title(title, fontsize=10)
ax.set_xlabel("INT tile column (X)"); ax.set_ylabel("INT tile row (Y)")
ty, tx = np.unravel_index(grid.argmax(), grid.shape)
ax.text(0.02, 0.02, f"peak score {grid.max():.0f} @ X{tx} Y{ty}  ({len(rows)} congested windows, all L5-L6)",
        transform=ax.transAxes, fontsize=8, va="bottom",
        bbox=dict(fc="white", ec="0.6", alpha=0.9))
fig.tight_layout(); fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"wrote {out}  ({len(rows)} windows, grid {grid.shape}, peak {grid.max():.0f})")
