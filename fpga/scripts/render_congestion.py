#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Render a placement-DENSITY heatmap from the placed-cell CSV (module,x,y) that
# apr_run.tcl dumps. High-density tiles = where the router runs out of channels
# (the congestion hotspot). A 2D histogram of cells-per-tile-bin; the bright band
# is the byte-window/MUXF cluster the congestion reports flag as level-5.
#
#   python3 render_congestion.py <cells_loc.csv> <out.png> ["title"]
import sys, csv
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_path = sys.argv[1]
out_png  = sys.argv[2]
title    = sys.argv[3] if len(sys.argv) > 3 else "Ventium core — placement density (congestion proxy)"

xs, ys = [], []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        try:
            xs.append(int(row["x"])); ys.append(int(row["y"]))
        except (KeyError, ValueError):
            continue
xs = np.array(xs); ys = np.array(ys)

# bin to ~4x4 tile cells so a bin ≈ a small placement window; density = cells/bin.
nbx = max(8, (xs.max() - xs.min()) // 4)
nby = max(8, (ys.max() - ys.min()) // 4)
H, xe, ye = np.histogram2d(xs, ys, bins=[nbx, nby])

fig, ax = plt.subplots(figsize=(11, 10))
im = ax.imshow(H.T, origin="lower", aspect="equal",
               extent=[xe[0], xe[-1], ye[0], ye[-1]], cmap="inferno")
cb = fig.colorbar(im, ax=ax, shrink=0.8)
cb.set_label("placed cells per ~4×4 tile bin (density)")
peak = H.max(); ti, tj = np.unravel_index(H.argmax(), H.shape)
ax.set_title(f"{title}\npeak density {int(peak)} cells/bin @ X≈{int((xe[ti]+xe[ti+1])/2)} Y≈{int((ye[tj]+ye[tj+1])/2)}")
ax.set_xlabel("SLICE / tile column (X)")
ax.set_ylabel("SLICE / tile row (Y)")
fig.tight_layout()
fig.savefig(out_png, dpi=130, bbox_inches="tight")
print(f"wrote {out_png}  ({len(xs)} cells, peak {int(peak)}/bin)")
