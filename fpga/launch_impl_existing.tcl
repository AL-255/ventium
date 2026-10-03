# Resume implementation from an already-completed Vivado synthesis run.
#
# The normal project generator launches synth+impl together.  Keeping this small
# entry point lets a long synthesis checkpoint be inspected before committing to
# placement and routing, without recreating the block design or rerunning synth.
if {$argc != 1} {
    error "usage: vivado -mode batch -source launch_impl_existing.tcl -tclargs <project.xpr>"
}

# Explicit crash-avoidance option for a fresh implementation. Vivado 2025.2
# documents RuntimeOptimized as Default without bram_power_opt; the latter
# crashed on this large hierarchy. Do not reset or retarget a prior run.
set opt_directive Default
if {[info exists ::env(VEN_FPGA_OPT_DIRECTIVE)]} {
    set opt_directive $::env(VEN_FPGA_OPT_DIRECTIVE)
    if {$opt_directive ni {Default RuntimeOptimized}} {
        error "VEN_FPGA_OPT_DIRECTIVE must be Default or RuntimeOptimized"
    }
}

# An explicitly requested target must match the existing constrained clock.
# With no target, retain compatibility with older checkpoints and report the
# actual finite positive period rather than guessing the intended frequency.
set expected_core_period ""
if {[info exists ::env(VEN_FPGA_CORE_MHZ)]} {
    if {$::env(VEN_FPGA_CORE_MHZ) ni {40 45 50}} {
        error "VEN_FPGA_CORE_MHZ must be 40, 45 or 50 when provided"
    }
    set expected_core_period [expr {1000.0 / $::env(VEN_FPGA_CORE_MHZ)}]
}

set project [file normalize [lindex $argv 0]]
open_project $project
set_param general.maxThreads 1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synth_1 is not complete"
}

if {$opt_directive eq "RuntimeOptimized"} {
    set synth [get_runs synth_1]
    if {[get_property STATUS $synth] ne "synth_design Complete!" ||
        [string tolower [get_property NEEDS_REFRESH $synth]] ni {0 false}} {
        error "synth_1 is stale or lacks native completion"
    }
    set impl [get_runs impl_1]
    if {[get_property PROGRESS $impl] ne "0%" ||
        [get_property STATUS $impl] ne "Not started"} {
        error "RuntimeOptimized requires a fresh, never-started impl_1; no reset permitted"
    }
    if {[string first "RuntimeOptimized - Runs Default without bram_power_opt" [help opt_design]] < 0} {
        error "installed opt_design help does not document RuntimeOptimized"
    }
    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $impl
    if {[get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE $impl] ne "RuntimeOptimized"} {
        error "opt_design directive did not retain RuntimeOptimized"
    }
    puts "## Fresh implementation: RuntimeOptimized (Default without bram_power_opt)"
}

launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 failed (PROGRESS=[get_property PROGRESS [get_runs impl_1]])"
}
if {$opt_directive eq "RuntimeOptimized" &&
    ([get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!" ||
     [string tolower [get_property NEEDS_REFRESH [get_runs impl_1]]] ni {0 false})} {
    error "impl_1 lacks native bitstream completion or is stale"
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
report_utilization -file [file join $impl_dir post_impl_utilization.rpt]
report_timing_summary -file [file join $impl_dir post_impl_timing_summary.rpt]

# Report the constrained clocks before slack.  Slack proves closure only at the
# constraint; it is not a frequency measurement. Support the current MMCM
# MMCM clock name as well as the legacy divider checkpoint's name.
proc report_clock_frequency {clock_name role {expected_period ""}} {
    set clock [get_clocks -quiet $clock_name]
    if {[llength $clock] != 1} {
        error "expected exactly one $role clock named '$clock_name', found [llength $clock]"
    }
    set period_ns [get_property PERIOD $clock]
    if {![string is double -strict $period_ns] || !($period_ns > 0.0 && $period_ns < Inf)} {
        error "clock '$clock_name' has invalid PERIOD '$period_ns'"
    }
    # Vivado may expose PERIOD quantized to 1 ps (e.g. 22.222 ns at 45 MHz).
    # The tiny arithmetic guard keeps the inclusive 1 ps boundary stable.
    if {$expected_period ne "" && abs($period_ns - $expected_period) > 0.001 + 1.0e-12} {
        error "clock '$clock_name' has PERIOD '$period_ns'; expected $expected_period ns"
    }
    puts [format "## Frequency (%s): %.6f MHz (%.6f ns constrained period)" \
        $role [expr {1000.0 / $period_ns}] $period_ns]
}

set expected_pl_period ""
if {$opt_directive eq "RuntimeOptimized"} { set expected_pl_period 10.0 }
report_clock_frequency clk_pl_0 "PL / HP0" $expected_pl_period
set core_clocks {}
foreach candidate {mmcm_clk u_clkdiv_clk_out wr_clk_i} {
    set matches [get_clocks -quiet $candidate]
    if {[llength $matches] > 1} {
        error "ambiguous implemented core clock '$candidate' ([llength $matches] matches)"
    }
    if {[llength $matches] == 1} { lappend core_clocks $candidate }
}
if {[llength $core_clocks] != 1} {
    error "expected exactly one implemented core clock, found [llength $core_clocks] ($core_clocks)"
}
set core_clock [lindex $core_clocks 0]
report_clock_frequency $core_clock "core" $expected_core_period

foreach analysis {setup hold} {
    set paths [get_timing_paths -max_paths 1 -nworst 1 -$analysis]
    if {[llength $paths] != 1} {
        error "expected exactly one worst $analysis timing path, found [llength $paths]"
    }
    set slack [get_property SLACK $paths]
    if {![string is double -strict $slack] || !($slack > -Inf && $slack < Inf)} {
        error "invalid worst $analysis slack '$slack'"
    }
    set worst_slack($analysis) $slack
}
set wns $worst_slack(setup)
set whs $worst_slack(hold)
puts "## WNS (setup worst slack) = $wns"
puts "## WHS (hold worst slack) = $whs"
puts "## IMPL OK"
close_project
