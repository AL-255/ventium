#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Two-panel compact device view: ONE figure, suptitle + two subfigures side by
# side (each with its own subtitle + legend). Panel 1 = the CPU core + FPU
# hierarchy in color (memory/BD gray); panel 2 = the L1/AXI + PS bridge + BD
# fabric in color (core gray). Same CSV format, hues, sub-block shading and
# legend conventions as render_device_view.py — just laid out compactly.
#
#   python3 fpga/scripts/render_device_view_split.py <cells.csv> <out.png> ["suptitle"]
import sys, csv, re, colorsys
from collections import defaultdict, Counter
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
from matplotlib.patches import Patch
from matplotlib.lines import Line2D

csv_path = sys.argv[1] if len(sys.argv) > 1 else "fpga/build/kv260_soc_impl_linux_40/cells_loc_soc.csv"
out_png  = sys.argv[2] if len(sys.argv) > 2 else "docs/fpga-device-view-soc-split.png"
suptitle = sys.argv[3] if len(sys.argv) > 3 else "Ventium Full SoC on K26 @ 40MHz"

GRAY = "#d4d4d4"
CORE_FOCUS = set("core_spine btb icache fpu uopcache sqrt_iter bcd srt_div "
                 "bcd2fp idiv dtlb itlb dcache_tm".split())
OUT_FOCUS  = set("l1d l1axi axi_master soc_axil smartconnect".split())
PANELS = [
    (CORE_FOCUS, "CPU core + FPU  (memory / BD grayed)"),
    (OUT_FOCUS,  "L1/AXI memory + PS bridge + BD  (core grayed)"),
]

MODULE_COLOR = {
    "icache": "#1f77b4", "fpu": "#ff7f0e", "btb": "#2ca02c", "uopcache": "#8c564b",
    "core_spine": "#9467bd", "dcache_tm": "#17becf", "bcd": "#e377c2",
    "sqrt_iter": "#d62728", "srt_div": "#c5b0d5", "idiv": "#bcbd22",
    "dtlb": "#393b79", "itlb": "#843c39", "bcd2fp": "#e7ba52",
    "l1d": "#1f77b4", "l1axi": "#2ca02c", "axi_master": "#ff7f0e",
    "soc_axil": "#d62728", "smartconnect": "#9467bd",
}
_FALLBACK = ["#393b79", "#637939", "#8c6d31", "#843c39", "#7b4173"]
LABEL = {
    "icache": "I-cache", "fpu": "FP datapath / regfile", "btb": "branch predictor / BTB",
    "uopcache": "µop-cache", "dcache_tm": "D-cache timing", "bcd": "FBSTP engine (FP→BCD)",
    "bcd2fp": "FBLD engine (BCD→FP)", "sqrt_iter": "iterative FSQRT",
    "srt_div": "iterative SRT FDIV", "idiv": "iterative integer DIV",
    "dtlb": "D-TLB", "itlb": "I-TLB", "core_spine": "core spine (decode/issue/ALU)",
    "l1d": "L1 data cache", "l1axi": "L1/AXI glue", "axi_master": "AXI master → PS-DDR",
    "soc_axil": "PS control / IO bridge", "smartconnect": "BD interconnect",
}
BREAKOUT_MIN = 4000
SAT_BOOST, SAT_FLOOR = 1.6, 0.85

def vivid(hex_base):
    h, l, s = colorsys.rgb_to_hls(*mcolors.to_rgb(hex_base))
    s = min(1.0, max(s * SAT_BOOST, SAT_FLOOR))
    return mcolors.to_hex(colorsys.hls_to_rgb(h, min(0.60, max(0.42, l)), s))

def shade(hex_base, t):
    h, _, s = colorsys.rgb_to_hls(*mcolors.to_rgb(hex_base))
    return colorsys.hls_to_rgb(h, 0.30 + 0.42 * t, min(1.0, max(s * SAT_BOOST, SAT_FLOOR)))

def clean_sub(s):
    s = re.sub(r"\[[^\]]*\]", "", s)
    s = re.sub(r"_i_\d+.*$", "", s)
    s = re.sub(r"_reg.*$", "", s)
    s = re.sub(r"(_\d+)+$", "", s)
    return s or "misc"

def prefix_groups(weight, maxg=5):
    names = list(weight)
    def by_T(T):
        g = defaultdict(list)
        for nm in names:
            g["_".join(nm.split("_")[:T]) or nm].append(nm)
        return g
    for T in (4, 3, 2, 1):
        g = by_T(T)
        if len(g) <= maxg:
            return g
    g = by_T(1)
    tot = {k: sum(weight[n] for n in v) for k, v in g.items()}
    keep = sorted(tot, key=lambda k: -tot[k])[:maxg - 1]
    out = {k: g[k] for k in keep}
    out["other"] = [n for k, v in g.items() if k not in keep for n in v]
    return out

# ---- load once ---------------------------------------------------------------
data = defaultdict(lambda: defaultdict(lambda: ([], [])))
with open(csv_path) as f:
    rd = csv.DictReader(f)
    for row in rd:
        try:
            x = int(row["x"]); y = int(row["y"])
        except (KeyError, ValueError):
            continue
        xs, ys = data[row["module"]][clean_sub(row["sub"])]
        xs.append(x); ys.append(y)
mod_total = {m: sum(len(v[0]) for v in subs.values()) for m, subs in data.items()}
order = sorted(data, key=lambda m: -mod_total[m])

