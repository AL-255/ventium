# Extend the exact parent source-contract checker by one payload-only define.
# This expands Tcl only; it does not launch Vivado or claim timing acceptance.
set handle [open [file join [file dirname [info script]] test_code_payload_rk_wrapper.tcl] r]
set checker [read $handle]
close $handle
set anchor {set actual_define_count $define_count}
if {[string first $anchor $checker] < 0} {
    error "parent checker anchor missing"
}
set first [string first $anchor $checker]
if {[string first $anchor $checker [expr {$first + [string length $anchor]}]] >= 0} {
    error "parent checker anchor repeated"
}
set extension {
# Preserve every ordered parent check after removing only this exact extension.
if {$define_count == 157} {
    if {[lindex $defs 153] ne "VEN_L1D_PAYLOAD_CODE_HINT"} {
        error "wrong payload-kind extension/order"
    }
    set defs [lreplace $defs 153 153]
    set define_count [llength $defs]
}
}
eval [string replace $checker $first [expr {$first + [string length $anchor] - 1}] "$anchor\n$extension"]
