# Public FPGA Source Release (`c0e3fe43`) — 2026-11-14

This release updates `main` to publish the complete, self-contained hardware source closure, fresh-source Vivado 2025.2 build recipe, SoC architecture diagram, and colored component floorplans for board-qualified FPGA image **`c0e3fe43`**. Ongoing unqualified experiments remain isolated on `experimental/uv-fast-ipc-apr`.

## Source & Artifact Identity

- **Reference raw bitstream (`rk_ao486_system.bit.bin`) SHA-256:**
  `c0e3fe43b2b7ce88e013df107be94d56c0fcfcae626ce4c262975fba92dcc3b7`
- **Reference framed bitstream (`rk_ao486_system.bit`) SHA-256:**
  `091e0fab60650ab890c783e2c63650e9e60770e822cf04334de3a13b3c9738a8`
- **Reference routed checkpoint (`fresh-routed.dcp`) SHA-256:**
  `2bd41907b5f87343078d47d1a62895129dcf511a804442c5e876cf9d2f9ce44b`
- **Original source-preparation receipt (`prepared.json`) SHA-256:**
  `47682f66fbd09eccd6d5efa3bac2c3f5bfc7b4b4a5bbd3b219f3608514d33dfa` (recorded in `fpga/known_good_c0e3fe43.json`)
- **Hash-pinned manifest (`main`):** [`fpga/known_good_c0e3fe43.json`](https://github.com/AL-255/ventium/blob/main/fpga/known_good_c0e3fe43.json) — **193 pinned files** (**186** RTL, constraint, ordered filelist, and define files byte-for-byte identical to the `apr-r1` build freeze + **7** portable public build/entry wrappers) and **161 hardware defines** (`fpga/known_good_defines.txt`, SHA-256 `1d40a25641a10ba87012c9f159e6a50427f3bc188c66f249be80b012a4a7c8dc`).

## Summary of Architectural & Physical Improvements Over `2886d24c`

1. **Tier-1 P54C IPC Enhancements (`+3.88%` Physical Quake Gameplay IPC):**
   - 32-entry **4-way set-associative I-TLB** (`VEN_ITLB_ASSOC_4WAY`) replacing direct-mapped code-page thrashing.
   - Dual-ported **256-entry 4-way BTB** (4&times; capacity, simultaneous fetch lookup + retire update).
   - Pipelined cacheable **`REP STOS` store streaming** (`VEN_REP_STOS_STREAM`, 1-cycle/element steady state with page/limit/interrupt safety).
   - Protected-mode fast-path **`MOVZX`/`MOVSX`** zero/sign-extending loads (`0F B6`/`0F B7`/`0F BE`/`0F BF` in `S_PIPE`) and 16-slot **posted-DDR4 CAM read-after-write hazard bypass** (`ven_ddram_axi_posted.sv`).
2. **Congestion Relief & True 40 MHz Static Timing Sign-Off:**
   - Replicated `pf_fill_addr_rep[0..3]` fanout trees and narrowed `ic_res_line_base` muxing, paired with fresh-source `retime_muxf_route_first` (`PerformanceOptimized` + `GLOBAL_RETIMING on` + `opt_design -muxf_remap` + `AltSpreadLogic_high` + `AlternateCLBRouting`).
   - Reduced utilization to **`171,819` LUTs (`50.35%`)**, **`30,703` CLBs (`71.97%`)**, and **`39,520` FFs (`5.79%`)**, eliminated **100% of `>=85%` global routing hotspots**, and closed post-route STA at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` failing endpoints).
3. **Full Physical Standard Acceptance Suite & Runtime DRP Overclocking:**
   - **Quake `timedemo demo1` (`40.000 MHz`):** `969` frames in `121.2 s` (**`8.0 FPS`**); interior gameplay IPC **`0.515778001` total U+V** / **`0.397847833` primary/U-only** across cycles **`28,696,827,616–32,989,404,795`** (counters include `REP`-element retirement). Capture GIF: [`docs/quake-timedemo-c0e3fe43.gif`](quake-timedemo-c0e3fe43.gif) (`3,075` frames, `320×200`, `15 fps` playback, palette compression only).
   - **Windows 95 OSR2 GUI:** Cold boot to desktop, interactive PS/2 mouse/keyboard across Calculator (`355/113`), Notepad, and MS Paint, plus clean shutdown (`40.000 MHz` and `58.824 MHz`). Screenshot: [`docs/win95-desktop-c0e3fe43.png`](win95-desktop-c0e3fe43.png).
   - **CoreMark (`40.000 MHz`):** Both 4,000-iteration standard seeds pass with exact reference CRCs (`2.100128 / 2.106796 CM/MHz`).
   - **Empirical Runtime DRP Overclocking (same bitstream):** `58.824 MHz` (`N=17`) passed cold Win95 + Quake; `62.500 MHz` (`N=16`) passed cold DOS Quake `demo1` + interactive `E1M1` gameplay. (STA sign-off covers `40.000 MHz` only.)
