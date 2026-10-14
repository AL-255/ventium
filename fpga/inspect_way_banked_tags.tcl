# Actual full-L1 synthesis comparison, not a simplified tag-memory model.
# Synthesis only: zero-I/O local timing must not be reported as CPU Fmax.
if {$argc != 5} {error {usage: parent candidate helpers defines output}}
if {[version -short] ne {2025.2}} {error {unexpected Vivado version}}
lassign $argv parent candidate helpers definitions out
if {[file exists $out]} {error {fresh output required}}
set handle [open $definitions r]
set defs [split [string trim [read $handle]] "\n"]
close $handle
if {[llength $defs] != 158 || [llength [lsort -unique $defs]] != 158} {
    error {expected unchanged full 158-definition hardware profile}
}
foreach flag {VEN_L1D_TAG_LUTRAM VEN_PIPE_MEM_CHAIN VEN_P54_DUAL_HIT VEN_P54_DUAL_STORE_PAIR} {
    if {[lsearch -exact $defs $flag] < 0} {error "missing $flag"}
}
file mkdir $out
set receipt [open [file join $out receipt.tcllist] {WRONLY CREAT EXCL}]
set_param general.maxThreads 1
foreach label {parent candidate} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i way_tag_probe
    set_property verilog_define $defs [current_fileset]
    read_verilog -sv [list [file join $helpers ven_p54_bank_arb.sv] \
        [file join $helpers ven_p54_hit_return.sv] [set $label]]
    synth_design -top ven_l1d -mode out_of_context -flatten_hierarchy rebuilt
    if {[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]} {
        error {unresolved black boxes}
    }
    report_utilization -hierarchical -file [file join $out $label-util.rpt]
    report_ram_utilization -file [file join $out $label-ram.rpt]
    set cells [open [file join $out $label-primitives.tsv] {WRONLY CREAT EXCL}]
    puts $cells "cell\tref_name"
    set refs [dict create]
    foreach cell [lsort [get_cells -hier -filter {IS_PRIMITIVE == 1}]] {
        set ref [get_property REF_NAME $cell]
        puts $cells "$cell\t$ref"
        if {[string match *dc_tag* $cell]} {dict incr refs $ref}
    }
    close $cells
    set flipflops 0
    set ram 0
    dict for {ref count} $refs {
        if {[string match FD* $ref]} {incr flipflops $count}
        if {[string match RAM* $ref]} {incr ram $count}
    }
    puts $receipt [list PROFILE $label TAG_PRIMITIVES $refs TAG_FF $flipflops TAG_RAM $ram]
    flush $receipt
    write_checkpoint [file join $out $label.dcp]
    # This run must reproduce the exact symptom before qualifying its repair.
    if {$label eq {parent} && $flipflops != 5120} {error {parent inference symptom not reproduced}}
    if {$label eq {candidate} && ($flipflops != 0 || $ram == 0)} {error {way banking did not restore distributed tag RAM}}
    close_project
}
puts $receipt {COMPLETE PROFILES 2 CPU_FMAX_QUALIFIED 0 HARDWARE_ACCEPTANCE 0}
close $receipt
puts {WAY_BANKED_TAG_SYNTHESIS_OK}
