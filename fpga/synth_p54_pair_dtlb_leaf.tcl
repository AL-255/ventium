# Bounded FPGA area probe for the third, independent V D-TLB query.
# Run only through run_vivado_exclusive.sh with an outer timeout. Lookup
# outputs are unconstrained top-level combinational paths, so no Fmax claim.
if {[llength $argv] != 2} {
    error "usage: -tclargs direct_base|direct_pair|assoc_base|assoc_pair OUTPUT_DIRECTORY"
}
set variant [lindex $argv 0]
set output_dir [file normalize [lindex $argv 1]]
set repo [file normalize [file join [file dirname [info script]] ..]]
set_param general.maxThreads 1
set defines {VEN_PIPE_MEM_CHAIN}
switch -- $variant {
    direct_base {set top tlb; set generics {IS_D=1}}
    direct_pair {set top tlb; set generics {IS_D=1}; lappend defines VEN_P54_DUAL_HIT}
    assoc_base {set top tlb_assoc; set generics {IS_D=1 TLB_WAYS=4}}
    assoc_pair {set top tlb_assoc; set generics {IS_D=1 TLB_WAYS=4}; lappend defines VEN_P54_DUAL_HIT}
    default {error "unknown variant $variant"}
}
file mkdir $output_dir
read_verilog -sv [list \
    [file join $repo rtl/mem/tlb.sv] \
    [file join $repo rtl/mem/tlb_assoc.sv]]
set synth_args [list -top $top -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy none -generic $generics]
foreach define $defines {lappend synth_args -verilog_define $define}
synth_design {*}$synth_args
create_clock -name core_clk -period 22.222 [get_ports clk]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
puts "P54-PAIR-DTLB-LEAF-SYNTH-OK variant=$variant output=$output_dir"
