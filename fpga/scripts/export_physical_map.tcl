# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Read-only export. Never run synthesis/place/route or write a checkpoint here.
# Launch only through fpga/run_vivado_exclusive.sh.
if {$argc != 2} {error "usage: export_physical_map.tcl routed.dcp empty-output-dir"}
set_param general.maxThreads 1
set dcp [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {![file isfile $dcp] || ![file isdirectory $out]} {error "missing input/output"}
foreach name {device.tsv tiles.tsv sites.tsv cells.tsv complete.txt} {
    if {[file exists [file join $out $name]]} {error "refusing to overwrite $name"}
}
proc table {path header} {
    set f [open $path {WRONLY CREAT EXCL}]
    puts $f [join $header \t]
    return $f
}
proc row {f values} {
    foreach v $values {
        if {[regexp {[\t\r\n]} $v]} {error "TSV control character in property"}
    }
    puts $f [join $values \t]
}
open_checkpoint $dcp
set f [table [file join $out device.tsv] {key value}]
foreach {k v} [list schema ventium-physical-v1 part [get_property PART [current_design]] \
        design [current_design] vivado [version -short] checkpoint $dcp] {row $f [list $k $v]}
close $f

# GRID_POINT_X/Y are one common physical coordinate system across resource
# types. Never merge SLICE_XnYm, DSP48E2_XnYm and RAMB36_XnYm suffixes.
set tiles [get_tiles -quiet]
set names [get_property NAME $tiles]
set xs [get_property GRID_POINT_X $tiles]
set ys [get_property GRID_POINT_Y $tiles]
set types [get_property TYPE $tiles]
set f [table [file join $out tiles.tsv] {tile grid_x grid_y tile_type}]
foreach n $names x $xs y $ys t $types {row $f [list $n $x $y $t]}
close $f
puts "PHYSICAL-MAP tiles=[llength $tiles]"

# Inventory the entire device, including unoccupied SLICE sites and all other
# site types. Non-CLB resources remain a separate context layer in the renderer.
set sites [get_sites -quiet]
set f [table [file join $out sites.tsv] {site site_type tile clock_region}]
foreach site $sites {
    set parent [get_tiles -quiet -of_objects $site]
    if {[llength $parent] != 1} {error "site has ambiguous physical tile: $site"}
    row $f [list $site [get_property SITE_TYPE $site] $parent [get_clock_regions -quiet -of_objects $site]]
}
close $f
puts "PHYSICAL-MAP sites=[llength $sites]"

set cells [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE == 1}]
set names [get_property NAME $cells]
set refs [get_property REF_NAME $cells]
set locs [get_property LOC $cells]
set bels [get_property BEL $cells]
set f [table [file join $out cells.tsv] {cell ref_name site bel}]
foreach n $names r $refs l $locs b $bels {row $f [list $n $r $l $b]}
close $f
puts "PHYSICAL-MAP primitives=[llength $cells]"
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 12 -file [file join $out hierarchy.rpt]
report_route_status -file [file join $out route-status.rpt]
report_timing -max_paths 20 -nworst 1 -input_pins -nets -file [file join $out timing.rpt]
# Congestion history is not always serialized in a DCP. Retain the result or
# explicit refusal; the renderer may instead use the *matching* native run log.
set f [open [file join $out congestion-status.txt] {WRONLY CREAT EXCL}]
if {[catch {report_design_analysis -congestion -min_congestion_level 3 -file [file join $out congestion.rpt]} msg]} {
    puts $f "unavailable: $msg"
} else {puts $f "command-completed; inspect report for retained history"}
close $f
close_design
set f [open [file join $out complete.txt] {WRONLY CREAT EXCL}]
puts $f "PHYSICAL-MAP-EXPORT-COMPLETE"
close $f
puts "PHYSICAL-MAP-EXPORT-COMPLETE"
