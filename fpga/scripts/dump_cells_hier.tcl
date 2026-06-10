# Dump per-cell placement for the 2-level colored device view:
#   module, sub, x, y
# where `module` = the top instance under `core` (u_icache / u_fpu_state / ... or
# core_spine for flat top logic) and `sub` = the next hierarchy level inside it
# (the sub-block whose luminance the renderer varies). Coordinates are the SITE
# X/Y parsed from LOC (the original device-view convention).
#
# Run: vivado -mode batch -source fpga/scripts/dump_cells_hier.tcl -tclargs <in.dcp> <out.csv>
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fh [open $out w]
puts $fh "module,sub,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1 && LOC != ""}] {
    set loc [get_property LOC $c]
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    set nm    [get_property NAME $c]
    set parts [split $nm /]
    set p0    [lindex $parts 0]
    if {[string match u_* $p0]} {
        set mod $p0
        set sub [lindex $parts 1]
        if {$sub eq ""} { set sub "(top)" }
    } else {
        set mod core_spine
        set sub "(spine)"
    }
    # collapse the flattened leaf name to its SIGNAL GROUP (the meaningful 2nd-level
    # sub-block after -flatten_hierarchy rebuilt erased the RTL sub-instances): drop
    # bit indices [..], synth _i_N tails, _reg suffixes, and trailing _N.
    regsub -all {\[[^\]]*\]} $sub "" sub
    regsub {_i_[0-9].*$}     $sub "" sub
    regsub {_reg.*$}         $sub "" sub
    regsub {(_[0-9]+)+$}     $sub "" sub
    if {$sub eq ""} { set sub "misc" }
    puts $fh "$mod,$sub,$x,$y"
    incr n
}
close $fh
puts "DUMP_HIER_DONE rows=$n out=$out"
