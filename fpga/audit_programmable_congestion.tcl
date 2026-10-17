# Read-only physical comparison. No synthesis, placement, routing or bitstream.
if {$argc != 3} {error "usage: parent-routed.dcp candidate-physopt.dcp output-dir"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set_param general.maxThreads 1
set out [file normalize [lindex $argv 2]]
if {![file isdirectory $out]} {error "output directory must already exist"}

# Tile-coordinate boxes come from r3's native Route 35-449 report, not a
# guessed slice-to-routing-coordinate conversion. Compare the SAME boxes in
# the parent and candidate. Overlapping boxes are intentionally not additive.
set boxes {
    short_core {4 47 272 320}
    long_south {0 63 257 384}
    long_east {16 31 180 243}
    global_east {17 32 201 216}
}
foreach label {parent candidate} dcp [lrange $argv 0 1] {
    open_checkpoint $dcp
    if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i"} {
        error "unexpected device"
    }
    report_clocks -file [file join $out ${label}-clocks.rpt]
    report_utilization -hierarchical -file [file join $out ${label}-utilization.rpt]
    report_control_sets -file [file join $out ${label}-control-sets.rpt]
    set countfile [open [file join $out ${label}-regions.tsv] {WRONLY CREAT EXCL}]
    puts $countfile "region\tparent_hierarchy\tprimitive_count\tlut_count\tregister_count\tcarry_count\tmux_count"
    foreach {region box} $boxes {
        lassign $box x0 x1 y0 y1
        set tiles {}
        foreach tile [get_tiles -quiet] {
            if {[regexp {_X([0-9]+)Y([0-9]+)$} $tile -> x y] &&
                $x >= $x0 && $x <= $x1 && $y >= $y0 && $y <= $y1} {
                lappend tiles $tile
            }
        }
        set sites [get_sites -quiet -of_objects $tiles]
        set cells [get_cells -quiet -of_objects $sites]
        if {![llength $cells]} {error "no placed cells in $label $region"}
        set groups [dict create]
        set cellfile [open [file join $out ${label}-${region}-cells.tsv] {WRONLY CREAT EXCL}]
        puts $cellfile "cell\tref_name\tsite"
        foreach cell $cells {
            set ref [get_property REF_NAME $cell]
            set loc [get_property LOC $cell]
            set parent [file dirname $cell]
            puts $cellfile "$cell\t$ref\t$loc"
            if {![dict exists $groups $parent]} {dict set groups $parent {0 0 0 0 0}}
            lassign [dict get $groups $parent] total lut reg carry mux
            incr total
            if {[string match LUT* $ref]} {incr lut}
            if {[string match FD* $ref]} {incr reg}
            if {[string match CARRY* $ref]} {incr carry}
            if {[string match MUXF* $ref]} {incr mux}
            dict set groups $parent [list $total $lut $reg $carry $mux]
        }
        close $cellfile
        foreach parent [lsort [dict keys $groups]] {
            puts $countfile "$region\t$parent\t[join [dict get $groups $parent] \t]"
        }
        puts "CONGESTION-BOX $label $region tiles=[llength $tiles] sites=[llength $sites] primitives=[llength $cells]"
    }
    close $countfile
    close_design
}
puts "PROGRAMMABLE-CONGESTION-AUDIT-COMPLETE"
