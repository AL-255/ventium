# Source-only tooling probe, not CPU/timing/hardware acceptance.
# Run only AFTER the live build closes, through run_vivado_exclusive.sh.
# No checkpoint, cached IP, or previous project is an input.
if {$argc != 2} {error "usage: internal-threads new-output-directory"}
lassign $argv threads out
if {$threads ni {1 2}} {error "only one or two internal threads supported"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set out [file normalize $out]
if {[file exists $out]} {error "probe output must not exist"}
file mkdir $out
set src [file join $out thread_probe.v]
set f [open $src {WRONLY CREAT EXCL}]
puts $f {module thread_probe(input clk, input [15:0] d, output reg [15:0] q);
always @(posedge clk) q <= d + 16'd1;
endmodule}
close $f
set xdc [file join $out clocks.xdc]
set f [open $xdc {WRONLY CREAT EXCL}]
puts $f {create_clock -period 25.000 [get_ports clk]}
close $f
create_project fresh_thread_probe [file join $out project] -part xczu15eg-ffvb1156-2-i
config_ip_cache -disable_cache
add_files $src
add_files -fileset constrs_1 $xdc
set_property top thread_probe [current_fileset]
foreach {run step} {synth_1 synth_design impl_1 opt_design} {
    set_property AUTO_INCREMENTAL_CHECKPOINT false [get_runs $run]
    set_property INCREMENTAL_CHECKPOINT {} [get_runs $run]
    # Mirror the legacy default followed by the fresh interceptor's override.
    set_param general.maxThreads 1
    set_param general.maxThreads $threads
    if {[get_param general.maxThreads] != $threads} {error "parent thread cap differs"}
    if {$run eq "synth_1"} {
        launch_runs $run -jobs 1
    } else {
        # Only this probe's own fresh synthesis feeds its implementation.
        # Stop at logic optimization: routing/bitstream are not needed to
        # establish the native worker's serialized thread setting.
        launch_runs $run -to_step opt_design -jobs 1
    }
    wait_on_run $run
    if {[get_property STATUS [get_runs $run]] ne "$step Complete!"} {
        error "native probe $run failed"
    }
    set script [file join [get_property DIRECTORY [get_runs $run]] thread_probe.tcl]
    set f [open $script r]
    set native [read $f]
    close $f
    set settings [regexp -all -inline -line {^[ \t]*set_param[ \t]+general\.maxThreads[ \t]+[^\r\n]+} $native]
    if {[llength $settings] != 1 || [lindex $settings 0] ne "set_param general.maxThreads $threads"} {
        error "native $run did not serialize the requested thread cap: $settings"
    }
    puts "FRESH-THREADS-NATIVE-WORKER-OK run=$run threads=$threads jobs=1"
}
puts "FRESH-THREADS-NATIVE-OK threads=$threads jobs=1 source-only (tooling test only)"
close_project
