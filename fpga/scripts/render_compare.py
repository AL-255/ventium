#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Side-by-side placement-density heatmaps for two configs (shared color scale),
# to show how a config change moves the congestion hotspot. Used here for
# narrowb+FP vs +VEN_UOPCACHE+FP (the byte-gather removal's effect on density).
#
#   python3 render_compare.py <csvA> <labelA> <csvB> <labelB> <out.png> ["suptitle"]
import sys, csv
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def load(p):
    xs, ys = [], []
    with open(p) as f:
        for row in csv.DictReader(f):
            try: xs.append(int(row["x"])); ys.append(int(row["y"]))
            except (KeyError, ValueError): continue
    return np.array(xs), np.array(ys)

csvA, labA, csvB, labB, out = sys.argv[1:6]
sup = sys.argv[6] if len(sys.argv) > 6 else "Placement density (congestion proxy) — config comparison"
xa, ya = load(csvA); xb, yb = load(csvB)
xmin = min(xa.min(), xb.min()); xmax = max(xa.max(), xb.max())
ymin = min(ya.min(), yb.min()); ymax = max(ya.max(), yb.max())
nbx = max(8, (xmax - xmin)//4); nby = max(8, (ymax - ymin)//4)
HA,_,_ = np.histogram2d(xa, ya, bins=[nbx,nby], range=[[xmin,xmax],[ymin,ymax]])
HB,_,_ = np.histogram2d(xb, yb, bins=[nbx,nby], range=[[xmin,xmax],[ymin,ymax]])
vmax = max(HA.max(), HB.max())

fig, axs = plt.subplots(1, 2, figsize=(15, 9), sharey=True)
for ax, H, lab in ((axs[0], HA, labA), (axs[1], HB, labB)):
    im = ax.imshow(H.T, origin="lower", aspect="equal", vmin=0, vmax=vmax,
                   extent=[xmin,xmax,ymin,ymax], cmap="inferno")
    ax.set_title(f"{lab}\npeak {int(H.max())} cells/bin   ({int(np.array([0]).sum()) or len(xa) if lab==labA else len(xb)} cells)")
    ax.set_xlabel("SLICE column (X)")
axs[0].set_ylabel("SLICE row (Y)")
fig.colorbar(im, ax=axs, shrink=0.7, label="placed cells per ~4×4 tile bin")
fig.suptitle(sup, fontsize=13)
fig.savefig(out, dpi=125, bbox_inches="tight")
print(f"wrote {out}  (peaks: {labA}={int(HA.max())}  {labB}={int(HB.max())}  shared vmax={int(vmax)})")
