# Experimental core-clock-only bitgen from a completed, unchanged 40 MHz DCP.
# Invoke only through run_vivado_exclusive.sh, AFTER its prior family closes.
# This never runs synthesis/place/route/physopt or changes timing exceptions.
# Native success does not establish empirical stability or timing sign-off.
if {$argc != 3} {error "usage: core_clock_variant.tcl routed.dcp fresh-output-dir output-divider"}
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set divider [lindex $argv 2]
if {![string is double -strict $divider] ||
    !($divider >= 10.0 && $divider <= 25.0) ||
    abs($divider*8-round($divider*8)) > 1.0e-9} {
    error "divider must be 10..25 in exact 0.125 increments (40..100 MHz)"
}
if {![file isfile $checkpoint] || [file type $checkpoint] ne "file" || [file exists $out]} {
    error "require a regular checkpoint and fresh output directory"
}

proc clock_period {name expected} {
    set c [get_clocks -quiet $name]
    if {[llength $c] != 1} {error "missing or ambiguous clock $name"}
    set period [get_property PERIOD $c]
    if {![string is double -strict $period] || !($period > 0 && $period < Inf) ||
        abs($period-$expected) > 0.001000001} {error "unexpected $name period $period, expected $expected"}
}
proc routed {} {
    foreach {kind accepted} {PLACED_FULLY {1 true} ROUTED_FULLY {1 true} PARTIALLY_ROUTED {0 false} ERRORS_IN_ROUTES {0 false}} {
        if {[report_route_status -boolean_check $kind] ni $accepted} {error "route legality failed: $kind"}
    }
}
proc physical_state {path} {
    set cells [lsort [get_cells -hierarchical -filter {IS_PRIMITIVE}]]
    set nets [lsort [get_nets -hierarchical]]
    if {[llength $cells] < 1000 || [llength $nets] < 1000} {error "unexpectedly small design"}
    # Vivado's whole-design ROUTE property expansion consumed >11 GiB before
    # the first edit. Bound each native query; retain EVERY value on disk and
    # compare exact bytes, not lossy hashes or a sample of nets.
    set stream [open $path {WRONLY CREAT EXCL}]
    try {
        foreach {kind objects properties} [list cells $cells {REF_NAME LOC BEL} nets $nets {ROUTE ROUTE_STATUS}] {
            puts $stream [list $kind [llength $objects]]
            for {set i 0} {$i < [llength $objects]} {incr i 128} {
                set batch [lrange $objects $i [expr {$i+127}]]
                puts $stream [list names $batch]
                foreach property $properties {
                    puts $stream [list $property [get_property $property $batch]]
                }
            }
        }
    } finally {close $stream}
    puts "PHYSICAL_STATE_SAVED $path"
}

set_param general.maxThreads 1
open_checkpoint $checkpoint
if {[get_property PART [current_project]] ne "xczu15eg-ffvb1156-2-i" ||
    [get_property TOP [current_design]] ne "rk_ao486_bd_wrapper"} {error "wrong native part/top"}
routed
clock_period clk_pl_0 10.0
clock_period mmcm_clk 25.0
set mmcm [get_cells -hierarchical -filter {REF_NAME == MMCME4_ADV}]
if {[llength $mmcm] != 1} {error "expected exactly one MMCM"}
foreach {property expected} {CLKFBOUT_MULT_F 10 DIVCLK_DIVIDE 1 CLKIN1_PERIOD 10 CLKOUT0_DIVIDE_F 25} {
    if {abs([get_property $property $mmcm]-$expected) > 0.000001} {error "wrong original MMCM $property"}
}
file mkdir $out
set before [file join $out physical_before.txt]
physical_state $before
report_property $mmcm -file [file join $out mmcm_before.rpt]

# The sole functional configuration edit. VCO and PS/AXI clock stay unchanged.
set_property CLKOUT0_DIVIDE_F $divider $mmcm
if {abs([get_property CLKOUT0_DIVIDE_F $mmcm]-$divider) > 0.000001} {error "divider did not retain requested value"}
foreach {property expected} {CLKFBOUT_MULT_F 10 DIVCLK_DIVIDE 1 CLKIN1_PERIOD 10} {
    if {abs([get_property $property $mmcm]-$expected) > 0.000001} {error "input/VCO setting changed"}
}
# Require native generated clocks to follow the actual primitive; never fix a
# mismatch by overriding only the timing constraint.
report_clocks -file [file join $out clocks.rpt]
clock_period clk_pl_0 10.0
clock_period mmcm_clk $divider
routed
set after [file join $out physical_after_edit.txt]
physical_state $after
if {[catch {exec cmp -- $before $after}]} {error "placement/routing changed during clock edit"}
report_property $mmcm -file [file join $out mmcm_after.rpt]
report_route_status -file [file join $out route_status.rpt]
report_timing_summary -file [file join $out timing_summary.rpt]
report_drc -file [file join $out drc.rpt]
write_checkpoint [file join $out core_clock_variant.dcp]
# No DRC severity overrides or force flag. Timing failures remain in reports.
write_bitstream -bin_file [file join $out core_clock_variant.bit]
routed
clock_period clk_pl_0 10.0
clock_period mmcm_clk $divider
set final [file join $out physical_after_bitgen.txt]
physical_state $final
if {[catch {exec cmp -- $before $final}]} {error "placement/routing changed during bitgen"}
foreach suffix {dcp bit bin} {
    set artifact [file join $out core_clock_variant.$suffix]
    if {![file isfile $artifact] || [file size $artifact] <= 0} {error "missing native $suffix output"}
}
set receipt [open [file join $out clock_variant.txt] {WRONLY CREAT EXCL}]
puts $receipt [list input_checkpoint $checkpoint]
puts $receipt [list mmcm $mmcm divider $divider intended_core_mhz [expr {1000.0/$divider}]]
puts $receipt {axi_mhz 100 vco_mhz 1000 complete_placement_and_route_equal true}
puts $receipt {rtl_changed false synthesis_repeated false route_repeated false}
puts $receipt {timing_signoff false physical_clock_measured false hardware_pass false}
close $receipt
close_design
puts "CORE_CLOCK_VARIANT_CREATED intended_mhz=[expr {1000.0/$divider}] hardware_pass=false"
