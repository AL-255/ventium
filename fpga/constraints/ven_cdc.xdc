# fpga/constraints/ven_cdc.xdc — CDC timing constraints for the +VEN_AXI_CDC dual-
# clock L1/AXI build (P1-3). Copyright 2026 Anhang Li (AL-255). Apache-2.0 WITH SHL-2.1.
#
# STATUS: written for the FUTURE MMCM dual-clock full-system BD (#37). It is NOT yet
# timing-validated — no Vivado run instantiates two genuinely asynchronous clocks for
# this RTL yet (the current bd_l1axi.tcl is the single-pl_clk0 CDC_BYPASS build, where
# the CDC path is a dormant net-alias passthrough and these constraints are inert).
# The RTL crossing is verified FUNCTIONALLY by verif/l1/run-l1axi-cdc-gate.sh (4 clock
# ratios) + run-l1axi-cdc-verify.sh (77/77 cosim). These constraints make it close
# timing CORRECTLY on real silicon; apply them when axi_clk becomes a separate MMCM
# clock. See fpga/L1_AXI_DESIGN.md §7.
#
# ========================== (A) TOP-LEVEL — add in the BD/system XDC ==========
# THE load-bearing constraint: declare core_clk and axi_clk asynchronous. This
# false-paths EVERY core_clk<->axi_clk path (the Gray-pointer 2-FF syncs, the bus_err
# level sync, the LUTRAM async-read data), so static timing does not try to close the
# inherently-async crossings. Correctness is then guaranteed STRUCTURALLY: Gray code
# (exactly one pointer bit changes per step → a metastable sample resolves to old-or-
# new, never corrupt) + the FWFT protocol (a word sits unread in the FIFO RAM, stable,
# until rd_empty deasserts ≥2 rd-clocks after it was committed). Use the ACTUAL MMCM
# output clock names from the clocking wizard:
#
#   set_clock_groups -asynchronous \
#       -group [get_clocks -include_generated_clocks <core_clk>] \
#       -group [get_clocks -include_generated_clocks <axi_clk>]
#
# (set_clock_groups is preferred over per-net set_false_path: it covers the data path
# too and cannot miss a crossing a maintainer adds later.)
#
# ========================== (B) SCOPED — read_xdc -ref ven_cdc_afifo ==========
# Belt-and-suspenders on top of (A): bound the Gray-pointer source→first-sync-flop
# hop to the DESTINATION clock period so the 2nd (ASYNC_REG) flop always gets a full
# period of settling window, maximizing MTBF. -datapath_only ignores the (async,
# meaningless) source clock edge. Read this file SCOPED to each ven_cdc_afifo instance
# so the relative cell names resolve, e.g. in the BD/synth tcl:
#   read_xdc -ref ven_cdc_afifo -unmanaged fpga/constraints/ven_cdc.xdc
# Replace 4.000 with the faster (shorter-period) of the two clocks if axi_clk < 4 ns.

# rd-pointer Gray crossing into the wr domain (wq1_rgray captures rgray):
set_max_delay -datapath_only -from [get_cells {rgray_reg[*]}] -to [get_cells {wq1_rgray_reg[*]}] 4.000
# wr-pointer Gray crossing into the rd domain (rq1_wgray captures wgray):
set_max_delay -datapath_only -from [get_cells {wgray_reg[*]}] -to [get_cells {rq1_wgray_reg[*]}] 4.000
# bus_bus_skew keeps the multi-bit Gray vector's bits arriving within one dst period
# of each other (so at most one bit is mid-transition when sampled — the Gray promise):
set_bus_skew -from [get_cells {rgray_reg[*]}] -to [get_cells {wq1_rgray_reg[*]}] 4.000
set_bus_skew -from [get_cells {wgray_reg[*]}] -to [get_cells {rq1_wgray_reg[*]}] 4.000

# NOTE — the LUTRAM async-read data path (mem_reg* -> rd_data, consumed combinationally
# by the bridge then registered) crosses the FIFO output boundary, so it is bounded by
# the top-level (A) async grouping + the FWFT stability guarantee, NOT scoped here.
# NOTE — the bus_err level sync (a_bus_err -> be_meta_reg in ven_axi_cdc) is a sticky
# single-bit level; (A)'s clock-groups false-paths it (no pulse to lose). If you prefer
# an explicit bound, add scoped to ven_axi_cdc:
#   set_max_delay -datapath_only -to [get_cells {be_meta_reg}] 4.000
