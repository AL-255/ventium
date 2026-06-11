# =====================================================================
# Dump the per-placed-cell CSV (module,sub,x,y) from a routed/placed checkpoint,
# for the 2-level colored device view (render_device_view.py). Same attribution
# rule as apr_run.tcl: `module` = the top instance under core (u_*/core_spine),
# `sub` = the signal GROUP inside it (leaf name, bit-indices + synth suffixes
# stripped). x/y = SITE LOC.
#
# Env:  DCP = routed checkpoint to open ; OUT = csv path
# Run:  DCP=fpga/build/strathc/fp2_timingopt/routed.dcp OUT=fpga/build/strathc/fp2_timingopt/cells_loc.csv \
#         vivado -mode batch -source fpga/scripts/dump_cells_loc.tcl -notrace
# =====================================================================
proc env_or {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }
set DCP [env_or DCP ""]
set OUT [env_or OUT ""]
if {$DCP eq "" || $OUT eq ""} { puts "ERROR: set DCP and OUT"; exit 1 }
open_checkpoint $DCP
set fh [open $OUT w]
puts $fh "module,sub,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1 && LOC != ""}] {
    set loc [get_property LOC $c]
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    set nm    [get_property NAME $c]
    set parts [split $nm /]
    set p0    [lindex $parts 0]
    if {[string match u_* $p0]} {
        set mod $p0; set sub [lindex $parts 1]
        if {$sub eq ""} { set sub "(top)" }
    } else { set mod core_spine; set sub "(spine)" }
    regsub -all {\[[^\]]*\]} $sub "" sub
    regsub {_i_[0-9].*$}     $sub "" sub
    regsub {_reg.*$}         $sub "" sub
    regsub {(_[0-9]+)+$}     $sub "" sub
    if {$sub eq ""} { set sub "misc" }
    puts $fh "$mod,$sub,$x,$y"; incr n
}
close $fh
puts "DUMP_CELLS_DONE cells=$n out=$OUT"
