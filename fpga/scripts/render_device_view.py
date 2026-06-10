#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Render a "device view colored by module" from the placed-cell CSV that
# apr_run.tcl / dump_cells_hier.tcl dump (module,sub,x,y per placed leaf cell).
# Each cell is a point at its placement site (X = SLICE column, Y = row). Two-level
# coloring:
#   * TOP level (RTL module: u_icache / u_fpu_state / ...) -> a FIXED hue, shared
#     across every plot so the same module is the same color in all device views.
#   * 2nd level (signal-group sub-block inside the module: ic_tag / ic_val / fpr /
#     btb_ctr / ...) -> a LUMINANCE step within that hue (dark = largest sub-block).
# The legend is structured: one bold module header (full hue), then its sub-blocks
# indented with their luminance swatches; small modules collapse to a header only.
#
#   python3 fpga/scripts/render_device_view.py <cells.csv> <out.png> ["title"]
import sys, csv, re, colorsys
from collections import defaultdict, Counter
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
from matplotlib.patches import Patch
from matplotlib.lines import Line2D

csv_path = sys.argv[1] if len(sys.argv) > 1 else "fpga/build/device_view/cells_loc.csv"
out_png  = sys.argv[2] if len(sys.argv) > 2 else "fpga/build/device_view/device_view.png"
title    = sys.argv[3] if len(sys.argv) > 3 else "Ventium core — placement, colored by RTL module"

# ---- FIXED module -> base hue (SHARED across all device views) --------------
MODULE_COLOR = {
    "u_icache":    "#1f77b4",  # blue
    "u_fpu_state": "#ff7f0e",  # orange
    "u_bpred_btb": "#2ca02c",  # green
    "u_uopcache":  "#8c564b",  # brown
    "core_spine":  "#9467bd",  # purple
    "u_dcache_tm": "#17becf",  # cyan
    "u_bcd":       "#e377c2",  # pink
    "u_sqrt_iter": "#d62728",  # red
    "u_srt_div":   "#7f7f7f",  # gray
    "u_idiv":      "#bcbd22",  # olive
    "u_dtlb":      "#393b79",  # indigo
    "u_bcd2fp":    "#e7ba52",  # gold
    "u_itlb":      "#843c39",  # maroon
}
_FALLBACK = ["#393b79", "#637939", "#8c6d31", "#843c39", "#7b4173"]
LABEL = {
    "u_fpu_state": "FP datapath / regfile", "u_icache": "I-cache",
    "u_bpred_btb": "branch predictor / BTB", "u_uopcache": "µop-cache",
    "u_dcache_tm": "D-cache timing", "u_dtlb": "D-TLB", "u_itlb": "I-TLB",
    "u_idiv": "iterative integer DIV", "u_sqrt_iter": "iterative FSQRT",
    "u_srt_div": "iterative SRT FDIV", "u_bcd": "FBSTP engine (FP→BCD)",
    "u_bcd2fp": "FBLD engine (BCD→FP)", "core_spine": "core spine (decode/issue/ALU)",
}
BREAKOUT_MIN = 4000  # modules >= this many cells get their sub-groups shown; else header-only

def shade(hex_base, t):
    """hue/sat of hex_base, lightness lerped by t in [0,1] (0=dark .. 1=light)."""
    r, g, b = mcolors.to_rgb(hex_base)
    h, _, s = colorsys.rgb_to_hls(r, g, b)
    return colorsys.hls_to_rgb(h, 0.34 + 0.46 * t, min(1.0, s))

def clean_sub(s):
    """Reduce a flattened leaf name to its signal token(s): drop [..] bit indices,
    synth _i_N tails, _reg suffix, and trailing _N — so prefix-merge sees real tokens."""
    s = re.sub(r"\[[^\]]*\]", "", s)
    s = re.sub(r"_i_\d+.*$", "", s)
    s = re.sub(r"_reg.*$", "", s)
    s = re.sub(r"(_\d+)+$", "", s)
    return s or "misc"

def prefix_groups(weight, maxg=6):
    """Merge sub-block names by their leading `_`-delimited tokens (xxxx_* / xxxx_yyyy_*),
    coarsening the prefix until there are <= maxg groups. `weight` maps name -> cell
    count. Picks the FINEST prefix (most tokens) that still fits in maxg groups; if even
    the first token over-runs, keeps the maxg-1 BIGGEST groups BY CELL COUNT and folds
    the rest into 'other'. Returns {group_key: [names]}."""
    names = list(weight)
    def by_T(T):
        g = defaultdict(list)
        for nm in names:
            key = "_".join(nm.split("_")[:T]) or nm
            g[key].append(nm)
        return g
    for T in (4, 3, 2, 1):
        g = by_T(T)
        if len(g) <= maxg:
            return g
    g = by_T(1)
    tot = {k: sum(weight[n] for n in v) for k, v in g.items()}   # rank by CELLS, not #names
    keep = sorted(tot, key=lambda k: -tot[k])[:maxg - 1]
    out = {k: g[k] for k in keep}
    out["other"] = [n for k, v in g.items() if k not in keep for n in v]
    return out

