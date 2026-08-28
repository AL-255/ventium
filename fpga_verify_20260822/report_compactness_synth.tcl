set dcp [file normalize "fpga_run_20260822_l1bypown/rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.dcp"]
set out [file normalize "fpga_verify_20260822/compactness_reports/utilization_hier_synth.rpt"]
open_checkpoint $dcp
report_utilization -hierarchical -hierarchical_depth 12 -file $out
close_design
exit
