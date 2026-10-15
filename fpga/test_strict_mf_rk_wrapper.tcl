# Require the architectural waiting-x87 policy, then retain every parent check.
# This validates source expansion only; it does not run Vivado.
set handle [open [file join [file dirname [info script]] test_rem_split_rk_wrapper.tcl] r]
set checker [read $handle]
close $handle
set anchor {if {$define_count != 158 || [lindex $defs 154] ne "VEN_SRT_REM_OPERAND_SPLIT"}}
set first [string first $anchor $checker]
if {$first < 0 || [string first $anchor $checker [expr {$first + [string length $anchor]}]] >= 0} {
    error "parent checker anchor drift"
}
set extension {
if {$define_count != 159 || [lindex $defs 155] ne "VEN_X87_MF_STRICT"} {
    error "wrong strict waiting-x87 extension/order"
}
set defs [lreplace $defs 155 155]
set define_count [llength $defs]
}
eval [string replace $checker $first [expr {$first + [string length $anchor] - 1}] "$extension\n$anchor"]
