# Read-only: inspect/export the clock leaf of the physical parent and candidate.
if {$argc != 3} {error "usage: parent.dcp candidate.dcp output-dir"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set_param general.maxThreads 1
set out [file normalize [lindex $argv 2]]
if {![file isdirectory $out]} {error "output directory missing"}
foreach label {parent candidate} dcp [lrange $argv 0 1] {
    open_checkpoint $dcp
    if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i"} {error "wrong part"}
    set mmcm [get_cells -hier -filter {REF_NAME =~ MMCME*}]
    if {[llength $mmcm] != 1} {error "expected one MMCM"}
    set leaf [get_cells [file dirname $mmcm]]
    report_property $mmcm -file [file join $out ${label}-mmcm.rpt]
    report_property $leaf -file [file join $out ${label}-leaf.rpt]
    set f [open [file join $out ${label}-clock-connections.tsv] {WRONLY CREAT EXCL}]
    puts $f "pin\tdirection\tnet\troute_status\tleaf_pin\tleaf_ref"
    # Only immediate clock/control connections. Expanding constant-net segments
    # across a complete CPU needlessly visits hundreds of thousands of pins.
    foreach name {CLKFBOUT CLKFBIN CLKIN1 CLKINSEL PWRDWN RST DCLK DEN DWE LOCKED CLKOUT0} {
        set pin [get_pins $mmcm/$name]
        set nets [get_nets -quiet -of_objects $pin]
        foreach net $nets {
            foreach peer [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}] {
                puts $f "$pin\t[get_property DIRECTION $pin]\t$net\t[get_property ROUTE_STATUS $net]\t$peer\t[get_property REF_NAME [get_cells -of_objects $peer]]"
            }
        }
    }
    close $f
    set buffers [get_cells -hier -filter {REF_NAME =~ BUFG*}]
    set index 0
    foreach buffer $buffers {
        report_property $buffer -file [file join $out ${label}-buffer-[incr index].rpt]
    }
    write_verilog -cell $leaf -mode funcsim -write_all_overrides -rename_top clock_leaf \
        [file join $out ${label}-clock-leaf.v]
    puts "CLOCK-LEAF-EXPORTED $label $leaf"
    close_design
}
puts "PROGRAMMABLE-CLOCK-NETLIST-AUDIT-COMPLETE"