# ---- load: module -> sub -> (xs, ys) ----------------------------------------
data = defaultdict(lambda: defaultdict(lambda: ([], [])))
with open(csv_path) as f:
    rd = csv.DictReader(f)
    has_sub = "sub" in (rd.fieldnames or [])
    for row in rd:
        try:
            x = int(row["x"]); y = int(row["y"])
        except (KeyError, ValueError):
            continue
        sub = clean_sub(row["sub"]) if has_sub else "(all)"
        xs, ys = data[row["module"]][sub]
        xs.append(x); ys.append(y)

mod_total = {m: sum(len(v[0]) for v in subs.values()) for m, subs in data.items()}
order = sorted(data.keys(), key=lambda m: -mod_total[m])

fb = 0
legend_blocks = []                 # (module, base_hex, [(label, color, count), ...])
layer_colors = []                  # idx -> rgb
site_layer = defaultdict(Counter)  # (x, y) -> Counter{layer_idx: cells}
def emit(col, xs, ys):
    li = len(layer_colors); layer_colors.append(tuple(mcolors.to_rgb(col)))
    for x, y in zip(xs, ys):
        site_layer[(x, y)][li] += 1
    return li

for m in order:
    base = MODULE_COLOR.get(m)
    if base is None:
        base = _FALLBACK[fb % len(_FALLBACK)]; fb += 1
    subs = data[m]
    leg = []
    if mod_total[m] >= BREAKOUT_MIN and len(subs) > 1:
        # prefix-merge the leaves into <=6 groups, then shade by group size
        weight = {nm: len(xy[0]) for nm, xy in subs.items()}
        groups = prefix_groups(weight)
        merged = []
        for key, names in groups.items():
            gx, gy = [], []
            for nm in names:
                xs, ys = subs[nm]; gx += xs; gy += ys
            merged.append((key, gx, gy))
        # biggest first; the 'other' catch-all always sorts LAST (lightest)
        merged.sort(key=lambda t: (t[0] == "other", -len(t[1])))
        n = len(merged)
        for i, (key, gx, gy) in enumerate(merged):
            col = shade(base, 0.12 + 0.76 * (i / max(1, n - 1)))  # dark=biggest
            emit(col, gx, gy)
            leg.append((f"{key}_*" if key != "other" else "other", col, len(gx)))
    else:
        # small module: one flat color = the module hue
        gx, gy = [], []
        for xs, ys in subs.values():
            gx += xs; gy += ys
        emit(base, gx, gy)
    legend_blocks.append((m, base, leg))

# ---- rasterize to square pixels (one cell = one tile site) ------------------
xs_all = [x for (x, _) in site_layer]; ys_all = [y for (_, y) in site_layer]
minx, maxx = min(xs_all), max(xs_all); miny, maxy = min(ys_all), max(ys_all)
W, H = maxx - minx + 1, maxy - miny + 1
img = np.ones((H, W, 3))            # white background
for (x, y), cnt in site_layer.items():
    li = cnt.most_common(1)[0][0]   # the module/sub occupying MOST cells at this site
    img[y - miny, x - minx] = layer_colors[li]

fig, ax = plt.subplots(figsize=(13, 11))
ax.imshow(img, origin="lower", interpolation="nearest", aspect="equal",
          extent=[minx - 0.5, maxx + 0.5, miny - 0.5, maxy + 0.5])
ax.set_xlabel("SLICE / tile column (X)")
ax.set_ylabel("SLICE / tile row (Y)")
ax.set_title(title)
ax.set_facecolor("white")

# ---- structured 2-level legend ----------------------------------------------
handles, labels = [], []
for m, base, leg in legend_blocks:
    name = LABEL.get(m, m)
    handles.append(Patch(facecolor=base, edgecolor="black", linewidth=0.4))
    labels.append(f"{name}  —  {mod_total[m]:,} cells")
    for sname, col, cnt in leg:
        handles.append(Line2D([0], [0], marker="s", linestyle="", markersize=7,
                              markerfacecolor=col, markeredgecolor="none"))
        labels.append(f"      {sname}  ({cnt:,})")

leg = ax.legend(handles, labels, loc="upper left", bbox_to_anchor=(1.01, 1.0),
                fontsize=7.5, framealpha=0.96, handlelength=1.1, labelspacing=0.28,
                borderpad=0.8, title="RTL module  ▸  sub-block (by cell count)")
leg.get_title().set_fontsize(9)
leg.get_title().set_fontweight("bold")
# bold the module header rows (full-color Patch handles)
for txt, h in zip(leg.get_texts(), handles):
    if isinstance(h, Patch):
        txt.set_fontweight("bold")

fig.tight_layout()
fig.savefig(out_png, dpi=130, bbox_inches="tight")
ncells = sum(mod_total.values())
print(f"wrote {out_png}  ({ncells} cells, {len(data)} modules)")
