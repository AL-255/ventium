# Placement-only diagnostic from a completed project, with its actual XDCs.
# Invoke via run_vivado_exclusive.sh with external RAM/disk/wall-time guards.
# No synthesis rerun, project-run reset, routing, phys_opt or bitstream writing.
if {$argc != 3} {
    error "usage: place_completed_40mhz.tcl <project.xpr> <synthesis-dcp-sha256> <new-output-directory>"
}
set project [file normalize [lindex $argv 0]]
set expected_sha [lindex $argv 1]
set output [file normalize [lindex $argv 2]]
if {![regexp {^[0-9a-f]{64}$} $expected_sha]} { error "invalid checkpoint hash" }
if {[version -short] ne "2025.2"} { error "requires Vivado 2025.2" }
if {![file isfile $project] || [file type $project] ne "file"} { error "not a regular project" }
if {![catch {file lstat $output info}]} { error "output already exists" }
set scratch [file normalize /home/yukidama/external/tmp]
if {[string first "${scratch}/" $output] != 0 || ![file isdirectory [file dirname $output]]} {
    error "output must be a new directory under external/tmp"
}
proc inspect_clock {name period} {
    set clocks [get_clocks -quiet $name]
    if {[llength $clocks] != 1} { error "missing/ambiguous clock $name" }
    set actual [get_property PERIOD $clocks]
    if {![string is double -strict $actual] || !($actual > 0 && $actual < Inf) ||
        abs($actual-$period) > 0.001 + 1.0e-12} { error "wrong/invalid clock $name period=$actual" }
    puts "PLACEMENT_CONSTRAINT $name frequency_MHz=[expr {1000.0/$actual}] period_ns=$actual"
}
proc regular_nonempty {path} {
    if {![file isfile $path] || [file type $path] ne "file" || [file size $path] <= 0} {
        error "missing/invalid native artifact $path"
    }
}
set_param general.maxThreads 1
open_project $project
if {[get_property PART [current_project]] ne "xczu15eg-ffvb1156-2-i" ||
    [get_property TOP [get_filesets sources_1]] ne "rk_ao486_bd_wrapper"} { error "wrong part/top" }
set synth [get_runs synth_1]
if {[get_property STATUS $synth] ne "synth_design Complete!" ||
    [get_property PROGRESS $synth] ne "100%" ||
    [string tolower [get_property NEEDS_REFRESH $synth]] ni {0 false}} { error "incomplete/stale synthesis" }
if {[get_property STATUS [get_runs impl_1]] ne "Not started" ||
    [get_property PROGRESS [get_runs impl_1]] ne "0%"} { error "implementation history is not fresh" }
set checkpoint [file join [get_property DIRECTORY $synth] rk_ao486_bd_wrapper.dcp]
regular_nonempty $checkpoint
if {[lindex [exec sha256sum -- $checkpoint] 0] ne $expected_sha} { error "wrong synthesis checkpoint" }
if {[string first "RuntimeOptimized - Runs Default without bram_power_opt" [help opt_design]] < 0} {
    error "installed help does not confirm crash-avoidance directive"
}
# Use exactly the frozen project's placement policy, not a directive sweep.
set place_directive [get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]]
if {$place_directive ne "AltSpreadLogic_high"} { error "unreviewed placement directive $place_directive" }
open_run synth_1
inspect_clock clk_pl_0 10.0
inspect_clock mmcm_clk 25.0
if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]} { error "unresolved black boxes" }
file mkdir $output
opt_design -directive RuntimeOptimized
write_checkpoint [file join $output optimized.dcp]
place_design -directive $place_directive
if {[report_route_status -boolean_check PLACED_FULLY] ni {1 true}} { error "not fully placed" }
write_checkpoint [file join $output placed.dcp]
inspect_clock clk_pl_0 10.0
inspect_clock mmcm_clk 25.0
report_clocks -file [file join $output clocks.rpt]
report_utilization -file [file join $output utilization.rpt]
report_design_analysis -congestion -file [file join $output congestion.rpt]
report_high_fanout_nets -max_nets 100 -file [file join $output fanout.rpt]
report_timing_summary -file [file join $output timing_summary.rpt]
report_timing -delay_type max -max_paths 30 -nworst 1 -path_type full_clock_expanded \
    -from [get_clocks mmcm_clk] -to [get_clocks mmcm_clk] -file [file join $output core_setup.rpt]
report_timing -delay_type min -max_paths 10 -nworst 1 -path_type full_clock_expanded \
    -from [get_clocks mmcm_clk] -to [get_clocks mmcm_clk] -file [file join $output core_hold.rpt]
report_drc -checks [get_drc_checks {MDRV-1 LUTLP-1}] -file [file join $output structural_drc.rpt]
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]} { error "structural errors" }
foreach artifact {optimized.dcp placed.dcp clocks.rpt utilization.rpt congestion.rpt fanout.rpt
                  timing_summary.rpt core_setup.rpt core_hold.rpt structural_drc.rpt} {
    regular_nonempty [file join $output $artifact]
}
if {[lindex [exec sha256sum -- $checkpoint] 0] ne $expected_sha} { error "input checkpoint changed" }
close_project
puts "NATIVE_PLACEMENT_DIAGNOSTIC_OK routing_started=false timing_signoff=false hardware_accepted=false"
