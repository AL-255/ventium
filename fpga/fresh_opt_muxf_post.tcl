# OPT_DESIGN.TCL.POST for the retime_muxf_route_first Vivado 2025.2 strategy.
# Runs after RuntimeOptimized opt_design in a fresh source-only implementation.
# Performs one explicit opt_design -muxf_remap pass without enabling
# bram_power_opt or resynth_remap.
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i"} {
    error "remap target part mismatch"
}
set muxf_threads [get_param general.maxThreads]
if {$muxf_threads ni {1 2 4 8}} {error "unsupported remap thread count: $muxf_threads"}
if {[info exists ::fresh_muxf_started]} {error "duplicate remap pass"}
set ::fresh_muxf_started 1
foreach muxf_stage {before after} {
    foreach muxf_kind {core-paths utilization} {
        if {[file exists "fresh-muxf-$muxf_stage-$muxf_kind.rpt"]} {
            error "pre-existing remap evidence"
        }
    }
}
proc fresh_muxf_report {stage} {
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
        -path_type full_clock_expanded -file "fresh-muxf-$stage-core-paths.rpt"
    report_utilization -hierarchical -file "fresh-muxf-$stage-utilization.rpt"
    foreach primitive {MUXF7 MUXF8 MUXF9} {
        set count [llength [get_cells -quiet -hierarchical -filter "REF_NAME == $primitive"]]
        puts "FRESH-MUXF-COUNTS stage=$stage primitive=$primitive count=$count"
    }
}
fresh_muxf_report before
puts "FRESH-MUXF-REMAP-BEGIN threads=$muxf_threads command=opt_design-muxf_remap"
opt_design -muxf_remap
fresh_muxf_report after
puts "FRESH-MUXF-REMAP-END"
