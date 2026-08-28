set src [file normalize "fpga_verify_20260822/compactness_reports/mul_width_probe.sv"]
set out [file normalize "fpga_verify_20260822/compactness_reports"]

read_verilog -sv $src
synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -part xczu15eg-ffvb1156-2-i -top mul_width_probe_wide
report_utilization -file [file join $out mul_width_wide_util.rpt]
close_design

read_verilog -sv $src
synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -part xczu15eg-ffvb1156-2-i -top mul_width_probe_narrow
report_utilization -file [file join $out mul_width_narrow_util.rpt]
close_design
exit