def build_panel(focus):
    """one panel's raster + legend entries for the given focus set"""
    layer_colors, legend_blocks = [], []
    site_layer = defaultdict(Counter)
    def emit(col, xs, ys):
        li = len(layer_colors); layer_colors.append(tuple(mcolors.to_rgb(col)))
        for x, y in zip(xs, ys):
            site_layer[(x, y)][li] += 1
    fb = 0
    for m in order:
        if m not in focus:
            gx, gy = [], []
            for xs, ys in data[m].values():
                gx += xs; gy += ys
            emit(GRAY, gx, gy)
            continue
        base = MODULE_COLOR.get(m)
        if base is None:
            base = _FALLBACK[fb % len(_FALLBACK)]; fb += 1
        base = vivid(base)
        subs = data[m]; leg = []
        if mod_total[m] >= BREAKOUT_MIN and len(subs) > 1:
            weight = {nm: len(xy[0]) for nm, xy in subs.items()}
            merged = []
            for key, names in prefix_groups(weight).items():
                gx, gy = [], []
                for nm in names:
                    xs, ys = subs[nm]; gx += xs; gy += ys
                merged.append((key, gx, gy))
            merged.sort(key=lambda t: (t[0] == "other", -len(t[1])))
            n = len(merged)
            for i, (key, gx, gy) in enumerate(merged):
                col = shade(base, 0.12 + 0.76 * (i / max(1, n - 1)))
                emit(col, gx, gy)
                leg.append((f"{key}_*" if key != "other" else "other", col, len(gx)))
        else:
            gx, gy = [], []
            for xs, ys in subs.values():
                gx += xs; gy += ys
            emit(base, gx, gy)
        legend_blocks.append((m, base, leg))
    xs_all = [x for (x, _) in site_layer]; ys_all = [y for (_, y) in site_layer]
    minx, maxx = min(xs_all), max(xs_all); miny, maxy = min(ys_all), max(ys_all)
    img = np.ones((maxy - miny + 1, maxx - minx + 1, 3))
    for (x, y), cnt in site_layer.items():
        img[y - miny, x - minx] = layer_colors[cnt.most_common(1)[0][0]]
    return img, (minx, maxx, miny, maxy), legend_blocks

# ---- compact 2-panel figure: [die][legend] [die][legend] ----------------------
# The die is ~4:1 tall (H~243 x W~60 sites); the figure width is sized to the
# CONTENT (two ~1.6in dies + two ~1.8in single-column legends), not to a wide
# canvas — that's what kills the blank space.
# Panel 1 (dense die) gets a side legend column; panel 2's die is mostly gray
# at the top (the core is grayed out), so its legend sits INSIDE the axes over
# that gray region — the whole fourth column disappears.
fig = plt.figure(figsize=(5.9, 6.4))
gs = fig.add_gridspec(1, 3, width_ratios=[1.0, 1.18, 1.05], wspace=0.03,
                      left=0.075, right=0.995, top=0.875, bottom=0.08)

def legend_items(legend_blocks):
    handles, labels = [], []
    for m, base, leg in legend_blocks:
        handles.append(Patch(facecolor=base, edgecolor="black", linewidth=0.4))
        labels.append(f"{LABEL.get(m, m)} — {mod_total[m]:,}")
        for sname, col, cnt in leg:
            handles.append(Line2D([0], [0], marker="s", linestyle="", markersize=5.5,
                                  markerfacecolor=col, markeredgecolor="none"))
            labels.append(f"   {sname} ({cnt:,})")
    return handles, labels

def style_legend(lg, handles):
    lg.get_title().set_fontsize(7)
    lg.get_title().set_fontweight("bold")
    for txt, h in zip(lg.get_texts(), handles):
        if isinstance(h, Patch):
            txt.set_fontweight("bold")

axes = []
for p, (focus, subtitle) in enumerate(PANELS):
    img, (minx, maxx, miny, maxy), legend_blocks = build_panel(focus)
    ax = fig.add_subplot(gs[0, 0 if p == 0 else 2])
    axes.append(ax)
    ax.imshow(img, origin="lower", interpolation="nearest", aspect="equal",
              extent=[minx - 0.5, maxx + 0.5, miny - 0.5, maxy + 0.5])
    ax.set_title(subtitle, fontsize=8.5, pad=5)
    ax.set_xlabel("SLICE column (X)", fontsize=7.5)
    if p == 0:
        ax.set_ylabel("SLICE row (Y)", fontsize=7.5)
    ax.tick_params(labelsize=6.5)
    handles, labels = legend_items(legend_blocks)
    if p == 0:
        lax = fig.add_subplot(gs[0, 1]); lax.axis("off")
        lg = lax.legend(handles, labels, loc="center left", bbox_to_anchor=(-0.16, 0.5),
                        fontsize=6.0, framealpha=0.0, handlelength=1.0,
                        labelspacing=0.22, borderpad=0.1, handletextpad=0.5,
                        title="module ▸ sub-block (cells)")
    else:
        # inset over the grayed-core region (upper half of the right die)
        lg = ax.legend(handles, labels, loc="upper right", bbox_to_anchor=(0.995, 0.995),
                       fontsize=6.0, framealpha=0.92, edgecolor="#999999",
                       handlelength=1.0, labelspacing=0.22, borderpad=0.45,
                       handletextpad=0.5, title="module ▸ sub-block (cells)")
    style_legend(lg, handles)

fig.suptitle(suptitle, fontsize=14, fontweight="bold", y=0.965)
fig.savefig(out_png, dpi=150, bbox_inches="tight", pad_inches=0.08)
print(f"wrote {out_png}")
