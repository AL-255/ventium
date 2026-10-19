# Tcl-only expansion check. No Vivado, project, synthesis or board access.
if {$argc != 1} {error "usage: repository-root"}
set root [file normalize [lindex $argv 0]]
set ::env(VEN_FPGA_SOURCE_ROOT) $root
set ::env(VEN_FPGA_FLOW_ROOT) [file join $root fpga rk]
set ::env(VEN_FPGA_DEFINE_FILE) [file join $root fpga known_good_defines.txt]
set ::env(VEN_FPGA_CORE_MHZ) 40
set ::env(VEN_FPGA_JOBS) 1
set ::env(VEN_FPGA_BUILD_PROFILE) logic_only
set ::env(VEN_FPGA_SKIP_PRESET) 1
proc set_param {name value} {
    if {$name ne "general.maxThreads" || $value != 1} {error "thread contract"}
}
rename uplevel original_uplevel
proc uplevel {level script} {
    if {$level ne "#0"} {error "unexpected evaluation"}
    set ::expanded $script
}
source [file join $root fpga create_project_3mhz_wrapper.tcl]
if {![info complete $::expanded]} {error "incomplete generated Tcl"}
foreach required [list "set VEN {$root}" "set ROOT {[file join $root fpga rk]}" \
    {set c3f 40000000} \
    {lappend files "$VEN/fpga/ven_programmable_clock.v" "$VEN/fpga/ven_pll_ctrl.sv"} \
    {CONFIG.PSU__GPIO_EMIO_WIDTH {95}} \
    {CONFIG.PSU__SAXIGP2__DATA_WIDTH {128}} \
    {CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100}} \
    {launch_runs synth_1 -jobs 1; wait_on_run synth_1} \
    {launch_runs impl_1 -to_step write_bitstream -jobs 1; wait_on_run impl_1} \
    {STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized} \
    {-no_timing_driven}] {
    if {[string first $required $::expanded] < 0} {error "missing contract: $required"}
}
set fh [open $::env(VEN_FPGA_DEFINE_FILE) r]
set defs [split [string trim [read $fh]] \n]
close $fh
if {[llength $defs] != 159 || ![regexp {set DEFS \{([^\}]*)\}} $::expanded -> actual] || $actual ne [join $defs { }]} {
    error "exact 159-define contract"
}
puts "KNOWN-GOOD-TCL-EXPANSION-OK (not native Vivado acceptance)"
