# Synthesize only the small clock leaf. Preserve the existing processor netlist.
if {$argc != 4 && $argc != 5} {error "usage: routed-parent.dcp frozen-source output-dir repo ?replaced.dcp?"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set_param general.maxThreads 1
lassign $argv reference source out repo
set part xczu15eg-ffvb1156-2-i
set leaf rk_ao486_bd_i/u_clkdiv/inst

proc clocks_ok {} {
    foreach {name period} {clk_pl_0 10.0 mmcm_clk 25.0} {
        set clk [get_clocks -quiet $name]
        if {[llength $clk] != 1 || abs([get_property PERIOD $clk]-$period) > 0.001} {
            error "incorrect constrained clock $name"
        }
    }
    set mmcm [get_cells -hier -filter {REF_NAME == MMCME4_ADV}]
    if {[llength $mmcm] != 1} {error "expected exactly one MMCM"}
    foreach {name expected} {CLKFBOUT_MULT_F 10 CLKOUT0_DIVIDE_F 25 DIVCLK_DIVIDE 1} {
        if {[get_property $name $mmcm] != $expected} {error "MMCM $name changed"}
    }
    puts "CLOCK-REPAIR-CONSTRAINTS core=40MHz reference=100MHz M10/D1/O25"
}
proc reuse_ok {stage} {
    set total [llength [get_cells -hier -filter {IS_PRIMITIVE == 1}]]
    set matched [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && IS_MATCHED == 1}]]
    set reused [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && IS_REUSED == 1}]]
    set match_pct [expr {100.0*$matched/$total}]
    set reuse_pct [expr {100.0*$reused/$total}]
    set f [open [file join $::out ${stage}-reuse.json] {WRONLY CREAT EXCL}]
    puts $f [format {{"stage":"%s","primitive_cells":%d,"matched_pct":%.9f,"reused_pct":%.9f}} \
        $stage $total $match_pct $reuse_pct]
    close $f
    # Raw IS_MATCHED counts include transformed primitive objects differently
    # from report_incremental_reuse. The successful parent has the same gap.
    # Require 99% placement reuse here AND 99.5% native cell/net match/reuse.
    if {$total < 200000 || $match_pct < 95.0 || $reuse_pct < 99.0} {error "clock-only replacement lost physical reuse"}
    puts [exec python3 -B [file join $::repo fpga/audit_clock_reuse.py] \
        [file join $::out ${stage}-reuse.rpt] --out [file join $::out ${stage}-canonical-reuse.json]]
    puts "CLOCK-REPAIR-REUSE $stage matched=$match_pct reused=$reuse_pct"
}

if {$argc == 4} {
create_project -in_memory -part $part
read_verilog -sv [list [file join $source ven_pll_ctrl.sv] [file join $source ven_programmable_clock.v]]
synth_design -top ven_programmable_clock -part $part -mode out_of_context -flatten_hierarchy rebuilt
set primitives [llength [get_cells -hier -filter {IS_PRIMITIVE == 1}]]
if {$primitives < 100 || $primitives > 1000} {error "not a small clock-only synthesis"}
write_edif [file join $out clock-leaf.edf]
write_checkpoint [file join $out clock-leaf.dcp]
close_project

open_checkpoint $reference
if {[get_property PART [current_design]] ne $part} {error "wrong reference part"}
clocks_ok
set soc [get_cells rk_ao486_bd_i/u_soc]
if {[llength $soc] != 1 || [llength [get_cells $leaf]] != 1} {error "unexpected integration hierarchy"}
write_verilog -cell $soc -mode funcsim -write_all_overrides -rename_top preserved_soc [file join $out soc-before.v]
# Strict boundary match: no guessed port dropping or new tie-offs permitted.
update_design -cells [get_cells $leaf] -strict -from_file [file join $out clock-leaf.edf]
} else {
    # Source, original replacement, SoC equality and preplace simulation are
    # hash-verified by the owner. Do not repeat even the small synthesis.
    open_checkpoint [lindex $argv 4]
    if {[get_property PART [current_design]] ne $part} {error "wrong resumed part"}
    set soc [get_cells rk_ao486_bd_i/u_soc]
    if {[llength $soc] != 1 || [llength [get_cells $leaf]] != 1} {error "bad resumed hierarchy"}
}
write_verilog -cell $soc -mode funcsim -write_all_overrides -rename_top preserved_soc [file join $out soc-after.v]
puts [exec python3 -B [file join $repo fpga/audit_clock_eco_netlists.py] \
    [file join $out soc-before.v] [file join $out soc-after.v] --out [file join $out soc-unchanged.json]]
clocks_ok
write_verilog -cell [get_cells $leaf] -mode funcsim -write_all_overrides -rename_top clock_leaf [file join $out repaired-clock-leaf.v]
puts [exec bash [file join $repo fpga/test_programmable_clock_netlist.sh] \
    [file join $out repaired-clock-leaf.v] [file join $out netlist-preplace] 2>@1]
write_checkpoint [file join $out replaced.dcp]
read_checkpoint -incremental -force_incr -directive RuntimeOptimized $reference
clocks_ok
report_incremental_reuse -file [file join $out initial-reuse.rpt]
reuse_ok initial
place_design
clocks_ok
# Preserve completed placement before any report parsing or downstream gate.
write_checkpoint [file join $out placed.dcp]
report_incremental_reuse -file [file join $out placed-reuse.rpt]
reuse_ok placed
set start [clock milliseconds]
route_design
set elapsed [expr {[clock milliseconds]-$start}]
if {$elapsed < 0 || $elapsed >= 14400000} {error "route exceeded four-hour limit"}
set f [open [file join $out route-time.json] {WRONLY CREAT EXCL}]
puts $f [format {{"route_elapsed_ms":%d,"limit_ms":14400000}} $elapsed]
close $f
puts "CLOCK-REPAIR-ROUTE milliseconds=$elapsed"
clocks_ok
write_checkpoint [file join $out routed.dcp]
report_route_status -file [file join $out route-status.rpt]
report_drc -file [file join $out drc.rpt]
report_clocks -file [file join $out clocks.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing-summary.rpt]
report_incremental_reuse -file [file join $out routed-reuse.rpt]
report_utilization -file [file join $out utilization.rpt]
report_property [get_cells -hier -filter {REF_NAME == MMCME4_ADV}] -file [file join $out mmcm.rpt]
set core_slack [get_property SLACK [get_timing_paths -setup -max_paths 1 -from [get_clocks mmcm_clk] -to [get_clocks mmcm_clk]]]
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
if {25.0-$core_slack <= 0} {error "invalid core period budget"}
set estimate [expr {1000.0/(25.0-$core_slack)}]
set f [open [file join $out timing.json] {WRONLY CREAT EXCL}]
puts $f [format {{"core_constraint_mhz":40,"axi_constraint_mhz":100,"core_setup_slack_ns":%.6f,"conditional_core_period_budget_mhz":%.6f,"global_wns_ns":%.6f,"global_whs_ns":%.6f,"timing_signoff":false}} $core_slack $estimate $wns $whs]
close $f
write_verilog -cell [get_cells $leaf] -mode funcsim -write_all_overrides -rename_top clock_leaf [file join $out routed-clock-leaf.v]
puts [exec bash [file join $repo fpga/test_programmable_clock_netlist.sh] \
    [file join $out routed-clock-leaf.v] [file join $out netlist-postroute] 2>@1]
write_bitstream -bin_file [file join $out ventium_programmable_clock_40.bit]
puts "PROGRAMMABLE-CLOCK-REPAIR-COMPLETE (not hardware acceptance)"
