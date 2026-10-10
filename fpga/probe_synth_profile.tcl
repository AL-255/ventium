# Native, tiny-design check of the REAL wrapper's synthesis profile expansion.
# Run only through run_vivado_exclusive.sh with a bounded scope and fresh output.
# Usage: ... -source probe_synth_profile.tcl -tclargs wrapper frozen-export output
# This neither builds the processor nor establishes its timing/area/performance.
if {$argc != 3} { error "expected wrapper frozen-export output" }
lassign $argv wrapper frozen output
foreach name {wrapper frozen output} { set $name [file normalize [set $name]] }
if {[version -short] ne "2025.2"} { error "requires Vivado 2025.2" }
if {[file exists $output]} { error "refusing existing output" }
file mkdir $output
set_param general.maxThreads 1
set fh [open "$output/probe.v" {WRONLY CREAT EXCL}]
puts $fh {module profile_probe(input clk, input [15:0] a, b, output reg [15:0] q);
reg [15:0] ar, br;
always @(posedge clk) begin ar <= a; br <= b; q <= ar + br; end
endmodule}
close $fh
set fh [open "$output/probe.xdc" {WRONLY CREAT EXCL}]
puts $fh {create_clock -name core -period 25.000 [get_ports clk]}
close $fh
foreach profile {balanced logic_only} {
    # Evaluate the wrapper in an isolated Tcl interpreter and intercept ONLY its
    # final expansion. This avoids running the full board flow; do not duplicate
    # the profile's option string in a hand-written native synth command.
    set ip [interp create]
    interp eval $ip [list set ::env(VEN_FPGA_CORE_MHZ) 40]
    interp eval $ip [list set ::env(VEN_FPGA_JOBS) 1]
    interp eval $ip [list set ::env(VEN_FPGA_BUILD_PROFILE) $profile]
    interp eval $ip [list set ::env(VEN_FPGA_FLOW_ROOT) "$frozen/flow"]
    interp eval $ip [list set ::env(VEN_FPGA_SOURCE_ROOT) "$frozen/ventium"]
    interp eval $ip [list set ::env(VEN_FPGA_TEMPLATE_ROOT) "$frozen/template"]
    interp eval $ip [list set ::env(VEN_FPGA_DEFINE_FILE) "$frozen/defines.txt"]
    interp eval $ip {
        proc set_param {name value} {
            if {$name ne "general.maxThreads" || $value != 1} { error "bad thread bound" }
        }
        rename uplevel native_uplevel
        proc uplevel {level body} {
            if {$level ne "#0"} { error "unexpected wrapper evaluation" }
            set ::expanded $body
        }
    }
    interp eval $ip [list source $wrapper]
    set expanded [interp eval $ip {set ::expanded}]
    set launch [interp eval $ip {set ::area_synth}]
    interp delete $ip
    if {[string first $launch $expanded] < 0} { error "profile launch not in expanded flow" }
    set fh [open "$output/$profile-expanded.tcl" {WRONLY CREAT EXCL}]
    puts $fh $expanded
    close $fh
    create_project $profile "$output/$profile" -part xczu15eg-ffvb1156-2-i
    add_files "$output/probe.v"
    add_files -fileset constrs_1 "$output/probe.xdc"
    set_property top profile_probe [current_fileset]
    # This is the wrapper's actual project-run configuration and launch.
    eval $launch
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%" ||
        [get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
        error "$profile synthesis failed"
    }
    set fh [open "$output/$profile/$profile.runs/synth_1/profile_probe.tcl" r]
    set native [read $fh]
    close $fh
    if {![regexp -line {^synth_design [^\n]+} $native actual]} { error "no native synth command" }
    set found [regexp {(^|\s)-no_timing_driven(\s|$)} $actual]
    if {$found != ($profile eq "logic_only")} { error "native optimization option mismatch: $actual" }
    open_run synth_1
    if {[get_property PERIOD [get_clocks core]] != 25.0} { error "40 MHz constraint changed" }
    report_utilization -file "$output/$profile-utilization.rpt"
    report_timing_summary -delay_type min_max -report_unconstrained \
        -file "$output/$profile-timing.rpt"
    puts "SYNTH-PROFILE-NATIVE-OK: $profile; core=40MHz; $actual"
    close_project
}
puts "SYNTH-PROFILE-PROBE-OK: both native option paths, unchanged 40MHz constraint; not processor qualification"
