# Verify the actual expanded project names both mouse sources. No Vivado run.
source [file join [file dirname [info script]] test_rem_split_rk_wrapper.tcl]
foreach name {ven_ps2_device.sv ven_ps2_mailbox.sv} {
    set expected "src/$name"
    set first [string first $expected $::expanded]
    if {$first < 0 || [string first $expected $::expanded [expr {$first + [string length $expected]}]] >= 0} {
        error "missing or duplicate mouse source in expanded project: $expected"
    }
    if {![file isfile [file join $flow src $name]]} {
        error "missing mouse RTL file: $name"
    }
}
puts "MOUSE-PROJECT-SOURCE-CONTRACT-OK: exact158defs, same clocks/profile, two additional peripheral sources"
