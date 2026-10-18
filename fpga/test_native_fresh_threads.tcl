proc fresh_threads_check_status {run step status directory} {
    # A deliberately partial implementation reports the NEXT unstarted stage.
    # That label alone is not completion evidence: require this fresh run's
    # native end markers, no error marker, and successful command log as well.
    if {[list $run $step] ni {{synth_1 synth_design} {impl_1 opt_design}}} {error "unknown native probe stage"}
    set expected [expr {$run eq "synth_1" ? "synth_design Complete!" : "Not started place_design"}]
    if {$status ne $expected} {error "native probe $run status=<$status> expected=<$expected>"}
    set end_markers {.vivado.end.rst}
    # Native synthesis has only the run marker; implementation also writes
    # per-step markers. Both require their exact command-completion log below.
    if {$run eq "impl_1"} {lappend end_markers .${step}.end.rst}
    foreach name $end_markers {
        if {![file isfile [file join $directory $name]]} {error "missing native completion: $name"}
    }
    foreach name [list .${step}.error.rst .vivado.error.rst] {
        if {[file exists [file join $directory $name]]} {error "native failure marker: $name"}
    }
    set f [open [file join $directory runme.log] r]
    set log [read $f]
    close $f
    if {![regexp -line "^$step completed successfully$" $log] || [regexp -line {^ERROR:} $log]} {
        error "native $step completion log missing or contains an error"
    }
}

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
    # Vivado 2025.2's setter requires numeric 0 for this boolean property;
    # the string "false" raises a native lexical-cast error.
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs $run]
    set_property INCREMENTAL_CHECKPOINT {} [get_runs $run]
    if {[get_property AUTO_INCREMENTAL_CHECKPOINT [get_runs $run]] ni {0 false} ||
        [get_property INCREMENTAL_CHECKPOINT [get_runs $run]] ne ""} {
        error "incremental checkpoint policy drift"
    }
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
    set probe_status [get_property STATUS [get_runs $run]]
    set probe_directory [get_property DIRECTORY [get_runs $run]]
    puts "FRESH-THREADS-NATIVE-STATUS run=$run actual=<$probe_status>"
    fresh_threads_check_status $run $step $probe_status $probe_directory
    set script [file join $probe_directory thread_probe.tcl]
    set f [open $script r]
    set native [read $f]
    close $f
    set settings [regexp -all -inline -line {^[ \t]*set_param[ \t]+general\.maxThreads[ \t]+[^\r\n]+} $native]
    if {[llength $settings] != 1 || [string trim [lindex $settings 0]] ne "set_param general.maxThreads $threads"} {
        error "native $run did not serialize the requested thread cap: $settings"
    }
    puts "FRESH-THREADS-NATIVE-WORKER-OK run=$run threads=$threads jobs=1"
}
puts "FRESH-THREADS-NATIVE-OK threads=$threads jobs=1 source-only (tooling test only)"
close_project
