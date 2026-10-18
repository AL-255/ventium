# Fresh tiny-project capability probe, not processor/hardware acceptance.
if {$argc != 1} {error "usage: new-output-directory"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "probe output must not exist"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
source [file join [file dirname [info script]] fresh_bounded_phys.tcl]
file mkdir $out
set src [file join $out bounded_probe.v]
set f [open $src {WRONLY CREAT EXCL}]
puts $f {module bounded_probe(input clk, input [15:0] d, output reg [15:0] q);
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
create_project fresh_bounded_probe [file join $out project] -part xczu15eg-ffvb1156-2-i
config_ip_cache -disable_cache
add_files $src
add_files -fileset constrs_1 $xdc
set_property top bounded_probe [current_fileset]
set_param general.maxThreads 1
set synth [get_runs synth_1]
set impl [get_runs impl_1]
foreach obj [list $synth $impl] {
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 $obj
    set_property INCREMENTAL_CHECKPOINT {} $obj
}
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized $synth
set_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING on $synth
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $impl
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_medium $impl
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE NoTimingRelaxation $impl
fresh_bounded_phys $impl
report_property $synth -file [file join $out synth-properties.rpt]
report_property $impl -file [file join $out impl-properties.rpt]
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property STATUS $synth] ne "synth_design Complete!"} {error "probe synthesis incomplete"}
# Only this probe's own newly synthesized netlist feeds implementation.
launch_runs impl_1 -to_step {phys_opt_design (Post-Route)} -jobs 1
wait_on_run impl_1
puts "BOUNDED-PROBE-IMPL-STATUS <[get_property STATUS $impl]>"
foreach {obj step} [list $synth synth_design $impl post_route_phys_opt_design] {
    set dir [get_property DIRECTORY $obj]
    foreach marker [list .vivado.end.rst] {
        if {![file isfile [file join $dir $marker]]} {error "missing $marker"}
    }
    foreach marker [list .vivado.error.rst .${step}.error.rst] {
        if {[file exists [file join $dir $marker]]} {error "native failure: $marker"}
    }
    if {$step ne "synth_design" && ![file isfile [file join $dir .${step}.end.rst]]} {
        error "missing native post-route completion"
    }
    set f [open [file join $dir runme.log] r]; set log [read $f]; close $f
    set command [expr {$step eq "synth_design" ? "synth_design" : "phys_opt_design"}]
    if {![regexp -line "^$command completed successfully$" $log] || [regexp -line {^ERROR:} $log]} {
        error "native completion log invalid"
    }
    set f [open [file join $dir bounded_probe.tcl] r]; set native [read $f]; close $f
    if {$step eq "synth_design"} {
        if {![regexp -line {^synth_design .* -global_retiming on(?: |$)} $native]} {
            error "native explicit synthesis retiming missing"
        }
        if {[regexp -line {^\s*(read_checkpoint|open_checkpoint)\s} $native]} {
            error "old checkpoint in synthesis"
        }
    } else {
        set commands [regexp -all -inline -line {^[ \t]*phys_opt_design[^\r\n]*} $native]
        set expected [list \
            {phys_opt_design -fanout_opt -placement_opt -restruct_opt -equ_drivers_opt} \
            {phys_opt_design -placement_opt -routing_opt -restruct_opt -hold_fix}]
        set actual {}; foreach c $commands {lappend actual [string trim $c]}
        if {$actual ne $expected} {error "native physical commands differ: $actual"}
    }
}
puts "FRESH-BOUNDED-NATIVE-OK retiming=on explicit-phys-only threads=1 jobs=1 (tooling test only)"
close_project
