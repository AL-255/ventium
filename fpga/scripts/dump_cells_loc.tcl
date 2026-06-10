# Re-dump a per-module placed-cell CSV in UNIFORM device coordinates.
#
# The old extraction parsed the SITE name (SLICE_X#Y# / DSP48E2_X#Y# / RAMB36_X#Y#)
# and used those #s directly — but each site TYPE has its OWN independent X/Y grid
# (a SLICE column index is not on the same scale as a DSP column index, and SLICE_Y
# is a fine per-row index while the X is a coarse per-column index). Mixing them, and
# the non-physical X:Y pitch, distorts the plot (egregiously on a large part like the
# ZU15EG). Here we map every cell to the TILE grid (COLUMN, ROW) — one uniform integer
# grid spanning the whole device for ALL site types — so the scatter is a true floorplan.
#
# Run: vivado -mode batch -source fpga/scripts/dump_cells_loc.tcl -tclargs <in.dcp> <out.csv>
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp

# site -> "col row" cache (many cells share one SLICE site; query each tile once).
set cache [dict create]
set fh [open $out w]
puts $fh "module,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1 && LOC != ""}] {
    set site [get_property LOC $c]
    if {$site eq ""} continue
    if {![dict exists $cache $site]} {
        set t [get_tiles -quiet -of_objects [get_sites -quiet $site]]
        if {$t eq ""} { dict set cache $site ""; continue }
        dict set cache $site "[get_property COLUMN $t] [get_property ROW $t]"
    }
    set cr [dict get $cache $site]
    if {$cr eq ""} continue
    lassign $cr col row
    set nm [get_property NAME $c]
    if {[regexp {^(u_[A-Za-z0-9_]+)/} $nm -> inst]} { set mod $inst } else { set mod "core_spine" }
    # x = tile COLUMN, y = tile ROW — one uniform device grid for ALL site types.
    puts $fh "$mod,$col,$row"
    incr n
}
close $fh
puts "DUMP_CELLS_LOC_DONE rows=$n out=$out"
