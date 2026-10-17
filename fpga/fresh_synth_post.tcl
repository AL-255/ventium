# Runs in the native synthesis child, with the actual synthesized design open.
set out $::env(VEN_FRESH_OUT)
set f [open [file join $out synth-clocks.tsv] {WRONLY CREAT EXCL}]
puts $f "clock\tperiod_ns"
set core 0; set axi 0
foreach c [get_clocks] {
    set period [get_property PERIOD $c]
    puts $f "[get_property NAME $c]\t$period"
    if {abs($period-25.0) < 0.001} {incr core}
    # The MMCM feedback clock is also 100 MHz. Only clk_pl_0 is the
    # functional AXI/PS source domain; frequency alone is not its identity.
    if {[get_property NAME $c] eq "clk_pl_0" && abs($period-10.0) < 0.001} {incr axi}
}
close $f
if {$core != 1 || $axi != 1} {error "fresh synthesis lacks unique 40 MHz core / 100 MHz AXI clocks"}
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out synth-timing.rpt]
report_utilization -hierarchical -file [file join $out synth-utilization.rpt]
puts "FRESH-SYNTH-CLOCKS-OK core=40MHz AXI=100MHz"
