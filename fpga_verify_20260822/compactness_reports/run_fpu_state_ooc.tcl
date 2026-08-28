set src [file normalize "rtl/fpu/fpu_top.sv"]
set out [file normalize "fpga_verify_20260822/compactness_reports/fpu_state_ooc_util.rpt"]
read_verilog -sv $src
synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -part xczu15eg-ffvb1156-2-i -top fpu_top
report_utilization -file $out
close_design
exit
