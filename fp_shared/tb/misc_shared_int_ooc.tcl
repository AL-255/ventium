# Matched area diagnostic, not implementation, whole-core Fmax or acceptance.
# The caller must pin these inputs, require both native miter passes first, use
# run_vivado_exclusive.sh and impose an external wall/resource bound.
if {$argc != 2} { error "usage: <prepared leaf directory> <fresh output directory>" }
set leaf [file normalize [lindex $argv 0]]
set output [file normalize [lindex $argv 1]]
if {[version -short] ne "2025.2"} { error "requires Vivado 2025.2" }
if {[file exists $output]} { error "refuse existing output" }
foreach name {original.sv candidate.sv fpu_x87_pkg.sv ventium_decode_pkg.sv clock.xdc} {
    if {![file isfile "$leaf/$name"] || [file size "$leaf/$name"] <= 0} {
        error "missing prepared input $name"
    }
}
file mkdir $output
set_param general.maxThreads 1
foreach {variant source} {original original.sv shared candidate.sv} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i
    # Project-mode read_verilog does not accept -define unless compile-unit
    # mode is enabled. Use the fileset define, identical for both variants.
    set_property verilog_define {VEN_FP_MISC_EARLY_DONE} [current_fileset]
    read_verilog -sv [list \
        "$leaf/fpu_x87_pkg.sv" "$leaf/ventium_decode_pkg.sv" "$leaf/$source"]
    read_xdc "$leaf/clock.xdc"
    synth_design -mode out_of_context -top ven_fp_misc \
        -part xczu15eg-ffvb1156-2-i -flatten_hierarchy rebuilt -directive Default
    report_utilization -file "$output/$variant-utilization.rpt"
    report_timing_summary -delay_type min_max -report_unconstrained \
        -file "$output/$variant-timing.rpt"
    report_timing -from [all_registers] -to [all_registers] -max_paths 10 \
        -file "$output/$variant-reg-timing.rpt"
    write_checkpoint "$output/$variant.dcp"
    puts "MISC-SHARED-INT-OOC-[string toupper $variant]-OK"
    close_project
}
puts "MISC-SHARED-INT-OOC-PAIR-OK"
