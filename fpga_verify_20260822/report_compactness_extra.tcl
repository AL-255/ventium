set run_dir "/home/yukidama/github/ventium/fpga_run_20260822_l1bypown/rk_ao486_system/rk_ao486_system.runs/impl_1"
set out_dir "/home/yukidama/github/ventium/fpga_verify_20260822/compactness_reports"

open_checkpoint [file join $run_dir rk_ao486_bd_wrapper_postroute_physopt.dcp]
report_control_sets -verbose -file [file join $out_dir control_sets_postroute.rpt]
report_utilization -hierarchical -hierarchical_depth 20 -hierarchical_percentages \
    -file [file join $out_dir utilization_hier_pct_postroute.rpt]
report_ram_utilization -file [file join $out_dir ram_utilization_postroute.rpt]
report_design_analysis -logic_level_distribution \
    -file [file join $out_dir logic_levels_postroute.rpt]
close_design
