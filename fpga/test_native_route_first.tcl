proc route_first_check_status {run status directory} {
    if {$run ni {synth_1 impl_1}} {error "unexpected probe run"}
    set step [expr {$run eq "synth_1" ? "synth_design" : "route_design"}]
    # Vivado may label a partial implementation by its next unstarted step.
    # Neither label suffices alone: require the native markers and log below.
    set allowed [expr {$run eq "synth_1" ? [list "synth_design Complete!"] :
        [list "route_design Complete!" "Not started write_bitstream"]}]
    if {$status ni $allowed} {error "unexpected $run status <$status>"}
    set markers {.vivado.end.rst}
    if {$run eq "impl_1"} {lappend markers .route_design.end.rst}
    foreach marker $markers {
        if {![file isfile [file join $directory $marker]]} {error "missing $marker"}
    }
    if {[llength [glob -nocomplain -directory $directory .*.error.rst]]} {error "native failure marker"}
    set f [open [file join $directory runme.log] r]; set log [read $f]; close $f
    if {![regexp -line "^$step completed successfully$" $log] || [regexp -line {^ERROR:} $log]} {
        error "native completion log missing or erroneous"
    }
}

# Source-only tooling probe, NOT full-core timing or hardware acceptance.
if {$argc ni {1 2 3}} {error "usage: new-output-directory ?performance-route-first|routability-route-first|routability-retime-route-first|performance-retime-routability-route-first|routability-retime-remap-route-first? ?serial_apr4|parallel8?"}
set strategy performance-route-first
if {$argc >= 2} {set strategy [lindex $argv 1]}
if {$strategy ni {performance-route-first routability-route-first routability-retime-route-first performance-retime-routability-route-first routability-retime-remap-route-first}} {error "unknown probe strategy"}
set thread_profile serial_apr4
if {$argc == 3} {set thread_profile [lindex $argv 2]}
if {$thread_profile ni {serial_apr4 parallel8}} {error "unknown probe thread profile"}
set synth_threads [expr {$thread_profile eq "parallel8" ? 8 : 1}]
set apr_threads [expr {$thread_profile eq "parallel8" ? 8 : 4}]
set synth_retiming [expr {$strategy in {routability-retime-route-first performance-retime-routability-route-first routability-retime-remap-route-first} ? "on" : "off"}]
set synth_directive [expr {$strategy in {routability-route-first routability-retime-route-first routability-retime-remap-route-first} ? "AlternateRoutability" : "PerformanceOptimized"}]
set place_directive [expr {$strategy in {routability-route-first routability-retime-route-first performance-retime-routability-route-first routability-retime-remap-route-first} ? "AltSpreadLogic_high" : "AltSpreadLogic_medium"}]
set route_directive [expr {$strategy in {routability-route-first routability-retime-route-first performance-retime-routability-route-first routability-retime-remap-route-first} ? "AlternateCLBRouting" : "NoTimingRelaxation"}]
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "probe output must not exist"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
source [file join [file dirname [info script]] fresh_route_first.tcl]
file mkdir $out
set src [file join $out route_first_probe.v]
set f [open $src {WRONLY CREAT EXCL}]
puts $f {module route_first_probe(input clk, input [15:0] d, output reg [15:0] q);
reg [15:0] a, b;
always @(posedge clk) begin
 a <= d;
 b <= a;
 q <= ((b + 16'd131) ^ (b >> 3)) + (b << 2);
end
endmodule}
close $f
set xdc [file join $out clocks.xdc]
set f [open $xdc {WRONLY CREAT EXCL}]
puts $f {create_clock -period 25.000 [get_ports clk]}
close $f
create_project fresh_route_first_probe [file join $out project] -part xczu15eg-ffvb1156-2-i
config_ip_cache -disable_cache
if {[get_property IP_CACHE_PERMISSIONS [current_project]] ni {disable disabled}} {error "IP cache enabled"}
add_files $src
add_files -fileset constrs_1 $xdc
set_property top route_first_probe [current_fileset]
set synth [get_runs synth_1]
set impl [get_runs impl_1]
foreach obj [list $synth $impl] {
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 $obj
    set_property INCREMENTAL_CHECKPOINT {} $obj
    if {[get_property AUTO_INCREMENTAL_CHECKPOINT $obj] ni {0 false} ||
        [get_property INCREMENTAL_CHECKPOINT $obj] ne ""} {error "incremental reuse enabled"}
}
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $synth_directive $synth
set_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING $synth_retiming $synth
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt $synth
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $impl
set_property -name {STEPS.OPT_DESIGN.ARGS.MORE OPTIONS} -value {} -objects $impl
set_property STEPS.OPT_DESIGN.TCL.POST {} $impl
if {$strategy eq "routability-retime-remap-route-first"} {
    set_property STEPS.OPT_DESIGN.TCL.POST [file join [file dirname [file normalize [info script]]] fresh_opt_remap_post.tcl] $impl
}
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $place_directive $impl
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $route_directive $impl
fresh_route_first $impl
if {$thread_profile eq "parallel8"} {
    set hook [file join [file dirname [file normalize [info script]]] fresh_threads8_pre.tcl]
    set_property STEPS.SYNTH_DESIGN.TCL.PRE $hook $synth
    set_property STEPS.OPT_DESIGN.TCL.PRE $hook $impl
}
report_property $synth -file [file join $out synth-properties.rpt]
report_property $impl -file [file join $out impl-properties.rpt]
foreach {run threads} [list synth_1 $synth_threads impl_1 $apr_threads] {
    set_param general.maxThreads $threads
    if {$run eq "synth_1"} {
        launch_runs $run -jobs 1
    } else {
        # Uses only the netlist just synthesized above, never a prior DCP.
        launch_runs $run -to_step route_design -jobs 1
    }
    wait_on_run $run
    set obj [get_runs $run]
    set dir [get_property DIRECTORY $obj]
    puts "ROUTE-FIRST-STATUS run=$run actual=<[get_property STATUS $obj]>"
    route_first_check_status $run [get_property STATUS $obj] $dir
    set f [open [file join $dir route_first_probe.tcl] r]; set native [read $f]; close $f
    set settings [regexp -all -inline -line {^[ \t]*set_param[ \t]+general\.maxThreads[ \t]+[^\r\n]+} $native]
    set f [open [file join $dir runme.log] r]; set native_log [read $f]; close $f
    set observed [regexp -all -inline -line {^FRESH-NATIVE-THREADS-CHECK observed=[^\r\n]*} $native_log]
    if {[llength $observed] && $observed ne [list "FRESH-NATIVE-THREADS-CHECK observed=$threads"]} {
        error "native worker thread readback mismatch: $observed"
    }
    set observed_default [expr {$threads == 8 && ![llength $settings] &&
        $observed eq [list "FRESH-NATIVE-THREADS-CHECK observed=8"]}]
    if {!$observed_default && ([llength $settings] != 1 || [string trim [lindex $settings 0]] ne "set_param general.maxThreads $threads")} {
        error "native stage thread cap mismatch: $settings"
    }
    if {$run eq "synth_1"} {
        if {![regexp -line [format {^synth_design .* -global_retiming %s(?: |$)} $synth_retiming] $native] ||
            ![regexp -line [format {^synth_design .* -directive %s(?: |$)} $synth_directive] $native] ||
            [regexp -line {^\s*(read_checkpoint|open_checkpoint)\s} $native]} {
            error "native synthesis policy drift"
        }
    } else {
        if {[regexp -line {^[ \t]*phys_opt_design(?:[ \t]|$)} $native]} {error "optional phys_opt still present"}
        foreach {command directive} [list opt_design RuntimeOptimized place_design $place_directive route_design $route_directive] {
            set commands [regexp -all -inline -line [format {^[ \t]*%s[^\r\n]*} $command] $native]
            if {[llength $commands] != 1 || [string trim [lindex $commands 0]] ne "$command -directive $directive"} {
                error "native command mismatch: $commands"
            }
        }
        # Native script contains only a source command for a post-hook. The
        # independent Python auditor also requires both actual opt_design
        # commands/completions and remap markers in order in runme.log.
        if {$strategy eq "routability-retime-remap-route-first"} {
            set audit_python {
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from audit_fresh_strategy import audit_impl, native_worker_log
script = Path(sys.argv[2])
result = audit_impl(script.read_text(), Path(sys.argv[3]).read_text(),
                    sys.argv[4], int(sys.argv[5]), native_worker_log(script))
print(json.dumps(result, sort_keys=True))
}
            # Vivado exports its own PYTHONHOME/PYTHONPATH. Isolate the system
            # interpreter, then add only our explicit audited module directory.
            puts [exec /usr/bin/python3 -I -B -c $audit_python \
                [file dirname [file normalize [info script]]] \
                [file join $dir route_first_probe.tcl] [file join $out impl-properties.rpt] \
                $strategy $apr_threads]
        }
        set dcp [file join $dir route_first_probe_routed.dcp]
        if {![file isfile $dcp] || [file size $dcp] == 0} {error "routed checkpoint missing"}
    }
    puts "ROUTE-FIRST-NATIVE-WORKER-OK run=$run threads=$threads jobs=1"
}
# No bitstream for this unpinned-I/O fixture. Its routed checkpoint above must
# serialize successfully; the real full build still writes its bitstream.
puts "FRESH-ROUTE-FIRST-NATIVE-OK synth=$synth_threads apr=$apr_threads optional-phys=off fresh-source (tooling test only)"
puts "FRESH-ROUTE-FIRST-STRATEGY-OK $strategy retiming=$synth_retiming"
close_project
