set run_dir [file normalize "fpga_run_20260822_l1bypown/rk_ao486_system/rk_ao486_system.runs/impl_1"]
set out_dir [file normalize "fpga_verify_20260822/compactness_reports"]
file mkdir $out_dir

open_checkpoint [file join $run_dir rk_ao486_bd_wrapper_postroute_physopt.dcp]

report_utilization -hierarchical -hierarchical_depth 12 \
    -file [file join $out_dir utilization_hier_postroute.rpt]
report_high_fanout_nets -fanout_greater_than 100 -max_nets 300 \
    -file [file join $out_dir high_fanout_postroute.rpt]
report_qor_suggestions \
    -file [file join $out_dir qor_suggestions_postroute.rpt]

if {[catch {
    report_design_analysis -complexity -hierarchical_depth 12 \
        -file [file join $out_dir complexity_postroute.rpt]
} err]} {
    puts "COMPLEXITY_REPORT_SKIPPED: $err"
}

close_design
exit
