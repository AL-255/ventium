# fpga/scripts/post_route_holdfix.tcl — post-route hold-margin fix (HOLD_FIX=1).
#
# The F4A board-only DOS-Quake fetch #DE was root-caused to a MARGINAL HOLD violation on
# the uopcache fill->store BRAM-write path (u_uopcache/wbuf_slots_reg -> store_slots_b
# DINxDIN): nominal WHS ~+16 ps, which is BELOW the silicon PVT/OCV/jitter noise floor, so
# the path goes hold-NEGATIVE on real silicon and the RAMB36 latches wrong write data ->
# corrupted predecoded uop -> fetch corruption. (See memory dosquake-marginal-hold-rootcause.)
#
# STA reports the path MET (+16 ps), so phys_opt_design -hold_fix alone does NOTHING (it only
# repairs NEGATIVE hold slack). So we first TIGHTEN the hold requirement via hold clock
# uncertainty: HOLD_UNC (default 150 ps) makes every +<150 ps path a "violation", and THEN
# phys_opt_design -hold_fix inserts real hold-fixing delay to push the margin up to +HOLD_UNC.
# Result: genuine silicon hold margin on the uopcache BRAM write (and every other thin path).
#
# NOTE: hold-fixing inserts delay cells, which need ROUTING ROOM. On the 92%-LUT xck26 this
# is starved (the root enabler) -> pair HOLD_FIX=1 with congestion relief (UOPCACHE=0, drop
# a feature, or a bigger device) so route/phys_opt has room. This hook runs as
# STEPS.ROUTE_DESIGN.TCL.POST (after route_design, before write_bitstream).

set HU [expr {[info exists ::env(HOLD_UNC)] && $::env(HOLD_UNC) ne "" ? $::env(HOLD_UNC) : 0.150}]
puts "HOLDFIX: WHS before:"
report_timing_summary -delay_type min -no_detailed_paths -file ./holdfix_before.rpt
catch { puts [exec grep -m1 -i {Worst Hold} ./holdfix_before.rpt] }
puts "HOLDFIX: applying set_clock_uncertainty -hold $HU on all design clocks, then phys_opt_design -hold_fix"
set_clock_uncertainty -hold $HU [get_clocks]
phys_opt_design -hold_fix
report_timing_summary -delay_type min -no_detailed_paths -file ./holdfix_after.rpt
catch { puts [exec grep -m1 -i {Worst Hold} ./holdfix_after.rpt] }
# remove the artificial uncertainty so the saved checkpoint's reports read true margins
set_clock_uncertainty -hold 0.0 [get_clocks]
puts "HOLDFIX: done (uncertainty cleared; hold-fix delay cells remain routed)"
