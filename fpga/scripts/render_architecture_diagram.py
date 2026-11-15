#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Render the Ventium P54C + RK-XCZU15EG-F SoC architecture diagram.

Deterministic, offline Matplotlib vector/raster generator (no Graphviz or
Vivado dependency). Uses strict two-column layout with a dedicated central
interconnect spine and orthogonal Manhattan bus routing so arrows never cross
module text.
"""
import argparse
from pathlib import Path


def draw_architecture(out_png: Path, out_svg: Path | None = None) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.path import Path as MplPath
    from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, PathPatch, Rectangle

    plt.rcParams.update({
        "font.family": "DejaVu Sans",
        "svg.fonttype": "none",
    })

    # Coordinate canvas: 0..100 horizontal, 0..72 vertical
    fig, ax = plt.subplots(figsize=(16.5, 11.88), dpi=200)
    fig.patch.set_facecolor("#ffffff")
    ax.set_facecolor("#ffffff")
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 72)
    ax.axis("off")

    def container(x, y, w, h, title, subtitle, edge, fill):
        box = FancyBboxPatch(
            (x, y), w, h,
            boxstyle="round,pad=0.0,rounding_size=0.85",
            linewidth=1.75, edgecolor=edge, facecolor=fill, zorder=1,
        )
        ax.add_patch(box)
        hdr_h = 2.35
        hdr = FancyBboxPatch(
            (x, y + h - hdr_h), w, hdr_h,
            boxstyle="round,pad=0.0,rounding_size=0.85",
            linewidth=0, facecolor=edge, zorder=2,
        )
        ax.add_patch(hdr)
        sq = Rectangle((x, y + h - hdr_h), w, hdr_h * 0.48, linewidth=0, facecolor=edge, zorder=2)
        ax.add_patch(sq)
        ax.text(
            x + 1.0, y + h - 1.18, title,
            fontsize=9.8, fontweight="bold", color="#ffffff", va="center", ha="left", zorder=3,
        )
        if subtitle:
            ax.text(
                x + w - 1.0, y + h - 1.18, subtitle,
                fontsize=7.8, family="DejaVu Sans Mono", color="#e2e8f0", va="center", ha="right", zorder=3,
            )

    def block(x, y, w, h, title, rtl, lines, edge, fill="#ffffff", title_color="#0f172a"):
        box = FancyBboxPatch(
            (x, y), w, h,
            boxstyle="round,pad=0.0,rounding_size=0.5",
            linewidth=1.2, edgecolor=edge, facecolor=fill, zorder=3,
        )
        ax.add_patch(box)
        strip = FancyBboxPatch(
            (x, y), 0.44, h,
            boxstyle="round,pad=0.0,rounding_size=0.22",
            linewidth=0, facecolor=edge, zorder=4,
        )
        ax.add_patch(strip)
        top_y = y + h - 0.72
        ax.text(
            x + 0.88, top_y, title,
            fontsize=8.35, fontweight="bold", color=title_color, va="top", ha="left", zorder=5,
        )
        ax.text(
            x + 0.88, top_y - 1.18, rtl,
            fontsize=6.75, family="DejaVu Sans Mono", color=edge, va="top", ha="left", zorder=5,
        )
        body_y = top_y - 2.32
        for line in lines:
            ax.text(
                x + 0.88, body_y, line,
                fontsize=7.3, color="#334155", va="top", ha="left", zorder=5,
            )
            body_y -= 1.06

    def ortho(points, color="#334155", bidir=False, lw=1.5, ls="-", label=None, label_xy=None):
        """Draw a crisp orthogonal polyline with end arrowheads."""
        if len(points) > 2:
            codes = [MplPath.MOVETO] + [MplPath.LINETO] * (len(points) - 1)
            poly = PathPatch(
                MplPath(points, codes),
                facecolor="none", edgecolor=color, linewidth=lw, linestyle=ls,
                joinstyle="round", capstyle="round", zorder=6,
            )
            ax.add_patch(poly)
            # End arrowhead
            arr_end = FancyArrowPatch(
                points[-2], points[-1],
                arrowstyle="-|>,head_length=5.2,head_width=3.2",
                linewidth=lw, linestyle="-", color=color, zorder=7,
            )
            ax.add_patch(arr_end)
            if bidir:
                arr_start = FancyArrowPatch(
                    points[1], points[0],
                    arrowstyle="-|>,head_length=5.2,head_width=3.2",
                    linewidth=lw, linestyle="-", color=color, zorder=7,
                )
                ax.add_patch(arr_start)
        else:
            style = "<|-|>" if bidir else "-|>"
            arr = FancyArrowPatch(
                points[0], points[1],
                arrowstyle=f"{style},head_length=5.2,head_width=3.2",
                linewidth=lw, linestyle=ls, color=color, zorder=7,
            )
            ax.add_patch(arr)
        if label and label_xy:
            ax.text(
                label_xy[0], label_xy[1], label,
                fontsize=6.95, fontweight="bold", color=color,
                va="center", ha="center",
                bbox=dict(boxstyle="round,pad=0.18,rounding_size=0.22", fc="#ffffff", ec=color, lw=0.65, alpha=0.96),
                zorder=8,
            )

    # =========================================================================
    # Title & Subtitle Banner
    # =========================================================================
    ax.text(
        1.5, 70.3,
        "Ventium P5/P54C Superscalar Processor & RK-XCZU15EG-F SoC Architecture",
        fontsize=15.5, fontweight="bold", color="#0f172a", va="center", ha="left",
    )
    ax.text(
        1.5, 68.45,
        "Board-qualified c0e3fe43 release  •  161 hardware defines  •  40.26 MHz post-route STA sign-off (40.0–62.5 MHz runtime DRP)  •  Dual-issue U/V + Pipelined x87",
        fontsize=8.65, color="#475569", va="center", ha="left",
    )

    # =========================================================================
    # Outer Clock Domain Envelopes
    # =========================================================================
    core_dom = FancyBboxPatch(
        (1.4, 18.2), 97.2, 48.9,
        boxstyle="round,pad=0.0,rounding_size=1.05",
        linewidth=1.35, linestyle=(0, (5, 3)), edgecolor="#64748b", facecolor="#f8fafc", zorder=0,
    )
    ax.add_patch(core_dom)
    ax.text(
        2.5, 66.25,
        "CORE CLOCK DOMAIN  —  mmcm_clk (40.000 MHz STA-signed-off boot; glitch-free runtime DRP 40.0–62.5 MHz)",
        fontsize=8.0, fontweight="bold", color="#334155", va="center", ha="left", zorder=2,
    )

    axi_dom = FancyBboxPatch(
        (1.4, 1.2), 97.2, 13.8,
        boxstyle="round,pad=0.0,rounding_size=1.05",
        linewidth=1.35, edgecolor="#1e293b", facecolor="#f1f5f9", zorder=0,
    )
    ax.add_patch(axi_dom)
    ax.text(
        2.5, 14.15,
        "PS / INTERCONNECT CLOCK DOMAIN  —  clk_pl_0 (100.000 MHz fixed ZynqMP IOPLL)  +  Cortex-A53 Linux",
        fontsize=8.0, fontweight="bold", color="#0f172a", va="center", ha="left",
        bbox=dict(boxstyle="round,pad=0.14,rounding_size=0.15", fc="#f1f5f9", ec="none"),
        zorder=7,
    )

    # Left column: x = 2.4 .. 59.8 (w = 57.4)
    # Central bus spine: x = 59.8 .. 65.2 (width = 5.4!)
    # Right column: x = 65.2 .. 97.6 (w = 32.4)

    # =========================================================================
    # ZONE 1: FRONT-END & FETCH (Left-Top, Blue)
    # =========================================================================
    container(
        2.4, 47.4, 57.4, 17.9,
        "1. Front-End, Branch Prediction & Dual-Stage Decode",
        "rtl/core/ + rtl/mem/",
        edge="#1d4ed8", fill="#eff6ff",
    )

    block(
        3.5, 55.6, 17.6, 6.7,
        "Branch Target Buffer", "bpred_btb.sv",
        [
            "• 256-entry, 4-way set-assoc",
            "• Distributed LUTRAM storage",
            "• 2-bit bimodal state + target",
        ],
        edge="#2563eb",
    )
    block(
        22.2, 55.6, 17.8, 6.7,
        "I-TLB & Fetch Auth", "tlb_assoc.sv / core.sv",
        [
            "• 32-entry, 4-way I-TLB (4K/4M)",
            "• LUTRAM FE-ITLB + direct flin",
            "• Selective CR0/CR4 PGE flush",
        ],
        edge="#2563eb",
    )
    block(
        41.1, 55.6, 17.6, 6.7,
        "L1 Instruction Cache", "icache.sv",
        [
            "• 8 KiB, 2-way, 32 B (256b) line",
            "• Scalar LUTRAM tag arrays",
            "• Split-line fetch & SMC snoop",
        ],
        edge="#2563eb",
    )

    block(
        3.5, 48.3, 26.8, 5.9,
        "Prefetch Queue & Uopcache", "uopcache.sv / core_ic_*.svh",
        [
            "• 256-bit fetch window + resident span tracker",
            "• Prefix/length predecode + decoded uop cache",
        ],
        edge="#1d4ed8",
    )
    block(
        31.6, 48.3, 27.1, 5.9,
        "Dual-Stage Decode & UV Pairing", "decode.sv / issue_uv.sv",
        [
            "• D1/D2 decode stages + AGI hazard interlock",
            "• AP-500 P54C U+V pairing (cycle_mode = 1'b1)",
        ],
        edge="#1d4ed8",
    )

    # Zone 1 internal connections
    ortho([(21.1, 58.95), (22.2, 58.95)], color="#1d4ed8")
    ortho([(40.0, 58.95), (41.1, 58.95)], color="#1d4ed8")
    ortho([(12.3, 55.6), (12.3, 54.2)], color="#1d4ed8")
    ortho([(49.9, 55.6), (49.9, 54.9), (22.5, 54.9), (22.5, 54.2)], color="#1d4ed8", label="256b line", label_xy=(36.2, 54.9))
    ortho([(30.3, 51.25), (31.6, 51.25)], color="#1d4ed8")

    # =========================================================================
    # ZONE 2: DUAL-ISSUE INTEGER & SYSTEM CORE (Left-Middle, Emerald)
    # =========================================================================
    container(
        2.4, 29.8, 57.4, 15.6,
        "2. Superscalar U/V Integer Execution & System Engine",
        "rtl/core/core.sv",
        edge="#047857", fill="#ecfdf5",
    )

    block(
        3.5, 36.8, 17.4, 5.6,
        "U-Pipe (Primary)", "core_exec.svh",
        [
            "• Full 32b ALU + barrel shift",
            "• Fast MUL/DIV, ctrl & sys",
        ],
        edge="#059669",
    )
    block(
        22.0, 36.8, 17.4, 5.6,
        "V-Pipe (Paired)", "issue_uv.sv / core.sv",
        [
            "• Paired 32b ALU & mem ops",
            "• Paired near Jcc/JMP/CALL",
        ],
        edge="#059669",
    )
    block(
        40.5, 36.8, 18.2, 5.6,
        "Dual AGU & 8-Port GPRs", "regfile.sv",
        [
            "• Parallel U + V effective addr",
            "• EAX–EDI + CS..GS descriptors",
        ],
        edge="#059669",
    )

    block(
        3.5, 30.6, 27.2, 5.3,
        "System Fastpath & Burst String", "core_fastpath.svh",
        [
            "• Relocated 32-bit PM fast load/store in S_PIPE",
            "• Pipelined REP STOSB/W/D cacheline streamer",
        ],
        edge="#047857",
    )
    block(
        31.9, 30.6, 26.8, 5.3,
        "Microcode, Paging & Fault FSM", "core.sv",
        [
            "• Split-page fragment engine (probe-before-write)",
            "• Hardware page walker, V86, TSS, IDT, SMM",
        ],
        edge="#047857",
    )

    # Zone 1 -> Zone 2 issue paths (routed cleanly in y = 45.4..48.3 gap)
    ortho([(40.0, 48.3), (40.0, 46.35), (12.2, 46.35), (12.2, 45.4)], color="#047857", label="U + V issue", label_xy=(26.0, 46.35))

    # =========================================================================
    # ZONE 4: L1 D-CACHE, D-TLB & AXI MASTER (Left-Bottom of Core Domain, Purple)
    # =========================================================================
    container(
        2.4, 19.0, 57.4, 9.2,
        "4. Data Cache, D-TLB & 64-bit L1 AXI4 Bus Unit",
        "rtl/mem/",
        edge="#6d28d9", fill="#f5f3ff",
    )

    block(
        3.5, 19.8, 17.4, 5.5,
        "64-Entry 4-Way D-TLB", "tlb_assoc.sv",
        [
            "• 4 KiB & 4 MiB PSE pages",
            "• Fast-path hit + page walk",
        ],
        edge="#7c3aed",
    )
    block(
        22.0, 19.8, 18.2, 5.5,
        "8 KiB Dual-Port L1D", "ven_l1d.sv",
        [
            "• 2-way, banked, 32 B lines",
            "• Store buffer + WB / WT",
        ],
        edge="#7c3aed",
    )
    block(
        41.3, 19.8, 17.4, 5.5,
        "L1 AXI4 Master", "ventium_l1_axi.sv",
        [
            "• 64b cacheline bursts",
            "• Byte-exact UC & PMIO",
        ],
        edge="#6d28d9",
    )

    ortho([(20.9, 22.55), (22.0, 22.55)], color="#6d28d9")
    ortho([(40.2, 22.55), (41.3, 22.55)], color="#6d28d9")
    # Integer Core <-> L1D/D-TLB
    ortho([(31.1, 29.8), (31.1, 28.2)], color="#6d28d9", bidir=True, label="32b U+V load/store", label_xy=(23.2, 29.0))

    # =========================================================================
    # ZONE 3: SHARED PIPELINED x87 FPU (Right-Top, Amber)
    # =========================================================================
    container(
        65.2, 39.2, 32.4, 26.1,
        "3. Shared Pipelined x87 FPU",
        "fp_shared/ + rtl/fpu/",
        edge="#b45309", fill="#fffbeb",
    )

    block(
        66.4, 56.9, 30.0, 5.5,
        "80-bit x87 Stack & FXCH Queue", "ven_fp_state.sv / fxch_queue.sv",
        [
            "• 8 × 80-bit extended-precision ST(0)..ST(7)",
            "• Zero-cycle FXCH rename (pairable)",
        ],
        edge="#d97706",
    )
    block(
        66.4, 50.8, 30.0, 5.4,
        "Pipelined FADD / FMUL / Misc", "ven_fp_alu.sv / widemul.sv",
        [
            "• 3-stage pipelined 80b adder & DSP mul",
            "• IEEE-754 rounding (24 / 53 / 64b)",
        ],
        edge="#d97706",
    )
    block(
        66.4, 44.9, 30.0, 5.2,
        "PC-Aware Radix-4 SRT FDIV / FSQRT", "fpu_srt_div.sv",
        [
            "• Precision early-stop: 19 / 33 / 39 clks",
            "• Non-blocking overlap with integer U-pipe",
        ],
        edge="#d97706",
    )
    block(
        66.4, 40.0, 30.0, 4.2,
        "Hardware Transcendental Engine", "ven_fp_trans.sv",
        [
            "• FSIN, FCOS, FSINCOS, FPTAN, FPATAN, FYL2X",
        ],
        edge="#b45309",
    )

    # =========================================================================
    # ZONE 5: PC PLATFORM CHIPSET & CLOCKING (Right-Bottom of Core Domain, Rose)
    # =========================================================================
    container(
        65.2, 19.0, 32.4, 18.8,
        "5. PC Platform & DRP Clock",
        "ao486_MiSTer + fpga/",
        edge="#be123c", fill="#fff1f2",
    )

    block(
        66.4, 29.1, 14.6, 5.8,
        "Platform Shim", "ven_ao486_shim.sv",
        [
            "• DDR4 vs VGA/PMIO",
            "• External DDR drain",
            "  barrier on I/O",
        ],
        edge="#e11d48",
    )
    block(
        81.8, 29.1, 14.6, 5.8,
        "DRP Clock Ctrl", "ven_pll_ctrl.sv",
        [
            "• MMCME4 (1 GHz VCO)",
            "• 40 MHz boot",
            "• 50–62.5 MHz DRP",
        ],
        edge="#0284c7", fill="#f0f9ff", title_color="#0369a1",
    )
    block(
        66.4, 19.8, 14.6, 8.4,
        "VGA + Capture", "vga.v / video_capture.sv",
        [
            "• 256 KiB BRAM VRAM",
            "• Mode 13h & SVGA GUI",
            "• Passive scanout",
            "  capture -> DDR ring",
        ],
        edge="#e11d48",
    )
    block(
        81.8, 19.8, 14.6, 8.4,
        "AT Peripherals", "system.v / opl3.sv",
        [
            "• Dual 8259A PIC",
            "• 8254 PIT, 8237 DMA",
            "• 8042 PS/2 KBD+Mouse",
            "• IDE, RTC, SB16/OPL3",
        ],
        edge="#e11d48",
    )

    # =========================================================================
    # CENTRAL INTERCONNECT SPINE (x = 60.8, 62.1, 63.4 — zero crossings!)
    # =========================================================================
    # 1) Decode -> x87 FPU issue (x = 61.2)
    ortho(
        [(58.7, 51.25), (61.2, 51.25), (61.2, 59.65), (66.4, 59.65)],
        color="#b45309", label="FP issue", label_xy=(62.6, 60.55),
    )
    # 2) x87 FPU <-> L1D 80-bit load/store (x = 62.4)
    ortho(
        [(66.4, 47.5), (62.4, 47.5), (62.4, 28.9), (38.0, 28.9), (38.0, 28.2)],
        color="#b45309", bidir=True, label="80b FP mem", label_xy=(62.4, 38.3),
    )
    # 3) I-Cache refill from L1 AXI4 Master (x = 60.8)
    ortho(
        [(58.7, 58.0), (60.6, 58.0), (60.6, 24.0), (58.7, 24.0)],
        color="#1d4ed8", ls=(0, (3, 2)), bidir=True, label="64b I$ refill", label_xy=(62.4, 43.2),
    )
    # 4) L1 AXI4 Master <-> Platform Shim (x = 63.8)
    ortho(
        [(58.7, 21.6), (63.8, 21.6), (63.8, 32.0), (66.4, 32.0)],
        color="#be123c", bidir=True, label="64b AXI4", label_xy=(62.5, 20.6),
    )
    # Internal Zone 5 Shim <-> VGA and AT Peripherals
    ortho([(73.7, 29.1), (73.7, 28.2)], color="#be123c", bidir=True)
    ortho([(81.0, 29.8), (81.4, 29.8), (81.4, 25.5), (81.8, 25.5)], color="#be123c", bidir=True)

    # =========================================================================
    # ZONE 6: 100 MHz ZYNQMP AXI / DDR4 / DEBUG SUBSYSTEM (Bottom, Slate)
    # =========================================================================
    block(
        2.5, 2.2, 31.5, 10.9,
        "16-Slot Posted DDR4 Bridge & RAW Bypass", "fpga/ven_ddram_axi_posted.sv",
        [
            "• Queues CPU/DMA stores with real external drain barrier",
            "• RAW-hazard-aware read bypass overtakes non-overlapping",
            "  queued stores (eliminates read-behind-write stalls)",
            "• Async AXI4 CDC (mmcm_clk <-> 100 MHz) + 64b->128b upsizer",
        ],
        edge="#1e293b",
    )
    block(
        36.2, 2.2, 30.0, 10.9,
        "Zynq UltraScale+ PS8 & Reserved DDR4", "zynq_ultra_ps_e (S_AXI_HP0)",
        [
            "• S_AXI_HP0 (128-bit @ 100 MHz -> PS DDR4 controller)",
            "• 256 MiB guest RAM at 0x60000000–0x6FFFFFFF (DT no-map)",
            "• Passive VGA frame-capture ring buffer in upper DDR4",
            "• ARM Cortex-A53 Linux hosts BIOS, HDD/CD & PS/2 daemon",
        ],
        edge="#0f172a",
    )
    block(
        68.4, 2.2, 29.2, 10.9,
        "AXI-Lite Debug, PMU & Board Control", "ven_mgmt_axil.v / ven_soc_dbg.sv",
        [
            "• M_AXI_HPM0_LPD @ 0xA0000000 + GPIO EMIO[94:0]",
            "• Hardware cycle, U-pipe & paired V-pipe PMU counters",
            "• AXI read/write latency profilers & trace status",
            "• Safe reset/drain-interlocked MMCM DRP clock control",
        ],
        edge="#334155",
    )

    # Horizontal PS-domain internal buses
    ortho([(34.0, 7.65), (36.2, 7.65)], color="#0f172a", bidir=True, label="128b", label_xy=(35.1, 9.0))
    ortho([(66.2, 7.65), (68.4, 7.65)], color="#334155", bidir=True, label="HPM0", label_xy=(67.3, 9.0))

    # Cross-domain buses routed cleanly in y = 15.0 .. 19.0 horizontal channel!
    # A) Platform Shim <-> 16-Slot Posted DDR4 Bridge (via x = 64.6, y = 17.1)
    ortho(
        [(66.4, 30.6), (64.6, 30.6), (64.6, 17.1), (31.5, 17.1), (31.5, 13.1)],
        color="#1e293b", bidir=True, label="Memory bus + external drained barrier", label_xy=(48.0, 17.1),
    )
    # B) VGA Frame Capture -> PS8 DDR4 ring buffer (via y = 15.9)
    ortho(
        [(73.7, 19.8), (73.7, 15.9), (63.8, 15.9), (63.8, 13.1)],
        color="#be123c", label="64b frame DMA", label_xy=(68.8, 15.9),
    )
    # C) AXI-Lite Debug / EMIO <-> AT Peripherals & DRP Clock
    ortho(
        [(89.1, 13.1), (89.1, 19.8)],
        color="#0284c7", bidir=True, label="PS/2, IDE, DRP", label_xy=(89.1, 16.55),
    )

    fig.subplots_adjust(left=0.01, right=0.99, bottom=0.01, top=0.99)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=200, facecolor="#ffffff")
    if out_svg is not None:
        out_svg.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(out_svg, facecolor="#ffffff")
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--png", type=Path, required=True, help="Output PNG path")
    parser.add_argument("--svg", type=Path, help="Optional output SVG path")
    args = parser.parse_args()
    draw_architecture(args.png, args.svg)
    print(f"Wrote {args.png}" + (f" and {args.svg}" if args.svg else ""))


if __name__ == "__main__":
    main()
