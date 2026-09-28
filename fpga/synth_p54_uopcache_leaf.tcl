# Bounded uop-cache FPGA storage/control probe. Crosspair is core-side and is
# not represented in this leaf; the report is not routed whole-core timing.
if {[llength $argv] != 2} {
    error "usage: -tclargs base|crossline OUTPUT_DIRECTORY"
}
set variant [lindex $argv 0]
set output_dir [file normalize [lindex $argv 1]]
set repo [file normalize [file join [file dirname [info script]] ..]]
# This large leaf otherwise starts several nested synthesis workers inside the
# fixed Vivado cgroup and can hit its process cap before producing a report.
set_param general.maxThreads 1
set defines {VTM_NO_DPI VEN_FAST_MEM_ADD}
set generics {EXEC_REPAIR=0}
switch -- $variant {
    base {}
    crossline {
        lappend defines VEN_UOP_CROSSLINE
        set generics {EXEC_REPAIR=1}
    }
    default {error "unknown variant $variant"}
}
file mkdir $output_dir
read_verilog -sv [list \
    [file join $repo rtl/ventium_pkg.sv] \
    [file join $repo rtl/core/ventium_alu_pkg.sv] \
    [file join $repo rtl/core/ventium_decode_pkg.sv] \
    [file join $repo rtl/core/ventium_sys_pkg.sv] \
    [file join $repo rtl/core/decode.sv] \
    [file join $repo rtl/mem/ven_predecode_len.sv] \
    [file join $repo rtl/mem/uopcache.sv]]
set synth_args [list -top uopcache -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy none -generic $generics]
foreach define $defines {lappend synth_args -verilog_define $define}
synth_design {*}$synth_args
create_clock -name core_clk -period 22.222 [get_ports clk]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir uopcache.dcp]
puts "P54-UOPCACHE-LEAF-SYNTH-OK variant=$variant output=$output_dir"
