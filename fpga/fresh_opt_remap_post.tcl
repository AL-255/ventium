# Optional hook for routability-retime-remap-route-first only.
# Integration point: OPT_DESIGN.TCL.POST, after the independently
# verified `opt_design -directive RuntimeOptimized` has completed. This second
# explicit pass does not re-enable the previously crashing bram_power_opt.
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i"} {
    error "remap target part mismatch"
}
set remap_threads [get_param general.maxThreads]
if {$remap_threads ni {4 8}} {error "unsupported remap thread count"}
if {[info exists ::fresh_remap_started]} {error "duplicate remap pass"}
set ::fresh_remap_started 1
# Capture matched-stage evidence, not just proof that a command executed.
# These are read-only unplaced estimates, never final timing sign-off. Keep
# them in this native worker's fresh run directory and refuse stale products.
foreach remap_stage {before after} {
    foreach remap_kind {core-paths utilization} {
        if {[file exists "fresh-remap-$remap_stage-$remap_kind.rpt"]} {
            error "pre-existing remap evidence"
        }
    }
}
proc fresh_remap_report {stage} {
    set clocks {}
    foreach clock [get_clocks] {
        if {abs([get_property PERIOD $clock]-25.0) < 0.001} {
            lappend clocks $clock
        }
    }
    if {[llength $clocks] != 1} {error "missing/ambiguous remap core clock"}
    if {[llength [get_timing_paths -setup -from $clocks -to $clocks -max_paths 1]] != 1} {
        error "missing remap core timing path"
    }
    report_timing -from $clocks -to $clocks -max_paths 20 \
        -path_type full_clock_expanded -file "fresh-remap-$stage-core-paths.rpt"
    report_utilization -hierarchical -file "fresh-remap-$stage-utilization.rpt"
}
fresh_remap_report before
puts "FRESH-LOGIC-REMAP-BEGIN threads=$remap_threads command=opt_design-resynth_remap"
opt_design -resynth_remap
fresh_remap_report after
puts "FRESH-LOGIC-REMAP-END"
