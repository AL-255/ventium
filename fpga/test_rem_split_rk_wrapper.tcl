# Extend the parent source-contract test by exactly one SRT operand-port flag.
# No Vivado is invoked; actual native elaboration/lint is a separate gate.
set handle [open [file join [file dirname [info script]] test_code_payload_rk_wrapper.tcl] r]
set checker [read $handle]
close $handle
set anchor {set actual_define_count $define_count}
set first [string first $anchor $checker]
if {$first < 0 || [string first $anchor $checker [expr {$first + [string length $anchor]}]] >= 0} {
    error "parent checker anchor drift"
}
set extension {
if {$define_count != 158 || [lindex $defs 154] ne "VEN_SRT_REM_OPERAND_SPLIT"} {
    error "wrong remainder operand extension/order"
}
set defs [lreplace $defs 154 154]
set define_count [llength $defs]
if {[lindex $defs 153] ne "VEN_L1D_PAYLOAD_CODE_HINT"} {
    error "missing parent payload-kind extension/order"
}
set defs [lreplace $defs 153 153]
set define_count [llength $defs]
}
eval [string replace $checker $first [expr {$first + [string length $anchor] - 1}] "$anchor\n$extension"]
