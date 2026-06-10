#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Render a "device view colored by module" from the placed-cell CSV that
# device_view.tcl dumps (module,x,y per placed leaf cell on the KV260 XCK26).
# Each cell is a point at its real placement site (X = SLICE column, Y = row);
# color = the RTL top-hierarchy module it belongs to → you can see which physical
# cluster is which module (fpu_state / icache / bpred_btb / core spine / ...).
#
#   python3 fpga/scripts/render_device_view.py <cells_loc.csv> <out.png> ["title"]
import sys, csv
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_path = sys.argv[1] if len(sys.argv) > 1 else "fpga/build/device_view/cells_loc.csv"
out_png  = sys.argv[2] if len(sys.argv) > 2 else "fpga/build/device_view/device_view.png"
title    = sys.argv[3] if len(sys.argv) > 3 else "Ventium core — KV260 (XCK26) placement, colored by module"

pts = defaultdict(lambda: ([], []))
with open(csv_path) as f:
    for row in csv.DictReader(f):
        try:
            x = int(row["x"]); y = int(row["y"])
        except (KeyError, ValueError):
            continue
        pts[row["module"]][0].append(x)
        pts[row["module"]][1].append(y)

# friendly labels + a stable, distinct color order (biggest blocks first)
LABEL = {
    "u_fpu_state": "FP datapath/regfile (u_fpu_state)",
    "u_icache": "I-cache (u_icache)",
    "u_bpred_btb": "branch predictor / BTB",
    "u_dcache_tm": "D-cache timing",
    "u_dtlb": "D-TLB", "u_itlb": "I-TLB",
    "u_idiv": "iterative integer DIV", "u_sqrt_iter": "iterative FSQRT",
    "u_srt_div": "iterative SRT FDIV", "u_bcd": "FBSTP engine (FP->BCD)",
    "u_bcd2fp": "FBLD engine (BCD->FP)", "core_spine": "core spine (decode/issue/ALU)",
}
order = sorted(pts.keys(), key=lambda m: -len(pts[m][0]))
cmap = plt.get_cmap("tab20")
fig, ax = plt.subplots(figsize=(13, 11))
for i, m in enumerate(order):
    xs, ys = pts[m]
    ax.scatter(xs, ys, s=2, color=cmap(i % 20),
               label=f"{LABEL.get(m, m)}  ({len(xs)} cells)", rasterized=True)
ax.set_xlabel("tile column (X)")
ax.set_ylabel("tile row (Y)")
ax.set_title(title)
ax.set_aspect("equal", adjustable="box")
leg = ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), markerscale=6,
                fontsize=9, framealpha=0.95, title="RTL module (by cell count)")
fig.tight_layout()
fig.savefig(out_png, dpi=130, bbox_inches="tight")
print(f"wrote {out_png}  ({sum(len(v[0]) for v in pts.values())} cells, {len(pts)} modules)")
